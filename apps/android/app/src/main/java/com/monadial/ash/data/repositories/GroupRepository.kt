package com.monadial.ash.data.repositories

import java.util.Base64
import com.monadial.ash.core.services.ConversationStorageService
import com.monadial.ash.domain.entities.GroupConversation
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import uniffi.ash.MemberPadState
import uniffi.ash.PadGroup
import uniffi.ash.SecurityLevel
import uniffi.ash.UsedRange

/** Serializable copy of the generated `MemberPadState`. */
@Serializable
internal data class StoredMemberPad(
    val member: Int,
    val pad: String,
    val used: List<List<Long>>,
    val checksums: List<Long>,
    val level: String
) {
    fun toState() = MemberPadState(
        member = member.toUByte(),
        pad = Base64.getDecoder().decode(pad).map { it.toUByte() },
        used = used.filter { it.size == 2 }.map { UsedRange(it[0].toULong(), it[1].toULong()) },
        checksums = checksums.map { it.toUInt() },
        level = when (level) {
            "maximum" -> SecurityLevel.MAXIMUM
            "enhanced" -> SecurityLevel.ENHANCED
            else -> SecurityLevel.STANDARD
        }
    )

    companion object {
        fun from(state: MemberPadState) = StoredMemberPad(
            member = state.member.toInt(),
            pad = Base64.getEncoder().encodeToString(state.pad.map { it.toByte() }.toByteArray()),
            used = state.used.map { listOf(it.start.toLong(), it.end.toLong()) },
            checksums = state.checksums.map { it.toLong() },
            level = when (state.level) {
                SecurityLevel.MAXIMUM -> "maximum"
                SecurityLevel.ENHANCED -> "enhanced"
                SecurityLevel.STANDARD -> "standard"
            }
        )
    }
}

/**
 * Group conversations and their pads, sealed with the vault key like
 * two-person conversations. Pads are saved after every send and receive.
 */
@Singleton
class GroupRepository @Inject constructor(
    private val storage: ConversationStorageService
) {
    // Nothing is cached here: decrypted groups live in the view models,
    // which are cleared when the app locks
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun load(): List<GroupConversation> = storage.getAllSealed(GROUP_PREFIX)
        .mapNotNull { runCatching { json.decodeFromString<GroupConversation>(it) }.getOrNull() }
        .sortedByDescending { it.createdAt }

    suspend fun save(group: GroupConversation) {
        storage.putSealed(GROUP_PREFIX + group.id, json.encodeToString(group))
    }

    suspend fun savePads(groupId: String, states: List<MemberPadState>) {
        storage.putSealed(PADS_PREFIX + groupId, json.encodeToString(states.map(StoredMemberPad::from)))
    }

    /** Null when the pads are missing or unreadable. */
    suspend fun loadPads(group: GroupConversation): PadGroup? {
        val stored = storage.getSealed(PADS_PREFIX + group.id) ?: return null
        val states = json.decodeFromString<List<StoredMemberPad>>(stored).map { it.toState() }
        return PadGroup.restore(group.me.toUByte(), states)
    }

    suspend fun delete(groupId: String) {
        storage.removeSealed(GROUP_PREFIX + groupId, PADS_PREFIX + groupId)
    }

    companion object {
        private const val GROUP_PREFIX = "group_"
        private const val PADS_PREFIX = "grouppads_"
    }
}
