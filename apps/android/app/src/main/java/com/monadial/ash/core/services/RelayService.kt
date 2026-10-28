package com.monadial.ash.core.services

import android.util.Base64
import android.util.Log
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// === Request DTOs (matching iOS) ===

@Serializable
data class SubmitMessageRequest(
    @SerialName("conversation_id") val conversationId: String,
    val ciphertext: String,
    val sequence: Long? = null,
    @SerialName("ttl_seconds") val ttlSeconds: Long? = null,
    @SerialName("extended_ttl") val extendedTTL: Boolean = false,
    val persistent: Boolean = false,
    /** Group member index of the sender; omitted for two-person conversations */
    val sender: Int? = null
)

@Serializable
data class SubmitMessageResponse(val accepted: Boolean, @SerialName("blob_id") val blobId: String)

@Serializable
data class AckMessageRequest(
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("blob_ids") val blobIds: List<String>,
    /** Group member acknowledging; omitted for two-person conversations */
    val member: Int? = null
)

@Serializable
data class AckMessageResponse(val acknowledged: Int)

@Serializable
data class RegisterConversationRequest(
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("auth_token_hash") val authTokenHash: String,
    @SerialName("burn_token_hash") val burnTokenHash: String,
    /** Retention chosen at the ceremony; omitted keeps the relay default */
    @SerialName("ttl_seconds") val ttlSeconds: Long? = null,
    /** 2 for a conversation, up to 8 for a group */
    val members: Int = 2
)

@Serializable
data class RegisterDeviceRequest(
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("device_token") val deviceToken: String,
    val platform: String = "android"
)

@Serializable
data class BurnConversationRequest(
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("burn_token") val burnToken: String
)

@Serializable
data class BurnStatusResponse(val burned: Boolean, @SerialName("burned_at") val burnedAt: String? = null)

// === Response DTOs ===

@Serializable
data class HealthResponse(val status: String, val version: String? = null)

@Serializable
data class PollMessageItem(
    val id: String,
    val ciphertext: String,
    val sequence: Long? = null,
    @SerialName("received_at") val receivedAt: String
)

@Serializable
data class PollMessagesResponse(
    val messages: List<PollMessageItem>,
    @SerialName("next_cursor") val nextCursor: String? = null,
    val burned: Boolean = false
)

// === Result types ===

data class ConnectionTestResult(
    val success: Boolean,
    val version: String? = null,
    val latencyMs: Long? = null,
    val error: String? = null
)

data class SendResult(val success: Boolean, val blobId: String? = null, val error: String? = null)

data class PollResult(
    val success: Boolean,
    val messages: List<ReceivedMessage> = emptyList(),
    val cursor: String? = null,
    val burned: Boolean = false,
    val error: String? = null
)

data class ReceivedMessage(val id: String, val ciphertext: ByteArray, val sequence: Long?, val receivedAt: String) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as ReceivedMessage
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()
}

