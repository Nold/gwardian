package com.monadial.ash.domain.entities

import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Message(
    val id: String = UUID.randomUUID().toString(),
    val conversationId: String,
    val content: MessageContent,
    val direction: MessageDirection,
    val timestamp: Long = System.currentTimeMillis(),
    val status: DeliveryStatus = DeliveryStatus.NONE,
    /** Pad offset for deduplication */
    val sequence: Long? = null,
    /** Server blob ID for ACK */
    val blobId: String? = null,
    /** Display TTL (disappearing messages) */
    val expiresAt: Long? = null,
    /** Server TTL (for sent messages awaiting delivery) */
    val serverExpiresAt: Long? = null,
    val isContentWiped: Boolean = false,
    /** Pad bytes this message used from [sequence], to wipe exactly those once it is gone */
    val padLength: Long? = null
) {
    // Computed properties
    val isExpired: Boolean
        get() = expiresAt?.let { System.currentTimeMillis() > it } ?: false

    val remainingTime: Long?
        get() = expiresAt?.let { maxOf(0, it - System.currentTimeMillis()) }

    val serverRemainingTime: Long?
        get() = serverExpiresAt?.let { maxOf(0, it - System.currentTimeMillis()) }

    val isAwaitingDelivery: Boolean
        get() =
            direction == MessageDirection.SENT &&
                (status == DeliveryStatus.SENDING || status == DeliveryStatus.SENT) &&
                serverExpiresAt != null

    val isDelivered: Boolean
        get() = status == DeliveryStatus.DELIVERED

    val isOutgoing: Boolean
        get() = direction == MessageDirection.SENT

    val formattedTime: String
        get() {
            val date = java.util.Date(timestamp)
            val format = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
            return format.format(date)
        }

    val displayContent: String
        get() =
            when {
                isContentWiped -> "[Message Expired]"
                else -> content.displayText
            }

    fun withDeliveryStatus(status: DeliveryStatus): Message = copy(status = status)

    fun withBlobId(blobId: String): Message = copy(blobId = blobId)

    fun withContentWiped(): Message = copy(isContentWiped = true)

    companion object {
        fun outgoing(conversationId: String, text: String, sequence: Long, serverTTLSeconds: Long): Message = Message(
            conversationId = conversationId,
            content = MessageContent.Text(text),
            direction = MessageDirection.SENT,
            status = DeliveryStatus.SENDING,
            sequence = sequence,
            serverExpiresAt = System.currentTimeMillis() + (serverTTLSeconds * 1000)
        )

        fun outgoingLocation(
            conversationId: String,
            latitude: Double,
            longitude: Double,
            sequence: Long,
            serverTTLSeconds: Long
        ): Message = Message(
            conversationId = conversationId,
            content = MessageContent.Location(latitude, longitude),
            direction = MessageDirection.SENT,
            status = DeliveryStatus.SENDING,
            sequence = sequence,
            serverExpiresAt = System.currentTimeMillis() + (serverTTLSeconds * 1000)
        )

        fun incoming(
            conversationId: String,
            content: MessageContent,
            sequence: Long,
            disappearingSeconds: Long?,
            blobId: String
        ): Message = Message(
            conversationId = conversationId,
            content = content,
            direction = MessageDirection.RECEIVED,
            status = DeliveryStatus.NONE,
            sequence = sequence,
            blobId = blobId,
            expiresAt = disappearingSeconds?.let { System.currentTimeMillis() + (it * 1000L) }
        )
    }
}

@Serializable
sealed class MessageContent {
    abstract val displayText: String
    abstract val byteCount: Int

    @Serializable
    @SerialName("text")
    data class Text(val text: String) : MessageContent() {
        override val displayText: String get() = text
        override val byteCount: Int get() = text.toByteArray(Charsets.UTF_8).size
    }

    @Serializable
    @SerialName("location")
    data class Location(val latitude: Double, val longitude: Double) : MessageContent() {
        override val displayText: String
            get() = "📍 Location: %.6f, %.6f".format(latitude, longitude)

        override val byteCount: Int
            get() = toEncodedString().toByteArray(Charsets.UTF_8).size

        // Locale.ROOT: a French phone would otherwise write "48,856600", which
        // no phone can read back
        fun toEncodedString(): String = String.format(java.util.Locale.ROOT, "LOC:%.6f,%.6f", latitude, longitude)

        companion object {
            fun fromEncodedString(encoded: String): Location? {
                if (!encoded.startsWith("LOC:")) return null
                val parts = encoded.removePrefix("LOC:").split(",")
                if (parts.size != 2) return null
                return try {
                    Location(parts[0].toDouble(), parts[1].toDouble())
                } catch (e: NumberFormatException) {
                    null
                }
            }
        }
    }

    companion object {
        fun fromBytes(bytes: ByteArray): MessageContent {
            val text = bytes.toString(Charsets.UTF_8)
            // Check if it's a location message
            if (text.startsWith("LOC:")) {
                Location.fromEncodedString(text)?.let { return it }
            }
            return Text(text)
        }

        fun toBytes(content: MessageContent): ByteArray = when (content) {
            is Text -> content.text.toByteArray(Charsets.UTF_8)
            is Location -> content.toEncodedString().toByteArray(Charsets.UTF_8)
        }
    }
}

@Serializable
enum class MessageDirection {
    SENT,
    RECEIVED
}

@Serializable
sealed class DeliveryStatus {
    @Serializable
    @SerialName("none")
    data object NONE : DeliveryStatus()

    @Serializable
    @SerialName("sending")
    data object SENDING : DeliveryStatus()

    @Serializable
    @SerialName("sent")
    data object SENT : DeliveryStatus()

    @Serializable
    @SerialName("delivered")
    data object DELIVERED : DeliveryStatus()

    @Serializable
    @SerialName("failed")
    data class FAILED(val reason: String? = null) : DeliveryStatus()

    val isFailed: Boolean
        get() = this is FAILED

    val displayName: String
        get() =
            when (this) {
                NONE -> ""
                SENDING -> "Sending..."
                SENT -> "Sent"
                DELIVERED -> "Delivered"
                is FAILED -> "Failed"
            }
}
