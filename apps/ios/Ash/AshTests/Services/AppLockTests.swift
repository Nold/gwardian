//
//  AppLockTests.swift
//  AshTests
//
//  Unit tests for the app lock: code rules, attempt delays, vault key
//  handling and sealing of Keychain records (docs/app-lock.md)
//

import Testing
import Foundation
@testable import Ash

// MARK: - Fakes

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

private struct VaultFixture {
    let store = FakeVaultKeyStore()
    let attempts = FakeLockAttemptStore()
    let clock = FakeClock()
    let vault: PasscodeVault

    init() {
        let clock = self.clock
        vault = PasscodeVault(store: store, attempts: attempts, now: { clock.now })
    }

    /// Enter a wrong code, waiting out any delay first.
    func failOnce() {
        if let retry = attempts.state.retryDate(now: clock.now) {
            clock.now = retry
        }
        _ = try? vault.unlock(code: "000000")
    }
}

// MARK: - LockPolicy

struct LockPolicyTests {
    @Test func validCodes() {
        #expect(LockPolicy.isValidCode("123456"))
        #expect(LockPolicy.isValidCode("000000"))
    }

    @Test func invalidCodes() {
        #expect(!LockPolicy.isValidCode(""))
        #expect(!LockPolicy.isValidCode("12345"))
        #expect(!LockPolicy.isValidCode("1234567"))
        #expect(!LockPolicy.isValidCode("12a456"))
        #expect(!LockPolicy.isValidCode("12 456"))
        // Non-ASCII digits (Arabic-Indic)
        #expect(!LockPolicy.isValidCode("١٢٣٤٥٦"))
    }

    @Test func delaysFollowTheTable() {
        #expect(LockPolicy.delay(afterFailures: 0) == 0)
        #expect(LockPolicy.delay(afterFailures: 4) == 0)
        #expect(LockPolicy.delay(afterFailures: 5) == 30)
        #expect(LockPolicy.delay(afterFailures: 6) == 60)
        #expect(LockPolicy.delay(afterFailures: 7) == 300)
        #expect(LockPolicy.delay(afterFailures: 8) == 900)
        #expect(LockPolicy.delay(afterFailures: 9) == 3600)
        #expect(LockPolicy.delay(afterFailures: 25) == 3600)
    }

    @Test func retryDate() {
        let failure = Date(timeIntervalSince1970: 1000)
        let state = LockAttemptState(failures: 5, lastFailure: failure)
        #expect(state.retryDate(now: failure.addingTimeInterval(10)) == failure.addingTimeInterval(30))
        #expect(state.retryDate(now: failure.addingTimeInterval(30)) == nil)
        #expect(LockAttemptState(failures: 3, lastFailure: failure).retryDate(now: failure) == nil)
    }

    @Test func attemptsBeforeErase() {
        #expect(LockAttemptState(failures: 3).attemptsBeforeErase == nil)
        #expect(LockAttemptState(failures: 3, eraseAfterFailures: true).attemptsBeforeErase == 7)
        #expect(LockAttemptState(failures: 12, eraseAfterFailures: true).attemptsBeforeErase == 0)
    }
}

// MARK: - PasscodeVault

struct PasscodeVaultTests {
    @Test func configureUnlocksTheVault() throws {
        let fixture = VaultFixture()
        #expect(!fixture.vault.isConfigured)
        try fixture.vault.configure(code: "123456")
        #expect(fixture.vault.isConfigured)
        #expect(fixture.vault.isUnlocked)
    }

    @Test func configureRejectsInvalidCodeAndSecondSetup() throws {
        let fixture = VaultFixture()
        #expect(throws: PasscodeVaultError.invalidCode) { try fixture.vault.configure(code: "1234") }
        try fixture.vault.configure(code: "123456")
        #expect(throws: PasscodeVaultError.alreadyConfigured) { try fixture.vault.configure(code: "654321") }
    }

    @Test func unlockBeforeSetupFails() {
        let fixture = VaultFixture()
        #expect(throws: PasscodeVaultError.notConfigured) { try fixture.vault.unlock(code: "123456") }
    }

    @Test func lockAndUnlockWithCode() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let sealed = try fixture.vault.seal(Data("pad".utf8))

        fixture.vault.lock()
        #expect(!fixture.vault.isUnlocked)
        #expect(throws: PasscodeVaultError.locked) { try fixture.vault.open(sealed) }

