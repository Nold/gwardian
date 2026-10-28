//
//  CryptoService.swift
//  Ash
//
//  Core cryptographic operations using ash-core FFI
//

import Foundation
import Security

/// Message types for authenticated encryption
enum MessageType: UInt8, Sendable {
    case text = 0x01
    case location = 0x02
    /// Request to delete one of the sender's messages (core::content)
    case delete = 0x03
    /// Text with its own lifetime chosen by the sender (core::content)
    case expiringText = 0x04
}

/// Result of authenticated decryption
struct AuthenticatedDecryptResult: Sendable {
    let plaintext: [UInt8]
    let messageType: MessageType
    let authTag: [UInt8]  // 32-byte authentication tag for display
}

/// Authentication overhead constant (64 bytes for Wegman-Carter MAC)
let AUTH_OVERHEAD: Int = 64

protocol CryptoServiceProtocol: Sendable {
    /// Legacy encrypt (no authentication) - DO NOT USE for new code
    func encrypt(plaintext: [UInt8], key: [UInt8]) throws -> [UInt8]
    /// Legacy decrypt (no authentication) - DO NOT USE for new code
    func decrypt(ciphertext: [UInt8], key: [UInt8]) throws -> [UInt8]

    /// Authenticated encryption with Wegman-Carter MAC
    /// - Parameters:
    ///   - plaintext: Data to encrypt
    ///   - authKey: 64 bytes from pad for authentication
    ///   - encryptionKey: N bytes from pad for encryption (same length as plaintext)
    ///   - messageType: Type of message (text or location)
    /// - Returns: Encoded frame with ciphertext and 32-byte authentication tag
    func encryptAuthenticated(plaintext: [UInt8], authKey: [UInt8], encryptionKey: [UInt8], messageType: MessageType) throws -> [UInt8]

    /// Authenticated decryption - verifies tag BEFORE decryption
    /// - Parameters:
    ///   - encodedFrame: Full message frame from encryptAuthenticated
    ///   - authKey: 64 bytes from pad for authentication
    ///   - encryptionKey: N bytes from pad for decryption
    /// - Returns: Decrypted plaintext, message type, and authentication tag
    /// - Throws: CryptoError.authenticationFailed if tag verification fails
    func decryptAuthenticated(encodedFrame: [UInt8], authKey: [UInt8], encryptionKey: [UInt8]) throws -> AuthenticatedDecryptResult

    /// Calculate total pad consumption for a message
    /// Returns: 64 (auth) + plaintext length
    func calculatePadConsumption(plaintextLength: Int) -> Int

    /// Generate a secure pad of the specified size (32KB - 10MB)
    func generateSecurePad(userEntropy: [UInt8], sizeBytes: Int) throws -> [UInt8]
    func generateMnemonic(from padBytes: [UInt8], wordCount: Int) -> [String]
}

enum CryptoError: Error, Sendable {
    case keyLengthMismatch
    case invalidData
    case entropyInsufficient
    case randomGenerationFailed
    case authenticationFailed
    case ffiError(String)
}

final class CryptoService: CryptoServiceProtocol, Sendable {

    func encrypt(plaintext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        do {
            return try Ash.encrypt(key: key, plaintext: plaintext)
        } catch let error as AshError {
            throw CryptoError.ffiError(error.localizedDescription)
        }
    }

    func decrypt(ciphertext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        do {
            return try Ash.decrypt(key: key, ciphertext: ciphertext)
        } catch let error as AshError {
            throw CryptoError.ffiError(error.localizedDescription)
        }
    }

    func encryptAuthenticated(plaintext: [UInt8], authKey: [UInt8], encryptionKey: [UInt8], messageType: MessageType) throws -> [UInt8] {
        do {
            return try Ash.encryptAuthenticated(
                authKey: authKey,
                encryptionKey: encryptionKey,
                plaintext: plaintext,
                msgType: messageType.rawValue
            )
        } catch let error as AshError {
            if case .AuthenticationFailed = error {
                throw CryptoError.authenticationFailed
            }
            throw CryptoError.ffiError(error.localizedDescription)
        }
    }

