//
//  Ceremony.swift
//  Ash
//
//  Domain Entity - Key exchange ceremony state
//

import Foundation

/// Role in the ceremony - who generates vs receives the pad
enum CeremonyRole: String, Sendable {
    case sender    // Generates pad, displays QR codes
    case receiver  // Scans QR codes from sender
}

// MARK: - QR Frame Calculator

/// Calculates QR frame counts for ceremony transfer.
///
/// Uses the Rust core library via FFI for accurate calculations that match
/// actual fountain code behavior.
///
/// Block size: 1500 bytes payload per frame
/// Frame format: 12 bytes header + 1500 bytes payload + 4 bytes CRC = 1516 bytes
/// Metadata overhead: ~50 bytes (17 fixed + ~30 relay URL)
enum QRFrameCalculator {
    /// Block size used for fountain encoding (from core)
    static var blockSize: Int {
        Int(getDefaultBlockSize())
    }

    /// Metadata overhead in bytes (from core)
    static var metadataOverhead: Int {
        Int(getMetadataOverhead())
    }

    /// Calculate source block count (K) for given pad size
    static func sourceBlocks(padBytes: Int) -> Int {
        Int(calculateSourceBlocks(padBytes: UInt64(padBytes), blockSize: UInt32(blockSize)))
    }

    /// Calculate expected frames needed for successful transfer
    /// - Parameters:
    ///   - padBytes: Size of pad in bytes
    ///   - method: Transfer method (affects overhead)
    /// - Returns: Expected number of frames to scan
    static func expectedFrames(padBytes: Int, method: CeremonyTransferMethod) -> Int {
        Int(calculateExpectedFrames(
            padBytes: UInt64(padBytes),
            blockSize: UInt32(blockSize),
            method: method.ffiMethod
        ))
    }

    /// Calculate frames to pre-generate (source + redundancy)
    static func framesToGenerate(padBytes: Int, method: CeremonyTransferMethod) -> Int {
        Int(calculateFramesToGenerate(
            padBytes: UInt64(padBytes),
            blockSize: UInt32(blockSize),
            method: method.ffiMethod
        ))
    }

    /// Generate detailed calculation breakdown
    static func calculationBreakdown(padBytes: Int, method: CeremonyTransferMethod) -> String {
        let k = sourceBlocks(padBytes: padBytes)
        let frames = expectedFrames(padBytes: padBytes, method: method)
        let totalData = padBytes + metadataOverhead

        switch method {
        case .raptor:
            return "(\(totalData) bytes ÷ \(blockSize)) × 1.05 + 3 = \(frames)"
        case .lt:
            return "(\(totalData) bytes ÷ \(blockSize)) × 1.15 + √\(k) = \(frames)"
        case .sequential:
            return "(\(totalData) bytes ÷ \(blockSize)) = \(frames)"
        }
    }
}

// MARK: - Dynamic QR Size

/// Calculates optimal QR code size based on screen dimensions
enum QRSizeCalculator {
    /// Calculate optimal QR code size for current device
    /// Smaller screens get smaller QR codes to maintain scannability
    static func optimalSize(for screenWidth: CGFloat) -> CGFloat {
        // Base size for large phones (iPhone Pro Max ~430pt width)
        // Scale down proportionally for smaller screens
        let baseWidth: CGFloat = 430
        let baseQRSize: CGFloat = 380
        let minQRSize: CGFloat = 280  // Minimum for reliable scanning
        let maxQRSize: CGFloat = 400  // Maximum useful size

        let scaleFactor = screenWidth / baseWidth
        let calculatedSize = baseQRSize * scaleFactor

        return min(max(calculatedSize, minQRSize), maxQRSize)
    }

    /// Block size adjusted for screen (smaller screens may need smaller blocks)
    /// Returns block size that produces QR codes fitting well on screen
    static func optimalBlockSize(for screenWidth: CGFloat) -> UInt32 {
        // For now, use fixed block size as QR version 23-24 works well
        // Future: could reduce block size for smaller screens
        return 1500
    }
}

