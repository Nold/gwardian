package com.monadial.ash.core.services

import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton
import uniffi.ash.AuthTokens
import uniffi.ash.CeremonyMetadata
import uniffi.ash.FountainCeremonyResult
import uniffi.ash.FountainFrameGenerator
import uniffi.ash.FountainFrameReceiver
import uniffi.ash.Pad
import uniffi.ash.PadSize
import uniffi.ash.Role
import uniffi.ash.TransferMethod
import uniffi.ash.createFountainGenerator
import uniffi.ash.decrypt
import uniffi.ash.deriveAllTokens
import uniffi.ash.deriveAuthToken
import uniffi.ash.deriveBurnToken
import uniffi.ash.deriveConversationId
import uniffi.ash.encrypt
import uniffi.ash.generateMnemonic
import uniffi.ash.generateQrPassphrase
import uniffi.ash.validatePassphrase

/**
 * Service that wraps the ASH Core Rust FFI bindings.
 * This is the trusted cryptographic authority - all ceremony and encryption
 * operations should go through this service.
 */
@Singleton
class AshCoreService @Inject constructor() {
    // === Fountain Code Operations (QR Transfer) ===

    /**
     * Create a fountain frame generator for QR display during ceremony.
     *
     * @param metadata Ceremony settings (TTL, disappearing messages, relay URL, etc.)
     * @param padBytes The one-time pad bytes to transfer
     * @param blockSize Size of each block (default 1000 bytes)
     * @param passphrase The six words both people agreed on aloud
     * @return FountainFrameGenerator that produces unlimited QR frames
     */
    fun createFountainGenerator(
        metadata: CeremonyMetadata,
        padBytes: ByteArray,
        blockSize: UInt = 1000u,
        passphrase: String
    ): FountainFrameGenerator {
        // A fresh salt per ceremony: the same words never give the same key twice
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return createFountainGenerator(
            metadata = metadata,
            padBytes = padBytes.map { it.toUByte() },
            blockSize = blockSize,
            passphrase = passphrase,
            method = TransferMethod.RAPTOR,
            salt = salt.map { it.toUByte() }
        )
    }

    /**
     * Create a fountain frame receiver for QR scanning during ceremony.
     *
     * @param passphrase The six words shown on the sender's phone
     * @return FountainFrameReceiver for collecting and decoding scanned frames
     */
    fun createFountainReceiver(passphrase: String): FountainFrameReceiver {
        return FountainFrameReceiver(passphrase)
    }

    /** Six random words for the QR ceremony passphrase. */
    fun generateQrPassphrase(): List<String> {
        val random = ByteArray(12).also { SecureRandom().nextBytes(it) }
        return generateQrPassphrase(random.map { it.toUByte() })
    }

    // === Mnemonic Operations ===

    /**
     * Generate a 6-word mnemonic checksum from pad bytes.
     * Both parties generate the same mnemonic from the same pad,
     * allowing verbal verification of successful transfer.
     *
     * @param padBytes The pad bytes to generate mnemonic from
     * @return List of 6 mnemonic words
     */
    fun generateMnemonic(padBytes: ByteArray): List<String> {
        return generateMnemonic(padBytes.map { it.toUByte() })
    }

    // === Authorization Token Operations ===

    /**
     * Derive all authorization tokens from pad bytes.
     * Returns conversation ID, auth token, and burn token.
     *
     * @param padBytes The pad bytes to derive tokens from
     * @return AuthTokens containing conversationId, authToken, and burnToken
     */
    fun deriveAllTokens(padBytes: ByteArray): AuthTokens {
        return deriveAllTokens(padBytes.map { it.toUByte() })
    }

    /**
     * Derive the conversation ID from pad bytes.
     * This is a 64-character hex string that uniquely identifies the conversation.
     *
     * @param padBytes The pad bytes
     * @return 64-character hex-encoded conversation ID
     */
    fun deriveConversationId(padBytes: ByteArray): String {
        return deriveConversationId(padBytes.map { it.toUByte() })
    }

    /**
     * Derive the auth token from pad bytes.
     * Used for API authentication (messages, polling, registration).
     *
     * @param padBytes The pad bytes
     * @return 64-character hex-encoded auth token
     */
    fun deriveAuthToken(padBytes: ByteArray): String {
        return deriveAuthToken(padBytes.map { it.toUByte() })
    }

