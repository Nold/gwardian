//
//  VaultKeyStore.swift
//  Ash
//
//  Where the vault key lives at rest (docs/app-lock.md): one Keychain copy
//  readable only with the app code, and an optional copy unlocked by
//  biometrics that the system deletes when enrollment changes.
//

import Foundation
import LocalAuthentication
import Security

enum VaultKeyStoreError: Error, Equatable, Sendable {
    case wrongCode
    case notFound
    /// The biometric copy is gone (enrollment changed) or was cancelled.
    case biometricsUnavailable
    case keychain(OSStatus)
}

protocol VaultKeyStore: Sendable {
    var hasCodeCopy: Bool { get }
    var hasBiometricCopy: Bool { get }
    func storeCodeCopy(_ key: Data, code: String) throws
    func loadCodeCopy(code: String) throws -> Data
    func storeBiometricCopy(_ key: Data) throws
    func loadBiometricCopy(reason: String) async throws -> Data
    func deleteBiometricCopy() throws
    func deleteAll() throws
}

final class KeychainVaultKeyStore: VaultKeyStore {
    private let service: String
    private let codeAccount = "vault.code"
    private let biometricAccount = "vault.biometric"
    /// Plain marker so presence can be checked without the code.
    private let markerAccount = "vault.configured"

    init(service: String = "com.monadial.gwardian.vault") {
        self.service = service
    }

    var hasCodeCopy: Bool { exists(markerAccount) }

    var hasBiometricCopy: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(biometricAccount)
        query[kSecUseAuthenticationContext as String] = context
        // An item that needs authentication answers "interaction not allowed"
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func storeCodeCopy(_ key: Data, code: String) throws {
        let context = try codeContext(code)
        try delete(codeAccount)
        var query = baseQuery(codeAccount)
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = try accessControl(.applicationPassword)
        query[kSecUseAuthenticationContext as String] = context
        try check(SecItemAdd(query as CFDictionary, nil))

        var marker = baseQuery(markerAccount)
        marker[kSecValueData as String] = Data([1])
        marker[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try delete(markerAccount)
        try check(SecItemAdd(marker as CFDictionary, nil))
    }

    func loadCodeCopy(code: String) throws -> Data {
        var query = baseQuery(codeAccount)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = try codeContext(code)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw VaultKeyStoreError.keychain(status) }
            return data
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw VaultKeyStoreError.wrongCode
        case errSecItemNotFound:
            throw VaultKeyStoreError.notFound
        default:
            throw VaultKeyStoreError.keychain(status)
        }
    }

    func storeBiometricCopy(_ key: Data) throws {
        try delete(biometricAccount)
        var query = baseQuery(biometricAccount)
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = try accessControl(.biometryCurrentSet)
        try check(SecItemAdd(query as CFDictionary, nil))
    }

    func loadBiometricCopy(reason: String) async throws -> Data {
        let service = self.service
        let account = biometricAccount
        // SecItemCopyMatching blocks while the system shows the Face ID prompt
        return try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context
            ]
            query[kSecUseOperationPrompt as String] = reason
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw VaultKeyStoreError.biometricsUnavailable
            }
            return data
        }.value
    }

    func deleteBiometricCopy() throws {
        try delete(biometricAccount)
    }

    func deleteAll() throws {
        try delete(codeAccount)
        try delete(biometricAccount)
        try delete(markerAccount)
    }

    // MARK: - Helpers

    private func codeContext(_ code: String) throws -> LAContext {
        let context = LAContext()
        // Never let the system show its own password prompt
        context.interactionNotAllowed = true
        guard context.setCredential(Data(code.utf8), type: .applicationPassword) else {
            throw VaultKeyStoreError.keychain(errSecParam)
        }
        return context
    }

    private func accessControl(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            throw VaultKeyStoreError.keychain(errSecParam)
        }
        return control
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func exists(_ account: String) -> Bool {
        SecItemCopyMatching(baseQuery(account) as CFDictionary, nil) == errSecSuccess
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultKeyStoreError.keychain(status)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw VaultKeyStoreError.keychain(status) }
    }
}
