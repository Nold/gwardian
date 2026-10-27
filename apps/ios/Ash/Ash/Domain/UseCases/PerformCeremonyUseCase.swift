//
//  PerformCeremonyUseCase.swift
//  Ash
//
//  Domain Layer - Use Case for key exchange ceremony
//  Uses ash-core FFI for cryptographic operations with fountain codes
//
//  Fountain codes enable reliable QR transfer:
//  - Receiver can decode from ANY sufficient subset of blocks
//  - No need to wait for specific frames
//  - Just keep scanning until complete
//

import Foundation
import CryptoKit

/// Conversation flags encode various settings exchanged during ceremony.
/// These flags are embedded in the QR metadata and shared between both parties.
///
/// Bit layout:
/// - Bits 0-2:   Receiver notifications (new message, expiring, expired)
/// - Bits 3-4:   Sender notifications (delivery failed, message read)
/// - Bits 5-7:   Reserved for future notification types
/// - Bit 8:      Persistence consent (local message storage)
/// - Bits 9-11:  Message padding settings (enabled flag + size)
/// - Bits 12-15: Conversation accent color
enum ConversationFlagsConstants {

    // MARK: - Notification Flags (Receiver) - Bits 0-2

    /// Notify receiver when new message arrives
    static let notifyNewMessage: UInt16 = 1 << 0
    /// Notify receiver before message expires (5min and 1min warnings)
    static let notifyMessageExpiring: UInt16 = 1 << 1
    /// Notify receiver when message expires
    static let notifyMessageExpired: UInt16 = 1 << 2

    // MARK: - Notification Flags (Sender) - Bits 3-4

    /// Notify sender if message TTL expires unread
    static let notifyDeliveryFailed: UInt16 = 1 << 3
    /// Reserved: notify sender when message is read (future read receipts)
    static let notifyMessageRead: UInt16 = 1 << 4

    // Bits 5-7: Reserved for future notification types

    /// Default notification flags: new message + expiring + delivery failed
    static let defaultFlags: UInt16 = notifyNewMessage | notifyMessageExpiring | notifyDeliveryFailed

    // MARK: - Security Flags - Bits 8-11

    /// User consented to local message persistence (requires Face ID + disappearing messages)
    static let persistenceConsent: UInt16 = 1 << 8

    /// Message padding enabled flag (bit 9)
    static let messagePaddingEnabled: UInt16 = 1 << 9
    /// Message padding size encoding (bits 10-11): 00=32, 01=64, 10=128, 11=256 bytes
    static let paddingSizeShift: UInt16 = 10
    static let paddingSizeMask: UInt16 = 0x0C00  // bits 10-11

    // MARK: - UI Flags - Bits 12-15

    /// Color encoding shift (4 bits for up to 16 colors)
    static let colorShift: UInt16 = 12
    static let colorMask: UInt16 = 0xF000  // bits 12-15

    // MARK: - Color Encoding/Decoding

    /// Encode color index into flags
    static func encodeColor(_ color: ConversationColor, into flags: UInt16) -> UInt16 {
        let colorIndex = UInt16(ConversationColor.allCases.firstIndex(of: color) ?? 0)
        return (flags & ~colorMask) | (colorIndex << colorShift)
    }

    /// Decode color from flags
    static func decodeColor(from flags: UInt16) -> ConversationColor {
        let colorIndex = Int((flags & colorMask) >> colorShift)
        let allColors = ConversationColor.allCases
        guard colorIndex < allColors.count else { return .indigo }
        return allColors[colorIndex]
    }

    // MARK: - Persistence Consent

    /// Check if persistence consent flag is set
    static func hasPersistenceConsent(_ flags: UInt16) -> Bool {
        (flags & persistenceConsent) != 0
    }

    // MARK: - Message Padding Encoding/Decoding

    /// Encode message padding settings into flags
    static func encodePadding(enabled: Bool, size: MessagePaddingSize, into flags: UInt16) -> UInt16 {
        var result = flags & ~(messagePaddingEnabled | paddingSizeMask)
        if enabled {
            result |= messagePaddingEnabled
            // Encode size: 32=0, 64=1, 128=2, 256=3, 512=4
            let sizeIndex: UInt16 = switch size {
            case .bytes32: 0
            case .bytes64: 1
            case .bytes128: 2
            case .bytes256: 3
            case .bytes512: 4
            }
            result |= (sizeIndex << paddingSizeShift)
        }
        return result
    }

    /// Check if message padding is enabled
    static func hasMessagePadding(_ flags: UInt16) -> Bool {
        (flags & messagePaddingEnabled) != 0
    }

    /// Decode message padding size from flags
    static func decodePaddingSize(from flags: UInt16) -> MessagePaddingSize {
        let sizeIndex = Int((flags & paddingSizeMask) >> paddingSizeShift)
        return switch sizeIndex {
        case 0: .bytes32
        case 1: .bytes64
        case 2: .bytes128
        case 3: .bytes256
        default: .bytes32
        }
    }
}

