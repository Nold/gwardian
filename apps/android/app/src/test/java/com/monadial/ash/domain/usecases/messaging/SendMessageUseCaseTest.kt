package com.monadial.ash.domain.usecases.messaging

import com.google.common.truth.Truth.assertThat
import com.monadial.ash.TestFixtures
import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.core.services.PadState
import com.monadial.ash.core.services.SendResult
import com.monadial.ash.domain.entities.ConversationRole
import com.monadial.ash.domain.entities.DeliveryStatus
import com.monadial.ash.domain.entities.MessageContent
import com.monadial.ash.domain.entities.MessageDirection
import com.monadial.ash.domain.repositories.ConversationRepository
import com.monadial.ash.domain.repositories.PadRepository
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.RelayService
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

@DisplayName("SendMessageUseCase")
class SendMessageUseCaseTest {

    private lateinit var conversationRepository: ConversationRepository
    private lateinit var padRepository: PadRepository
    private lateinit var cryptoService: CryptoService
    private lateinit var relayService: RelayService
    private lateinit var useCase: SendMessageUseCase

    @BeforeEach
    fun setup() {
        conversationRepository = mockk(relaxed = true)
        padRepository = mockk(relaxed = true)
        cryptoService = mockk(relaxed = true)
        relayService = mockk(relaxed = true)
        useCase = SendMessageUseCase(conversationRepository, padRepository, cryptoService, relayService)
    }

