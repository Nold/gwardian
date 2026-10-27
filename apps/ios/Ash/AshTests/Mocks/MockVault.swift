//
//  MockVault.swift
//  AshTests
//
//  In-memory stores for PasscodeVault
//

import Foundation
@testable import Ash

/// In-memory vault key store; the code copy opens only with the same code.
final class FakeVaultKeyStore: VaultKeyStore, @unchecked Sendable {
    private var codeCopy: (key: Data, code: String)?
    private var biometricCopy: Data?
    var biometricsFail = false

    var hasCodeCopy: Bool { codeCopy != nil }
    var hasBiometricCopy: Bool { biometricCopy != nil }

    func storeCodeCopy(_ key: Data, code: String) throws {
        codeCopy = (key, code)
    }

    func loadCodeCopy(code: String) throws -> Data {
        guard let codeCopy else { throw VaultKeyStoreError.notFound }
        guard codeCopy.code == code else { throw VaultKeyStoreError.wrongCode }
        return codeCopy.key
    }

    func storeBiometricCopy(_ key: Data) throws {
        biometricCopy = key
    }

    func loadBiometricCopy(reason: String) async throws -> Data {
        guard let biometricCopy, !biometricsFail else { throw VaultKeyStoreError.biometricsUnavailable }
        return biometricCopy
    }

    func deleteBiometricCopy() throws {
        biometricCopy = nil
    }

    func deleteAll() throws {
        codeCopy = nil
        biometricCopy = nil
    }
}

final class FakeLockAttemptStore: LockAttemptStore, @unchecked Sendable {
    var state = LockAttemptState()
    func load() -> LockAttemptState { state }
    func save(_ state: LockAttemptState) { self.state = state }
}

final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

extension PasscodeVault {
    /// A vault backed by in-memory stores
    static func inMemory() -> PasscodeVault {
        PasscodeVault(store: FakeVaultKeyStore(), attempts: FakeLockAttemptStore())
    }
}
