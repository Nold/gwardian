package com.monadial.ash.core.services

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.crypto.Cipher
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.suspendCancellableCoroutine

@Singleton
class BiometricService @Inject constructor(@ApplicationContext private val context: Context) {
    private val biometricManager = BiometricManager.from(context)

    val isAvailable: Boolean
        get() =
            biometricManager.canAuthenticate(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
            ) == BiometricManager.BIOMETRIC_SUCCESS

    val biometricType: String
        get() =
            when {
                biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    == BiometricManager.BIOMETRIC_SUCCESS -> "Biometric"
                else -> "Device Credential"
            }

    suspend fun authenticate(activity: FragmentActivity, title: String, subtitle: String): Boolean =
        suspendCoroutine { continuation ->
            val executor = ContextCompat.getMainExecutor(context)

            val callback =
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        continuation.resume(true)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        continuation.resume(false)
                    }

                    override fun onAuthenticationFailed() {
                        // Don't resume yet - user can retry
                    }
                }

            val biometricPrompt = BiometricPrompt(activity, executor, callback)

            val promptInfo =
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.DEVICE_CREDENTIAL
                    )
                    .build()

            biometricPrompt.authenticate(promptInfo)
        }

    /** Strong biometrics, required to unlock a Keystore key (app lock shortcut). */
    val isStrongBiometricAvailable: Boolean
        get() =
            biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS

    /**
     * Show the biometric prompt bound to [cipher]; returns the authenticated
     * cipher, or null if the user cancelled or used the app code instead.
     */
    suspend fun authenticate(activity: FragmentActivity, title: String, subtitle: String, cipher: Cipher): Cipher? =
        suspendCancellableCoroutine { continuation ->
            val callback =
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (continuation.isActive) continuation.resume(result.cryptoObject?.cipher)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (continuation.isActive) continuation.resume(null)
                    }
                }

            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(context), callback)
            val promptInfo =
                BiometricPrompt.PromptInfo.Builder()
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                    .setNegativeButtonText("Use app code")
                    .build()

            prompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
            continuation.invokeOnCancellation { prompt.cancelAuthentication() }
        }
}
