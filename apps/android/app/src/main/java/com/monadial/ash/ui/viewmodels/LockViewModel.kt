package com.monadial.ash.ui.viewmodels

import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.services.BiometricService
import com.monadial.ash.core.services.applock.AppLockManager
import com.monadial.ash.core.services.applock.AppLockState
import com.monadial.ash.core.services.applock.BiometricAuthenticator
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** App code screens and settings; the state lives in [AppLockManager]. */
@HiltViewModel
class LockViewModel @Inject constructor(
    private val manager: AppLockManager,
    private val biometricService: BiometricService
) : ViewModel() {
    val state: StateFlow<AppLockState> = manager.state

    val canUseBiometrics: Boolean get() = biometricService.isStrongBiometricAvailable

    fun configure(code: String) {
        viewModelScope.launch { manager.configure(code) }
    }

    fun unlock(code: String): Boolean = manager.unlock(code)

    fun unlockWithBiometrics(activity: FragmentActivity) {
        viewModelScope.launch {
            manager.unlockWithBiometrics(authenticator(activity, "Unlock with your fingerprint or face"))
        }
    }

    /** Enabling shows the prompt once, so it is known to work. */
    fun setBiometricUnlock(activity: FragmentActivity, enabled: Boolean) {
        viewModelScope.launch {
            manager.setBiometricUnlock(enabled, authenticator(activity, "Confirm to allow biometric unlock"))
        }
    }

    fun setEraseAfterFailures(enabled: Boolean) = manager.setEraseAfterFailures(enabled)

    fun changeCode(current: String, new: String): Boolean = manager.changeCode(current, new)

    fun clearError() = manager.clearError()

    fun refresh() = manager.refresh()

    private fun authenticator(activity: FragmentActivity, subtitle: String): BiometricAuthenticator = { cipher ->
        biometricService.authenticate(activity, "Gwardian", subtitle, cipher)
    }
}
