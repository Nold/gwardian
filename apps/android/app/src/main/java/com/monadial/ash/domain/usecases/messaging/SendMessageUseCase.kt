package com.monadial.ash.domain.usecases.messaging

import android.util.Log
import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.entities.ConversationRole
import com.monadial.ash.domain.entities.DeliveryStatus
import com.monadial.ash.domain.entities.Message
import com.monadial.ash.domain.entities.MessageContent
import com.monadial.ash.domain.entities.MessageDirection
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.services.AUTH_KEY_BYTES
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.MessageTypes
import com.monadial.ash.domain.services.RelayService
import javax.inject.Inject
import uniffi.ash.encodeDeleteRequest
import uniffi.ash.encodeExpiringText

private const val TAG = "SendMessageUseCase"

/**
 * Result of a successful message send operation.
 */
data class SendMessageResult(
    val message: Message,
    val blobId: String,
    val sequence: Long,
    val updatedConversation: Conversation
)

/** A frame encrypted and recorded, ready for the relay. */
private data class EncryptedFrame(
    val ciphertext: ByteArray,
    val sequence: Long,
    val padLength: Long,
    val updatedConversation: Conversation
)

/**
 * Use case for sending encrypted messages, as authenticated frames shared
 * with iOS (core `MessageFrame`): the pad range of a message holds a 64-byte
 * authentication key, then the encryption key.
 *
 * 1. Check the pad, compute the sequence (offset where the keys start)
 * 2. Consume the pad bytes and save the conversation
 * 3. Encrypt and authenticate
 * 4. Submit to the relay
 */