    /**
     * Derive the burn token from pad bytes.
     * Used specifically for burn operations (defense in depth).
     *
     * @param padBytes The pad bytes
     * @return 64-character hex-encoded burn token
     */
    fun deriveBurnToken(padBytes: ByteArray): String {
        return deriveBurnToken(padBytes.map { it.toUByte() })
    }

    // === OTP Encryption ===

    /**
     * Encrypt plaintext using OTP (XOR with key).
     * Key and plaintext must be the same length.
     *
     * @param key The key bytes (must match plaintext length)
     * @param plaintext The data to encrypt
     * @return Encrypted ciphertext
     */
    fun encrypt(key: ByteArray, plaintext: ByteArray): ByteArray {
        return encrypt(
            key = key.map { it.toUByte() },
            plaintext = plaintext.map { it.toUByte() }
        ).map { it.toByte() }.toByteArray()
    }

    /**
     * Decrypt ciphertext using OTP (XOR with key).
     * Key and ciphertext must be the same length.
     *
     * @param key The key bytes (must match ciphertext length)
     * @param ciphertext The data to decrypt
     * @return Decrypted plaintext
     */
    fun decrypt(key: ByteArray, ciphertext: ByteArray): ByteArray {
        return decrypt(
            key = key.map { it.toUByte() },
            ciphertext = ciphertext.map { it.toUByte() }
        ).map { it.toByte() }.toByteArray()
    }

    // === Passphrase Validation ===

    /**
     * Whether a typed passphrase is six words from the word list.
     *
     * @param passphrase The passphrase to validate
     * @return true if valid, false otherwise
     */
    fun validatePassphrase(passphrase: String): Boolean {
        return validatePassphrase(passphrase)
    }

    // === Pad Operations ===

    /**
     * Create a Pad from entropy bytes.
     *
     * @param entropy The entropy bytes collected from user gestures
     * @param size The desired pad size
     * @return A new Pad instance
     */
    fun createPadFromEntropy(entropy: ByteArray, size: PadSize): Pad {
        return Pad.fromEntropy(entropy.map { it.toUByte() }, size)
    }

    /**
     * Create a Pad from raw bytes (for reconstruction from ceremony).
     *
     * @param bytes The raw pad bytes
     * @return A new Pad instance
     */
    fun createPadFromBytes(bytes: ByteArray): Pad {
        return Pad.fromBytes(bytes.map { it.toUByte() })
    }

    /**
     * Create a Pad from raw bytes with existing consumption state.
     * Used when restoring from persistent storage.
     *
     * @param bytes The raw pad bytes
     * @param consumedFront Bytes consumed from start (by Initiator)
     * @param consumedBack Bytes consumed from end (by Responder)
     * @return A new Pad instance with restored state
     */
    fun createPadFromBytesWithState(bytes: ByteArray, consumedFront: ULong, consumedBack: ULong): Pad {
        return Pad.fromBytesWithState(
            bytes.map { it.toUByte() },
            consumedFront,
            consumedBack
        )
    }

    // === Helper Extensions ===

    /**
     * Convert a FountainFrameGenerator frame to ByteArray.
     */
    fun FountainFrameGenerator.generateFrameBytes(index: UInt): ByteArray =
        this.generateFrame(index).map { it.toByte() }.toByteArray()

    /**
     * Convert a FountainFrameGenerator frame to ByteArray (next frame).
     */
    fun FountainFrameGenerator.nextFrameBytes(): ByteArray = this.nextFrame().map { it.toByte() }.toByteArray()

    /**
     * Add a frame to the receiver from ByteArray.
     */
    fun FountainFrameReceiver.addFrameBytes(frameBytes: ByteArray): Boolean =
        this.addFrame(frameBytes.map { it.toUByte() })

    /**
     * Get the decoded pad bytes from a ceremony result.
     */
    fun FountainCeremonyResult.getPadBytes(): ByteArray = this.pad.map { it.toByte() }.toByteArray()

    /**
     * Get pad bytes from a Pad.
     */
    fun Pad.getBytes(): ByteArray = this.asBytes().map { it.toByte() }.toByteArray()

    /**
     * Consume bytes from a Pad.
     */
    fun Pad.consumeBytes(n: UInt, role: Role): ByteArray = this.consume(n, role).map { it.toByte() }.toByteArray()
}

// === Extension functions for convenience ===

/**
 * Convert ByteArray to UByte list for FFI calls.
 */
fun ByteArray.toUByteList(): List<UByte> = map { it.toUByte() }

/**
 * Convert UByte list to ByteArray from FFI calls.
 */
fun List<UByte>.toByteArray(): ByteArray = map { it.toByte() }.toByteArray()
