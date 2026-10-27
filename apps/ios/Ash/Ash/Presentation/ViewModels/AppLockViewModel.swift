//
//  AppLockViewModel.swift
//  Ash
//
//  Presentation Layer - App lock state (docs/app-lock.md): mandatory app
//  code, optional biometric shortcut, delays and optional erase
//

import SwiftUI

@MainActor
@Observable
final class AppLockViewModel {
    enum Phase: Equatable {
        /// No app code yet: it must be chosen before anything else
        case setup
        case locked
        case unlocked
    }

    // MARK: - Dependencies

    private let vault: PasscodeVault
    private let biometricService: BiometricServiceProtocol
    private let settingsService: SettingsServiceProtocol
    /// Run once after the code is chosen, to seal records written before
    private let onConfigured: () -> Void

    // MARK: - State

    private(set) var phase: Phase
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    /// Set while a delay after wrong codes is running
    private(set) var retryUntil: Date?
    /// Set when erase after failures is enabled
    private(set) var attemptsBeforeErase: Int?
    /// Bumped on every wrong code, so the screen can react
    private(set) var wrongCodeCount = 0
    /// Everything was erased after too many wrong codes
    private(set) var wasErased = false
    private(set) var isBiometricUnlockEnabled = false
    private(set) var eraseAfterFailures = false

    // MARK: - Computed Properties

    var isLocked: Bool { phase != .unlocked }

    var biometricType: BiometricType {
        biometricService.availableBiometricType
    }

    var canUseBiometrics: Bool {
        biometricService.canUseBiometrics
    }

    var lockOnBackground: Bool {
        get { settingsService.lockOnBackground }
        set {
            let settings = settingsService
            settings.lockOnBackground = newValue
        }
    }

    // MARK: - Initialization

    init(
        vault: PasscodeVault,
        biometricService: BiometricServiceProtocol = BiometricService(),
        settingsService: SettingsServiceProtocol = SettingsService(),
        onConfigured: @escaping () -> Void = {}
    ) {
        self.vault = vault
        self.biometricService = biometricService
        self.settingsService = settingsService
        self.onConfigured = onConfigured
        phase = vault.isConfigured ? .locked : .setup
        refresh()
    }

    // MARK: - Setup

    /// Choose the app code. Returns false if it was refused.
    @discardableResult
    func configure(code: String) -> Bool {
        do {
            try vault.configure(code: code)
            onConfigured()
            wasErased = false
            errorMessage = nil
            phase = .unlocked
            refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: - Unlock

    /// Returns true when the code was correct.
    @discardableResult
    func unlock(code: String) -> Bool {
        do {
            try vault.unlock(code: code)
            errorMessage = nil
            phase = .unlocked
            refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func unlockWithBiometrics() async {
        guard phase == .locked, isBiometricUnlockEnabled, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await vault.unlockWithBiometrics(reason: "Unlock to access your conversations")
            errorMessage = nil
            phase = .unlocked
        } catch {
            // Cancelled, or the enrollment changed and the shortcut is gone
            refresh()
        }
    }

    // MARK: - Lock

    func lock() {
        guard phase == .unlocked else { return }
        vault.lock()
        phase = .locked
        errorMessage = nil
        refresh()
    }

    func appDidEnterBackground() {
        if lockOnBackground {
            lock()
        }
    }

    func appDidBecomeActive() {
        if isLocked {
            errorMessage = nil
            refresh()
        }
    }

    // MARK: - Settings

    /// Enabling asks for biometrics once, so it is known to work.
    @discardableResult
    func setBiometricUnlock(_ enabled: Bool) async -> Bool {
        do {
            if enabled {
                guard canUseBiometrics else { return false }
                guard try await biometricService.authenticate(reason: "Allow unlocking with \(biometricType.displayName)")
                else { return false }
            }
            try vault.setBiometricUnlock(enabled: enabled)
            errorMessage = nil
        } catch {
            Log.warning(.security, "Failed to change biometric unlock")
        }
        refresh()
        return isBiometricUnlockEnabled == enabled
    }

    func setEraseAfterFailures(_ enabled: Bool) {
        do {
            try vault.setEraseAfterFailures(enabled)
        } catch {
            Log.warning(.security, "Failed to change erase option")
        }
        refresh()
    }

    /// A wrong current code counts as a failed attempt.
    func changeCode(current: String, new: String) -> Bool {
        do {
            try vault.changeCode(current: current, new: new)
            errorMessage = nil
            refresh()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Helpers

    private func refresh() {
        let state = vault.attemptState
        retryUntil = state.retryDate(now: Date())
        attemptsBeforeErase = state.attemptsBeforeErase
        eraseAfterFailures = state.eraseAfterFailures
        isBiometricUnlockEnabled = vault.isBiometricUnlockEnabled
    }

    private func handle(_ error: Error) {
        guard let error = error as? PasscodeVaultError else {
            errorMessage = "Something went wrong. Try again."
            return
        }
        switch error {
        case .wrongCode(let attemptsLeft):
            wrongCodeCount += 1
            if let attemptsLeft {
                errorMessage = attemptsLeft == 1
                    ? "Wrong code. 1 attempt left before everything is erased."
                    : "Wrong code. \(attemptsLeft) attempts left before everything is erased."
            } else {
                errorMessage = "Wrong code."
            }
        case .retryLater:
            errorMessage = nil
        case .erased:
            wasErased = true
            errorMessage = nil
            phase = .setup
        case .invalidCode:
            errorMessage = "The code must have \(LockPolicy.codeLength) digits."
        case .locked, .notConfigured, .alreadyConfigured, .biometricsUnavailable, .corruptedRecord:
            errorMessage = "Something went wrong. Try again."
        }
        refresh()
    }
}
