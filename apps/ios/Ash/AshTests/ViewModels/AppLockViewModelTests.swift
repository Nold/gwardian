//
//  AppLockViewModelTests.swift
//  AshTests
//
//  Unit tests for AppLockViewModel
//

import Testing
@testable import Ash

@MainActor
struct AppLockViewModelTests {

    // MARK: - Initialization Tests

    @Test func init_withBiometricLockDisabled_isNotLocked() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = false

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        #expect(viewModel.isLocked == false)
    }

    @Test func init_withBiometricLockEnabled_isLocked() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        #expect(viewModel.isLocked == true)
    }

    // MARK: - Biometric Properties Tests

    @Test func biometricType_returnsBiometricServiceType() {
        let biometric = MockBiometricService()
        biometric.mockBiometricType = .faceID

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: MockSettingsService()
        )

        #expect(viewModel.biometricType == .faceID)
    }

    @Test func canUseBiometrics_returnsBiometricServiceValue() {
        let biometric = MockBiometricService()
        biometric.mockCanUseBiometrics = true

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: MockSettingsService()
        )

        #expect(viewModel.canUseBiometrics == true)
    }

    // MARK: - Lock/Unlock Tests

    @Test func lock_whenBiometricEnabled_locksApp() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        // Unlock first
        viewModel.disableBiometricLock()
        settings.isBiometricLockEnabled = true
        #expect(viewModel.isLocked == false)

        viewModel.lock()

        #expect(viewModel.isLocked == true)
    }

    @Test func lock_whenBiometricDisabled_doesNotLock() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = false

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        viewModel.lock()

        #expect(viewModel.isLocked == false)
    }

    @Test func unlock_successfulAuthentication_unlocksApp() async {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let biometric = MockBiometricService()
        biometric.shouldSucceed = true

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: settings
        )

        #expect(viewModel.isLocked == true)

        await viewModel.unlock()

        #expect(viewModel.isLocked == false)
        #expect(viewModel.authenticationError == nil)
    }

    @Test func unlock_failedAuthentication_remainsLocked() async {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let biometric = MockBiometricService()
        biometric.shouldSucceed = false

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: settings
        )

        await viewModel.unlock()

        #expect(viewModel.isLocked == true)
        #expect(viewModel.authenticationError != nil)
    }

    @Test func unlock_withError_setsAuthenticationError() async {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let biometric = MockBiometricService()
        // User/system cancellation is intentionally silent, so use a real failure
        biometric.errorToThrow = .authenticationFailed

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: settings
        )

        await viewModel.unlock()

        #expect(viewModel.isLocked == true)
        #expect(viewModel.authenticationError != nil)
    }

    @Test func unlock_whenNotLocked_doesNothing() async {
        let biometric = MockBiometricService()

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: MockSettingsService()
        )

        #expect(viewModel.isLocked == false)

        await viewModel.unlock()

        #expect(biometric.authenticateCalled == false)
    }

    // MARK: - App Lifecycle Tests

    @Test func appDidEnterBackground_withLockOnBackground_locks() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true
        settings.lockOnBackground = true

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        viewModel.disableBiometricLock()
        settings.isBiometricLockEnabled = true

        viewModel.appDidEnterBackground()

        #expect(viewModel.isLocked == true)
    }

    @Test func appDidEnterBackground_withoutLockOnBackground_doesNotLock() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true
        settings.lockOnBackground = false

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        viewModel.disableBiometricLock()
        #expect(viewModel.isLocked == false)

        settings.isBiometricLockEnabled = true
        viewModel.appDidEnterBackground()

        #expect(viewModel.isLocked == false)
    }

    // MARK: - Enable/Disable Biometric Lock Tests

    @Test func enableBiometricLock_successfulAuth_enablesLock() async {
        let biometric = MockBiometricService()
        biometric.shouldSucceed = true

        let settings = MockSettingsService()

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: settings
        )

        let result = await viewModel.enableBiometricLock()

        #expect(result == true)
        #expect(settings.isBiometricLockEnabled == true)
    }

    @Test func enableBiometricLock_failedAuth_doesNotEnable() async {
        let biometric = MockBiometricService()
        biometric.shouldSucceed = false

        let settings = MockSettingsService()

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: settings
        )

        let result = await viewModel.enableBiometricLock()

        #expect(result == false)
        #expect(settings.isBiometricLockEnabled == false)
    }

    @Test func enableBiometricLock_biometricsNotAvailable_returnsFalse() async {
        let biometric = MockBiometricService()
        biometric.mockCanUseBiometrics = false

        let viewModel = AppLockViewModel(
            biometricService: biometric,
            settingsService: MockSettingsService()
        )

        let result = await viewModel.enableBiometricLock()

        #expect(result == false)
        #expect(viewModel.authenticationError != nil)
    }

    @Test func disableBiometricLock_disablesAndUnlocks() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        #expect(viewModel.isLocked == true)

        viewModel.disableBiometricLock()

        #expect(viewModel.isLocked == false)
        #expect(settings.isBiometricLockEnabled == false)
    }

    // MARK: - Settings Binding Tests

    @Test func isBiometricLockEnabled_getterReturnsSettingsValue() {
        let settings = MockSettingsService()
        settings.isBiometricLockEnabled = true

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        #expect(viewModel.isBiometricLockEnabled == true)
    }

    @Test func lockOnBackground_getterReturnsSettingsValue() {
        let settings = MockSettingsService()
        settings.lockOnBackground = false

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        #expect(viewModel.lockOnBackground == false)
    }

    @Test func lockOnBackground_setterUpdatesSettings() {
        let settings = MockSettingsService()

        let viewModel = AppLockViewModel(
            biometricService: MockBiometricService(),
            settingsService: settings
        )

        viewModel.lockOnBackground = false

        #expect(settings.lockOnBackground == false)
    }
}
