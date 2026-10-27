//
//  PasscodeVault.swift
//  Ash
//
//  Holds the vault key while the app is unlocked and enforces the attempt
//  rules (docs/app-lock.md). Pads and conversations are sealed with the
//  vault key before they reach the Keychain.
//

import CryptoKit
import Foundation

enum PasscodeVaultError: Error, Equatable, Sendable {
    case locked
    case notConfigured
    case alreadyConfigured
    case invalidCode
    /// `attemptsBeforeErase` is set when erase after failures is enabled.
    case wrongCode(attemptsBeforeErase: Int?)
    case retryLater(until: Date)
    /// Too many wrong codes with erase enabled: everything was erased.
    case erased
    case biometricsUnavailable
    case corruptedRecord
}

final class PasscodeVault: @unchecked Sendable {
    /// Called after an erase so stored records can be deleted too.
    var onErase: (@Sendable () -> Void)?

    private let store: VaultKeyStore
    private let attempts: LockAttemptStore
    private let now: @Sendable () -> Date
    private let mutex = NSLock()
    private var key: SymmetricKey?

    init(
        store: VaultKeyStore = KeychainVaultKeyStore(),
        attempts: LockAttemptStore = KeychainLockAttemptStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.attempts = attempts
        self.now = now
    }

    // MARK: - State

    var isConfigured: Bool { store.hasCodeCopy }

    var isUnlocked: Bool { withLock { key != nil } }

    var isBiometricUnlockEnabled: Bool { store.hasBiometricCopy }

    var attemptState: LockAttemptState { attempts.load() }

    // MARK: - Code

    /// Set up the code and the vault key; the vault is then unlocked.
    func configure(code: String) throws {
        guard LockPolicy.isValidCode(code) else { throw PasscodeVaultError.invalidCode }
        guard !isConfigured else { throw PasscodeVaultError.alreadyConfigured }
        let newKey = SymmetricKey(size: .bits256)
        try store.storeCodeCopy(Self.data(newKey), code: code)
        withLock { key = newKey }
        attempts.save(LockAttemptState())
    }

    func unlock(code: String) throws {
        guard isConfigured else { throw PasscodeVaultError.notConfigured }
        var state = attempts.load()
        if let retry = state.retryDate(now: now()) {
            throw PasscodeVaultError.retryLater(until: retry)
        }
        guard LockPolicy.isValidCode(code) else { throw PasscodeVaultError.invalidCode }
        do {
            let data = try store.loadCodeCopy(code: code)
            withLock { key = SymmetricKey(data: data) }
            state.failures = 0
            state.lastFailure = nil
            attempts.save(state)
        } catch VaultKeyStoreError.wrongCode {
            state.failures += 1
            state.lastFailure = now()
            attempts.save(state)
            if state.eraseAfterFailures && state.failures >= LockPolicy.eraseThreshold {
                erase()
                throw PasscodeVaultError.erased
            }
            throw PasscodeVaultError.wrongCode(attemptsBeforeErase: state.attemptsBeforeErase)
        }
    }

    func changeCode(current: String, new: String) throws {
        guard LockPolicy.isValidCode(new) else { throw PasscodeVaultError.invalidCode }
        try unlock(code: current)
        let data = try withLock { () throws -> Data in
            guard let key = self.key else { throw PasscodeVaultError.locked }
            return Self.data(key)
        }
        try store.storeCodeCopy(data, code: new)
    }

    // MARK: - Biometrics

    func unlockWithBiometrics(reason: String) async throws {
        guard store.hasBiometricCopy else { throw PasscodeVaultError.biometricsUnavailable }
        do {
            let data = try await store.loadBiometricCopy(reason: reason)
            withLock { key = SymmetricKey(data: data) }
        } catch {
            throw PasscodeVaultError.biometricsUnavailable
        }
    }

    /// Requires the vault to be unlocked, so turning biometrics on always
    /// follows a correct code or an existing biometric unlock.
    func setBiometricUnlock(enabled: Bool) throws {
        if enabled {
            let data = try withLock { () throws -> Data in
                guard let key = self.key else { throw PasscodeVaultError.locked }
                return Self.data(key)
            }
            try store.storeBiometricCopy(data)
        } else {
            try store.deleteBiometricCopy()
        }
    }

    // MARK: - Erase option

    func setEraseAfterFailures(_ enabled: Bool) throws {
        guard isUnlocked else { throw PasscodeVaultError.locked }
        var state = attempts.load()
        state.eraseAfterFailures = enabled
        attempts.save(state)
    }

    // MARK: - Lock and erase

    func lock() {
        withLock { key = nil }
    }

    /// Delete both copies of the vault key, which makes every sealed record
    /// unreadable, then let the owner delete the records.
    func erase() {
        withLock { key = nil }
        do {
            try store.deleteAll()
        } catch {
            Log.error(.security, "Failed to delete vault key: \(error)")
        }
        attempts.save(LockAttemptState())
        onErase?()
    }

    // MARK: - Sealing

    static let marker = Data("GWV1".utf8)

    func seal(_ plaintext: Data) throws -> Data {
        let key = try withLock { () throws -> SymmetricKey in
            guard let key = self.key else { throw PasscodeVaultError.locked }
            return key
        }
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return Self.marker + box.combined
    }

    func open(_ sealed: Data) throws -> Data {
        guard Self.isSealed(sealed) else { throw PasscodeVaultError.corruptedRecord }
        let key = try withLock { () throws -> SymmetricKey in
            guard let key = self.key else { throw PasscodeVaultError.locked }
            return key
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst(Self.marker.count))
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw PasscodeVaultError.corruptedRecord
        }
    }

    static func isSealed(_ data: Data) -> Bool {
        data.starts(with: marker)
    }

    // MARK: - Helpers

    private static func data(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }
}
