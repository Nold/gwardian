package com.monadial.ash.domain.usecases.conversation

import android.util.Log
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.domain.entities.Conversation
import com.monadial.ash.domain.services.RelayService
import javax.inject.Inject

private const val TAG = "RegisterConversationUseCase"

/**
 * Use case for registering a conversation with the relay server.
 *
 * This consolidates the registration logic from:
 * - MessagingViewModel.registerConversationWithRelay()
 * - InitiatorCeremonyViewModel.registerConversationWithRelay()
 * - ReceiverCeremonyViewModel.registerConversationWithRelay()
 *
 * Registration involves:
 * 1. Hashing auth and burn tokens
 * 2. Sending registration request to relay
 */
class RegisterConversationUseCase @Inject constructor(
    private val relayService: RelayService
) {
    /**
     * Registers a conversation with the relay server.
     *
     * @param conversation The conversation to register
     * @return Success(true) if registered, Success(false) if registration failed but not critical
     */
    suspend operator fun invoke(conversation: Conversation): AppResult<Boolean> {
        return try {
            val authTokenHash = relayService.hashToken(conversation.authToken)
            val burnTokenHash = relayService.hashToken(conversation.burnToken)

            val result = relayService.registerConversation(
                conversationId = conversation.id,
                authTokenHash = authTokenHash,
                burnTokenHash = burnTokenHash,
                relayUrl = conversation.relayUrl,
                ttlSeconds = conversation.messageRetention.seconds
            )

            when (result) {
                is AppResult.Success -> {
                    Log.d(TAG, "[${conversation.id.take(8)}] Conversation registered with relay")
                    AppResult.Success(true)
                }
                is AppResult.Error -> {
                    Log.w(TAG, "[${conversation.id.take(8)}] Failed to register: ${result.error.message}")
                    AppResult.Success(false)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "[${conversation.id.take(8)}] Failed to register: ${e.message}")
            AppResult.Success(false)
        }
    }
}
