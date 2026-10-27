package com.monadial.ash.core.services.applock

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Android storage for the vault key (docs/app-lock.md).
 *
 * Code copy: wrapped with AES-GCM under a key derived from PBKDF2(code)
 * combined with an HMAC of the code computed by a non-exportable Keystore
 * key, so guessing the code requires this device.
 *
 * Biometric copy: wrapped by a Keystore key that requires biometric
 * authentication and is invalidated when enrollment changes.
 */
class KeystoreVaultKeyStore(context: Context) : VaultKeyStore {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    private val random = SecureRandom()

    override val hasCodeCopy: Boolean get() = prefs.contains(CODE_WRAPPED)

    override val hasBiometricCopy: Boolean
        get() = prefs.contains(BIO_WRAPPED) && keyStore.containsAlias(BIO_ALIAS)

    // Code copy

    override fun storeCodeCopy(key: ByteArray, code: String) {
        val salt = ByteArray(SALT_SIZE).also(random::nextBytes)
        val wrapped = gcm(Cipher.ENCRYPT_MODE, codeKey(code, salt), null, key)
        prefs.edit(commit = true) {
            putString(CODE_SALT, encode(salt))
            putString(CODE_WRAPPED, encode(wrapped))
        }
    }

    override fun loadCodeCopy(code: String): ByteArray {
        val salt = prefs.getString(CODE_SALT, null)?.let(::decode) ?: throw VaultKeyStoreException.NotFound()
        val wrapped = prefs.getString(CODE_WRAPPED, null)?.let(::decode) ?: throw VaultKeyStoreException.NotFound()
        return try {
            gcm(Cipher.DECRYPT_MODE, codeKey(code, salt), wrapped.copyOfRange(0, NONCE_SIZE), wrapped)
        } catch (e: AEADBadTagException) {
            throw VaultKeyStoreException.WrongCode()
        }
    }

    // Biometric copy

    override suspend fun storeBiometricCopy(key: ByteArray, authenticate: BiometricAuthenticator) {
        deleteBiometricCopy()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, createBiometricKey())
        val authenticated = authenticate(cipher) ?: throw VaultKeyStoreException.BiometricsUnavailable()
        val wrapped = authenticated.iv + authenticated.doFinal(key)
        prefs.edit(commit = true) { putString(BIO_WRAPPED, encode(wrapped)) }
    }

    override suspend fun loadBiometricCopy(authenticate: BiometricAuthenticator): ByteArray {
        val wrapped = prefs.getString(BIO_WRAPPED, null)?.let(::decode)
            ?: throw VaultKeyStoreException.BiometricsUnavailable()
        val secret = keyStore.getKey(BIO_ALIAS, null) as? SecretKey
            ?: throw VaultKeyStoreException.BiometricsUnavailable()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        try {
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, wrapped, 0, NONCE_SIZE))
        } catch (e: KeyPermanentlyInvalidatedException) {
            // A face or finger was added: the shortcut is gone for good
            deleteBiometricCopy()
            throw VaultKeyStoreException.BiometricsUnavailable()
        }
        val authenticated = authenticate(cipher) ?: throw VaultKeyStoreException.BiometricsUnavailable()
        return authenticated.doFinal(wrapped, NONCE_SIZE, wrapped.size - NONCE_SIZE)
    }

    override fun deleteBiometricCopy() {
        prefs.edit(commit = true) { remove(BIO_WRAPPED) }
        if (keyStore.containsAlias(BIO_ALIAS)) keyStore.deleteEntry(BIO_ALIAS)
    }

    override fun deleteAll() {
        prefs.edit(commit = true) { clear() }
        listOf(BIO_ALIAS, HMAC_ALIAS).forEach { if (keyStore.containsAlias(it)) keyStore.deleteEntry(it) }
    }

    // Helpers

    /** SHA-256(PBKDF2(code, salt) || HMAC_device(salt || code)) */
    private fun codeKey(code: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(code.toCharArray(), salt, PBKDF2_ITERATIONS, 256)
        val stretched = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        spec.clearPassword()
        val mac = Mac.getInstance("HmacSHA256").apply { init(deviceHmacKey()) }
        val bound = mac.doFinal(salt + code.toByteArray(Charsets.UTF_8))
        return MessageDigest.getInstance("SHA-256").digest(stretched + bound)
    }

    private fun gcm(mode: Int, key: ByteArray, nonce: ByteArray?, input: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        return if (mode == Cipher.ENCRYPT_MODE) {
            val fresh = ByteArray(NONCE_SIZE).also(random::nextBytes)
            cipher.init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, fresh))
            fresh + cipher.doFinal(input)
        } else {
            cipher.init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
            cipher.doFinal(input, NONCE_SIZE, input.size - NONCE_SIZE)
        }
    }

    private fun deviceHmacKey(): SecretKey {
        (keyStore.getKey(HMAC_ALIAS, null) as? SecretKey)?.let { return it }
        val builder = KeyGenParameterSpec.Builder(HMAC_ALIAS, KeyProperties.PURPOSE_SIGN)
        return generateWithStrongBox(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, builder)
    }

    private fun createBiometricKey(): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            BIO_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        return generateWithStrongBox(KeyProperties.KEY_ALGORITHM_AES, builder)
    }

    /** Prefer the secure element when the device has one. */
    private fun generateWithStrongBox(algorithm: String, builder: KeyGenParameterSpec.Builder): SecretKey {
        val generator = KeyGenerator.getInstance(algorithm, ANDROID_KEYSTORE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.init(builder.setIsStrongBoxBacked(true).build())
                return generator.generateKey()
            } catch (e: StrongBoxUnavailableException) {
                builder.setIsStrongBoxBacked(false)
            }
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    private fun decode(text: String): ByteArray = Base64.getDecoder().decode(text)

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val PREFS_NAME = "gwardian_vault"
        private const val HMAC_ALIAS = "gwardian_vault_hmac"
        private const val BIO_ALIAS = "gwardian_vault_biometric"
        private const val CODE_SALT = "code_salt"
        private const val CODE_WRAPPED = "code_wrapped"
        private const val BIO_WRAPPED = "biometric_wrapped"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val SALT_SIZE = 16
        private const val NONCE_SIZE = 12
        private const val TAG_BITS = 128
        private const val PBKDF2_ITERATIONS = 100_000
    }
}

/** Keeps the attempt counter in encrypted preferences outside the vault. */
class PrefsLockAttemptStore(context: Context) : LockAttemptStore {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "gwardian_lock",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    override fun load(): LockAttemptState = LockAttemptState(
        failures = prefs.getInt(FAILURES, 0),
        lastFailureMillis = prefs.getLong(LAST_FAILURE, -1L).takeIf { it >= 0 },
        eraseAfterFailures = prefs.getBoolean(ERASE, false)
    )

    override fun save(state: LockAttemptState) {
        prefs.edit(commit = true) {
            putInt(FAILURES, state.failures)
            if (state.lastFailureMillis != null) putLong(LAST_FAILURE, state.lastFailureMillis) else remove(LAST_FAILURE)
            putBoolean(ERASE, state.eraseAfterFailures)
        }
    }

    private companion object {
        const val FAILURES = "failures"
        const val LAST_FAILURE = "last_failure"
        const val ERASE = "erase_after_failures"
    }
}
