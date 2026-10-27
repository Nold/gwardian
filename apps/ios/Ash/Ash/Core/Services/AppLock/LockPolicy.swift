//
//  LockPolicy.swift
//  Ash
//
//  Rules for the app code (docs/app-lock.md): format, delays after wrong
//  codes, and the optional erase after too many failures.
//

import Foundation

enum LockPolicy {
    static let codeLength = 6
    /// Wrong codes in a row that erase everything, when erase is enabled.
    static let eraseThreshold = 10

    static func isValidCode(_ code: String) -> Bool {
        code.count == codeLength && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Wait required before the next try, after `failures` wrong codes in a row.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        switch failures {
        case ..<5: return 0
        case 5: return 30
        case 6: return 60
        case 7: return 5 * 60
        case 8: return 15 * 60
        default: return 60 * 60
        }
    }
}

/// Failed attempts, kept in secure storage outside the vault.
struct LockAttemptState: Codable, Equatable, Sendable {
    var failures = 0
    var lastFailure: Date?
    /// Erase everything after `LockPolicy.eraseThreshold` wrong codes.
    var eraseAfterFailures = false

    /// When the next try is allowed, or nil if it is allowed now.
    func retryDate(now: Date) -> Date? {
        guard let lastFailure else { return nil }
        let retry = lastFailure.addingTimeInterval(LockPolicy.delay(afterFailures: failures))
        return retry > now ? retry : nil
    }

    /// Wrong codes left before erasing, when erase is enabled.
    var attemptsBeforeErase: Int? {
        eraseAfterFailures ? max(LockPolicy.eraseThreshold - failures, 0) : nil
    }
}

protocol LockAttemptStore: Sendable {
    func load() -> LockAttemptState
    func save(_ state: LockAttemptState)
}

/// Keeps the attempt counter in the Keychain, which survives the app being
/// killed and is wiped with the rest on a fresh install.
final class KeychainLockAttemptStore: LockAttemptStore {
    private let keychain: KeychainServiceProtocol
    private let key = "lock.attempts"

    init(keychain: KeychainServiceProtocol = KeychainService(service: "com.monadial.gwardian.lock")) {
        self.keychain = keychain
    }

    func load() -> LockAttemptState {
        guard let data = try? keychain.retrieve(for: key),
              let state = try? JSONDecoder().decode(LockAttemptState.self, from: data)
        else { return LockAttemptState() }
        return state
    }

    func save(_ state: LockAttemptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        do {
            try keychain.store(data: data, for: key)
        } catch {
            Log.error(.security, "Failed to save lock attempts: \(error)")
        }
    }
}
