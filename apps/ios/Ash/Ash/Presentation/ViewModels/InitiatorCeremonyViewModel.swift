//
//  InitiatorCeremonyViewModel.swift
//  Ash
//
//  Presentation Layer - Initiator ceremony flow (generates pad, displays QR)
//  Uses fountain codes for reliable QR transfer
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class InitiatorCeremonyViewModel {

    private let dependencies: Dependencies

    // MARK: - State

    private(set) var phase: CeremonyPhase = .selectingPadSize
    private(set) var generatedPadBytes: [UInt8]?
    private(set) var fountainGenerator: FountainFrameGenerator?
    private(set) var sourceBlockCount: Int = 0
    private(set) var totalFramesToGenerate: Int = 0

    // MARK: - QR Generation Cache (minimal memory)

    /// Small LRU cache for recently displayed QR images
    /// Keeps only a few frames to smooth out display timing jitter
    private var qrCache: [Int: UIImage] = [:]
    /// Maximum cache size (very small to minimize memory)
    private let maxCacheSize: Int = 5

    // Configuration state
    var selectedPadSizeOption: PadSizeOption = .medium
    var customPadSizeKB: Double = 256  // Custom size in KB (default 256 KB)
    var entropyProgress: Double = 0.0
    var collectedEntropy: [UInt8] = []

    /// How the pad is sent to the other phone
    var channel: CeremonyChannel = .qrCodes

    /// Bluetooth sending session, while `channel` is `.bluetooth`
    private(set) var bleSender: BLEPadSenderSession?

    /// Required passphrase for QR frame encryption
    var passphrase: String = ""

    var conversationName: String = ""

    /// Selected accent color for the conversation
    var selectedColor: ConversationColor = .indigo

    /// Relay server URL for this conversation
    var selectedRelayURL: String = ""

    /// Connection test state
    private(set) var isTestingConnection: Bool = false
    private(set) var connectionTestResult: RelayConnectionResult?

    enum RelayConnectionResult: Equatable {
        case success(version: String)
        case failure(error: String)
    }

    /// Server retention - how long messages wait on server before expiring
    var serverRetention: MessageRetention = .oneDay

    /// Disappearing messages setting (client-side display TTL)
    var disappearingMessages: DisappearingMessages = .off

    /// Selected transfer method for QR ceremony
    var transferMethod: CeremonyTransferMethod = .raptor

    /// Backing storage for selected FPS
    private var _selectedFPS: Double = 8.0

    /// Selected frame rate for QR display (frames per second)
    var selectedFPS: Double {
        get { _selectedFPS }
        set {
            _selectedFPS = newValue
            // Restart timer with new interval if currently playing
            if isPlaying {
                startTimer()
            }
        }
    }

    /// Available FPS options
    static let fpsOptions: [Double] = [4, 6, 8, 10, 12, 15]

    // MARK: - Notification Preferences

    /// Notify when new message arrives (receiver)
    var notifyNewMessage: Bool = true
    /// Notify before message expires - 5min and 1min warnings (receiver)
    var notifyMessageExpiring: Bool = true
    /// Notify when message expires (receiver)
    var notifyMessageExpired: Bool = false
    /// Notify if message TTL expires unread (sender)
    var notifyDeliveryFailed: Bool = true

    /// Computed conversation flags for ceremony metadata
    var conversationFlags: UInt16 {
        var flags: UInt16 = 0
        if notifyNewMessage { flags |= ConversationFlagsConstants.notifyNewMessage }
        if notifyMessageExpiring { flags |= ConversationFlagsConstants.notifyMessageExpiring }
        if notifyMessageExpired { flags |= ConversationFlagsConstants.notifyMessageExpired }
        if notifyDeliveryFailed { flags |= ConversationFlagsConstants.notifyDeliveryFailed }
        if willPersistMessages { flags |= ConversationFlagsConstants.persistenceConsent }
        // Message padding is always enabled with 128-byte minimum size
        flags = ConversationFlagsConstants.encodePadding(
            enabled: true,
            size: .default,
            into: flags
        )
        return flags
    }

    var consent: ConsentState = ConsentState()

    // Display cycling
    private var displayTimer: Timer?
    private var currentDisplayIndex: Int = 0

    // MARK: - Constants

    /// Block size for fountain encoding (matches QRFrameCalculator.blockSize)
    private var fountainBlockSize: UInt32 {
        UInt32(QRFrameCalculator.blockSize)
    }

    /// Dynamic QR code size based on screen width
    private var qrCodeSize: CGFloat {
        let screenWidth: CGFloat
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            screenWidth = windowScene.screen.bounds.width
        } else {
            screenWidth = 390 // Default iPhone width fallback
        }
        return QRSizeCalculator.optimalSize(for: screenWidth)
    }

    /// Frame display interval in seconds (computed from selectedFPS)
    private var frameDisplayInterval: TimeInterval {
        1.0 / selectedFPS
    }

    // MARK: - Initialization

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.selectedRelayURL = dependencies.settingsService.relayServerURL
        Log.debug(.ceremony, "Initiator ceremony view model initialized")
    }

    // MARK: - Computed Properties

    /// Passphrase is valid if it meets the minimum requirements (4+ chars)
    var isPassphraseValid: Bool {
        guard !passphrase.isEmpty else { return false }
        return validatePassphrase(passphrase: passphrase)
    }

    /// QR codes need the spoken passphrase; Bluetooth uses its own key exchange.
    var isChannelReady: Bool {
        channel == .bluetooth || isPassphraseValid
    }

    /// Computed pad size in bytes
    var padSizeBytes: UInt64 {
        if let preset = selectedPadSizeOption.presetBytes {
            return preset
        }
        // Custom size: convert from KB, clamped to valid range
        let bytes = UInt64(customPadSizeKB * 1024)
        return min(max(bytes, PadSizeLimits.minimumBytes), PadSizeLimits.maximumBytes)
    }

    /// Whether custom pad size is valid
    var isCustomPadSizeValid: Bool {
        guard selectedPadSizeOption == .custom else { return true }
        return PadSizeLimits.isValid(UInt64(customPadSizeKB * 1024))
    }

    /// Whether Face ID/biometric lock is enabled in settings
    /// Required for local message persistence
    var isFaceIDEnabled: Bool {
        dependencies.vault.isConfigured
    }

    /// Whether all conditions for persistence are met
    /// Requires: disappearing messages enabled AND Face ID enabled
    var canEnablePersistence: Bool {
        disappearingMessages.isEnabled && isFaceIDEnabled
    }

    /// User's consent to enable local message persistence
    /// Only shown and settable when canEnablePersistence is true
    var persistenceConsent: Bool = false

    /// Whether message persistence will be active for this conversation
    /// Requires: conditions met AND user consent
    var willPersistMessages: Bool {
        canEnablePersistence && persistenceConsent
    }

    var isRelayURLValid: Bool {
        guard let url = URL(string: selectedRelayURL) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }

    var isConsentComplete: Bool {
        consent.allConfirmed
    }

    var currentFrameIndex: Int {
        currentDisplayIndex
    }

    var totalFrameCount: Int {
        sourceBlockCount
    }

    // MARK: - Pad Size Selection

    func selectPadSizeOption(_ option: PadSizeOption) {
        dependencies.hapticService.selection()
        selectedPadSizeOption = option
        Log.debug(.ceremony, "Pad size option selected: \(option.displayName)")
    }

    func setCustomPadSize(_ sizeKB: Double) {
        customPadSizeKB = sizeKB
        Log.debug(.ceremony, "Custom pad size set: \(sizeKB) KB")
    }

    func proceedToOptions() {
        dependencies.hapticService.medium()
        Log.debug(.ceremony, "Proceeding to options phase")
        phase = .configuringOptions
    }

    // MARK: - Options & Consent

    func proceedToConsent() {
        dependencies.hapticService.medium()
        Log.debug(.ceremony, "Proceeding to consent phase")
        phase = .confirmingConsent
    }

    func testRelayConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        guard let url = URL(string: selectedRelayURL)?.appendingPathComponent("health") else {
            connectionTestResult = .failure(error: "Invalid URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                connectionTestResult = .failure(error: "Server error")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                connectionTestResult = .success(version: "v\(version)")
                dependencies.hapticService.success()
            } else {
                connectionTestResult = .success(version: "OK")
                dependencies.hapticService.success()
            }
        } catch {
            connectionTestResult = .failure(error: error.localizedDescription)
            dependencies.hapticService.error()
        }
    }

    func clearConnectionTest() {
        connectionTestResult = nil
    }

    func confirmConsent() {
        guard isConsentComplete else { return }
        dependencies.hapticService.success()
        Log.info(.ceremony, "Consent confirmed, proceeding to entropy collection")
        phase = .collectingEntropy
    }

    // MARK: - Entropy Collection

    func addEntropy(from point: CGPoint) {
        let x = UInt8(truncatingIfNeeded: Int(point.x * 256))
        let y = UInt8(truncatingIfNeeded: Int(point.y * 256))
        let timestamp = UInt8(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000))

        collectedEntropy.append(contentsOf: [x, y, timestamp])
        entropyProgress = min(1.0, Double(collectedEntropy.count) / 500.0)

        if entropyProgress >= 1.0 {
            Log.info(.ceremony, "Entropy collection complete: \(collectedEntropy.count) bytes")
            Task { await generatePad() }
        }
    }

    // MARK: - Pad Generation with Fountain Codes

    func generatePad() async {
        dependencies.hapticService.success()
        phase = .generatingPad

        let entropy = collectedEntropy
        let padSize = Int(padSizeBytes)
        Log.info(.ceremony, "Generating pad: \(padSize) bytes from \(entropy.count) entropy bytes")

        do {
            let padBytes = try await dependencies.performCeremonyUseCase.generatePadBytes(
                entropy: entropy,
                sizeBytes: Int(padSizeBytes)
            )
            generatedPadBytes = padBytes

            let disappearingSeconds = UInt32(disappearingMessages.seconds ?? 0)
            // Encode color into conversation flags (uses bits 12-15)
            let flagsWithColor = ConversationFlagsConstants.encodeColor(selectedColor, into: conversationFlags)
            let metadata = CeremonyMetadataSwift(
                ttlSeconds: serverRetention.seconds,
                disappearingMessagesSeconds: disappearingSeconds,
                conversationFlags: flagsWithColor,
                relayURL: selectedRelayURL
            )

            if channel == .bluetooth {
                startBluetooth(padBytes: padBytes, metadata: metadata)
                return
            }

            Log.debug(.ceremony, "Creating fountain generator: serverTTL=\(serverRetention.displayName), disappearing=\(disappearingMessages.displayName), flags=0x\(String(flagsWithColor, radix: 16)), color=\(selectedColor.rawValue)")

            // Passphrase is required for ceremony encryption
            let generator = try await dependencies.performCeremonyUseCase.createFountainGenerator(
                padBytes: padBytes,
                metadata: metadata,
                blockSize: fountainBlockSize,
                passphrase: passphrase,
                transferMethod: transferMethod
            )

            fountainGenerator = generator
            sourceBlockCount = Int(generator.sourceCount())
            totalFramesToGenerate = QRFrameCalculator.framesToGenerate(
                padBytes: Int(padSizeBytes),
                method: transferMethod
            )

            Log.info(.ceremony, "Fountain generator ready: method=\(transferMethod.displayName), \(sourceBlockCount) source blocks, \(totalFramesToGenerate) total frames (redundancy=\(totalFramesToGenerate - sourceBlockCount)), block size: \(generator.blockSize())")
            await startStreamingQRCodes()
        } catch {
            Log.error(.ceremony, "Pad generation failed: \(error)")
            phase = .failed(.qrGenerationFailed)
        }
    }

    // MARK: - Bluetooth

    /// Send the pad and settings over Bluetooth instead of QR codes.
    private func startBluetooth(padBytes: [UInt8], metadata: CeremonyMetadataSwift) {
        let payload = encodeCeremonyPayload(
            metadata: CeremonyMetadata(
                version: 1,
                ttlSeconds: metadata.ttlSeconds,
                disappearingMessagesSeconds: metadata.disappearingMessagesSeconds,
                notificationFlags: metadata.conversationFlags,
                transferMethod: transferMethod.ffiMethod,
                relayUrl: metadata.relayURL
            ),
            padBytes: padBytes
        )
        let session = BLEPadSenderSession(pad: payload)
        bleSender = session
        phase = .bluetoothTransfer
        Log.info(.ceremony, "Sending pad over Bluetooth (\(payload.count) bytes)")
        session.start()
    }

    /// The other phone received and authenticated the pad.
    /// No mnemonic step: the six words already ruled out anyone in the
    /// middle, and the sealed transfer rejects any altered byte.
    func bluetoothCompleted() {
        guard phase == .bluetoothTransfer else { return }
        bleSender = nil
        dependencies.hapticService.success()
        Task { _ = await finalize() }
    }

    /// The six words differed: the exchange may be intercepted.
    func bluetoothWordsRejected() {
        bleSender?.cancel()
        bleSender = nil
        rejectVerification()
    }

    /// Start looking for the other phone again after a failure.
    func retryBluetooth() {
        bleSender?.start()
    }

    /// Start streaming QR display - generates on-demand with minimal caching
    private func startStreamingQRCodes() async {
        guard fountainGenerator != nil else {
            Log.error(.ceremony, "No fountain generator available")
            phase = .failed(.qrGenerationFailed)
            return
        }

        Log.info(.ceremony, "On-demand QR streaming: \(totalFramesToGenerate) frames (\(sourceBlockCount) source + \(totalFramesToGenerate - sourceBlockCount) redundancy) at \(Int(qrCodeSize))px")

        // No pre-generation - just start display immediately
        // QR codes are generated on-demand as they're displayed
        qrCache.removeAll()

        dependencies.hapticService.success()
        phase = .transferring(currentFrame: 0, totalFrames: totalFramesToGenerate)
        startDisplayCycling()
    }

    /// Generate a single QR image for the given frame index (on-demand)
    private func generateQRImage(at index: Int) -> UIImage? {
        guard let generator = fountainGenerator else { return nil }
        let frameBytes = generator.generateFrame(index: UInt32(index))
        let frameData = Data(frameBytes)
        return QRCodeGenerator.generate(from: frameData, size: qrCodeSize)
    }

    /// Get QR image for index, using small cache to smooth display
    private func getQRImage(at index: Int) -> UIImage? {
        // Check cache first
        if let cached = qrCache[index] {
            return cached
        }

        // Generate on-demand
        guard let image = generateQRImage(at: index) else { return nil }

        // Add to cache
        qrCache[index] = image

        // Evict old entries if cache is too large
        if qrCache.count > maxCacheSize {
            // Remove entries furthest from current index
            let sortedKeys = qrCache.keys.sorted { abs($0 - index) > abs($1 - index) }
            for key in sortedKeys.prefix(qrCache.count - maxCacheSize) {
                qrCache.removeValue(forKey: key)
            }
        }

        return image
    }

    // MARK: - QR Display Cycling

    /// Whether automatic playback is running
    private(set) var isPlaying: Bool = false

    private func startDisplayCycling() {
        currentDisplayIndex = 0
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: frameDisplayInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard totalFramesToGenerate > 0, isPlaying else { return }
        currentDisplayIndex = (currentDisplayIndex + 1) % totalFramesToGenerate
        updatePhase()
    }

    private func updatePhase() {
        if case .transferring = phase {
            phase = .transferring(currentFrame: currentDisplayIndex, totalFrames: totalFramesToGenerate)
        }
    }

    func stopDisplayCycling() {
        displayTimer?.invalidate()
        displayTimer = nil
        isPlaying = false
    }

    // MARK: - Playback Control (for UI)

    /// Toggle play/pause
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    /// Pause automatic frame advancement
    func pausePlayback() {
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Resume automatic frame advancement
    func resumePlayback() {
        isPlaying = true
        startTimer()
    }

    /// Go to next frame
    func nextFrame() {
        guard totalFramesToGenerate > 0 else { return }
        currentDisplayIndex = (currentDisplayIndex + 1) % totalFramesToGenerate
        updatePhase()
    }

    /// Go to previous frame
    func previousFrame() {
        guard totalFramesToGenerate > 0 else { return }
        currentDisplayIndex = (currentDisplayIndex - 1 + totalFramesToGenerate) % totalFramesToGenerate
        updatePhase()
    }

    /// Go to first frame
    func goToFirstFrame() {
        currentDisplayIndex = 0
        updatePhase()
    }

    /// Go to last frame
    func goToLastFrame() {
        guard totalFramesToGenerate > 0 else { return }
        currentDisplayIndex = totalFramesToGenerate - 1
        updatePhase()
    }

    /// Set playback speed (frames per second)
    func setPlaybackSpeed(fps: Double) {
        guard fps > 0 else { return }
        let wasPlaying = isPlaying
        pausePlayback()
        // Note: We don't store fps as a property, but we could add one if needed
        // For now, just restart with default interval
        if wasPlaying {
            resumePlayback()
        }
    }

    func currentQRImage() -> UIImage? {
        return getQRImage(at: currentDisplayIndex)
    }

    func currentFrameData() -> Data? {
        guard let generator = fountainGenerator else { return nil }
        let frameBytes = generator.generateFrame(index: UInt32(currentDisplayIndex))
        return Data(frameBytes)
    }

    func finishSending() {
        Log.info(.ceremony, "Sender finished, proceeding to verification")
        stopDisplayCycling()
        Task { await proceedToVerification() }
    }

    // MARK: - Verification

    private func proceedToVerification() async {
        guard let padBytes = generatedPadBytes else {
            Log.error(.ceremony, "No pad bytes for verification")
            phase = .failed(.padReconstructionFailed)
            return
        }

        Log.info(.ceremony, "Generating verification mnemonic for \(padBytes.count) byte pad")
        let mnemonic = await dependencies.performCeremonyUseCase.generateMnemonic(from: padBytes)
        phase = .verifying(mnemonic: mnemonic)
    }

    func confirmVerification() async -> Conversation? {
        dependencies.hapticService.success()

        guard case .verifying = phase else {
            Log.error(.ceremony, "Invalid state for verification confirmation")
            phase = .failed(.checksumMismatch)
            return nil
        }
        return await finalize()
    }

    /// Create the conversation from the transferred pad and settings.
    private func finalize() async -> Conversation? {
        guard let padBytes = generatedPadBytes else {
            Log.error(.ceremony, "No pad bytes to finalize")
            phase = .failed(.padReconstructionFailed)
            return nil
        }

        do {
            let customName = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = customName.isEmpty ? nil : customName

            Log.info(.ceremony, "Initiator finalizing ceremony with relay: \(selectedRelayURL), retention: \(serverRetention.displayName)")

            let mnemonic = generateMnemonic(padBytes: padBytes)
            let conversation = try await dependencies.performCeremonyUseCase.finalizeCeremony(
                padBytes: padBytes,
                mnemonic: mnemonic,
                role: .initiator,
                relayURL: selectedRelayURL,
                customName: finalName,
                messageRetention: serverRetention,
                disappearingMessages: disappearingMessages,
                accentColor: selectedColor,
                messagePaddingEnabled: true,
                messagePaddingSize: .default,
                persistenceConsent: willPersistMessages
            )

            Log.info(.ceremony, "Ceremony completed: conversation \(conversation.id.prefix(8)), role=initiator, pad=\(padBytes.count) bytes")
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
        Log.debug(.ceremony, "Resetting initiator ceremony state")
        stopDisplayCycling()
        bleSender?.cancel()
        bleSender = nil
        phase = .selectingPadSize
        generatedPadBytes = nil
        fountainGenerator = nil
        qrCache.removeAll()
        sourceBlockCount = 0
        totalFramesToGenerate = 0
        isPlaying = false
        collectedEntropy = []
        entropyProgress = 0
        consent = ConsentState()
        currentDisplayIndex = 0
        selectedRelayURL = dependencies.settingsService.relayServerURL
        connectionTestResult = nil
        selectedColor = .indigo
        // Reset notification preferences to defaults
        notifyNewMessage = true
        notifyMessageExpiring = true
        notifyMessageExpired = false
        notifyDeliveryFailed = true
        persistenceConsent = false
        transferMethod = .raptor
    }

    func cancel() {
        Log.info(.ceremony, "Ceremony cancelled")
        stopDisplayCycling()
        bleSender?.cancel()
        bleSender = nil
        phase = .failed(.cancelled)
    }

    nonisolated deinit {
        // Timer cleanup is handled by stopDisplayCycling() called in reset()/cancel()
        // Timer will be invalidated automatically when deallocated if still running
    }
}
