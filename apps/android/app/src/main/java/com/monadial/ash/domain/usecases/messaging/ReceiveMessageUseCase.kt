package com.monadial.ash.domain.usecases.messaging

import android.util.Log
import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.ConversationRole
import com.monadial.ash.domain.entities.Message
import com.monadial.ash.domain.entities.MessageContent
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.services.AUTH_KEY_BYTES
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.FRAME_OVERHEAD_BYTES
import com.monadial.ash.domain.services.MessageTypes
import javax.inject.Inject
import uniffi.ash.decodeDeleteRequest
import uniffi.ash.decodeExpiringText

private const val TAG = "ReceiveMessageUseCase"

/**
 * Input data for receiving a message.
 */
data class ReceivedMessageData(
    val id: String,
    val ciphertext: ByteArray,
    val sequence: Long?,
    val receivedAt: String
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as ReceivedMessageData
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()
}

/**
 * Result of processing a received message.
 */
sealed class ReceiveMessageResult {
    data class Success(
        val message: Message,
        val updatedConversation: Conversation
    ) : ReceiveMessageResult()

    /** The peer asks to delete its own message with this sequence. */
    data class DeleteRequest(
        val sequence: Long,
        val updatedConversation: Conversation
    ) : ReceiveMessageResult()

    /** Consumed, nothing to show (malformed control content from the peer). */
    data class Ignored(val updatedConversation: Conversation) : ReceiveMessageResult()

    data class Skipped(val reason: String) : ReceiveMessageResult()
    data class Error(val error: AppError) : ReceiveMessageResult()
}

/**
 * Use case for receiving and decrypting messages.
 *
 * Encapsulates the receive flow:
 * 1. Validate sequence number
 * 2. Check for own message / already processed
 * 3. Get key bytes for decryption
 * 4. Decrypt ciphertext using OTP
 * 5. Parse message content
 * 6. Update peer consumption state
 * 7. Update conversation state
 *
 * This follows Single Responsibility Principle by handling only message receiving.
 */
