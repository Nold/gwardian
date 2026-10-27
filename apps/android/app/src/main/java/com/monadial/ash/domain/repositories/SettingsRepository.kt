package com.monadial.ash.domain.repositories

import com.monadial.ash.core.common.AppResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * Repository interface for application settings.
 * Abstracts DataStore/SharedPreferences from the domain layer.
 */
interface SettingsRepository {

    /**
     * Observable relay server URL.
     */
    val relayServerUrl: Flow<String>

    /**
     * Observable biometric authentication enabled state.
     * StateFlow is used as this setting always has a value.
     */
    val isBiometricEnabled: StateFlow<Boolean>

    /**
     * Observable lock on background state.
     */
    val lockOnBackground: Flow<Boolean>

    /**
     * Get the current relay server URL.
     */
    suspend fun getRelayUrl(): String

    /**
     * Set the relay server URL.
     */
    suspend fun setRelayUrl(url: String): AppResult<Unit>

    /**
     * Get the default relay URL.
     */
    fun getDefaultRelayUrl(): String

    /**
     * Check if biometric authentication is enabled.
     */
    suspend fun getBiometricEnabled(): Boolean

    /**
     * Enable or disable biometric authentication.
     */
    suspend fun setBiometricEnabled(enabled: Boolean): AppResult<Unit>

    /**
     * Check if lock on background is enabled.
     */
    suspend fun getLockOnBackground(): Boolean

    /**
     * Enable or disable lock on background.
     */
    suspend fun setLockOnBackground(enabled: Boolean): AppResult<Unit>
}
