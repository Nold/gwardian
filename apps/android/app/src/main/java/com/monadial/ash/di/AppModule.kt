package com.monadial.ash.di

import android.content.Context
import com.monadial.ash.core.services.AshCoreService
import com.monadial.ash.core.services.BiometricService
import com.monadial.ash.core.services.ConversationStorageService
import com.monadial.ash.core.services.LocationService
import com.monadial.ash.core.services.RelayService
import com.monadial.ash.core.services.SSEService
import com.monadial.ash.core.services.SettingsService
import com.monadial.ash.core.services.applock.KeystoreVaultKeyStore
import com.monadial.ash.core.services.applock.PasscodeVault
import com.monadial.ash.core.services.applock.PrefsLockAttemptStore
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import javax.inject.Singleton
import kotlinx.serialization.json.Json

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides
    @Singleton
    fun provideHttpClient(): HttpClient {
        return HttpClient(OkHttp) {
            install(ContentNegotiation) {
                json(
                    Json {
                        ignoreUnknownKeys = true
                        isLenient = true
                    }
                )
            }
        }
    }

    @Provides
    @Singleton
    fun provideSettingsService(@ApplicationContext context: Context): SettingsService {
        return SettingsService(context)
    }

    @Provides
    @Singleton
    fun provideBiometricService(@ApplicationContext context: Context): BiometricService = BiometricService(context)

    @Provides
    @Singleton
    fun provideRelayService(httpClient: HttpClient, settingsService: SettingsService): RelayService =
        RelayService(httpClient, settingsService)

    @Provides
    @Singleton
    fun providePasscodeVault(@ApplicationContext context: Context): PasscodeVault =
        PasscodeVault(KeystoreVaultKeyStore(context), PrefsLockAttemptStore(context))

    @Provides
    @Singleton
    fun provideConversationStorageService(
        @ApplicationContext context: Context,
        vault: PasscodeVault
    ): ConversationStorageService = ConversationStorageService(context, vault).also { storage ->
        // Too many wrong codes: the vault key is gone, delete what it sealed
        vault.onErase = { storage.wipeAll() }
    }

    @Provides
    @Singleton
    fun provideSSEService(): SSEService = SSEService()

    @Provides
    @Singleton
    fun provideLocationService(@ApplicationContext context: Context): LocationService = LocationService(context)

    @Provides
    @Singleton
    fun provideAshCoreService(): AshCoreService = AshCoreService()
}