class ReceiveMessageUseCase @Inject constructor(
    private val conversationRepository: ConversationRepository,
    private val padRepository: PadRepository,
    private val cryptoService: CryptoService
) {

    /**
     * Process a received encrypted message.
     *
     * @param conversation The conversation this message belongs to
     * @param received The received message data (ciphertext, sequence, etc.)
     * @return Result containing the decrypted message and updated conversation, or skip/error
     */
    suspend operator fun invoke(
        conversation: Conversation,
        received: ReceivedMessageData
    ): ReceiveMessageResult {
        val logId = conversation.id.take(8)

        // 1. Validate sequence
        val senderOffset = received.sequence
        if (senderOffset == null) {
            Log.w(TAG, "[$logId] Received message without sequence, skipping")
            return ReceiveMessageResult.Skipped("No sequence number")
        }

        // 2. Check if this is our OWN sent message (must skip to avoid corrupting peerConsumed)
        val isOwnMessage = when (conversation.role) {
            ConversationRole.INITIATOR -> {
                // Initiator sends from [0, sendOffset) - messages in this range are ours
                senderOffset < conversation.sendOffset
            }
            ConversationRole.RESPONDER -> {
                // Responder sends from [totalBytes - sendOffset, totalBytes)
                senderOffset >= conversation.padTotalSize - conversation.sendOffset
            }
        }

        if (isOwnMessage) {
            Log.d(TAG, "[$logId] Skipping own sent message seq=$senderOffset")
            return ReceiveMessageResult.Skipped("Own message echo")
        }

        // 3. Check if already processed
        if (conversation.hasProcessedIncomingSequence(senderOffset)) {
            Log.d(TAG, "[$logId] Skipping already-processed message seq=$senderOffset")
            return ReceiveMessageResult.Skipped("Already processed")
        }

        Log.d(TAG, "[$logId] Processing: ${received.ciphertext.size} bytes, seq=$senderOffset")

        // 4. Pad range of an authenticated frame: auth key, then encryption key
        val plaintextLength = received.ciphertext.size - FRAME_OVERHEAD_BYTES
        if (plaintextLength <= 0) {
            Log.w(TAG, "[$logId] Frame too short: ${received.ciphertext.size} bytes")
            return ReceiveMessageResult.Error(AppError.Validation("Frame too short"))
        }
        val padLength = AUTH_KEY_BYTES + plaintextLength
        if (senderOffset < 0 || senderOffset + padLength > conversation.padTotalSize) {
            return ReceiveMessageResult.Error(AppError.Validation("Invalid pad offset"))
        }

        // Key bytes for decryption (does NOT update consumption state)
        val keyBytes = when (val result = padRepository.getBytesForDecryption(conversation.id, senderOffset, padLength)) {
            is AppResult.Error -> {
                Log.e(TAG, "[$logId] Failed to get key bytes: ${result.error.message}")
                return ReceiveMessageResult.Error(result.error)
            }
            is AppResult.Success -> result.data
        }

        // 5. Verify and decrypt: an altered frame is rejected before any state changes
        val frame = try {
            cryptoService.decryptAuthenticated(
                authKey = keyBytes.copyOfRange(0, AUTH_KEY_BYTES),
                encryptionKey = keyBytes.copyOfRange(AUTH_KEY_BYTES, keyBytes.size),
                frame = received.ciphertext
            )
        } catch (e: Exception) {
            Log.e(TAG, "[$logId] Authentication or decryption failed: ${e.message}")
            return ReceiveMessageResult.Error(AppError.Crypto.DecryptionFailed("Decryption failed: ${e.message}", e))
        }

        // 6. Decode before committing state, so nothing fails after it. The
        // author chooses each text's lifetime; plain text does not disappear.
        // Locations keep the conversation's setting.
        val decoded: Decoded = when (frame.msgType) {
            MessageTypes.DELETE -> runCatching { decodeDeleteRequest(frame.plaintext.toUBytes()).toLong() }
                .map { Decoded.Delete(it) }.getOrDefault(Decoded.Ignored)
            MessageTypes.EXPIRING_TEXT -> runCatching { decodeExpiringText(frame.plaintext.toUBytes()) }
                .map { Decoded.Content(MessageContent.Text(it.text), it.seconds.toLong()) }.getOrDefault(Decoded.Ignored)
            MessageTypes.LOCATION -> Decoded.Content(
                MessageContent.fromBytes(frame.plaintext),
                conversation.disappearingMessages.seconds?.toLong()
            )
            MessageTypes.TEXT -> Decoded.Content(MessageContent.Text(frame.plaintext.decodeToString()), null)
            else -> Decoded.Ignored
        }

        // 7. Update peer consumption tracking
        // - If I'm initiator (peer is responder): peerConsumed = totalBytes - sequence
        // - If I'm responder (peer is initiator): peerConsumed = sequence + length
        val peerRole = if (conversation.role == ConversationRole.INITIATOR) {
            ConversationRole.RESPONDER
        } else {
            ConversationRole.INITIATOR
        }
        val consumedAmount = if (conversation.role == ConversationRole.INITIATOR) {
            conversation.padTotalSize - senderOffset
        } else {
            senderOffset + padLength
        }
        Log.d(TAG, "[$logId] Updating peer consumption: peerRole=$peerRole, consumed=$consumedAmount")
        padRepository.updatePeerConsumption(conversation.id, peerRole, consumedAmount)

        // 8. Update conversation state and persist
        val updatedConv = conversation.afterReceiving(senderOffset, padLength.toLong())
        conversationRepository.saveConversation(updatedConv)
        Log.d(TAG, "[$logId] Conversation state saved. Remaining=${updatedConv.remainingBytes}")

        return when (decoded) {
            is Decoded.Delete -> ReceiveMessageResult.DeleteRequest(decoded.sequence, updatedConv)
            Decoded.Ignored -> {
                Log.w(TAG, "[$logId] Malformed message content ignored")
                ReceiveMessageResult.Ignored(updatedConv)
            }
            is Decoded.Content -> {
                Log.i(TAG, "[$logId] Decrypted message, seq=$senderOffset")
                val message = Message.incoming(
                    conversationId = conversation.id,
                    content = decoded.content,
                    sequence = senderOffset,
                    disappearingSeconds = decoded.lifetimeSeconds,
                    blobId = received.id
                ).copy(padLength = padLength.toLong())
                ReceiveMessageResult.Success(message, updatedConv)
            }
        }
    }

    private sealed interface Decoded {
        data class Content(val content: MessageContent, val lifetimeSeconds: Long?) : Decoded
        data class Delete(val sequence: Long) : Decoded
        data object Ignored : Decoded
    }

    private fun ByteArray.toUBytes(): List<UByte> = map { it.toUByte() }
}