// MARK: - Pad Size Option

/// Pad size selection for ceremony UI.
/// This is a Swift-side enum for UI purposes, separate from core constraints.
/// Core accepts any size between 32KB and 1GB.
enum PadSizeOption: String, CaseIterable, Identifiable {
    case small = "small"       // 64 KB
    case medium = "medium"     // 256 KB
    case large = "large"       // 512 KB
    case huge = "huge"         // 1 MB
    case custom = "custom"     // User-specified size

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .huge: return "Huge"
        case .custom: return "Custom"
        }
    }

    /// Preset size in bytes (nil for custom)
    var presetBytes: UInt64? {
        switch self {
        case .small: return 64 * 1024      // 64 KB
        case .medium: return 256 * 1024    // 256 KB
        case .large: return 512 * 1024     // 512 KB
        case .huge: return 1024 * 1024     // 1 MB
        case .custom: return nil
        }
    }

    /// Human-readable size description
    var sizeDescription: String {
        switch self {
        case .small: return "64 KB"
        case .medium: return "256 KB"
        case .large: return "512 KB"
        case .huge: return "1 MB"
        case .custom: return "Custom"
        }
    }

    /// User-friendly description with method-specific frame count
    func description(for method: CeremonyTransferMethod) -> String {
        guard let bytes = presetBytes else {
            return "Choose your own size"
        }
        let messages = estimatedMessages(for: bytes)
        let frames = QRFrameCalculator.expectedFrames(padBytes: Int(bytes), method: method)
        return "~\(messages) messages, ~\(frames) QR frames"
    }

    /// Legacy description using Raptor as default
    var description: String {
        description(for: .raptor)
    }

    /// Expected QR frames needed for transfer
    func expectedFrames(for bytes: UInt64, method: CeremonyTransferMethod) -> Int {
        QRFrameCalculator.expectedFrames(padBytes: Int(bytes), method: method)
    }

    /// Approximate QR frames for preset sizes (Raptor default)
    var approximateFrames: Int {
        guard let bytes = presetBytes else { return 0 }
        return QRFrameCalculator.expectedFrames(padBytes: Int(bytes), method: .raptor)
    }

    /// Get frames for preset with specific method
    func approximateFrames(for method: CeremonyTransferMethod) -> Int {
        guard let bytes = presetBytes else { return 0 }
        return QRFrameCalculator.expectedFrames(padBytes: Int(bytes), method: method)
    }

    /// Estimated number of messages this pad can support.
    /// Formula: usable_bytes / (auth_overhead + avg_message_size)
    /// where auth_overhead = 64 bytes (Wegman-Carter MAC)
    /// and avg_message_size = 100 bytes (typical short message)
    func estimatedMessages(for bytes: UInt64) -> Int {
        let reservedForTokens: UInt64 = 160  // First 160 bytes for token derivation
        let authOverhead: UInt64 = 64        // MAC overhead per message
        let avgMessageSize: UInt64 = 100     // Typical message size
        let bytesPerMessage = authOverhead + avgMessageSize
        let usableBytes = bytes > reservedForTokens ? bytes - reservedForTokens : 0
        return Int(usableBytes / bytesPerMessage)
    }

    /// Estimated messages for preset sizes
    var estimatedMessages: Int {
        guard let bytes = presetBytes else { return 0 }
        return estimatedMessages(for: bytes)
    }

    /// Calculation breakdown for display
    func calculationBreakdown(for method: CeremonyTransferMethod) -> String {
        guard let bytes = presetBytes else { return "" }
        return QRFrameCalculator.calculationBreakdown(padBytes: Int(bytes), method: method)
    }
}

