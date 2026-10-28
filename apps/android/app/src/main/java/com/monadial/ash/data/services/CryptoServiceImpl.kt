package com.monadial.ash.data.services

import com.monadial.ash.core.services.AshCoreService
import com.monadial.ash.domain.services.CryptoService
import com.monadial.ash.domain.services.DecryptedFrame
import uniffi.ash.AuthTokens
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainFrameGenerator
import uniffi.ash.FountainFrameReceiver
import uniffi.ash.Pad
import uniffi.ash.PadSize
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Implementation of CryptoService that delegates to AshCoreService.
 * This is the trusted cryptographic authority.
 */
@Singleton
class CryptoServiceImpl @Inject constructor(
    private val ashCoreService: AshCoreService
) : CryptoService {

    override fun createFountainGenerator(
        metadata: CeremonyMetadata,
        padBytes: ByteArray,
        blockSize: UInt,
        passphrase: String?
    ): FountainFrameGenerator {
        return ashCoreService.createFountainGenerator(metadata, padBytes, blockSize, passphrase)
    }

    override fun createFountainReceiver(passphrase: String?): FountainFrameReceiver {
        return ashCoreService.createFountainReceiver(passphrase)
    }

    override fun generateQrPassphrase(): List<String> = ashCoreService.generateQrPassphrase()

    override fun generateMnemonic(padBytes: ByteArray): List<String> {
        return ashCoreService.generateMnemonic(padBytes)
    }

    override fun deriveAllTokens(padBytes: ByteArray): AuthTokens {
        return ashCoreService.deriveAllTokens(padBytes)
    }

    override fun deriveConversationId(padBytes: ByteArray): String {
        return ashCoreService.deriveConversationId(padBytes)
    }

    override fun deriveAuthToken(padBytes: ByteArray): String {
        return ashCoreService.deriveAuthToken(padBytes)
    }

    override fun deriveBurnToken(padBytes: ByteArray): String {
        return ashCoreService.deriveBurnToken(padBytes)
    }

    override fun encryptAuthenticated(
        authKey: ByteArray,
        encryptionKey: ByteArray,
        plaintext: ByteArray,
        msgType: Int
    ): ByteArray = uniffi.ash.encryptAuthenticated(
        authKey.toUBytes(),
        encryptionKey.toUBytes(),
        plaintext.toUBytes(),
        msgType.toUByte()
    ).toBytes()

    override fun decryptAuthenticated(authKey: ByteArray, encryptionKey: ByteArray, frame: ByteArray): DecryptedFrame {
        val result = uniffi.ash.decryptAuthenticated(authKey.toUBytes(), encryptionKey.toUBytes(), frame.toUBytes())
        return DecryptedFrame(msgType = result.msgType.toInt(), plaintext = result.plaintext.toBytes())
    }

    private fun ByteArray.toUBytes(): List<UByte> = map { it.toUByte() }

    private fun List<UByte>.toBytes(): ByteArray = ByteArray(size) { this[it].toByte() }

    override fun encrypt(key: ByteArray, plaintext: ByteArray): ByteArray {
        return ashCoreService.encrypt(key, plaintext)
    }

    override fun decrypt(key: ByteArray, ciphertext: ByteArray): ByteArray {
        return ashCoreService.decrypt(key, ciphertext)
    }

    override fun validatePassphrase(passphrase: String): Boolean {
        return ashCoreService.validatePassphrase(passphrase)
    }

    override fun createPadFromEntropy(entropy: ByteArray, size: PadSize): Pad {
        return ashCoreService.createPadFromEntropy(entropy, size)
    }

    override fun createPadFromBytes(bytes: ByteArray): Pad {
        return ashCoreService.createPadFromBytes(bytes)
    }

    override fun createPadFromBytesWithState(
        bytes: ByteArray,
        consumedFront: ULong,
        consumedBack: ULong
    ): Pad {
        return ashCoreService.createPadFromBytesWithState(bytes, consumedFront, consumedBack)
    }

    override fun hashToken(token: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hashBytes = digest.digest(token.toByteArray(Charsets.UTF_8))
        return hashBytes.joinToString("") { String.format("%02x", it) }
    }

    override fun generateFrameBytes(generator: FountainFrameGenerator, index: UInt): ByteArray {
        return with(ashCoreService) { generator.generateFrameBytes(index) }
    }

    override fun addFrameBytes(receiver: FountainFrameReceiver, frameBytes: ByteArray): Boolean {
        return with(ashCoreService) { receiver.addFrameBytes(frameBytes) }
    }
}
