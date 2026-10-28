package com.monadial.ash.domain.services

import uniffi.ash.AuthTokens
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainFrameGenerator
import uniffi.ash.FountainFrameReceiver
import uniffi.ash.Pad
import uniffi.ash.PadSize

/**
 * Interface for cryptographic operations.
 * Wraps the ASH Core Rust FFI bindings.
 * This is the trusted cryptographic authority.
 */
interface CryptoService {

    // === Fountain Code Operations (QR Transfer) ===

    /**
     * Create a fountain frame generator for QR display during ceremony.
     */
    fun createFountainGenerator(
        metadata: CeremonyMetadata,
        padBytes: ByteArray,
        blockSize: UInt = 1000u,
        passphrase: String?
    ): FountainFrameGenerator

    /**
     * Create a fountain frame receiver for QR scanning during ceremony.
     */
    fun createFountainReceiver(passphrase: String?): FountainFrameReceiver

    /** Six random words for the QR ceremony passphrase. */
    fun generateQrPassphrase(): List<String>

    // === Mnemonic Operations ===

    /**
     * Generate a 6-word mnemonic checksum from pad bytes.
     */
    fun generateMnemonic(padBytes: ByteArray): List<String>

    // === Authorization Token Operations ===

    /**
     * Derive all authorization tokens from pad bytes.
     */
    fun deriveAllTokens(padBytes: ByteArray): AuthTokens

    /**
     * Derive the conversation ID from pad bytes.
     */
    fun deriveConversationId(padBytes: ByteArray): String

    /**
     * Derive the auth token from pad bytes.
     */
    fun deriveAuthToken(padBytes: ByteArray): String

    /**
     * Derive the burn token from pad bytes.
     */
    fun deriveBurnToken(padBytes: ByteArray): String

    // === Authenticated Messages (same frames as iOS) ===

    /**
     * Encrypt [plaintext] into an authenticated frame
     * `[version][type][length][ciphertext][tag]`. [authKey] is the first
     * [AUTH_KEY_BYTES] of the consumed pad bytes, [encryptionKey] the rest.
     */
    fun encryptAuthenticated(authKey: ByteArray, encryptionKey: ByteArray, plaintext: ByteArray, msgType: Int): ByteArray

    /** Verify and decrypt an authenticated frame; throws if it was altered. */
    fun decryptAuthenticated(authKey: ByteArray, encryptionKey: ByteArray, frame: ByteArray): DecryptedFrame

    // === OTP Encryption ===

    /**
     * Encrypt plaintext using OTP (XOR with key).
     */
    fun encrypt(key: ByteArray, plaintext: ByteArray): ByteArray

    /**
     * Decrypt ciphertext using OTP (XOR with key).
     */
    fun decrypt(key: ByteArray, ciphertext: ByteArray): ByteArray

    // === Passphrase Validation ===

    /**
     * Validate that a passphrase meets requirements.
     */
    fun validatePassphrase(passphrase: String): Boolean

    // === Pad Operations ===

    /**
     * Create a Pad from entropy bytes.
     */
    fun createPadFromEntropy(entropy: ByteArray, size: PadSize): Pad

    /**
     * Create a Pad from raw bytes.
     */
    fun createPadFromBytes(bytes: ByteArray): Pad

    /**
     * Create a Pad from raw bytes with existing consumption state.
     */
    fun createPadFromBytesWithState(bytes: ByteArray, consumedFront: ULong, consumedBack: ULong): Pad

    // === Utility ===

    /**
     * Hash a token using SHA-256.
     */
    fun hashToken(token: String): String

    // === Frame Helper Extensions ===

    /**
     * Generate frame bytes from generator at index.
     */
    fun generateFrameBytes(generator: FountainFrameGenerator, index: UInt): ByteArray

    /**
     * Add frame bytes to receiver.
     */
    fun addFrameBytes(receiver: FountainFrameReceiver, frameBytes: ByteArray): Boolean
}

/** Bytes of the authentication key at the start of a message's pad range. */
const val AUTH_KEY_BYTES = 64

/** Frame bytes around the ciphertext: 4-byte header and 32-byte tag. */
const val FRAME_OVERHEAD_BYTES = 36

/** Wire message types (core MessageType), shared with iOS. */
object MessageTypes {
    const val TEXT = 0x01
    const val LOCATION = 0x02
    const val DELETE = 0x03
    const val EXPIRING_TEXT = 0x04
}

/** A verified, decrypted frame. */
class DecryptedFrame(val msgType: Int, val plaintext: ByteArray)
