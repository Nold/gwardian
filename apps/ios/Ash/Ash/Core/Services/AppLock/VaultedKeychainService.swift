//
//  VaultedKeychainService.swift
//  Ash
//
//  Keychain storage whose values are sealed with the vault key, for pads and
//  conversations. Reads and writes fail with `PasscodeVaultError.locked`
//  while the app is locked.
//

import Foundation

final class VaultedKeychainService: KeychainServiceProtocol {
    private let base: KeychainServiceProtocol
    private let vault: PasscodeVault

    init(base: KeychainServiceProtocol, vault: PasscodeVault) {
        self.base = base
        self.vault = vault
    }

    func store(data: Data, for key: String) throws {
        try base.store(data: vault.seal(data), for: key)
    }

    func retrieve(for key: String) throws -> Data? {
        guard let stored = try base.retrieve(for: key) else { return nil }
        if PasscodeVault.isSealed(stored) {
            return try vault.open(stored)
        }
        // Written before the app lock existed: seal it now
        guard vault.isUnlocked else { throw PasscodeVaultError.locked }
        try base.store(data: vault.seal(stored), for: key)
        return stored
    }

    func delete(for key: String) throws {
        try base.delete(for: key)
    }

    func deleteAll() throws {
        try base.deleteAll()
    }

    func exists(for key: String) throws -> Bool {
        try base.exists(for: key)
    }

    func allKeys(withPrefix prefix: String) throws -> [String] {
        try base.allKeys(withPrefix: prefix)
    }

    /// Seal every record still stored in plaintext; run once after the code
    /// is set up. Returns how many records were sealed.
    @discardableResult
    func sealLegacyRecords() throws -> Int {
        var sealed = 0
        for key in try base.allKeys(withPrefix: "") {
            guard let stored = try base.retrieve(for: key), !PasscodeVault.isSealed(stored) else { continue }
            try base.store(data: vault.seal(stored), for: key)
            sealed += 1
        }
        return sealed
    }
}