        try fixture.vault.unlock(code: "123456")
        #expect(try fixture.vault.open(sealed) == Data("pad".utf8))
    }

    @Test func wrongCodeCountsFailures() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()

        #expect(throws: PasscodeVaultError.wrongCode(attemptsBeforeErase: nil)) {
            try fixture.vault.unlock(code: "111111")
        }
        #expect(!fixture.vault.isUnlocked)
        #expect(fixture.attempts.state.failures == 1)
    }

    @Test func correctCodeResetsFailures() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        for _ in 0..<3 { fixture.failOnce() }

        try fixture.vault.unlock(code: "123456")
        #expect(fixture.attempts.state.failures == 0)
        #expect(fixture.attempts.state.lastFailure == nil)
    }

    @Test func fifthWrongCodeImposesDelay() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        for _ in 0..<5 { fixture.failOnce() }

        let until = fixture.clock.now.addingTimeInterval(30)
        // Even the correct code is refused during the delay
        #expect(throws: PasscodeVaultError.retryLater(until: until)) {
            try fixture.vault.unlock(code: "123456")
        }
        #expect(fixture.attempts.state.failures == 5)

        fixture.clock.advance(30)
        try fixture.vault.unlock(code: "123456")
        #expect(fixture.vault.isUnlocked)
    }

    @Test func tenWrongCodesWithoutEraseOptionKeepEverything() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        for _ in 0..<12 { fixture.failOnce() }

        #expect(fixture.vault.isConfigured)
        fixture.clock.advance(3600)
        try fixture.vault.unlock(code: "123456")
    }

    @Test func tenWrongCodesWithEraseOptionEraseEverything() throws {
        let fixture = VaultFixture()
        let erased = ErasedFlag()
        fixture.vault.onErase = { erased.value = true }
        try fixture.vault.configure(code: "123456")
        try fixture.vault.setEraseAfterFailures(true)
        try fixture.vault.setBiometricUnlock(enabled: true)
        fixture.vault.lock()

        for _ in 0..<9 { fixture.failOnce() }
        #expect(fixture.vault.isConfigured)
        #expect(fixture.attempts.state.attemptsBeforeErase == 1)

        fixture.clock.advance(3600)
        #expect(throws: PasscodeVaultError.erased) { try fixture.vault.unlock(code: "000000") }
        #expect(!fixture.vault.isConfigured)
        #expect(!fixture.vault.isBiometricUnlockEnabled)
        #expect(!fixture.vault.isUnlocked)
        #expect(erased.value)
        #expect(fixture.attempts.state == LockAttemptState())
    }

    @Test func wrongCodeReportsAttemptsLeftWhenEraseEnabled() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        try fixture.vault.setEraseAfterFailures(true)
        fixture.vault.lock()

        #expect(throws: PasscodeVaultError.wrongCode(attemptsBeforeErase: 9)) {
            try fixture.vault.unlock(code: "111111")
        }
    }

    @Test func eraseOptionRequiresUnlockedVault() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        #expect(throws: PasscodeVaultError.locked) { try fixture.vault.setEraseAfterFailures(true) }
    }

    @Test func changeCodeKeepsTheVaultKey() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let sealed = try fixture.vault.seal(Data("pad".utf8))

        try fixture.vault.changeCode(current: "123456", new: "654321")
        fixture.vault.lock()

        #expect(throws: PasscodeVaultError.wrongCode(attemptsBeforeErase: nil)) {
            try fixture.vault.unlock(code: "123456")
        }
        try fixture.vault.unlock(code: "654321")
        #expect(try fixture.vault.open(sealed) == Data("pad".utf8))
    }

    @Test func changeCodeNeedsTheCurrentCode() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        #expect(throws: PasscodeVaultError.wrongCode(attemptsBeforeErase: nil)) {
            try fixture.vault.changeCode(current: "111111", new: "654321")
        }
        #expect(throws: PasscodeVaultError.invalidCode) {
            try fixture.vault.changeCode(current: "123456", new: "12")
        }
    }

    @Test func biometricUnlock() async throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let sealed = try fixture.vault.seal(Data("pad".utf8))
        try fixture.vault.setBiometricUnlock(enabled: true)
        #expect(fixture.vault.isBiometricUnlockEnabled)
        fixture.vault.lock()

        try await fixture.vault.unlockWithBiometrics(reason: "test")
        #expect(try fixture.vault.open(sealed) == Data("pad".utf8))
    }

    @Test func biometricUnlockFailsWhenDisabledOrInvalidated() async throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        await #expect(throws: PasscodeVaultError.biometricsUnavailable) {
            try await fixture.vault.unlockWithBiometrics(reason: "test")
        }

        try fixture.vault.unlock(code: "123456")
        try fixture.vault.setBiometricUnlock(enabled: true)
        fixture.vault.lock()
        fixture.store.biometricsFail = true
        await #expect(throws: PasscodeVaultError.biometricsUnavailable) {
            try await fixture.vault.unlockWithBiometrics(reason: "test")
        }
        #expect(!fixture.vault.isUnlocked)
    }

    @Test func enablingBiometricsRequiresUnlockedVault() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        fixture.vault.lock()
        #expect(throws: PasscodeVaultError.locked) { try fixture.vault.setBiometricUnlock(enabled: true) }
    }

    @Test func sealedRecordsAreMarkedAndAuthenticated() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let plaintext = Data("secret pad bytes".utf8)
        let sealed = try fixture.vault.seal(plaintext)

        #expect(PasscodeVault.isSealed(sealed))
        #expect(!PasscodeVault.isSealed(plaintext))
        #expect(sealed.range(of: plaintext) == nil)

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: PasscodeVaultError.corruptedRecord) { try fixture.vault.open(tampered) }
        #expect(throws: PasscodeVaultError.corruptedRecord) { try fixture.vault.open(plaintext) }
    }

    @Test func recordsFromAnotherVaultDoNotOpen() throws {
        let first = VaultFixture()
        let second = VaultFixture()
        try first.vault.configure(code: "123456")
        try second.vault.configure(code: "123456")
        let sealed = try first.vault.seal(Data("pad".utf8))
        #expect(throws: PasscodeVaultError.corruptedRecord) { try second.vault.open(sealed) }
    }
}