/// Message padding size options - hides actual message length
/// All messages are padded to this minimum size for privacy
enum MessagePaddingSize: String, Codable, CaseIterable, Sendable, Equatable {
    case bytes32 = "32"
    case bytes64 = "64"
    case bytes128 = "128"
    case bytes256 = "256"
    case bytes512 = "512"

    var bytes: Int {
        switch self {
        case .bytes32: return 32
        case .bytes64: return 64
        case .bytes128: return 128
        case .bytes256: return 256
        case .bytes512: return 512
        }
    }

    var displayName: String {
        "\(bytes) bytes"
    }

    /// Encode padding size into 3 bits (0-7)
    var encoded: UInt8 {
        switch self {
        case .bytes32: return 0
        case .bytes64: return 1
        case .bytes128: return 2
        case .bytes256: return 3
        case .bytes512: return 4
        }
    }

    /// Decode padding size from 3 bits
    static func decode(from value: UInt8) -> MessagePaddingSize {
        switch value {
        case 0: return .bytes32
        case 1: return .bytes64
        case 2: return .bytes128
        case 3: return .bytes256
        case 4: return .bytes512
        default: return .bytes32
        }
    }

    /// Default padding size from Info.plist (ASH_MESSAGE_PADDING_SIZE)
    static var `default`: MessagePaddingSize {
        guard let plistValue = Bundle.main.object(forInfoDictionaryKey: "ASH_MESSAGE_PADDING_SIZE") as? Int else {
            return .bytes32
        }
        switch plistValue {
        case 32: return .bytes32
        case 64: return .bytes64
        case 128: return .bytes128
        case 256: return .bytes256
        case 512: return .bytes512
        default: return .bytes32
        }
    }
}

/// Transfer method for QR ceremony (domain layer wrapper).
///
/// Wraps the FFI TransferMethod enum with additional display properties.
/// Determines which erasure coding strategy is used for pad transfer.
/// All methods use the same wire format, so receivers auto-adapt.
enum CeremonyTransferMethod: String, Codable, CaseIterable, Sendable {
    /// Raptor codes - near-optimal, K + 2-5 blocks overhead (recommended)
    case raptor
    /// LT codes - legacy fountain codes, K + O(sqrt(K)) blocks overhead
    case lt
    /// Sequential - plain numbered frames, no erasure coding
    case sequential

    var displayName: String {
        switch self {
        case .raptor: return "Raptor"
        case .lt: return "LT Codes"
        case .sequential: return "Sequential"
        }
    }

    var descriptionText: String {
        switch self {
        case .raptor: return "Near-optimal erasure coding with minimal overhead"
        case .lt: return "Legacy fountain codes with moderate overhead"
        case .sequential: return "Plain numbered frames, no error recovery"
        }
    }

    var isRecommended: Bool {
        self == .raptor
    }

    /// Convert to FFI TransferMethod for core library calls
    var ffiMethod: TransferMethod {
        switch self {
        case .raptor: return .raptor
        case .lt: return .lt
        case .sequential: return .sequential
        }
    }
}

/// Pad size limits from core
enum PadSizeLimits {
    /// Minimum pad size (32 KB)
    static let minimumBytes: UInt64 = 32 * 1024
    /// Maximum pad size (10 MB for UI, core supports up to 1 GB)
    static let maximumBytes: UInt64 = 10 * 1024 * 1024

    /// Format bytes as human-readable string
    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        } else {
            return "\(bytes) bytes"
        }
    }

    /// Validate pad size
    static func isValid(_ bytes: UInt64) -> Bool {
        bytes >= minimumBytes && bytes <= maximumBytes
    }
}