/// Ceremony metadata that gets transferred via QR
/// Contains TTL, disappearing messages, conversation flags, and relay URL
struct CeremonyMetadataSwift: Sendable {
    let ttlSeconds: UInt64
    let disappearingMessagesSeconds: UInt32
    let conversationFlags: UInt16
    let relayURL: String

    init(
        ttlSeconds: UInt64 = MessageTTL.defaultSeconds,
        disappearingMessagesSeconds: UInt32 = 0,
        conversationFlags: UInt16 = ConversationFlagsConstants.defaultFlags,
        relayURL: String
    ) {
        self.ttlSeconds = ttlSeconds
        self.disappearingMessagesSeconds = disappearingMessagesSeconds
        self.conversationFlags = conversationFlags
        self.relayURL = relayURL
    }

    // Helper methods for checking notification flags
    var notifyNewMessage: Bool { (conversationFlags & ConversationFlagsConstants.notifyNewMessage) != 0 }
    var notifyMessageExpiring: Bool { (conversationFlags & ConversationFlagsConstants.notifyMessageExpiring) != 0 }
    var notifyMessageExpired: Bool { (conversationFlags & ConversationFlagsConstants.notifyMessageExpired) != 0 }
    var notifyDeliveryFailed: Bool { (conversationFlags & ConversationFlagsConstants.notifyDeliveryFailed) != 0 }
}

/// Result of decoding fountain ceremony frames
struct CeremonyResult: Sendable {
    let metadata: CeremonyMetadataSwift
    let padBytes: [UInt8]
    let blocksUsed: UInt32
}

/// Use case for performing the key exchange ceremony
protocol PerformCeremonyUseCaseProtocol: Sendable {
    /// Generate a pad from collected entropy (sender role), returns pad bytes
    func generatePadBytes(entropy: [UInt8], sizeBytes: Int) async throws -> [UInt8]

    /// Create a fountain frame generator for QR display
    /// The generator produces unlimited blocks - display cycles through them
    /// Without a passphrase the QR frames are plain
    /// transferMethod selects the encoding strategy (Raptor recommended)
    func createFountainGenerator(
        padBytes: [UInt8],
        metadata: CeremonyMetadataSwift,
        blockSize: UInt32,
        passphrase: String?,
        transferMethod: CeremonyTransferMethod
    ) async throws -> FountainFrameGenerator

    /// Create a fountain frame receiver for QR scanning
    /// Passphrase: the sender's six words, if its screen shows any
    func createFountainReceiver(passphrase: String?) throws -> FountainFrameReceiver

    /// Generate mnemonic checksum for verification
    func generateMnemonic(from padBytes: [UInt8]) async -> [String]

    /// Finalize ceremony and create conversation
    /// - Parameters:
    ///   - padBytes: The shared one-time pad bytes
    ///   - mnemonic: The mnemonic checksum for verification
    ///   - role: The role in this conversation (initiator = forward, responder = backward)
    ///   - relayURL: The relay server URL
    ///   - customName: Optional custom name for the conversation
    ///   - messageRetention: Server TTL setting for unread messages
    ///   - disappearingMessages: Display TTL setting for messages (client-side)
    ///   - accentColor: Accent color for the conversation UI
    ///   - messagePaddingEnabled: Whether message padding is enabled
    ///   - messagePaddingSize: Minimum message size when padding is enabled
    ///   - persistenceConsent: User consented to local message persistence
    func finalizeCeremony(
        padBytes: [UInt8],
        mnemonic: [String],
        role: ConversationRole,
        relayURL: String,
        customName: String?,
        messageRetention: MessageRetention,
        disappearingMessages: DisappearingMessages,
        accentColor: ConversationColor,
        messagePaddingEnabled: Bool,
        messagePaddingSize: MessagePaddingSize,
        persistenceConsent: Bool
    ) async throws -> Conversation
}

/// Implementation of ceremony use case using ash-core FFI with fountain codes
final class PerformCeremonyUseCase: PerformCeremonyUseCaseProtocol, Sendable {
    private let cryptoService: CryptoServiceProtocol
    private let conversationRepository: ConversationRepository
    private let padManager: PadManagerProtocol
    private let relayServiceFactory: RelayServiceFactory

    init(
        cryptoService: CryptoServiceProtocol,
        conversationRepository: ConversationRepository,
        padManager: PadManagerProtocol,
        relayServiceFactory: @escaping RelayServiceFactory
    ) {
        self.cryptoService = cryptoService
        self.conversationRepository = conversationRepository
        self.padManager = padManager
        self.relayServiceFactory = relayServiceFactory
    }

