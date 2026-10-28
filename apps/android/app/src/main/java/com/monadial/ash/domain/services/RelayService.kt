package com.monadial.ash.domain.services

import com.monadial.ash.core.common.AppResult
import com.monadial.ash.core.services.BurnStatusResponse
import com.monadial.ash.core.services.ConnectionTestResult
import com.monadial.ash.core.services.HealthResponse
import com.monadial.ash.core.services.PollResult
import com.monadial.ash.core.services.SendResult
import kotlinx.coroutines.flow.Flow

/**
 * Interface for relay server communication.
 * Abstracts HTTP operations for testability.
 */
interface RelayService {

    // === Health Check ===

    /**
     * Check relay server health.
     */
    suspend fun checkHealth(relayUrl: String? = null): AppResult<HealthResponse>

    /**
     * Test connection to relay server with latency measurement.
     */
    suspend fun testConnection(relayUrl: String): ConnectionTestResult

    // === Messages ===

    /**
     * Submit an encrypted message to the relay.
     */
    suspend fun submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: ByteArray,
        sequence: Long? = null,
        ttlSeconds: Long? = null,
        extendedTTL: Boolean = false,
        persistent: Boolean = false,
        relayUrl: String? = null,
        /** Group member index of the sender */
        sender: Int? = null
    ): AppResult<SendResult>

    /**
     * Fetch messages from the relay.
     */
    suspend fun fetchMessages(
        conversationId: String,
        authToken: String,
        cursor: String? = null,
        relayUrl: String? = null,
        /** Group member polling: skips its own messages and those it acknowledged */
        member: Int? = null
    ): AppResult<PollResult>

    /**
     * Poll messages continuously as a Flow.
     */
    fun pollMessages(
        conversationId: String,
        authToken: String,
        cursor: String? = null,
        relayUrl: String? = null
    ): Flow<PollResult>

    /**
     * Acknowledge receipt of messages.
     */
    suspend fun acknowledgeMessages(
        conversationId: String,
        authToken: String,
        blobIds: List<String>,
        relayUrl: String? = null,
        /** Group member acknowledging */
        member: Int? = null
    ): AppResult<Int>

    // === Conversation Management ===

    /**
     * Register a new conversation with the relay.
     */
    suspend fun registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String,
        relayUrl: String? = null,
        ttlSeconds: Long? = null,
        members: Int = 2
    ): AppResult<Unit>

    // === Device Registration ===

    /**
     * Register device for push notifications.
     */
    suspend fun registerDevice(
        conversationId: String,
        authToken: String,
        deviceToken: String,
        relayUrl: String? = null
    ): AppResult<Unit>

    // === Burn Operations ===

    /**
     * Burn (permanently delete) a conversation on the relay.
     */
    suspend fun burnConversation(
        conversationId: String,
        burnToken: String,
        relayUrl: String? = null
    ): AppResult<Unit>

    /**
     * Check if a conversation has been burned.
     */
    suspend fun checkBurnStatus(
        conversationId: String,
        authToken: String,
        relayUrl: String? = null
    ): AppResult<BurnStatusResponse>

    // === Utility ===

    /**
     * Hash a token using SHA-256.
     */
    fun hashToken(token: String): String
}