class SendMessageUseCase @Inject constructor(
    private val conversationRepository: ConversationRepository,
    private val padRepository: PadRepository,
    private val cryptoService: CryptoService,
    private val relayService: RelayService
) {

    /**
     * Send a message in a conversation.
     *
     * @param lifetimeSeconds text only: seconds the message stays on the other
     * phone once shown, chosen by its author; null means it does not disappear
     */
    suspend operator fun invoke(
        conversation: Conversation,
        content: MessageContent,
        lifetimeSeconds: Int? = null
    ): AppResult<SendMessageResult> {
        val (msgType, payload) = when {
            content is MessageContent.Text && lifetimeSeconds != null ->
                MessageTypes.EXPIRING_TEXT to encodeExpiringText(lifetimeSeconds.toUInt(), content.text)
                    .map { it.toByte() }.toByteArray()
            content is MessageContent.Location -> MessageTypes.LOCATION to MessageContent.toBytes(content)
            else -> MessageTypes.TEXT to MessageContent.toBytes(content)
        }

        val frame = when (val result = encrypt(conversation, msgType, payload)) {
            is AppResult.Error -> return result
            is AppResult.Success -> result.data
        }
        val blobId = when (val result = submit(conversation, frame)) {
            is AppResult.Error -> return result
            is AppResult.Success -> result.data
        }

        val now = System.currentTimeMillis()
        val message = Message(
            conversationId = conversation.id,
            content = content,
            direction = MessageDirection.SENT,
            status = DeliveryStatus.SENT,
            sequence = frame.sequence,
            blobId = blobId,
            // The author's chosen lifetime applies on this phone too
            expiresAt = lifetimeSeconds?.let { now + it * 1_000L },
            serverExpiresAt = now + (conversation.messageRetention.seconds * 1000L),
            padLength = frame.padLength
        )
        return AppResult.Success(SendMessageResult(message, blobId, frame.sequence, frame.updatedConversation))
    }

    /**
     * Ask the other phone to delete one of this phone's messages, by its
     * sequence. A request: a modified app or an earlier screenshot can keep it.
     */
    suspend fun deleteForEveryone(conversation: Conversation, sequence: Long): AppResult<Conversation> {
        val payload = encodeDeleteRequest(sequence.toULong()).map { it.toByte() }.toByteArray()
        val frame = when (val result = encrypt(conversation, MessageTypes.DELETE, payload)) {
            is AppResult.Error -> return result
            is AppResult.Success -> result.data
        }
        return when (val result = submit(conversation, frame)) {
            is AppResult.Error -> result
            is AppResult.Success -> AppResult.Success(frame.updatedConversation)
        }
    }

    /** Consume the pad range of [payload], save the conversation, then encrypt. */
    private suspend fun encrypt(conversation: Conversation, msgType: Int, payload: ByteArray): AppResult<EncryptedFrame> {
        val logId = conversation.id.take(8)
        val padLength = AUTH_KEY_BYTES + payload.size

        // 1. Check if we can send
        when (val canSend = padRepository.canSend(conversation.id, padLength, conversation.role)) {
            is AppResult.Error -> return canSend
            is AppResult.Success -> if (!canSend.data) {
                Log.w(TAG, "[$logId] Pad exhausted - cannot send")
                return AppResult.Error(AppError.Pad.Exhausted)
            }
        }

        // 2. Sequence: offset where the keys start
        // - Initiator: at consumed_front (nextSendOffset)
        // - Responder: at total_size - consumed_back - pad_length
        val sequenceResult = if (conversation.role == ConversationRole.RESPONDER) {
            when (val state = padRepository.getPadState(conversation.id)) {
                is AppResult.Error -> return state
                is AppResult.Success -> AppResult.Success(state.data.totalBytes - state.data.consumedBack - padLength)
            }
        } else {
            padRepository.nextSendOffset(conversation.id, conversation.role)
        }
        val sequence = when (sequenceResult) {
            is AppResult.Error -> return sequenceResult
            is AppResult.Success -> sequenceResult.data
        }

        // 3. Consume pad bytes (updates state): auth key, then encryption key
        val keyBytes = when (val result = padRepository.consumeForSending(conversation.id, padLength, conversation.role)) {
            is AppResult.Error -> return result
            is AppResult.Success -> result.data
        }

        val updatedConv = conversation.afterSending(padLength.toLong())
        if (conversationRepository.saveConversation(updatedConv) is AppResult.Error) {
            Log.e(TAG, "[$logId] Failed to save conversation state")
        }

        // 4. Encrypt and authenticate
        val ciphertext = try {
            cryptoService.encryptAuthenticated(
                authKey = keyBytes.copyOfRange(0, minOf(AUTH_KEY_BYTES, keyBytes.size)),
                encryptionKey = keyBytes.copyOfRange(minOf(AUTH_KEY_BYTES, keyBytes.size), keyBytes.size),
                plaintext = payload,
                msgType = msgType
            )
        } catch (e: Exception) {
            Log.e(TAG, "[$logId] Encryption failed: ${e.message}")
            return AppResult.Error(AppError.Crypto.EncryptionFailed("Encryption failed: ${e.message}", e))
        }
        Log.d(TAG, "[$logId] Encrypted: type=$msgType, ${payload.size} → ${ciphertext.size} bytes, seq=$sequence")
        return AppResult.Success(EncryptedFrame(ciphertext, sequence, padLength.toLong(), updatedConv))
    }

    private suspend fun submit(conversation: Conversation, frame: EncryptedFrame): AppResult<String> {
        val logId = conversation.id.take(8)
        val result = relayService.submitMessage(
            conversationId = conversation.id,
            authToken = conversation.authToken,
            ciphertext = frame.ciphertext,
            sequence = frame.sequence,
            ttlSeconds = conversation.messageRetention.seconds,
            relayUrl = conversation.relayUrl
        )
        return when (result) {
            is AppResult.Error -> {
                Log.e(TAG, "[$logId] Send failed: ${result.error.message}")
                result
            }
            is AppResult.Success -> {
                val blobId = result.data.blobId
                    ?: return AppResult.Error(AppError.Relay.SubmitFailed("No blob ID returned"))
                Log.i(TAG, "[$logId] Sent: blobId=${blobId.take(8)}")
                AppResult.Success(blobId)
            }
        }
    }
}
