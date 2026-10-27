package com.monadial.ash.core.services.applock

import javax.crypto.Cipher

sealed class VaultKeyStoreException(message: String) : Exception(message) {
    class WrongCode : VaultKeyStoreException("Wrong code")
    class NotFound : VaultKeyStoreException("Vault key not found")

    /** The biometric copy is gone (enrollment changed) or was cancelled. */
    class BiometricsUnavailable : VaultKeyStoreException("Biometrics unavailable")
}

/**
 * Shows the biometric prompt for [cipher] and returns it once authenticated,
 * or null if the user cancelled.
 */
typealias BiometricAuthenticator = suspend (cipher: Cipher) -> Cipher?

/**
 * Where the vault key lives at rest (docs/app-lock.md): one copy readable
 * only with the app code, and an optional copy unlocked by biometrics that
 * the system invalidates when enrollment changes.
 */
interface VaultKeyStore {
    val hasCodeCopy: Boolean
    val hasBiometricCopy: Boolean
    fun storeCodeCopy(key: ByteArray, code: String)
    fun loadCodeCopy(code: String): ByteArray
    suspend fun storeBiometricCopy(key: ByteArray, authenticate: BiometricAuthenticator)
    suspend fun loadBiometricCopy(authenticate: BiometricAuthenticator): ByteArray
    fun deleteBiometricCopy()
    fun deleteAll()
}