    @Nested
    @DisplayName("invoke() with text messages")
    inner class TextMessageTests {

        @Test
        @DisplayName("should send text message successfully as initiator")
        fun sendTextAsInitiator() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(
                role = ConversationRole.INITIATOR,
                padConsumedFront = 100
            )
            val content = MessageContent.Text("Hello, World!")
            val expectedBlobId = "blob-123"

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(100L)
            coEvery { padRepository.consumeForSending(any(), any(), any()) } coAnswers {
                // Exactly the pad range asked for: auth key + encryption key
                AppResult.Success(ByteArray(secondArg<Int>()))
            }
            every { cryptoService.encryptAuthenticated(any(), any(), any(), any()) } returns ByteArray(13) { 0xAA.toByte() }
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = expectedBlobId))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isSuccess).isTrue()
            val sendResult = result.getOrNull()!!
            assertThat(sendResult.blobId).isEqualTo(expectedBlobId)
            assertThat(sendResult.message.direction).isEqualTo(MessageDirection.SENT)
            assertThat(sendResult.message.status).isEqualTo(DeliveryStatus.SENT)
            assertThat(sendResult.message.content).isEqualTo(content)
        }

        @Test
        @DisplayName("should send text message successfully as responder")
        fun sendTextAsResponder() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(
                role = ConversationRole.RESPONDER,
                padTotalSize = 65536,
                padConsumedBack = 100
            )
            val content = MessageContent.Text("Response message")
            val expectedBlobId = "blob-456"

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.getPadState(any()) } returns AppResult.Success(
                PadState(
                    totalBytes = 65536,
                    consumedFront = 0,
                    consumedBack = 100,
                    remaining = 65436,
                    isExhausted = false
                )
            )
            coEvery { padRepository.consumeForSending(any(), any(), any()) } coAnswers {
                // Exactly the pad range asked for: auth key + encryption key
                AppResult.Success(ByteArray(secondArg<Int>()))
            }
            every { cryptoService.encryptAuthenticated(any(), any(), any(), any()) } returns ByteArray(16) { 0xBB.toByte() }
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = expectedBlobId))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isSuccess).isTrue()
            val sendResult = result.getOrNull()!!
            assertThat(sendResult.blobId).isEqualTo(expectedBlobId)
        }

        @Test
        @DisplayName("should return error when pad is exhausted")
        fun padExhausted() = runTest {
            // Given
            val conversation = TestFixtures.createConversation()
            val content = MessageContent.Text("Test message")

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(false)

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isError).isTrue()
            val error = result.errorOrNull()
            assertThat(error).isInstanceOf(AppError.Pad.Exhausted::class.java)
        }

        @Test
        @DisplayName("should return error when canSend check fails")
        fun canSendCheckFails() = runTest {
            // Given
            val conversation = TestFixtures.createConversation()
            val content = MessageContent.Text("Test message")

            coEvery { padRepository.canSend(any(), any(), any()) } returns
                AppResult.Error(AppError.Storage.ReadFailed("Pad not found"))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isError).isTrue()
        }

        @Test
        @DisplayName("should return error when relay submission fails")
        fun relaySubmitFails() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(role = ConversationRole.INITIATOR)
            val content = MessageContent.Text("Test message")

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(0L)
            coEvery { padRepository.consumeForSending(any(), any(), any()) } coAnswers {
                // Exactly the pad range asked for: auth key + encryption key
                AppResult.Success(ByteArray(secondArg<Int>()))
            }
            every { cryptoService.encryptAuthenticated(any(), any(), any(), any()) } returns ByteArray(12)
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Error(AppError.Network.ConnectionFailed("Network error"))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isError).isTrue()
            val error = result.errorOrNull()
            assertThat(error).isInstanceOf(AppError.Network.ConnectionFailed::class.java)
        }

        @Test
        @DisplayName("should return error when relay returns success but no blobId")
        fun relayReturnsNoBlobId() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(role = ConversationRole.INITIATOR)
            val content = MessageContent.Text("Test message")

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(0L)
            coEvery { padRepository.consumeForSending(any(), any(), any()) } coAnswers {
                // Exactly the pad range asked for: auth key + encryption key
                AppResult.Success(ByteArray(secondArg<Int>()))
            }
            every { cryptoService.encryptAuthenticated(any(), any(), any(), any()) } returns ByteArray(12)
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = null))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isError).isTrue()
            val error = result.errorOrNull()
            assertThat(error).isInstanceOf(AppError.Relay.SubmitFailed::class.java)
        }
    }

    @Nested
    @DisplayName("invoke() with location messages")
    inner class LocationMessageTests {

        @Test
        @DisplayName("should send location message successfully")
        fun sendLocation() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(role = ConversationRole.INITIATOR)
            val content = MessageContent.Location(latitude = 52.3676, longitude = 4.9041)
            val expectedBlobId = "blob-location"

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(0L)
            coEvery { padRepository.consumeForSending(any(), any(), any()) } coAnswers {
                // Exactly the pad range asked for: auth key + encryption key
                AppResult.Success(ByteArray(secondArg<Int>()))
            }
            every { cryptoService.encryptAuthenticated(any(), any(), any(), any()) } returns ByteArray(24) { 0xCC.toByte() }
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = expectedBlobId))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isSuccess).isTrue()
            val sendResult = result.getOrNull()!!
            assertThat(sendResult.blobId).isEqualTo(expectedBlobId)
            assertThat(sendResult.message.content).isEqualTo(content)
        }
    }

    @Nested
    @DisplayName("encryption verification")
    inner class EncryptionTests {

        @Test
        @DisplayName("should use consumed pad bytes for encryption")
        fun usesConsumedPadBytes() = runTest {
            // Given
            val conversation = TestFixtures.createConversation(role = ConversationRole.INITIATOR)
            val content = MessageContent.Text("Test")
            // 64-byte authentication key, then the 4-byte encryption key
            val keyBytes = ByteArray(68) { it.toByte() }
            val ciphertext = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte())

            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(0L)
            coEvery { padRepository.consumeForSending(any(), 68, any()) } returns AppResult.Success(keyBytes)
            every {
                cryptoService.encryptAuthenticated(
                    keyBytes.copyOfRange(0, 64),
                    keyBytes.copyOfRange(64, 68),
                    "Test".encodeToByteArray(),
                    0x01
                )
            } returns ciphertext
            coEvery { conversationRepository.saveConversation(any()) } returns AppResult.Success(Unit)
            coEvery { relayService.submitMessage(any(), any(), ciphertext, any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = "blob-123"))

            // When
            val result = useCase(conversation, content)

            // Then
            assertThat(result.isSuccess).isTrue()
            coVerify { relayService.submitMessage(any(), any(), ciphertext, any(), any(), any(), any(), any(), any()) }
            assertThat(result.getOrNull()!!.message.padLength).isEqualTo(68L)
        }

        @Test
        @DisplayName("should send an expiring text with its lifetime")
        fun expiringText() = runTest {
            // The lifetime prefix is encoded by the Rust core
            assumeTrue(runCatching { uniffi.ash.getMaxGroupMembers() }.isSuccess, "host Rust bindings not built")
            val conversation = TestFixtures.createConversation(role = ConversationRole.INITIATOR)
            coEvery { padRepository.canSend(any(), any(), any()) } returns AppResult.Success(true)
            coEvery { padRepository.nextSendOffset(any(), any()) } returns AppResult.Success(0L)
            // 64 + 4 bytes of lifetime + 2 bytes of text
            coEvery { padRepository.consumeForSending(any(), 70, any()) } returns AppResult.Success(ByteArray(70))
            every { cryptoService.encryptAuthenticated(any(), any(), any(), 0x04) } returns byteArrayOf(1)
            coEvery { relayService.submitMessage(any(), any(), any(), any(), any(), any(), any(), any(), any()) } returns
                AppResult.Success(SendResult(success = true, blobId = "blob"))

            val result = useCase(conversation, MessageContent.Text("hi"), lifetimeSeconds = 30)

            assertThat(result.isSuccess).isTrue()
            assertThat(result.getOrNull()!!.message.expiresAt).isNotNull()
        }
    }
}