@Singleton
class RelayService @Inject constructor(
    private val httpClient: HttpClient,
    private val settingsService: SettingsService
) {
    companion object {
        private const val TAG = "RelayService"
    }

    private fun logId(conversationId: String) = conversationId.take(8)

    // === Health Check ===

    suspend fun checkHealth(relayUrl: String? = null): Result<HealthResponse> {
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()
            val response: HttpResponse = httpClient.get("$url/health")
            if (response.status.isSuccess()) {
                Result.success(response.body())
            } else {
                Result.failure(Exception("Health check failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun testConnection(relayUrl: String): ConnectionTestResult {
        return try {
            val startTime = System.currentTimeMillis()
            val response: HttpResponse = httpClient.get("$relayUrl/health")
            val latencyMs = System.currentTimeMillis() - startTime
            if (response.status.isSuccess()) {
                val health: HealthResponse = response.body()
                ConnectionTestResult(success = true, version = health.version, latencyMs = latencyMs)
            } else {
                ConnectionTestResult(success = false, error = "Status: ${response.status}")
            }
        } catch (e: Exception) {
            ConnectionTestResult(success = false, error = e.message)
        }
    }

    // === Messages (matching iOS: POST /v1/messages) ===

    suspend fun submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: ByteArray,
        sequence: Long? = null,
        ttlSeconds: Long? = null,
        extendedTTL: Boolean = false,
        persistent: Boolean = false,
        relayUrl: String? = null,
        sender: Int? = null
    ): SendResult {
        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()
            val encoded = Base64.encodeToString(ciphertext, Base64.NO_WRAP)

            Log.d(TAG, "[$id] Submitting: ${ciphertext.size} bytes, seq=${sequence ?: 0}, ttl=${ttlSeconds ?: 0}s")

            val request =
                SubmitMessageRequest(
                    conversationId = conversationId,
                    ciphertext = encoded,
                    sequence = sequence,
                    ttlSeconds = ttlSeconds,
                    extendedTTL = extendedTTL,
                    persistent = persistent,
                    sender = sender
                )

            val response: HttpResponse =
                httpClient.post("$url/v1/messages") {
                    header("Authorization", "Bearer $authToken")
                    contentType(ContentType.Application.Json)
                    setBody(request)
                }

            if (response.status.isSuccess()) {
                val result: SubmitMessageResponse = response.body()
                if (result.accepted) {
                    Log.d(TAG, "[$id] Submitted successfully: blob=${result.blobId.take(8)}")
                    SendResult(success = true, blobId = result.blobId)
                } else {
                    SendResult(success = false, error = "Message not accepted")
                }
            } else {
                SendResult(success = false, error = "Status: ${response.status}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "[$id] Submit failed: ${e.message}")
            SendResult(success = false, error = e.message)
        }
    }

    // === Poll Messages (matching iOS: GET /v1/messages?conversation_id=...) ===

    suspend fun fetchMessages(
        conversationId: String,
        authToken: String,
        cursor: String? = null,
        relayUrl: String? = null,
        member: Int? = null
    ): PollResult {
        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()
            val response: HttpResponse =
                httpClient.get("$url/v1/messages") {
                    header("Authorization", "Bearer $authToken")
                    parameter("conversation_id", conversationId)
                    cursor?.let { parameter("cursor", it) }
                    member?.let { parameter("member", it) }
                }

            if (response.status.isSuccess()) {
                val result: PollMessagesResponse = response.body()
                val receivedMessages =
                    result.messages.map { msg ->
                        ReceivedMessage(
                            id = msg.id,
                            ciphertext = Base64.decode(msg.ciphertext, Base64.DEFAULT),
                            sequence = msg.sequence,
                            receivedAt = msg.receivedAt
                        )
                    }
                if (result.messages.isNotEmpty()) {
                    Log.d(TAG, "[$id] Poll returned ${result.messages.size} messages, burned=${result.burned}")
                }
                PollResult(
                    success = true,
                    messages = receivedMessages,
                    cursor = result.nextCursor,
                    burned = result.burned
                )
            } else {
                PollResult(success = false, error = "Status: ${response.status}")
            }
        } catch (e: Exception) {
            PollResult(success = false, error = e.message)
        }
    }

    fun pollMessages(
        conversationId: String,
        authToken: String,
        cursor: String? = null,
        relayUrl: String? = null
    ): Flow<PollResult> = flow {
        var currentCursor = cursor
        while (true) {
            val result = fetchMessages(conversationId, authToken, currentCursor, relayUrl)
            emit(result)
            if (result.success && result.cursor != null) {
                currentCursor = result.cursor
            }
            delay(5000) // Poll every 5 seconds
        }
    }

    // === Acknowledge Messages (matching iOS: POST /v1/messages/ack) ===

    suspend fun acknowledgeMessages(
        conversationId: String,
        authToken: String,
        blobIds: List<String>,
        relayUrl: String? = null,
        member: Int? = null
    ): Result<Int> {
        if (blobIds.isEmpty()) return Result.success(0)

        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()

            Log.d(TAG, "[$id] Acknowledging ${blobIds.size} messages")

            val request =
                AckMessageRequest(
                    conversationId = conversationId,
                    blobIds = blobIds,
                    member = member
                )

            val response: HttpResponse =
                httpClient.post("$url/v1/messages/ack") {
                    header("Authorization", "Bearer $authToken")
                    contentType(ContentType.Application.Json)
                    setBody(request)
                }

            if (response.status.isSuccess()) {
                val result: AckMessageResponse = response.body()
                Log.d(TAG, "[$id] Acknowledged ${result.acknowledged} messages")
                Result.success(result.acknowledged)
            } else {
                Result.failure(Exception("ACK failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // === Register Conversation (matching iOS: POST /v1/conversations) ===

    suspend fun registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String,
        relayUrl: String? = null,
        ttlSeconds: Long? = null,
        members: Int = 2
    ): Result<Unit> {
        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()

            Log.d(TAG, "[$id] Registering conversation with relay")

            val request =
                RegisterConversationRequest(
                    conversationId = conversationId,
                    authTokenHash = authTokenHash,
                    burnTokenHash = burnTokenHash,
                    ttlSeconds = ttlSeconds,
                    members = members
                )

            val response: HttpResponse =
                httpClient.post("$url/v1/conversations") {
                    contentType(ContentType.Application.Json)
                    setBody(request)
                }

            if (response.status.isSuccess()) {
                Log.d(TAG, "[$id] Conversation registered successfully")
                Result.success(Unit)
            } else {
                Result.failure(Exception("Registration failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // === Register Device (matching iOS: POST /v1/register) ===

    suspend fun registerDevice(
        conversationId: String,
        authToken: String,
        deviceToken: String,
        relayUrl: String? = null
    ): Result<Unit> {
        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()

            Log.d(TAG, "[$id] Registering device for push notifications")

            val request =
                RegisterDeviceRequest(
                    conversationId = conversationId,
                    deviceToken = deviceToken,
                    platform = "android"
                )

            val response: HttpResponse =
                httpClient.post("$url/v1/register") {
                    header("Authorization", "Bearer $authToken")
                    contentType(ContentType.Application.Json)
                    setBody(request)
                }

            if (response.status.isSuccess()) {
                Log.d(TAG, "[$id] Device registered successfully")
                Result.success(Unit)
            } else {
                Result.failure(Exception("Device registration failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // === Burn Conversation (matching iOS: POST /v1/burn) ===

    suspend fun burnConversation(conversationId: String, burnToken: String, relayUrl: String? = null): Result<Unit> {
        val id = logId(conversationId)
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()

            Log.w(TAG, "[$id] Burning conversation on relay")

            val request =
                BurnConversationRequest(
                    conversationId = conversationId,
                    burnToken = burnToken
                )

            val response: HttpResponse =
                httpClient.post("$url/v1/burn") {
                    contentType(ContentType.Application.Json)
                    setBody(request)
                }

            if (response.status.isSuccess()) {
                Log.w(TAG, "[$id] Conversation burned on relay")
                Result.success(Unit)
            } else {
                Result.failure(Exception("Burn failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // === Check Burn Status (matching iOS: GET /v1/burn?conversation_id=...) ===

    suspend fun checkBurnStatus(
        conversationId: String,
        authToken: String,
        relayUrl: String? = null
    ): Result<BurnStatusResponse> {
        return try {
            val url = relayUrl ?: settingsService.relayServerUrl.first()
            val response: HttpResponse =
                httpClient.get("$url/v1/burn") {
                    header("Authorization", "Bearer $authToken")
                    parameter("conversation_id", conversationId)
                }
            if (response.status.isSuccess()) {
                Result.success(response.body())
            } else {
                Result.failure(Exception("Burn status check failed: ${response.status}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // === Utility ===

    fun hashToken(token: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hashBytes = digest.digest(token.toByteArray(Charsets.UTF_8))
        return hashBytes.joinToString("") { String.format("%02x", it) }
    }
}
