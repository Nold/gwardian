package com.monadial.ash.core.services.applock

import com.monadial.ash.core.services.ConversationStorageService
import com.monadial.ash.data.repositories.GroupSessions
import com.monadial.ash.domain.entities.GroupMessageStore
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the app shows, decided by the app lock (docs/app-lock.md). */
enum class LockPhase {
    /** No app code yet: it must be chosen before anything else */
    SETUP,
    LOCKED,
    UNLOCKED
}

data class AppLockState(
    val phase: LockPhase,
    val errorMessage: String? = null,
    /** Set while a delay after wrong codes is running */
    val retryAtMillis: Long? = null,
    /** Set when erase after failures is enabled */
    val attemptsBeforeErase: Int? = null,
    /** Bumped on every wrong code, so the screen can react */
    val wrongCodeCount: Int = 0,
    /** Everything was erased after too many wrong codes */
    val wasErased: Boolean = false,
    val isBiometricUnlockEnabled: Boolean = false,
    val eraseAfterFailures: Boolean = false,
    val isAuthenticating: Boolean = false
)

/**
 * App-wide lock state shared by the lock screen, the setup screen and
 * settings. Holds no key itself: the vault does.
 */
@Singleton
class AppLockManager @Inject constructor(
    private val vault: PasscodeVault,
    private val storage: ConversationStorageService,
    private val groupMessages: GroupMessageStore,
    private val groupSessions: GroupSessions
) {
    private val _state = MutableStateFlow(AppLockState(if (vault.isConfigured) LockPhase.LOCKED else LockPhase.SETUP))
    val state: StateFlow<AppLockState> = _state.asStateFlow()

    init {
        refresh()
    }

    // Setup

    /** Choose the app code, then seal records written before the lock. */
    suspend fun configure(code: String): Boolean {
        return try {
            vault.configure(code)
            storage.sealLegacyRecords()
            _state.update { it.copy(phase = LockPhase.UNLOCKED, wasErased = false, errorMessage = null) }
            refresh()
            true
        } catch (e: PasscodeVaultException) {
            handle(e)
            false
        }
    }

    // Unlock

    fun unlock(code: String): Boolean {
        return try {
            vault.unlock(code)
            _state.update { it.copy(phase = LockPhase.UNLOCKED, errorMessage = null) }
            refresh()
            true
        } catch (e: PasscodeVaultException) {
            handle(e)
            false
        }
    }

    suspend fun unlockWithBiometrics(authenticate: BiometricAuthenticator) {
        val current = _state.value
        if (current.phase != LockPhase.LOCKED || !current.isBiometricUnlockEnabled || current.isAuthenticating) return
        _state.update { it.copy(isAuthenticating = true) }
        try {
            vault.unlockWithBiometrics(authenticate)
            _state.update { it.copy(phase = LockPhase.UNLOCKED, errorMessage = null) }
        } catch (e: PasscodeVaultException) {
            // Cancelled, or the enrollment changed and the shortcut is gone
        } finally {
            _state.update { it.copy(isAuthenticating = false) }
            refresh()
        }
    }

    // Lock

    fun lock() {
        if (_state.value.phase != LockPhase.UNLOCKED) return
        vault.lock()
        storage.clearCache()
        groupMessages.clearAll()
        // Waits for any pad operation in flight, which fails anyway once the
        // vault is locked, then drops the pads from memory
        groupSessions.scope.launch { groupSessions.lockAll() }
        _state.update { it.copy(phase = LockPhase.LOCKED, errorMessage = null) }
        refresh()
    }

    // Settings

    suspend fun setBiometricUnlock(enabled: Boolean, authenticate: BiometricAuthenticator): Boolean {
        try {
            vault.setBiometricUnlock(enabled, authenticate)
        } catch (e: Exception) {
            // Cancelled or unavailable: leave it as it was
        }
        refresh()
        return _state.value.isBiometricUnlockEnabled == enabled
    }

    fun setEraseAfterFailures(enabled: Boolean) {
        try {
            vault.setEraseAfterFailures(enabled)
        } catch (e: PasscodeVaultException) {
            // Only possible while locked, where settings are not shown
        }
        refresh()
    }

    /** A wrong current code counts as a failed attempt. */
    fun changeCode(current: String, new: String): Boolean {
        return try {
            vault.changeCode(current, new)
            _state.update { it.copy(errorMessage = null) }
            refresh()
            true
        } catch (e: PasscodeVaultException) {
            handle(e)
            false
        }
    }

    fun clearError() {
        _state.update { it.copy(errorMessage = null) }
    }

    /** Re-read the attempt counter and the biometric copy. */
    fun refresh() {
        val attempts = vault.attemptState
        _state.update {
            it.copy(
                retryAtMillis = attempts.retryAtMillis(System.currentTimeMillis()),
                attemptsBeforeErase = attempts.attemptsBeforeErase,
                eraseAfterFailures = attempts.eraseAfterFailures,
                isBiometricUnlockEnabled = vault.isBiometricUnlockEnabled
            )
        }
    }

    private fun handle(error: PasscodeVaultException) {
        when (error) {
            is PasscodeVaultException.WrongCode -> {
                val left = error.attemptsBeforeErase
                val message = when (left) {
                    null -> "Wrong code."
                    1 -> "Wrong code. 1 attempt left before everything is erased."
                    else -> "Wrong code. $left attempts left before everything is erased."
                }
                _state.update { it.copy(errorMessage = message, wrongCodeCount = it.wrongCodeCount + 1) }
            }
            is PasscodeVaultException.RetryLater -> _state.update { it.copy(errorMessage = null) }
            is PasscodeVaultException.Erased ->
                _state.update { it.copy(phase = LockPhase.SETUP, wasErased = true, errorMessage = null) }
            is PasscodeVaultException.InvalidCode ->
                _state.update { it.copy(errorMessage = "The code must have ${LockPolicy.CODE_LENGTH} digits.") }
            else -> _state.update { it.copy(errorMessage = "Something went wrong. Try again.") }
        }
        refresh()
    }
}
