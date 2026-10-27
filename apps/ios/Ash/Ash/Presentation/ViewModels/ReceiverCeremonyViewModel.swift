//
//  ReceiverCeremonyViewModel.swift
//  Ash
//
//  Presentation Layer - Receiver ceremony flow (scans QR, reconstructs pad)
//  Uses fountain codes for reliable QR transfer
//
//  With fountain codes, you can scan ANY frames and complete
//  once enough unique blocks are received. No need to wait for specific frames.
//

import SwiftUI

@MainActor
@Observable
final class ReceiverCeremonyViewModel {

    private let dependencies: Dependencies

    // MARK: - State

    private(set) var phase: CeremonyPhase = .configuringReceiver
    private(set) var generatedPadBytes: [UInt8]?
    private(set) var receivedMetadata: CeremonyMetadataSwift?
    private(set) var fountainReceiver: FountainFrameReceiver?
    private(set) var sourceBlockCount: Int = 0

    // Progress tracking - stored properties to trigger @Observable updates
    private(set) var receivedFrameCount: Int = 0
    private(set) var progress: Double = 0.0

    /// How the pad comes from the other phone
    var channel: CeremonyChannel = .qrCodes

    /// Bluetooth receiving session, while `channel` is `.bluetooth`
    private(set) var bleReceiver: BLEPadReceiverSession?

    // Configuration state
    /// Required passphrase for QR frame decryption (must match sender's passphrase)
    var passphrase: String = ""
    var conversationName: String = ""

    /// Selected accent color for the conversation
    var selectedColor: ConversationColor = .indigo

    /// Persistence consent decoded from initiator's metadata
    private(set) var receivedPersistenceConsent: Bool = false

    /// Message padding enabled decoded from initiator's metadata
    private(set) var receivedMessagePaddingEnabled: Bool = false

    /// Message padding size decoded from initiator's metadata
    private(set) var receivedMessagePaddingSize: MessagePaddingSize = .bytes32