/// Current phase of the ceremony
enum CeremonyPhase: Equatable, Sendable {
    case idle
    case selectingRole
    case selectingPadSize
    case configuringOptions          // Sender: passphrase + name options
    case confirmingConsent           // Sender: ethics/consent confirmation
    case collectingEntropy
    case generatingPad
    case generatingQRCodes(progress: Double, total: Int)
    case configuringReceiver        // Receiver: passphrase config before scanning
    case transferring(currentFrame: Int, totalFrames: Int)
    /// Pad and settings going over Bluetooth; progress is in the BLE session
    case bluetoothTransfer
    case verifying(mnemonic: [String])
    case completed(conversation: Conversation)
    case failed(CeremonyError)
}

/// How the pad travels from one phone to the other
enum CeremonyChannel: String, CaseIterable, Sendable {
    /// 🔴 Maximum: QR codes, nothing goes over the air
    case qrCodes
    /// 🟠 Enhanced: Bluetooth, protected by a post-quantum key exchange
    case bluetooth

    var displayName: String {
        switch self {
        case .qrCodes: return "QR Codes"
        case .bluetooth: return "Bluetooth"
        }
    }
}

/// Errors that can occur during ceremony
enum CeremonyError: Error, Equatable, Sendable {
    case insufficientEntropy
    case qrGenerationFailed
    case qrScanFailed
    case frameDecodingFailed
    case checksumMismatch
    case padReconstructionFailed
    case cancelled

    var localizedDescription: String {
        switch self {
        case .insufficientEntropy:
            return "Not enough randomness collected. Please try again."
        case .qrGenerationFailed:
            return "Failed to generate QR codes."
        case .qrScanFailed:
            return "Failed to scan QR code. Please try again."
        case .frameDecodingFailed:
            return "Invalid QR code data."
        case .checksumMismatch:
            return "Checksum mismatch - ceremony aborted for security."
        case .padReconstructionFailed:
            return "Failed to reconstruct pad from frames."
        case .cancelled:
            return "Ceremony was cancelled."
        }
    }
}

/// Consent checkboxes that must be confirmed before proceeding
struct ConsentState: Equatable {
    var environmentConfirmed: Bool = false    // No one watching
    var notUnderSurveillance: Bool = false    // Not coerced
    var ethicsUnderstood: Bool = false        // Understands ethical use
    var keyLossUnderstood: Bool = false       // Understands no recovery
    var relayWarningUnderstood: Bool = false  // Understands relay limitations
    var dataLossUnderstood: Bool = false      // Understands relay data is ephemeral
    var burnUnderstood: Bool = false          // Understands burn destroys keys

    var allConfirmed: Bool {
        environmentConfirmed &&
        notUnderSurveillance &&
        ethicsUnderstood &&
        keyLossUnderstood &&
        relayWarningUnderstood &&
        dataLossUnderstood &&
        burnUnderstood
    }
}

/// Immutable snapshot of ceremony progress (simplified ephemeral design)
struct CeremonyState: Equatable {
    var phase: CeremonyPhase = .idle
    var role: CeremonyRole = .sender
    var selectedPadSizeOption: PadSizeOption = .medium
    var customPadSizeBytes: UInt64 = 256 * 1024  // Default custom size
    var entropyProgress: Double = 0.0
    var collectedEntropy: [UInt8] = []
    var generatedPad: [UInt8]? = nil
    var scannedFrames: Set<Int> = []
    var totalFrames: Int = 0

    /// Required passphrase for QR frame encryption (spoken between parties)
    var passphrase: String = ""

    /// Get the actual pad size in bytes
    var padSizeBytes: UInt64 {
        selectedPadSizeOption.presetBytes ?? customPadSizeBytes
    }

    /// Optional custom name for the conversation
    var conversationName: String? = nil

    /// Disappearing messages setting (client-side display TTL)
    var disappearingMessages: DisappearingMessages = .off

    /// Consent checkboxes state
    var consent: ConsentState = ConsentState()

    var isInProgress: Bool {
        switch phase {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var canCancel: Bool {
        switch phase {
        case .idle, .completed:
            return false
        default:
            return true
        }
    }

    /// Reset to initial state
    mutating func reset() {
        self = CeremonyState()
    }
}
