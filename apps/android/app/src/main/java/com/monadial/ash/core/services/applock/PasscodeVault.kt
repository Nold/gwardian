package com.monadial.ash.core.services.applock

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

sealed class PasscodeVaultException(message: String) : Exception(message) {
    class Locked : PasscodeVaultException("Vault is locked")
    class NotConfigured : PasscodeVaultException("No app code")
    class AlreadyConfigured : PasscodeVaultException("App code already set")
    class InvalidCode : PasscodeVaultException("Invalid code")

    /** [attemptsBeforeErase] is set when erase after failures is enabled. */
    class WrongCode(val attemptsBeforeErase: Int?) : PasscodeVaultException("Wrong code")
    class RetryLater(val untilMillis: Long) : PasscodeVaultException("Retry later")

    /** Too many wrong codes with erase enabled: everything was erased. */
    class Erased : PasscodeVaultException("Erased")
    class BiometricsUnavailable : PasscodeVaultException("Biometrics unavailable")
    class CorruptedRecord : PasscodeVaultException("Corrupted record")
}

/**
 * Holds the vault key while the app is unlocked and enforces the attempt
 * rules (docs/app-lock.md). Pads and conversations are sealed with the
 * vault key before they reach storage.
 */
class PasscodeVault(
    private val store: VaultKeyStore,
    private val attempts: LockAttemptStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: SecureRandom = SecureRandom()
) {
    /** Called after an erase so stored records can be deleted too. */
    @Volatile
    var onErase: (() -> Unit)? = null

    @Volatile
    private var key: ByteArray? = null

    // State

    val isConfigured: Boolean get() = store.hasCodeCopy

    val isUnlocked: Boolean get() = key != null

    val isBiometricUnlockEnabled: Boolean get() = store.hasBiometricCopy

    val attemptState: LockAttemptState get() = attempts.load()

    // Code

    /** Set up the code and the vault key; the vault is then unlocked. */
    @Synchronized
    fun configure(code: String) {
        if (!LockPolicy.isValidCode(code)) throw PasscodeVaultException.InvalidCode()
        if (isConfigured) throw PasscodeVaultException.AlreadyConfigured()
        val newKey = ByteArray(KEY_SIZE).also(random::nextBytes)
        store.storeCodeCopy(newKey, code)
        key = newKey
        attempts.save(LockAttemptState())
    }

    @Synchronized
    fun unlock(code: String) {
        if (!isConfigured) throw PasscodeVaultException.NotConfigured()
        val state = attempts.load()
        state.retryAtMillis(clock())?.let { throw PasscodeVaultException.RetryLater(it) }
        if (!LockPolicy.isValidCode(code)) throw PasscodeVaultException.InvalidCode()
        try {
            key = store.loadCodeCopy(code)
            attempts.save(state.copy(failures = 0, lastFailureMillis = null))
        } catch (e: VaultKeyStoreException.WrongCode) {
            val failed = state.copy(failures = state.failures + 1, lastFailureMillis = clock())
            attempts.save(failed)
            if (failed.eraseAfterFailures && failed.failures >= LockPolicy.ERASE_THRESHOLD) {
                erase()
                throw PasscodeVaultException.Erased()
            }
            throw PasscodeVaultException.WrongCode(failed.attemptsBeforeErase)
        }
    }

    @Synchronized
    fun changeCode(current: String, new: String) {
        if (!LockPolicy.isValidCode(new)) throw PasscodeVaultException.InvalidCode()
        unlock(current)
        store.storeCodeCopy(requireKey(), new)
    }

    // Biometrics

    suspend fun unlockWithBiometrics(authenticate: BiometricAuthenticator) {
        if (!store.hasBiometricCopy) throw PasscodeVaultException.BiometricsUnavailable()
        key = try {
            store.loadBiometricCopy(authenticate)
        } catch (e: Exception) {
            throw PasscodeVaultException.BiometricsUnavailable()
        }
    }

    /**
     * Requires the vault to be unlocked, so turning biometrics on always
     * follows a correct code or an existing biometric unlock.
     */
    suspend fun setBiometricUnlock(enabled: Boolean, authenticate: BiometricAuthenticator) {
        if (enabled) {
            store.storeBiometricCopy(requireKey(), authenticate)
        } else {
            store.deleteBiometricCopy()
        }
    }

    // Erase option

    @Synchronized
    fun setEraseAfterFailures(enabled: Boolean) {
        requireKey()
        attempts.save(attempts.load().copy(eraseAfterFailures = enabled))
    }

    // Lock and erase

    fun lock() {
        key = null
    }

    /**
     * Delete both copies of the vault key, which makes every sealed record
     * unreadable, then let the owner delete the records.
     */
    @Synchronized
    fun erase() {
        key = null
        store.deleteAll()
        attempts.save(LockAttemptState())
        onErase?.invoke()
    }

    // Sealing

    fun seal(plaintext: ByteArray): ByteArray {
        val nonce = ByteArray(NONCE_SIZE).also(random::nextBytes)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(requireKey(), "AES"), GCMParameterSpec(TAG_BITS, nonce))
        return MARKER + nonce + cipher.doFinal(plaintext)
    }

    fun open(sealed: ByteArray): ByteArray {
        if (!isSealed(sealed) || sealed.size < MARKER.size + NONCE_SIZE) {
            throw PasscodeVaultException.CorruptedRecord()
        }
        val key = requireKey()
        val nonce = sealed.copyOfRange(MARKER.size, MARKER.size + NONCE_SIZE)
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            cipher.doFinal(sealed, MARKER.size + NONCE_SIZE, sealed.size - MARKER.size - NONCE_SIZE)
        } catch (e: AEADBadTagException) {
            throw PasscodeVaultException.CorruptedRecord()
        }
    }

    /** Seal a string record; the result is text starting with "GWV1". */
    fun sealString(plaintext: String): String =
        STRING_MARKER + Base64.getEncoder().encodeToString(seal(plaintext.toByteArray(Charsets.UTF_8)))

    fun openString(sealed: String): String {
        if (!isSealedString(sealed)) throw PasscodeVaultException.CorruptedRecord()
        val bytes = try {
            Base64.getDecoder().decode(sealed.substring(STRING_MARKER.length))
        } catch (e: IllegalArgumentException) {
            throw PasscodeVaultException.CorruptedRecord()
        }
        return String(open(bytes), Charsets.UTF_8)
    }

    private fun requireKey(): ByteArray = key ?: throw PasscodeVaultException.Locked()

    companion object {
        val MARKER = "GWV1".toByteArray(Charsets.US_ASCII)
        const val STRING_MARKER = "GWV1:"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val KEY_SIZE = 32
        private const val NONCE_SIZE = 12
        private const val TAG_BITS = 128

        fun isSealed(data: ByteArray): Boolean =
            data.size >= MARKER.size && data.copyOfRange(0, MARKER.size).contentEquals(MARKER)

        fun isSealedString(data: String): Boolean = data.startsWith(STRING_MARKER)
    }
}