private final class ErasedFlag: @unchecked Sendable {
    var value = false
}

// MARK: - VaultedKeychainService

struct VaultedKeychainServiceTests {
    @Test func storesSealedAndReadsPlain() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let base = MockKeychainService()
        let keychain = VaultedKeychainService(base: base, vault: fixture.vault)

        try keychain.store(data: Data("pad".utf8), for: "pad.a")
        let raw = try #require(try base.retrieve(for: "pad.a"))
        #expect(PasscodeVault.isSealed(raw))
        #expect(try keychain.retrieve(for: "pad.a") == Data("pad".utf8))
    }

    @Test func lockedVaultRefusesReadsAndWrites() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let base = MockKeychainService()
        let keychain = VaultedKeychainService(base: base, vault: fixture.vault)
        try keychain.store(data: Data("pad".utf8), for: "pad.a")
        try base.store(data: Data("legacy".utf8), for: "pad.b")
        fixture.vault.lock()

        #expect(throws: PasscodeVaultError.locked) { try keychain.retrieve(for: "pad.a") }
        #expect(throws: PasscodeVaultError.locked) { try keychain.retrieve(for: "pad.b") }
        #expect(throws: PasscodeVaultError.locked) { try keychain.store(data: Data(), for: "pad.c") }
        #expect(try keychain.retrieve(for: "missing") == nil)
    }

    @Test func legacyRecordIsSealedOnRead() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let base = MockKeychainService()
        try base.store(data: Data("legacy".utf8), for: "pad.a")
        let keychain = VaultedKeychainService(base: base, vault: fixture.vault)

        #expect(try keychain.retrieve(for: "pad.a") == Data("legacy".utf8))
        let raw = try #require(try base.retrieve(for: "pad.a"))
        #expect(PasscodeVault.isSealed(raw))
    }

    @Test func sealLegacyRecordsMigratesOnlyPlaintext() throws {
        let fixture = VaultFixture()
        try fixture.vault.configure(code: "123456")
        let base = MockKeychainService()
        let keychain = VaultedKeychainService(base: base, vault: fixture.vault)
        try keychain.store(data: Data("new".utf8), for: "pad.new")
        try base.store(data: Data("old1".utf8), for: "pad.old1")
        try base.store(data: Data("old2".utf8), for: "conversation.old2")

        #expect(try keychain.sealLegacyRecords() == 2)
        for key in try base.allKeys(withPrefix: "") {
            #expect(PasscodeVault.isSealed(try #require(try base.retrieve(for: key))))
        }
        #expect(try keychain.retrieve(for: "pad.old1") == Data("old1".utf8))
        #expect(try keychain.retrieve(for: "conversation.old2") == Data("old2".utf8))
        #expect(try keychain.sealLegacyRecords() == 0)
    }
}