    /// Hash a token using SHA-256 and return hex-encoded string
    private func hashToken(_ token: String) -> String {
        let data = Data(token.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func generatePadBytes(entropy: [UInt8], sizeBytes: Int) async throws -> [UInt8] {
        // Generate secure random pad mixed with user entropy
        // Pad size is variable (32KB - 1GB), validated by core
        return try cryptoService.generateSecurePad(userEntropy: entropy, sizeBytes: sizeBytes)
    }

    func createFountainGenerator(
        padBytes: [UInt8],
        metadata: CeremonyMetadataSwift,
        blockSize: UInt32,
        passphrase: String?,
        transferMethod: CeremonyTransferMethod
    ) async throws -> FountainFrameGenerator {
        // Create CeremonyMetadata for FFI
        let ffiMetadata = CeremonyMetadata(
            version: 1,
            ttlSeconds: metadata.ttlSeconds,
            disappearingMessagesSeconds: metadata.disappearingMessagesSeconds,
            notificationFlags: metadata.conversationFlags,
            transferMethod: transferMethod.ffiMethod,
            relayUrl: metadata.relayURL
        )

        // Create fountain generator via FFI with required passphrase and transfer method
        // A fresh salt per ceremony: the same words never give the same key twice
        return try Ash.createFountainGenerator(
            metadata: ffiMetadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: passphrase,
            method: transferMethod.ffiMethod,
            salt: SecureRandom.bytes(16)
        )
    }

    func createFountainReceiver(passphrase: String?) throws -> FountainFrameReceiver {
        return try FountainFrameReceiver(passphrase: passphrase)
    }

    func generateMnemonic(from padBytes: [UInt8]) async -> [String] {
        // Generate 6-word mnemonic from pad bytes via FFI
        return cryptoService.generateMnemonic(from: padBytes, wordCount: 6)
    }

    func finalizeCeremony(
        padBytes: [UInt8],
        mnemonic: [String],
        role: ConversationRole,
        relayURL: String,
        customName: String?,
        messageRetention: MessageRetention,
        disappearingMessages: DisappearingMessages,
        accentColor: ConversationColor,
        messagePaddingEnabled: Bool,
        messagePaddingSize: MessagePaddingSize,
        persistenceConsent: Bool
    ) async throws -> Conversation {
        Log.info(.ceremony, "Finalizing ceremony (\(padBytes.count) bytes, retention=\(messageRetention.displayName), disappearing=\(disappearingMessages.displayName), color=\(accentColor.rawValue), padding=\(messagePaddingEnabled ? messagePaddingSize.displayName : "off"), persistence=\(persistenceConsent))")

        // Derive authorization tokens from pad bytes
        let tokens = try Ash.deriveAllTokens(padBytes: padBytes)
        Log.debug(.ceremony, "Authorization tokens derived")

        // Create conversation with message retention, disappearing messages setting, accent color, and padding
        let conversation = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: mnemonic,
            role: role,
            relayURL: relayURL,
            customName: customName,
            messageRetention: messageRetention,
            disappearingMessages: disappearingMessages,
            accentColor: accentColor,
            messagePaddingEnabled: messagePaddingEnabled,
            messagePaddingSize: messagePaddingSize,
            persistenceConsent: persistenceConsent,
            authToken: tokens.authToken,
            burnToken: tokens.burnToken
        )

        Log.debug(.ceremony, "Conversation created")

        // Store pad securely via PadManager
        try await padManager.storePad(bytes: padBytes, for: conversation.id)
        Log.debug(.ceremony, "Pad stored securely")

        // Save conversation
        try await conversationRepository.save(conversation)

        // Register conversation with relay server (fire-and-forget)
        if let relay = relayServiceFactory(relayURL) {
            let authTokenHash = hashToken(tokens.authToken)
            let burnTokenHash = hashToken(tokens.burnToken)
            Task {
                do {
                    try await relay.registerConversation(
                        conversationId: conversation.id,
                        authTokenHash: authTokenHash,
                        burnTokenHash: burnTokenHash
                    )
                    Log.info(.ceremony, "Conversation registered with relay")
                } catch {
                    Log.warning(.ceremony, "Failed to register conversation with relay: \(error)")
                }
            }
        }

        Log.info(.ceremony, "Ceremony complete")
        return conversation
    }
}

// MARK: - FFI Namespace

/// Namespace for ash-core FFI functions
/// Wraps global functions to avoid naming conflicts
private enum Ash {
    static func createFountainGenerator(
        metadata: CeremonyMetadata,
        padBytes: [UInt8],
        blockSize: UInt32,
        passphrase: String?,
        method: TransferMethod,
        salt: [UInt8]
    ) throws -> FountainFrameGenerator {
        try _createFountainGenerator(
            metadata: metadata,
            padBytes: padBytes,
            blockSize: blockSize,
            passphrase: passphrase,
            method: method,
            salt: salt
        )
    }

    static func deriveAllTokens(padBytes: [UInt8]) throws -> AuthTokens {
        try _deriveAllTokens(padBytes: padBytes)
    }
}

// Private wrappers to call global FFI functions
private func _createFountainGenerator(
    metadata: CeremonyMetadata,
    padBytes: [UInt8],
    blockSize: UInt32,
    passphrase: String?,
    method: TransferMethod,
    salt: [UInt8]
) throws -> FountainFrameGenerator {
    try createFountainGenerator(
        metadata: metadata,
        padBytes: padBytes,
        blockSize: blockSize,
        passphrase: passphrase,
        method: method,
        salt: salt
    )
}

private func _deriveAllTokens(padBytes: [UInt8]) throws -> AuthTokens {
    try deriveAllTokens(padBytes: padBytes)
}
