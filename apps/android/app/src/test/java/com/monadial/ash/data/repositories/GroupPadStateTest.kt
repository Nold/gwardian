package com.monadial.ash.data.repositories

import com.google.common.truth.Truth.assertThat
import com.monadial.ash.domain.entities.ConversationColor
import com.monadial.ash.domain.entities.DisappearingMessages
import com.monadial.ash.domain.entities.GroupConversation
import com.monadial.ash.domain.entities.GroupMember
import com.monadial.ash.domain.entities.MessageRetention
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import uniffi.ash.GroupMemberCard
import uniffi.ash.PadGroup
import uniffi.ash.SecurityLevel
import uniffi.ash.decodeMemberCard
import uniffi.ash.encodeMemberCard
import uniffi.ash.getMaxGroupMembers

/** Group cards and pads stored and restored as after a ceremony. */
class GroupPadStateTest {

    @BeforeEach
    fun requireNativeLibrary() {
        assumeTrue(runCatching { getMaxGroupMembers() }.isSuccess, "host Rust bindings not built")
    }

    private fun pad(seed: Int, size: Int = 8192): List<UByte> = List(size) { ((it * 31) xor seed).toUByte() }

    private fun formGroup(me: Int, count: Int): PadGroup {
        val group = PadGroup(me.toUByte(), pad(me), SecurityLevel.MAXIMUM)
        for (other in 0 until count) {
            if (other != me) group.addMember(other.toUByte(), pad(other), SecurityLevel.MAXIMUM)
        }
        return group
    }

    @Test
    @DisplayName("A member card survives encoding")
    fun memberCardRoundTrip() {
        val card = GroupMemberCard(2u, 4u, "Noé", pad(2, 64))
        assertThat(decodeMemberCard(encodeMemberCard(card))).isEqualTo(card)
        assertThat(getMaxGroupMembers().toInt()).isEqualTo(8)
    }

    @Test
    @DisplayName("Every member derives the same relay tokens")
    fun sameTokens() {
        val tokens = (0 until 3).map { formGroup(it, 3).takeRelayTokens() }
        assertThat(tokens.map { it.conversationId }.toSet()).hasSize(1)
        assertThat(tokens.map { it.authToken }.toSet()).hasSize(1)
    }

    @Test
    @DisplayName("Stored pads keep sending where they stopped")
    fun padsSurviveStorage() {
        val json = Json { ignoreUnknownKeys = true }
        val alice = formGroup(0, 3)
        val sam = formGroup(1, 3)
        alice.takeRelayTokens()
        sam.takeRelayTokens()

        val first = alice.encrypt(1u, "one".encodeToByteArray().map { it.toUByte() })
        val stored = json.encodeToString(alice.exportState().map(StoredMemberPad::from))
        val restored = PadGroup.restore(0u, json.decodeFromString<List<StoredMemberPad>>(stored).map { it.toState() })
        val second = restored.encrypt(1u, "two".encodeToByteArray().map { it.toUByte() })

        assertThat(sam.decrypt(first).plaintext.map { it.toByte() }.toByteArray().decodeToString()).isEqualTo("one")
        assertThat(sam.decrypt(second).plaintext.map { it.toByte() }.toByteArray().decodeToString()).isEqualTo("two")
    }

    @Test
    @DisplayName("Display name lists the other members")
    fun displayName() {
        val group = GroupConversation(
            id = "id", authToken = "a", burnToken = "b", relayUrl = "https://relay.example", me = 0,
            members = listOf(GroupMember(0, "Léa"), GroupMember(1, "Sam"), GroupMember(2, "Noé")),
            createdAt = 0, messageRetention = MessageRetention.ONE_DAY,
            disappearingMessages = DisappearingMessages.OFF, color = ConversationColor.TEAL,
            isFamilyConversation = true
        )
        assertThat(group.displayName).isEqualTo("Sam and Noé")
        val json = Json { ignoreUnknownKeys = true }
        assertThat(json.decodeFromString<GroupConversation>(json.encodeToString(group))).isEqualTo(group)
    }
}
