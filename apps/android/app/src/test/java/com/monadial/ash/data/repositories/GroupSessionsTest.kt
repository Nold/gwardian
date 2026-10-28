package com.monadial.ash.data.repositories

import com.google.common.truth.Truth.assertThat
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.domain.entities.GroupMember
import com.monadial.ash.domain.entities.MessageRetention
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import uniffi.ash.MemberPadState
import uniffi.ash.PadGroup
import uniffi.ash.SecurityLevel
import uniffi.ash.getMaxGroupMembers

/** The single shared copy of a group's pads. */
class GroupSessionsTest {

    @BeforeEach
    fun requireNativeLibrary() {
        assumeTrue(runCatching { getMaxGroupMembers() }.isSuccess, "host Rust bindings not built")
    }

    private fun pad(seed: Int) = List(8192) { ((it * 31) xor seed).toUByte() }

    private fun group(me: Int) = GroupConversation(
        id = "g", authToken = "a", burnToken = "b", relayUrl = "https://relay.example", me = me,
        members = listOf(GroupMember(0, "Léa"), GroupMember(1, "Sam")), createdAt = 0,
        messageRetention = MessageRetention.ONE_DAY, disappearingMessages = DisappearingMessages.OFF,
        color = ConversationColor.TEAL, isFamilyConversation = false
    )

    /** A repository holding member [me]'s view of a two-member group. */
    private fun repository(me: Int, saved: MutableMap<String, List<MemberPadState>>, failSaves: () -> Boolean = { false }) =
        mockk<GroupRepository>().also { repo ->
            val padGroup = PadGroup(me.toUByte(), pad(me), SecurityLevel.MAXIMUM)
            padGroup.addMember((1 - me).toUByte(), pad(1 - me), SecurityLevel.MAXIMUM)
            saved["g"] = padGroup.exportState()
            coEvery { repo.loadPads(any()) } answers {
                saved["g"]?.let { PadGroup.restore(me.toUByte(), it) }
            }
            coEvery { repo.savePads(any(), any()) } answers {
                if (failSaves()) throw IllegalStateException("vault locked")
                saved[firstArg<String>()] = secondArg<List<MemberPadState>>()
            }
            coEvery { repo.delete(any()) } answers {
                saved.remove(firstArg<String>())
                Unit
            }
        }

    private fun text(outcome: GroupReadOutcome) =
        (outcome as GroupReadOutcome.Message).message.plaintext.map { it.toByte() }.toByteArray().decodeToString()

    @Test
    @DisplayName("Messages read once, then as duplicates")
    fun readOnce() = runTest {
        val sender = GroupSessions(repository(0, mutableMapOf()))
        val reader = GroupSessions(repository(1, mutableMapOf()))
        val first = sender.encrypt(group(0), 1u, "one")
        val second = sender.encrypt(group(0), 1u, "two")

        assertThat(reader.read(group(1), listOf(first, second)) { it.map(::text) }).containsExactly("one", "two").inOrder()
        assertThat(reader.read(group(1), listOf(first)) { it }).containsExactly(GroupReadOutcome.Duplicate)
    }

    @Test
    @DisplayName("Nothing is delivered when the pads cannot be saved")
    fun failedSave() = runTest {
        val frame = GroupSessions(repository(0, mutableMapOf())).encrypt(group(0), 1u, "x")
        var failing = false
        val reader = GroupSessions(repository(1, mutableMapOf()) { failing })
        reader.open(group(1))
        failing = true

        var delivered = false
        assertThrows<IllegalStateException> { reader.read(group(1), listOf(frame)) { delivered = true } }
        assertThat(delivered).isFalse()
    }

    @Test
    @DisplayName("A deleted group is never written back")
    fun deleted() = runTest {
        val saved = mutableMapOf<String, List<MemberPadState>>()
        val sessions = GroupSessions(repository(0, saved))
        sessions.open(group(0))
        sessions.delete("g")

        assertThrows<GroupDeletedException> { sessions.encrypt(group(0), 1u, "x") }
        assertThat(saved).doesNotContainKey("g")
    }
}