    func decryptAuthenticated(encodedFrame: [UInt8], authKey: [UInt8], encryptionKey: [UInt8]) throws -> AuthenticatedDecryptResult {
        do {
            let result = try Ash.decryptAuthenticated(
                authKey: authKey,
                encryptionKey: encryptionKey,
                encodedFrame: encodedFrame
            )
            let messageType = MessageType(rawValue: result.msgType) ?? .text
            return AuthenticatedDecryptResult(
                plaintext: result.plaintext,
                messageType: messageType,
                authTag: result.tag
            )
        } catch let error as AshError {
            if case .AuthenticationFailed = error {
                throw CryptoError.authenticationFailed
            }
            throw CryptoError.ffiError(error.localizedDescription)
        }
    }

    func calculatePadConsumption(plaintextLength: Int) -> Int {
        return AUTH_OVERHEAD + plaintextLength
    }

    func generateSecurePad(userEntropy: [UInt8], sizeBytes: Int) throws -> [UInt8] {
        // Validate size is within allowed bounds (32KB - 10MB)
        let minSize = Int(PadSizeLimits.minimumBytes)
        let maxSize = Int(PadSizeLimits.maximumBytes)

        guard sizeBytes >= minSize && sizeBytes <= maxSize else {
            Log.error(.crypto, "Invalid pad size: \(sizeBytes) bytes (must be \(minSize)-\(maxSize))")
            throw CryptoError.invalidData
        }

        var randomBytes = [UInt8](repeating: 0, count: sizeBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, sizeBytes, &randomBytes)

        guard status == errSecSuccess else {
            Log.error(.crypto, "SecRandomCopyBytes failed: \(status)")
            throw CryptoError.randomGenerationFailed
        }

        if !userEntropy.isEmpty {
            for i in 0..<sizeBytes {
                randomBytes[i] ^= userEntropy[i % userEntropy.count]
            }
        }

        Log.debug(.crypto, "Generated \(sizeBytes) byte pad with \(userEntropy.count) entropy bytes")
        return randomBytes
    }

    func generateMnemonic(from padBytes: [UInt8], wordCount: Int) -> [String] {
        if wordCount == 6 {
            return Ash.generateMnemonic(padBytes: padBytes)
        } else {
            return Ash.generateMnemonicWithCount(padBytes: padBytes, wordCount: UInt32(wordCount))
        }
    }
}

/// Namespace for ash-core FFI functions
/// Wraps global functions to avoid naming conflicts
private enum Ash {
    static func encrypt(key: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        try _encrypt(key: key, plaintext: plaintext)
    }

    static func decrypt(key: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
        try _decrypt(key: key, ciphertext: ciphertext)
    }

    static func encryptAuthenticated(authKey: [UInt8], encryptionKey: [UInt8], plaintext: [UInt8], msgType: UInt8) throws -> [UInt8] {
        try _encryptAuthenticated(authKey: authKey, encryptionKey: encryptionKey, plaintext: plaintext, msgType: msgType)
    }

    static func decryptAuthenticated(authKey: [UInt8], encryptionKey: [UInt8], encodedFrame: [UInt8]) throws -> DecryptedMessage {
        try _decryptAuthenticated(authKey: authKey, encryptionKey: encryptionKey, encodedFrame: encodedFrame)
    }

    static func generateMnemonic(padBytes: [UInt8]) -> [String] {
        _generateMnemonic(padBytes: padBytes)
    }

    static func generateMnemonicWithCount(padBytes: [UInt8], wordCount: UInt32) -> [String] {
        _generateMnemonicWithCount(padBytes: padBytes, wordCount: wordCount)
    }
}

// Private wrappers to call global FFI functions (prefixed with _ to avoid shadowing)
private func _encrypt(key: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
    try encrypt(key: key, plaintext: plaintext)
}

private func _decrypt(key: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
    try decrypt(key: key, ciphertext: ciphertext)
}

private func _encryptAuthenticated(authKey: [UInt8], encryptionKey: [UInt8], plaintext: [UInt8], msgType: UInt8) throws -> [UInt8] {
    try encryptAuthenticated(authKey: authKey, encryptionKey: encryptionKey, plaintext: plaintext, msgType: msgType)
}

private func _decryptAuthenticated(authKey: [UInt8], encryptionKey: [UInt8], encodedFrame: [UInt8]) throws -> DecryptedMessage {
    try decryptAuthenticated(authKey: authKey, encryptionKey: encryptionKey, encodedFrame: encodedFrame)
}

private func _generateMnemonic(padBytes: [UInt8]) -> [String] {
    generateMnemonic(padBytes: padBytes)
}

private func _generateMnemonicWithCount(padBytes: [UInt8], wordCount: UInt32) -> [String] {
    generateMnemonicWithCount(padBytes: padBytes, wordCount: wordCount)
}
