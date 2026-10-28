package com.monadial.ash.data.services

import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.core.services.BurnStatusResponse
import com.monadial.ash.core.services.ConnectionTestResult
import com.monadial.ash.core.services.HealthResponse
import com.monadial.ash.core.services.PollResult
import com.monadial.ash.core.services.SendResult
import com.monadial.ash.domain.services.RelayService
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton
import com.monadial.ash.core.services.RelayService as CoreRelayService

/**
 * Implementation of RelayService that delegates to the core RelayService.
 * Converts kotlin.Result to AppResult for consistent error handling.
 */
@Singleton
class RelayServiceImpl @Inject constructor(
    private val coreRelayService: CoreRelayService
) : RelayService {

    override suspend fun checkHealth(relayUrl: String?): AppResult<HealthResponse> {
        return coreRelayService.checkHealth(relayUrl).toAppResult()
    }

    override suspend fun testConnection(relayUrl: String): ConnectionTestResult {
        return coreRelayService.testConnection(relayUrl)
    }

    override suspend fun submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: ByteArray,
        sequence: Long?,
        ttlSeconds: Long?,
        extendedTTL: Boolean,
        persistent: Boolean,
        relayUrl: String?,
        sender: Int?
    ): AppResult<SendResult> {
        val result = coreRelayService.submitMessage(
            conversationId = conversationId,
            authToken = authToken,
            ciphertext = ciphertext,
            sequence = sequence,
            ttlSeconds = ttlSeconds,
            extendedTTL = extendedTTL,
            persistent = persistent,
            relayUrl = relayUrl,
            sender = sender
        )
        return if (result.success) {
            AppResult.Success(result)
        } else {
            AppResult.Error(
                AppError.Relay.SubmitFailed(result.error ?: "Unknown submit error")
            )
        }
    }

    override suspend fun fetchMessages(
        conversationId: String,
        authToken: String,
        cursor: String?,
        relayUrl: String?,
        member: Int?
    ): AppResult<PollResult> {
        val result = coreRelayService.fetchMessages(
            conversationId = conversationId,
            authToken = authToken,
            cursor = cursor,
            relayUrl = relayUrl,
            member = member
        )
        return if (result.success) {
            if (result.burned) {
                AppResult.Error(AppError.Relay.ConversationBurned)
            } else {
                AppResult.Success(result)
            }
        } else {
            AppResult.Error(
                AppError.Network.ConnectionFailed(result.error ?: "Failed to fetch messages")
            )
        }
    }

    override fun pollMessages(
        conversationId: String,
        authToken: String,
        cursor: String?,
        relayUrl: String?
    ): Flow<PollResult> {
        return coreRelayService.pollMessages(conversationId, authToken, cursor, relayUrl)
    }

    override suspend fun acknowledgeMessages(
        conversationId: String,
        authToken: String,
        blobIds: List<String>,
        relayUrl: String?,
        member: Int?
    ): AppResult<Int> {
        return coreRelayService.acknowledgeMessages(
            conversationId = conversationId,
            authToken = authToken,
            blobIds = blobIds,
            relayUrl = relayUrl,
            member = member
        ).toAppResult()
    }

    override suspend fun registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String,
        relayUrl: String?,
        ttlSeconds: Long?,
        members: Int
    ): AppResult<Unit> {
        return coreRelayService.registerConversation(
            conversationId = conversationId,
            authTokenHash = authTokenHash,
            burnTokenHash = burnTokenHash,
            relayUrl = relayUrl,
            ttlSeconds = ttlSeconds,
            members = members
        ).fold(
            onSuccess = { AppResult.Success(Unit) },
            onFailure = { AppResult.Error(AppError.Relay.RegistrationFailed) }
        )
    }

    override suspend fun registerDevice(
        conversationId: String,
        authToken: String,
        deviceToken: String,
        relayUrl: String?
    ): AppResult<Unit> {
        return coreRelayService.registerDevice(
            conversationId = conversationId,
            authToken = authToken,
            deviceToken = deviceToken,
            relayUrl = relayUrl
        ).toAppResult()
    }

    override suspend fun burnConversation(
        conversationId: String,
        burnToken: String,
        relayUrl: String?
    ): AppResult<Unit> {
        return coreRelayService.burnConversation(
            conversationId = conversationId,
            burnToken = burnToken,
            relayUrl = relayUrl
        ).toAppResult()
    }

    override suspend fun checkBurnStatus(
        conversationId: String,
        authToken: String,
        relayUrl: String?
    ): AppResult<BurnStatusResponse> {
        return coreRelayService.checkBurnStatus(
            conversationId = conversationId,
            authToken = authToken,
            relayUrl = relayUrl
        ).toAppResult()
    }

    override fun hashToken(token: String): String {
        return coreRelayService.hashToken(token)
    }

    private fun <T> Result<T>.toAppResult(): AppResult<T> {
        return fold(
            onSuccess = { AppResult.Success(it) },
            onFailure = { AppResult.Error(AppError.fromException(it)) }
        )
    }
}