    // MARK: - Initialization

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        Log.debug(.ceremony, "Receiver ceremony view model initialized")
    }

    // MARK: - Computed Properties

    /// Passphrase is valid if it meets the minimum requirements (4+ chars)
    var isPassphraseValid: Bool {
        guard !passphrase.isEmpty else { return false }
        return validatePassphrase(passphrase: passphrase)
    }

    /// Whether Face ID/biometric lock is enabled in settings
    var isFaceIDEnabled: Bool {
        dependencies.vault.isConfigured
    }

    /// Whether persistence requires Face ID but it's not enabled
    /// If initiator enabled persistence, receiver must have Face ID enabled
    var requiresFaceIDForPersistence: Bool {
        receivedPersistenceConsent && !isFaceIDEnabled
    }

    /// Whether receiver can proceed with verification
    /// Blocked if persistence requires Face ID
    var canProceedWithVerification: Bool {
        !requiresFaceIDForPersistence
    }

    /// QR codes need the spoken passphrase; Bluetooth uses its own key exchange.
    var isChannelReady: Bool {
        channel == .bluetooth || isPassphraseValid
    }

    // MARK: - Received Metadata Display

    /// Human-readable list of enabled notification preferences
    var receivedNotificationDescriptions: [String] {
        guard let metadata = receivedMetadata else { return [] }
        var descriptions: [String] = []
        if metadata.notifyNewMessage { descriptions.append("New messages") }
        if metadata.notifyMessageExpiring { descriptions.append("Expiring warnings") }
        if metadata.notifyMessageExpired { descriptions.append("Expired messages") }
        if metadata.notifyDeliveryFailed { descriptions.append("Delivery failures") }
        return descriptions
    }

    /// Formatted relay URL for display
    var receivedRelayURL: String {
        receivedMetadata?.relayURL ?? ""
    }

    /// Formatted TTL for display
    var receivedTTLDescription: String {
        guard let ttl = receivedMetadata?.ttlSeconds else { return "" }
        switch ttl {
        case 0..<3600: return "\(ttl / 60) minutes"
        case 3600..<86400: return "\(ttl / 3600) hours"
        default: return "\(ttl / 86400) days"
        }
    }

    /// Formatted disappearing messages for display
    var receivedDisappearingDescription: String {
        guard let seconds = receivedMetadata?.disappearingMessagesSeconds, seconds > 0 else { return "Off" }
        switch seconds {
        case 0..<60: return "\(seconds) seconds"
        case 60..<3600: return "\(seconds / 60) minutes"
        default: return "\(seconds / 3600) hours"
        }
    }

    // MARK: - Scanning Setup

    func startScanning() {
        dependencies.hapticService.medium()
        Log.info(.ceremony, "Starting QR scan with passphrase")

        // Create fountain receiver with required passphrase
        fountainReceiver = dependencies.performCeremonyUseCase.createFountainReceiver(passphrase: passphrase)

        phase = .transferring(currentFrame: 0, totalFrames: 0)
    }

    // MARK: - Bluetooth

    /// Advertise a code and wait for the other phone to send the pad.
    func startBluetooth() {
        dependencies.hapticService.medium()
        let session = BLEPadReceiverSession()
        bleReceiver = session
        phase = .bluetoothTransfer
        session.start()
    }

    /// The pad and settings arrived and were authenticated.
    func bluetoothCompleted() {
        guard phase == .bluetoothTransfer, let received = bleReceiver?.receivedPad else { return }
        bleReceiver = nil
        do {
            let payload = try decodeCeremonyPayload(payload: received.pad)
            dependencies.hapticService.success()
            apply(metadata: payload.metadata, pad: payload.pad)
        } catch {
            Log.error(.ceremony, "Invalid Bluetooth payload: \(error)")
            phase = .failed(.padReconstructionFailed)
        }
    }

    /// The six words differed: the exchange may be intercepted.
    func bluetoothWordsRejected() {
        bleReceiver?.cancel()
        bleReceiver = nil
        rejectVerification()
    }

    /// Advertise a new code after a failure.
    func retryBluetooth() {
        bleReceiver?.start()
    }

    // MARK: - Frame Processing

    func processScannedFrame(_ data: Data) {
        guard let receiver = fountainReceiver else {
            Log.warning(.ceremony, "No fountain receiver available")
            return
        }

        let bytes = [UInt8](data)

        do {
            // Add frame to receiver - it handles deduplication internally
            let isComplete = try receiver.addFrame(frameBytes: bytes)
            dependencies.hapticService.light()

            // Update source count after first successful frame
            let newSourceCount = Int(receiver.sourceCount())
            if sourceBlockCount == 0 && newSourceCount > 0 {
                sourceBlockCount = newSourceCount
                Log.info(.ceremony, "Expecting ~\(sourceBlockCount) source blocks for complete decode")
            }

            // Update stored properties to trigger UI refresh
            receivedFrameCount = Int(receiver.blocksReceived())
            progress = receiver.progress()

            if receivedFrameCount % 5 == 0 {
                Log.debug(.ceremony, "Received \(receivedFrameCount) blocks, progress: \(Int(progress * 100))%")
            }

            phase = .transferring(currentFrame: receivedFrameCount, totalFrames: sourceBlockCount)

            if isComplete {
                Log.info(.ceremony, "Fountain decode complete! Used \(receivedFrameCount) blocks")
                dependencies.hapticService.success()
                Task { await reconstructAndVerify() }
            }
        } catch {
            // CRC mismatch or invalid frame - just ignore and continue scanning
            // This is expected for corrupted scans or wrong passphrase
            Log.debug(.ceremony, "Frame decode error (expected for corrupted scans): \(error)")
        }
    }

    // MARK: - Reconstruction

    private func reconstructAndVerify() async {
        guard let receiver = fountainReceiver,
              let result = receiver.getResult() else {
            Log.error(.ceremony, "Failed to get fountain decode result")
            phase = .failed(.padReconstructionFailed)
            return
        }

        Log.info(.ceremony, "Reconstructed pad: \(result.pad.count) bytes using \(result.blocksUsed) blocks")
        apply(metadata: result.metadata, pad: result.pad)
    }

    /// Take the settings chosen by the initiator, then show the words to compare.
    private func apply(metadata ffiMetadata: CeremonyMetadata, pad: [UInt8]) {
        let flags = ffiMetadata.notificationFlags
        let metadata = CeremonyMetadataSwift(
            ttlSeconds: ffiMetadata.ttlSeconds,
            disappearingMessagesSeconds: ffiMetadata.disappearingMessagesSeconds,
            conversationFlags: flags,
            relayURL: ffiMetadata.relayUrl
        )
        receivedMetadata = metadata
        generatedPadBytes = pad

        // Decode color from conversation flags (bits 12-15) and apply it
        let decodedColor = ConversationFlagsConstants.decodeColor(from: flags)
        selectedColor = decodedColor

        // Decode persistence consent from conversation flags (bit 4)
        receivedPersistenceConsent = ConversationFlagsConstants.hasPersistenceConsent(flags)

        // Decode message padding settings from conversation flags (bits 5-7)
        receivedMessagePaddingEnabled = ConversationFlagsConstants.hasMessagePadding(flags)
        receivedMessagePaddingSize = ConversationFlagsConstants.decodePaddingSize(from: flags)

        let paddingDesc = receivedMessagePaddingEnabled ? receivedMessagePaddingSize.displayName : "off"
        Log.info(.ceremony, "Decoded metadata: ttl=\(metadata.ttlSeconds)s, disappearing=\(metadata.disappearingMessagesSeconds)s, color=\(decodedColor.rawValue), padding=\(paddingDesc), persistence=\(receivedPersistenceConsent)")

        // Generate mnemonic for verification
        let mnemonic = generateMnemonic(padBytes: pad)
        phase = .verifying(mnemonic: mnemonic)
    }

    // MARK: - Verification

    func confirmVerification() async -> Conversation? {
        dependencies.hapticService.success()

        guard let padBytes = generatedPadBytes,
              case .verifying = phase else {
            Log.error(.ceremony, "Invalid state for verification confirmation")
            phase = .failed(.checksumMismatch)
            return nil
        }

        do {
            let customName = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = customName.isEmpty ? nil : customName

            // Use relay URL from metadata or fallback to settings
            let relayURL = receivedMetadata?.relayURL ?? dependencies.settingsService.relayServerURL

            // Extract message retention (server TTL) from metadata
            let messageRetention = MessageRetention.from(
                seconds: receivedMetadata?.ttlSeconds ?? MessageTTL.defaultSeconds
            )

            // Extract disappearing messages setting from metadata
            let disappearingMessages = DisappearingMessages.from(
                seconds: receivedMetadata?.disappearingMessagesSeconds ?? 0
            )

            Log.info(.ceremony, "Receiver finalizing ceremony (retention=\(messageRetention.displayName), disappearing=\(disappearingMessages.displayName))")

            let mnemonic = generateMnemonic(padBytes: padBytes)
            let conversation = try await dependencies.performCeremonyUseCase.finalizeCeremony(
                padBytes: padBytes,
                mnemonic: mnemonic,
                role: .responder,
                relayURL: relayURL,
                customName: finalName,
                messageRetention: messageRetention,
                disappearingMessages: disappearingMessages,
                accentColor: selectedColor,
                messagePaddingEnabled: receivedMessagePaddingEnabled,
                messagePaddingSize: receivedMessagePaddingSize,
                persistenceConsent: receivedPersistenceConsent
            )

            Log.info(.ceremony, "Ceremony completed: conversation \(conversation.id.prefix(8)), role=responder, pad=\(padBytes.count) bytes")
            phase = .completed(conversation: conversation)
            return conversation
        } catch {
            Log.error(.ceremony, "Finalization failed: \(error)")
            phase = .failed(.padReconstructionFailed)
            return nil
        }
    }

    func rejectVerification() {
        Log.warning(.ceremony, "Verification rejected by user")
        dependencies.hapticService.error()
        phase = .failed(.checksumMismatch)
    }

    // MARK: - Reset & Cancel

    func reset() {
        Log.debug(.ceremony, "Resetting receiver ceremony state")
        phase = .configuringReceiver
        generatedPadBytes = nil
        receivedMetadata = nil
        fountainReceiver = nil
        sourceBlockCount = 0
        receivedFrameCount = 0
        progress = 0.0
        selectedColor = .indigo
        receivedPersistenceConsent = false
        receivedMessagePaddingEnabled = false
        receivedMessagePaddingSize = .bytes32
    }

    func cancel() {
        Log.info(.ceremony, "Ceremony cancelled")
        bleReceiver?.cancel()
        bleReceiver = nil
        phase = .failed(.cancelled)
    }
}
