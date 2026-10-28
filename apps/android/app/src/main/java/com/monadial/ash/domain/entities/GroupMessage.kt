package com.monadial.ash.domain.entities

import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** A decrypted group message, kept in memory only. */
data class GroupChatMessage(
    val id: String = UUID.randomUUID().toString(),
    /** Member index of the author */
    val sender: Int,
    val text: String,
    val timestamp: Long,
    val status: Status,
    /** Set for disappearing messages */
    val expiresAt: Long? = null
) {
    enum class Status { SENDING, SENT, FAILED, RECEIVED }

    val isOutgoing: Boolean get() = status != Status.RECEIVED
}

/**
 * Decrypted group messages for this app session. Nothing is written to disk;
 * everything is gone when the app process ends or the group is deleted.
 */
@Singleton
class GroupMessageStore @Inject constructor() {
    private val _messages = MutableStateFlow<Map<String, List<GroupChatMessage>>>(emptyMap())
    val messages: StateFlow<Map<String, List<GroupChatMessage>>> = _messages.asStateFlow()

    fun append(groupId: String, message: GroupChatMessage) =
        _messages.update { it + (groupId to (it[groupId].orEmpty() + message)) }

    fun update(groupId: String, id: String, change: (GroupChatMessage) -> GroupChatMessage) =
        _messages.update { all ->
            all + (groupId to all[groupId].orEmpty().map { if (it.id == id) change(it) else it })
        }

    /** Drop disappearing messages whose time is up. */
    fun removeExpired(groupId: String, now: Long = System.currentTimeMillis()) =
        _messages.update { all ->
            val kept = all[groupId].orEmpty().filter { (it.expiresAt ?: Long.MAX_VALUE) > now }
            if (kept.size == all[groupId]?.size) all else all + (groupId to kept)
        }

    fun clear(groupId: String) = _messages.update { it - groupId }

    fun clearAll() = _messages.update { emptyMap() }
}
