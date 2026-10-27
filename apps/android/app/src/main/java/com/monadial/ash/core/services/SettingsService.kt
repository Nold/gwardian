package com.monadial.ash.core.services

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.monadial.ash.BuildConfig
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "ash_settings")

@Singleton
class SettingsService @Inject constructor(@ApplicationContext private val context: Context) {
    private object Keys {
        val BIOMETRIC_ENABLED = booleanPreferencesKey("biometric_enabled")
        val LOCK_ON_BACKGROUND = booleanPreferencesKey("lock_on_background")
        val RELAY_SERVER_URL = stringPreferencesKey("relay_server_url")
        val DEFAULT_EXTENDED_TTL = booleanPreferencesKey("default_extended_ttl")
    }

    private val _isBiometricEnabled = MutableStateFlow(false)
    val isBiometricEnabled: StateFlow<Boolean> = _isBiometricEnabled.asStateFlow()

    private val _shouldLock = MutableStateFlow(false)
    val shouldLock: StateFlow<Boolean> = _shouldLock.asStateFlow()

    val lockOnBackground: Flow<Boolean> =
        context.dataStore.data
            .map { preferences -> preferences[Keys.LOCK_ON_BACKGROUND] ?: true }

    val relayServerUrl: Flow<String> =
        context.dataStore.data
            .map { preferences -> preferences[Keys.RELAY_SERVER_URL] ?: BuildConfig.DEFAULT_RELAY_URL }

    val defaultExtendedTtl: Flow<Boolean> =
        context.dataStore.data
            .map { preferences -> preferences[Keys.DEFAULT_EXTENDED_TTL] ?: false }

    suspend fun initialize() {
        _isBiometricEnabled.value = context.dataStore.data.first()[Keys.BIOMETRIC_ENABLED] ?: false
    }

    suspend fun setBiometricEnabled(enabled: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.BIOMETRIC_ENABLED] = enabled
        }
        _isBiometricEnabled.value = enabled
    }

    suspend fun setLockOnBackground(enabled: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.LOCK_ON_BACKGROUND] = enabled
        }
    }

    suspend fun setRelayServerUrl(url: String) {
        context.dataStore.edit { preferences ->
            preferences[Keys.RELAY_SERVER_URL] = url
        }
    }

    suspend fun setDefaultExtendedTtl(enabled: Boolean) {
        context.dataStore.edit { preferences ->
            preferences[Keys.DEFAULT_EXTENDED_TTL] = enabled
        }
    }

    suspend fun getRelayServerUrlSync(): String =
        context.dataStore.data.first()[Keys.RELAY_SERVER_URL] ?: BuildConfig.DEFAULT_RELAY_URL

    suspend fun getRelayUrl(): String =
        context.dataStore.data.first()[Keys.RELAY_SERVER_URL] ?: BuildConfig.DEFAULT_RELAY_URL

    fun triggerLock() {
        _shouldLock.value = true
    }

    fun clearLock() {
        _shouldLock.value = false
    }
}
