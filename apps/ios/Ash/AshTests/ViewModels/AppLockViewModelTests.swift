//
//  AppLockViewModelTests.swift
//  AshTests
//
//  Unit tests for AppLockViewModel
//

import Testing
import Foundation
@testable import Ash

@MainActor
struct AppLockViewModelTests {
    private let store = FakeVaultKeyStore()
    private let attempts = FakeLockAttemptStore()
    private let biometric = MockBiometricService()
    private let settings = MockSettingsService()

    private func makeViewModel(onConfigured: @escaping () -> Void = {}) -> AppLockViewModel {
        AppLockViewModel(
            vault: PasscodeVault(store: store, attempts: attempts),
            biometricService: biometric,
            settingsService: settings,
            onConfigured: onConfigured
        )
    }

    /// A view model whose code "123456" is set up, then locked
    private func makeLocked() -> AppLockViewModel {
        makeViewModel().configure(code: "123456")
        return makeViewModel()
    }

    // MARK: - Setup

    @Test func startsInSetupWithoutCode() {
        let viewModel = makeViewModel()
        #expect(viewModel.phase == .setup)
        #expect(viewModel.isLocked)
    }

    @Test func configureUnlocksAndRunsMigration() {
        var migrated = false
        let viewModel = makeViewModel(onConfigured: { migrated = true })

        #expect(viewModel.configure(code: "123456"))
        #expect(viewModel.phase == .unlocked)
        #expect(migrated)
    }

    @Test func configureRejectsShortCode() {
        let viewModel = makeViewModel()
        #expect(!viewModel.configure(code: "123"))
        #expect(viewModel.phase == .setup)
        #expect(viewModel.errorMessage != nil)
    }

    @Test func startsLockedWhenCodeExists() {
        #expect(makeLocked().phase == .locked)
    }

    // MARK: - Unlock

    @Test func correctCodeUnlocks() {
        let viewModel = makeLocked()
        #expect(viewModel.unlock(code: "123456"))
        #expect(viewModel.phase == .unlocked)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func wrongCodeStaysLocked() {
        let viewModel = makeLocked()
        #expect(!viewModel.unlock(code: "000000"))
        #expect(viewModel.phase == .locked)
        #expect(viewModel.wrongCodeCount == 1)
        #expect(viewModel.errorMessage == "Wrong code.")
    }

    @Test func fifthWrongCodeStartsDelay() {
        let viewModel = makeLocked()
        for _ in 0..<5 { viewModel.unlock(code: "000000") }
        #expect(viewModel.retryUntil != nil)
        #expect(!viewModel.unlock(code: "123456"))
    }

    @Test func eraseOptionShowsAttemptsLeft() {
        let setup = makeViewModel()
        setup.configure(code: "123456")
        setup.setEraseAfterFailures(true)
        let viewModel = makeViewModel()

        #expect(viewModel.attemptsBeforeErase == 10)
        viewModel.unlock(code: "000000")
        #expect(viewModel.attemptsBeforeErase == 9)
        #expect(viewModel.errorMessage == "Wrong code. 9 attempts left before everything is erased.")
    }

    @Test func eraseReturnsToSetup() {
        let setup = makeViewModel()
        setup.configure(code: "123456")
        setup.setEraseAfterFailures(true)
        attempts.state.failures = 9
        let viewModel = makeViewModel()

        #expect(!viewModel.unlock(code: "000000"))
        #expect(viewModel.phase == .setup)
        #expect(viewModel.wasErased)
        #expect(!store.hasCodeCopy)

        #expect(viewModel.configure(code: "654321"))
        #expect(!viewModel.wasErased)
    }

    // MARK: - Lock

    @Test func backgroundLocksWhenEnabled() {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        settings.lockOnBackground = true

        viewModel.appDidEnterBackground()
        #expect(viewModel.phase == .locked)
    }

    @Test func backgroundKeepsUnlockedWhenDisabled() {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        settings.lockOnBackground = false

        viewModel.appDidEnterBackground()
        #expect(viewModel.phase == .unlocked)
    }

    @Test func lockDuringSetupKeepsSetup() {
        let viewModel = makeViewModel()
        viewModel.lock()
        #expect(viewModel.phase == .setup)
    }

    // MARK: - Biometrics

    @Test func enablingBiometricsAsksOnceThenUnlocks() async {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")

        #expect(await viewModel.setBiometricUnlock(true))
        #expect(biometric.authenticateCalled)
        #expect(viewModel.isBiometricUnlockEnabled)

        viewModel.lock()
        await viewModel.unlockWithBiometrics()
        #expect(viewModel.phase == .unlocked)
    }

    @Test func failedBiometricCheckDoesNotEnable() async {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        biometric.shouldSucceed = false

        #expect(!(await viewModel.setBiometricUnlock(true)))
        #expect(!viewModel.isBiometricUnlockEnabled)
    }

    @Test func disablingBiometricsDoesNotAsk() async {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        await viewModel.setBiometricUnlock(true)
        biometric.reset()

        #expect(await viewModel.setBiometricUnlock(false))
        #expect(!biometric.authenticateCalled)
        #expect(!viewModel.isBiometricUnlockEnabled)
    }

    @Test func invalidatedBiometricsNeedTheCode() async {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        await viewModel.setBiometricUnlock(true)
        viewModel.lock()
        store.biometricsFail = true

        await viewModel.unlockWithBiometrics()
        #expect(viewModel.phase == .locked)
    }

    @Test func biometricTypeComesFromService() {
        biometric.mockBiometricType = .touchID
        biometric.mockCanUseBiometrics = false
        let viewModel = makeViewModel()
        #expect(viewModel.biometricType == .touchID)
        #expect(!viewModel.canUseBiometrics)
    }

    // MARK: - Settings

    @Test func changeCode() {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")

        #expect(viewModel.changeCode(current: "123456", new: "654321"))
        viewModel.lock()
        #expect(!viewModel.unlock(code: "123456"))
        #expect(viewModel.unlock(code: "654321"))
    }

    @Test func eraseOptionToggles() {
        let viewModel = makeViewModel()
        viewModel.configure(code: "123456")
        #expect(!viewModel.eraseAfterFailures)

        viewModel.setEraseAfterFailures(true)
        #expect(viewModel.eraseAfterFailures)
        viewModel.setEraseAfterFailures(false)
        #expect(!viewModel.eraseAfterFailures)
    }

    @Test func lockOnBackgroundUpdatesSettings() {
        let viewModel = makeViewModel()
        viewModel.lockOnBackground = false
        #expect(settings.lockOnBackground == false)
    }
}
