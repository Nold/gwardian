package com.monadial.ash.data.repositories

import com.monadial.ash.core.common.AppError
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.core.services.SettingsService
import com.monadial.ash.domain.repositories.SettingsRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first

/**
 * Implementation of SettingsRepository using SettingsService.
 * Provides a clean interface for settings operations.
 */
@Singleton
class SettingsRepositoryImpl @Inject constructor(
    private val settingsService: SettingsService
) : SettingsRepository {

    override val relayServerUrl: Flow<String>
        get() = settingsService.relayServerUrl

    override val isBiometricEnabled: StateFlow<Boolean>
        get() = settingsService.isBiometricEnabled

    override val lockOnBackground: Flow<Boolean>
        get() = settingsService.lockOnBackground

    override suspend fun getRelayUrl(): String {
        return settingsService.getRelayUrl()
    }

    override suspend fun setRelayUrl(url: String): AppResult<Unit> {
        return try {
            settingsService.setRelayServerUrl(url)
            AppResult.Success(Unit)
        } catch (e: Exception) {
            AppResult.Error(AppError.Storage.WriteFailed("Failed to save relay URL", e))
        }
    }

    override fun getDefaultRelayUrl(): String {
        return com.monadial.ash.BuildConfig.DEFAULT_RELAY_URL
    }

    override suspend fun getBiometricEnabled(): Boolean {
        return settingsService.isBiometricEnabled.value
    }

    override suspend fun setBiometricEnabled(enabled: Boolean): AppResult<Unit> {
        return try {
            settingsService.setBiometricEnabled(enabled)
            AppResult.Success(Unit)
        } catch (e: Exception) {
            AppResult.Error(AppError.Storage.WriteFailed("Failed to save biometric setting", e))
        }
    }

    override suspend fun getLockOnBackground(): Boolean {
        return settingsService.lockOnBackground.first()
    }

    override suspend fun setLockOnBackground(enabled: Boolean): AppResult<Unit> {
        return try {
            settingsService.setLockOnBackground(enabled)
            AppResult.Success(Unit)
        } catch (e: Exception) {
            AppResult.Error(AppError.Storage.WriteFailed("Failed to save lock setting", e))
        }
    }
}
