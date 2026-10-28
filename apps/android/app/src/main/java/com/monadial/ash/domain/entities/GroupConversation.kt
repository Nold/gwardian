package com.monadial.ash.domain.entities

import kotlinx.serialization.Serializable

/** A member of a group; index 0 created it. */
@Serializable
data class GroupMember(val index: Int, val name: String)

/**
 * A group conversation: every member sends with their own pad and holds a
 * copy of everyone else's (core/src/group.rs, docs/group-ceremony.md).
 */
@Serializable
data class GroupConversation(
    /** Relay conversation ID, derived from member 0's pad */
    val id: String,
    val authToken: String,
    val burnToken: String,
    val relayUrl: String,
    /** This device's member index */
    val me: Int,
    val members: List<GroupMember>,
    val createdAt: Long,
    val messageRetention: MessageRetention,
    val disappearingMessages: DisappearingMessages,
    val color: ConversationColor,
    /** Created at home: the six words started off */
    val isFamilyConversation: Boolean
) {
    val others: List<GroupMember> get() = members.filter { it.index != me }

    /** "Léa, Sam and Noé" */
    val displayName: String
        get() {
            val names = others.map { it.name.ifBlank { "Member ${it.index + 1}" } }
            return when (names.size) {
                0 -> "Group"
                1 -> names[0]
                else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
            }
        }

    fun nameOf(index: Int): String = members.firstOrNull { it.index == index }?.name ?: "Member ${index + 1}"
}
