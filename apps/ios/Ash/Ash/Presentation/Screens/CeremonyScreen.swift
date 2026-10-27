//
//  CeremonyScreen.swift
//  Ash
//
//  Create new conversation ceremony flow
//  Supports automatic dark/light mode
//

import SwiftUI
import UIKit

struct CeremonyScreen: View {
    @Bindable var viewModel: CeremonyViewModel
    let onComplete: (Conversation) -> Void
    let onCancel: () -> Void

    /// Get the current accent color from the active view model
    private var currentAccentColor: Color {
        if let initiator = viewModel.initiatorViewModel {
            return initiator.selectedColor.color
        } else if let receiver = viewModel.receiverViewModel {
            return receiver.selectedColor.color
        }
        return Color.ashAccent
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .idle, .selectingRole:
                    RoleSelectionView(viewModel: viewModel)

                case .selectingPadSize:
                    if let initiator = viewModel.initiatorViewModel {
                        PadSizeView(viewModel: initiator)
                    }

                case .configuringOptions:
                    if let initiator = viewModel.initiatorViewModel {
                        OptionsView(viewModel: initiator)
                    }

                case .confirmingConsent:
                    if let initiator = viewModel.initiatorViewModel {
                        ConsentView(viewModel: initiator, accentColor: initiator.selectedColor.color)
                    }

                case .collectingEntropy:
                    if let initiator = viewModel.initiatorViewModel {
                        EntropyView(viewModel: initiator, accentColor: initiator.selectedColor.color)
                    }

                case .generatingPad:
                    GeneratingView(title: "Generating Pad", subtitle: "Creating secure encryption key...", current: 0, total: 0, accentColor: currentAccentColor)

                case .generatingQRCodes(let progress, let total):
                    GeneratingView(title: "Generating QR Codes", subtitle: "Preparing \(total) frames for transfer...", current: Int(progress * Double(total)), total: total, accentColor: currentAccentColor)

                case .configuringReceiver:
                    if let receiver = viewModel.receiverViewModel {
                        ReceiverSetupView(viewModel: receiver)
                    }

                case .transferring(let current, let total):
                    if let initiator = viewModel.initiatorViewModel {
                        QRDisplayView(viewModel: initiator, currentFrame: current, totalFrames: total, accentColor: initiator.selectedColor.color)
                    } else if let receiver = viewModel.receiverViewModel {
                        QRScanView(viewModel: receiver, accentColor: receiver.selectedColor.color)
                    }

                case .bluetoothTransfer:
                    if let initiator = viewModel.initiatorViewModel, let session = initiator.bleSender {
                        BluetoothSendView(
                            session: session,
                            accentColor: initiator.selectedColor.color,
                            onCompleted: { initiator.bluetoothCompleted() },
                            onWordsRejected: { initiator.bluetoothWordsRejected() },
                            onRetry: { initiator.retryBluetooth() }
                        )
                    } else if let receiver = viewModel.receiverViewModel, let session = receiver.bleReceiver {
                        BluetoothReceiveView(
                            session: session,
                            accentColor: receiver.selectedColor.color,
                            onCompleted: { receiver.bluetoothCompleted() },
                            onWordsRejected: { receiver.bluetoothWordsRejected() },
                            onRetry: { receiver.retryBluetooth() }
                        )
                    }

                case .verifying(let mnemonic):
                    if let initiator = viewModel.initiatorViewModel {
                        VerificationView(
                            mnemonic: mnemonic,
                            accentColor: initiator.selectedColor.color,
                            conversationName: Binding(get: { initiator.conversationName }, set: { initiator.conversationName = $0 }),
                            onConfirm: { Task { if let c = await initiator.confirmVerification() { onComplete(c) } } },
                            onReject: { initiator.rejectVerification() }
                        )
                    } else if let receiver = viewModel.receiverViewModel {
                        VerificationView(
                            mnemonic: mnemonic,
                            accentColor: receiver.selectedColor.color,
                            conversationName: Binding(get: { receiver.conversationName }, set: { receiver.conversationName = $0 }),
                            onConfirm: { Task { if let c = await receiver.confirmVerification() { onComplete(c) } } },
                            onReject: { receiver.rejectVerification() },
                            receivedTTL: receiver.receivedTTLDescription,
                            receivedDisappearing: receiver.receivedDisappearingDescription,
                            receivedRelay: receiver.receivedRelayURL,
                            receivedNotifications: receiver.receivedNotificationDescriptions,
                            receivedPersistenceEnabled: receiver.receivedPersistenceConsent,
                            requiresFaceIDForPersistence: receiver.requiresFaceIDForPersistence,
                            canProceed: receiver.canProceedWithVerification
                        )
                    }

                case .completed(let conversation):
                    CompletedView(conversation: conversation, onContinue: { onComplete(conversation) }, accentColor: currentAccentColor)

                case .failed(let error):
                    FailedView(error: error, onRetry: { viewModel.reset(); viewModel.start() }, onCancel: onCancel, accentColor: currentAccentColor)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancel(); onCancel() }
                }
            }
            .interactiveDismissDisabled(viewModel.isInProgress)
        }
        .tint(currentAccentColor)
        .onAppear { viewModel.start() }
    }
}

// MARK: - Role Selection

private struct RoleSelectionView: View {
    @Bindable var viewModel: CeremonyViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Header
            VStack(spacing: 16) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(24)
                    .background(Color.accentColor.opacity(0.1), in: Circle())

                Text("Choose Your Role")
                    .font(.title2.bold())

                Text("One device creates the conversation,\nthe other joins by scanning")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)

            Spacer()

            // Role Cards
            VStack(spacing: 14) {
                RoleCard(
                    icon: "qrcode",
                    title: "Create",
                    subtitle: "Generate pad and display QR codes",
                    badge: "Initiator"
                ) {
                    viewModel.selectRole(.sender)
                }

                RoleCard(
                    icon: "camera.viewfinder",
                    title: "Join",
                    subtitle: "Scan QR codes from other device",
                    badge: "Receiver"
                ) {
                    viewModel.selectRole(.receiver)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }
}

private struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        Text(badge)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pad Size Selection

private struct PadSizeView: View {
    @Bindable var viewModel: InitiatorCeremonyViewModel

    private var canProceed: Bool {
        viewModel.isChannelReady && viewModel.isCustomPadSizeValid
    }

    /// Formatted custom pad size description
    private var customSizeDescription: String {
        let bytes = UInt64(viewModel.customPadSizeKB) * 1024
        let messages = PadSizeOption.custom.estimatedMessages(for: bytes)
        let frames = QRFrameCalculator.expectedFrames(padBytes: Int(bytes), method: viewModel.transferMethod)
        return "~\(messages) messages, ~\(frames) QR frames"
    }

    /// Calculation breakdown for current selection
    private var calculationBreakdown: String {
        let bytes: Int
        if let preset = viewModel.selectedPadSizeOption.presetBytes {
            bytes = Int(preset)
        } else {
            bytes = Int(viewModel.customPadSizeKB) * 1024
        }
        return QRFrameCalculator.calculationBreakdown(padBytes: bytes, method: viewModel.transferMethod)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header with slider icon
                VStack(spacing: 16) {
                    Image(systemName: "lock.doc")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(20)
                        .background(Color.accentColor.opacity(0.1), in: Circle())

                    Text("Secure Pad Setup")
                        .font(.title2.bold())

                    Text("The pad is your one-time encryption key. Larger pads support more messages but take longer to transfer via QR codes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.bottom, 24)
                .padding(.horizontal, 20)

                // Transfer Method Picker
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text("Transfer Method")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Picker("Transfer Method", selection: $viewModel.transferMethod) {
                        ForEach(CeremonyTransferMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    Text(viewModel.transferMethod.descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // Pad Size Cards
                VStack(spacing: 10) {
                    ForEach(PadSizeOption.allCases.filter { $0 != .custom }) { option in
                        PadSizeCard(
                            name: option.displayName,
                            size: option.sizeDescription,
                            messages: "~\(option.estimatedMessages) messages",
                            frames: "\(option.approximateFrames(for: viewModel.transferMethod)) frames",
                            calculation: option.calculationBreakdown(for: viewModel.transferMethod),
                            isSelected: viewModel.selectedPadSizeOption == option
                        ) {
                            viewModel.selectPadSizeOption(option)
                        }
                    }

                    // Custom Size Card
                    CustomPadSizeCard(
                        sizeKB: $viewModel.customPadSizeKB,
                        description: customSizeDescription,
                        isSelected: viewModel.selectedPadSizeOption == .custom,
                        isValid: viewModel.isCustomPadSizeValid
                    ) {
                        viewModel.selectPadSizeOption(.custom)
                    }
                }
                .padding(.horizontal, 20)

                // Calculation breakdown for selected option
                if viewModel.selectedPadSizeOption != .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Frame calculation", systemImage: "function")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(calculationBreakdown)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Info about pad usage
                VStack(alignment: .leading, spacing: 8) {
                    Label("How it works", systemImage: "info.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("Each message uses ~164 bytes of the pad (64 bytes for authentication + ~100 bytes average message). Once the pad is exhausted, no more messages can be sent.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ChannelPicker(channel: $viewModel.channel)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                if viewModel.channel == .qrCodes {
                    // Passphrase Section (Required)
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "lock.shield.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 32)
                                Text("Verbal Passphrase")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Required")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange, in: Capsule())
                            }

                            Text("Read these six words to your contact before the ceremony, out of earshot of others. They encrypt the QR codes, so filming the screen reveals nothing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        PassphraseWordsView(words: viewModel.passphraseWords)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                        Button {
                            viewModel.regeneratePassphrase()
                        } label: {
                            Label("New Words", systemImage: "arrow.clockwise")
                                .font(.subheadline)
                        }
                        .padding(.bottom, 12)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // Passphrase explanation
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Why six words?", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text("Without them, anyone who films the QR codes could copy your pad. The app draws the words itself so they are never easy to guess, and the other phone needs them to read the codes.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Continue Button
                Button {
                    viewModel.proceedToOptions()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor, in: Capsule())
                }
                .disabled(!canProceed)
                .opacity(canProceed ? 1 : 0.5)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
    }
}

private struct PadSizeCard: View {
    let name: String
    let size: String
    let messages: String
    let frames: String
    let calculation: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.headline)
                        Text(size)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.8), in: Capsule())
                    }
                    HStack(spacing: 12) {
                        Label(messages, systemImage: "message")
                        Label(frames, systemImage: "qrcode")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                } else {
                    Circle()
                        .stroke(Color(.systemGray3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CustomPadSizeCard: View {
    @Binding var sizeKB: Double
    let description: String
    let isSelected: Bool
    let isValid: Bool
    let onTap: () -> Void

    // Range: 32 KB to 10 MB
    private let minKB: Double = 32
    private let maxKB: Double = 10 * 1024

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Custom")
                                .font(.headline)
                            Text(PadSizeLimits.formatBytes(UInt64(sizeKB * 1024)))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.8), in: Capsule())
                        }
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    } else {
                        Circle()
                            .stroke(Color(.systemGray3), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }

                if isSelected {
                    VStack(spacing: 8) {
                        Slider(value: $sizeKB, in: minKB...maxKB, step: 32)
                            .tint(.purple)

                        HStack {
                            Text("32 KB")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("10 MB")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.purple.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Options (Settings)

private struct OptionsView: View {
    @Bindable var viewModel: InitiatorCeremonyViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(20)
                        .background(Color.accentColor.opacity(0.1), in: Circle())

                    Text("Settings")
                        .font(.title2.bold())

                    Text("Configure message handling and delivery")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.bottom, 24)

                // Message Settings Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text("Message Timing")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Server Retention")
                                .font(.subheadline)
                            Text("How long unread messages wait")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $viewModel.serverRetention) {
                            ForEach(MessageRetention.allCases, id: \.self) { Text($0.displayName) }
                        }
                        .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().padding(.leading, 16)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Disappearing Messages")
                                .font(.subheadline)
                            Text("Auto-delete after viewing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $viewModel.disappearingMessages) {
                            ForEach(DisappearingMessages.allCases, id: \.self) { Text($0.displayName) }
                        }
                        .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Persistence information - only shown when disappearing messages are enabled
                    if viewModel.disappearingMessages.isEnabled {
                        Divider().padding(.leading, 16)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: viewModel.canEnablePersistence ? "lock.iphone" : "exclamationmark.triangle")
                                    .font(.title3)
                                    .foregroundStyle(viewModel.canEnablePersistence ? .blue : .orange)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Local Message Storage")
                                        .font(.subheadline.bold())

                                    if viewModel.canEnablePersistence {
                                        // Face ID is enabled - show consent checkbox
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                            Text("Face ID enabled")
                                                .foregroundStyle(.green)
                                        }
                                        .font(.caption.bold())

                                        Text("Messages can be stored locally on your device, protected by Face ID. They will be securely erased when the disappearing timer expires.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        // Persistence consent toggle
                                        Toggle(isOn: $viewModel.persistenceConsent) {
                                            Text("Enable local storage")
                                                .font(.subheadline)
                                        }
                                        .tint(.blue)
                                        .padding(.top, 4)

                                        if viewModel.persistenceConsent {
                                            Text("Messages will persist between app sessions until they expire.")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                                .padding(.top, 2)
                                        }
                                    } else {
                                        // Face ID not enabled - show warning
                                        HStack(spacing: 4) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.orange)
                                            Text("Face ID not enabled")
                                                .foregroundStyle(.orange)
                                        }
                                        .font(.caption.bold())

                                        Text("To enable local message storage, you must first enable Face ID in Settings. Without it, messages are only stored in memory and will be lost when you leave the conversation.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Relay Server Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "server.rack")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text("Relay Server")
                            .font(.subheadline.bold())
                        Spacer()

                        // Connection status indicator
                        if let result = viewModel.connectionTestResult {
                            switch result {
                            case .success:
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                            case .failure:
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Relay URL", text: $viewModel.selectedRelayURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote.monospaced())
                            .onChange(of: viewModel.selectedRelayURL) { _, _ in
                                viewModel.clearConnectionTest()
                            }

                        HStack(spacing: 12) {
                            Button {
                                Task { await viewModel.testRelayConnection() }
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.isTestingConnection {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                    }
                                    Text("Test")
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                            }
                            .disabled(viewModel.isTestingConnection || !viewModel.isRelayURLValid)
                            .buttonStyle(.plain)

                            if let result = viewModel.connectionTestResult {
                                switch result {
                                case .success(let version):
                                    Text("v\(version)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.green)
                                case .failure:
                                    Text("Connection failed")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }

                            Spacer()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Notification Settings Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "bell.badge")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text("Notifications")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    Toggle(isOn: $viewModel.notifyNewMessage) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Messages")
                                .font(.subheadline)
                            Text("Alert when message arrives")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 16)

                    Toggle(isOn: $viewModel.notifyMessageExpiring) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Expiry Warnings")
                                .font(.subheadline)
                            Text("5min and 1min before expiry")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 16)

                    Toggle(isOn: $viewModel.notifyMessageExpired) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Expired Messages")
                                .font(.subheadline)
                            Text("Alert when message expires")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider().padding(.leading, 16)

                    Toggle(isOn: $viewModel.notifyDeliveryFailed) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delivery Failed")
                                .font(.subheadline)
                            Text("Alert if recipient misses message")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Conversation Color Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "paintpalette")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                        Text("Conversation Color")
                            .font(.subheadline.bold())
                        Spacer()

                        // Preview circle
                        Circle()
                            .fill(viewModel.selectedColor.color)
                            .frame(width: 20, height: 20)
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    // Color grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        ForEach(ConversationColor.allCases) { color in
                            Button {
                                viewModel.selectedColor = color
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 44, height: 44)

                                    if viewModel.selectedColor == color {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 3)
                                            .frame(width: 44, height: 44)

                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Button {
                    viewModel.proceedToConsent()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor, in: Capsule())
                }
                .disabled(!viewModel.isRelayURLValid)
                .opacity(viewModel.isRelayURLValid ? 1 : 0.5)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Security Verification (Consent)

private struct ConsentView: View {
    @Bindable var viewModel: InitiatorCeremonyViewModel
    let accentColor: Color
    @State private var showEthicsGuidelines = false

    private var completedCount: Int {
        [viewModel.consent.environmentConfirmed, viewModel.consent.notUnderSurveillance,
         viewModel.consent.ethicsUnderstood, viewModel.consent.keyLossUnderstood,
         viewModel.consent.relayWarningUnderstood, viewModel.consent.dataLossUnderstood,
         viewModel.consent.burnUnderstood].filter { $0 }.count
    }

    private let totalItems = 7

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(accentColor)
                        .padding(20)
                        .background(accentColor.opacity(0.1), in: Circle())

                    Text("Security Verification")
                        .font(.title2.bold())

                    Text("Confirm you understand before proceeding")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)

                // Progress bar
                HStack(spacing: 6) {
                    ForEach(0..<totalItems, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i < completedCount ? accentColor : Color(.systemGray5))
                            .frame(height: 5)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                // Environment Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "eye.slash")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 32)
                        Text("Environment")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.environmentConfirmed,
                        title: "No one is watching my screen",
                        subtitle: "No cameras, mirrors, or people can see your display",
                        accentColor: accentColor)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.notUnderSurveillance,
                        title: "I am not under surveillance or coercion",
                        subtitle: "Do not proceed if being forced or monitored",
                        accentColor: accentColor)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Responsibilities Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "hand.raised")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 32)
                        Text("Responsibilities")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.ethicsUnderstood,
                        title: "I understand the ethical responsibilities",
                        subtitle: "This tool is for legitimate private communication",
                        accentColor: accentColor)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.keyLossUnderstood,
                        title: "Keys cannot be recovered",
                        subtitle: "If you lose access, messages are gone forever",
                        accentColor: accentColor)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Technical Limitations Section
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 32)
                        Text("Limitations")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.relayWarningUnderstood,
                        title: "Relay server may be unavailable",
                        subtitle: "Messages won't deliver without connectivity",
                        accentColor: accentColor)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.dataLossUnderstood,
                        title: "Relay data is not persisted",
                        subtitle: "Server restarts may cause unread message loss",
                        accentColor: accentColor)

                    Divider().padding(.leading, 56)

                    ConsentRow(isChecked: $viewModel.consent.burnUnderstood,
                        title: "Burn destroys all key material",
                        subtitle: "Either party can burn, it cannot be undone",
                        icon: "flame.fill",
                        iconColor: .red,
                        accentColor: accentColor)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Button { showEthicsGuidelines = true } label: {
                    Label("Read Ethics Guidelines", systemImage: "doc.text")
                        .font(.subheadline)
                }
                .padding(.top, 20)

                Button {
                    viewModel.confirmConsent()
                } label: {
                    HStack {
                        if viewModel.isConsentComplete {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text("I Understand & Proceed")
                    }
                    .font(.headline)
                    .foregroundStyle(viewModel.isConsentComplete ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(viewModel.isConsentComplete ? accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .disabled(!viewModel.isConsentComplete)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showEthicsGuidelines) {
            EthicsGuidelinesSheet()
        }
        .tint(accentColor)
    }
}

private struct ConsentRow: View {
    @Binding var isChecked: Bool
    let title: String
    let subtitle: String
    var icon: String? = nil
    var iconColor: Color? = nil
    var accentColor: Color = Color.ashAccent

    var body: some View {
        Button { isChecked.toggle() } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(isChecked ? accentColor : Color(.systemGray3), lineWidth: 2)
                        .frame(width: 26, height: 26)
                    if isChecked {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let icon = icon {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(iconColor ?? .primary)
                        }
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ethics Guidelines Sheet

private struct EthicsGuidelinesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("ASH is designed for legitimate private communication.\nBy using this application, you agree to:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    VStack(spacing: 0) {
                        GuidelineRow(number: 1, title: "Respect Privacy", description: "Use this tool only for communications where both parties consent and have a legitimate need for privacy.")
                        Divider().padding(.leading, 56)
                        GuidelineRow(number: 2, title: "No Harmful Use", description: "Do not use ASH to plan, coordinate, or facilitate illegal activities, harassment, or harm to others.")
                        Divider().padding(.leading, 56)
                        GuidelineRow(number: 3, title: "Honest Communication", description: "Be truthful with your communication partners about the nature and purpose of your conversations.")
                        Divider().padding(.leading, 56)
                        GuidelineRow(number: 4, title: "Accept Responsibility", description: "You are solely responsible for the content of your messages and how you use this tool.")
                        Divider().padding(.leading, 56)
                        GuidelineRow(number: 5, title: "Understand Limitations", description: "ASH provides technical privacy but cannot protect against physical surveillance, compromised devices, or coerced disclosure.")
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                    Text("ASH was created to protect legitimate privacy needs such as journalist-source communication, whistleblowing, personal privacy, and human rights work. Misuse undermines these important purposes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Ethics Guidelines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct GuidelineRow: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                Text("\(number)").font(.subheadline.bold()).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Entropy Collection

private struct EntropyView: View {
    @Bindable var viewModel: InitiatorCeremonyViewModel
    let accentColor: Color
    @State private var points: [CGPoint] = []
    @State private var segments: [[CGPoint]] = []

    private var progressPercent: Int {
        Int(viewModel.entropyProgress * 100)
    }

    private var isComplete: Bool {
        viewModel.entropyProgress >= 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                ZStack {
                    // Outer ring (progress)
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 4)
                        .frame(width: 88, height: 88)

                    Circle()
                        .trim(from: 0, to: viewModel.entropyProgress)
                        .stroke(
                            isComplete ? Color.green : accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 88, height: 88)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: viewModel.entropyProgress)

                    // Inner icon
                    Image(systemName: isComplete ? "checkmark" : "hand.draw")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(isComplete ? Color.green : accentColor)
                }

                Text(isComplete ? "Entropy Complete!" : "Generate Entropy")
                    .font(.title2.bold())

                Text("Draw random patterns to generate secure randomness")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            .padding(.horizontal, 20)

            // Drawing Canvas
            GeometryReader { geo in
                ZStack {
                    // Canvas background with gradient border
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemGroupedBackground))

                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.6),
                                    accentColor.opacity(0.2),
                                    accentColor.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )

                    // Drawing canvas
                    Canvas { ctx, size in
                        // Draw all completed segments
                        for seg in segments {
                            drawPath(ctx: ctx, pts: seg, opacity: 0.4)
                        }
                        // Draw current path
                        drawPath(ctx: ctx, pts: points, opacity: 1.0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    // Hint text when empty
                    if segments.isEmpty && points.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "scribble.variable")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                            Text("Draw here")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Progress ring overlay around canvas
                    RoundedRectangle(cornerRadius: 20)
                        .trim(from: 0, to: viewModel.entropyProgress)
                        .stroke(accentColor.opacity(0.3), lineWidth: 3)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.entropyProgress)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            // Clamp to canvas bounds
                            let clampedPoint = CGPoint(
                                x: max(0, min(v.location.x, geo.size.width)),
                                y: max(0, min(v.location.y, geo.size.height))
                            )
                            points.append(clampedPoint)
                            if points.count > 400 { points.removeFirst(80) }
                            viewModel.addEntropy(from: v.location)
                        }
                        .onEnded { _ in
                            if points.count > 1 {
                                segments.append(points)
                                if segments.count > 15 { segments.removeFirst() }
                            }
                            points = []
                        }
                )
            }
            .padding(.horizontal, 20)

            // Progress indicator
            HStack(spacing: 16) {
                // Percentage
                Text("\(progressPercent)%")
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
                    .foregroundStyle(isComplete ? .green : .primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isComplete ? "Ready to proceed" : "Keep drawing...")
                        .font(.subheadline.weight(.medium))
                    Text("Random patterns strengthen encryption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    private func drawPath(ctx: GraphicsContext, pts: [CGPoint], opacity: Double) {
        guard pts.count > 1 else { return }
        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i-1].x + pts[i].x) / 2, y: (pts[i-1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i-1])
        }
        if let last = pts.last { path.addLine(to: last) }
        ctx.stroke(
            path,
            with: .color(accentColor.opacity(opacity)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Generating

private struct GeneratingView: View {
    let title: String
    let subtitle: String
    let current: Int
    let total: Int
    var accentColor: Color = Color.ashAccent

    private var progressPercent: Int {
        guard total > 0 else { return 0 }
        return Int((Double(current) / Double(total)) * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Progress ring
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 10)
                    .frame(width: 160, height: 160)

                if total > 0 {
                    // Progress ring
                    Circle()
                        .trim(from: 0, to: Double(current) / Double(total))
                        .stroke(
                            accentColor,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .frame(width: 160, height: 160)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: current)

                    // Center content
                    VStack(spacing: 4) {
                        Text("\(progressPercent)%")
                            .font(.system(size: 40, weight: .bold).monospacedDigit())

                        Text("\(current) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Indeterminate state
                    ProgressView()
                        .scaleEffect(2)
                }
            }

            // Title and subtitle
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 40)

            Spacer()

            // Tip at bottom
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Keep the app open during this process")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Receiver Setup

private struct ReceiverSetupView: View {
    @Bindable var viewModel: ReceiverCeremonyViewModel

    private var canProceed: Bool {
        viewModel.isChannelReady
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(20)
                        .background(Color.accentColor.opacity(0.1), in: Circle())

                    Text(viewModel.channel == .bluetooth ? "Ready to Receive" : "Ready to Scan")
                        .font(.title2.bold())

                    Text(viewModel.channel == .bluetooth
                         ? "Choose the same method as the other phone"
                         : "Type the six words read by the other person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.bottom, 24)

                ChannelPicker(channel: $viewModel.channel)
                    .padding(.horizontal, 20)

                if viewModel.channel == .qrCodes {
                    // Passphrase Section (Required)
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            Text("Verbal Passphrase")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("Required")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange, in: Capsule())
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        TextField("The six words, e.g. able acid aged also area army", text: $viewModel.passphrase, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                        if !viewModel.passphrase.isEmpty && !viewModel.isPassphraseValid {
                            Text("Type the six words shown on the other phone.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                    // Conversation Color Section
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "paintpalette")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            Text("Conversation Color")
                                .font(.subheadline.bold())
                            Spacer()

                            // Preview circle
                            Circle()
                                .fill(viewModel.selectedColor.color)
                                .frame(width: 20, height: 20)
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        // Color grid
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                            ForEach(ConversationColor.allCases) { color in
                                Button {
                                    viewModel.selectedColor = color
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(color.color)
                                            .frame(width: 44, height: 44)

                                        if viewModel.selectedColor == color {
                                            Circle()
                                                .strokeBorder(.white, lineWidth: 3)
                                                .frame(width: 44, height: 44)

                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    // Instructions
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            Text("How it works")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        VStack(alignment: .leading, spacing: 12) {
                            InstructionRow(number: 1, text: "Hold steady and point at the QR codes")
                            InstructionRow(number: 2, text: "Frames are captured automatically")
                            InstructionRow(number: 3, text: "Progress shows when complete")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Start button
                Button {
                    if viewModel.channel == .bluetooth {
                        viewModel.startBluetooth()
                    } else {
                        viewModel.startScanning()
                    }
                } label: {
                    HStack {
                        Image(systemName: viewModel.channel == .bluetooth ? "antenna.radiowaves.left.and.right" : "camera.fill")
                        Text(viewModel.channel == .bluetooth ? "Receive with Bluetooth" : "Start Scanning")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor, in: Capsule())
                }
                .disabled(!canProceed)
                .opacity(canProceed ? 1 : 0.5)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// The six passphrase words, numbered, large enough to read aloud
private struct PassphraseWordsView: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(word)
                        .font(.title3.weight(.semibold).monospaced())
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// QR codes (🔴 Maximum) or Bluetooth (🟠 Enhanced)
private struct ChannelPicker: View {
    @Binding var channel: CeremonyChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Transfer", selection: $channel) {
                ForEach(CeremonyChannel.allCases, id: \.self) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .pickerStyle(.segmented)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var explanation: String {
        switch channel {
        case .qrCodes:
            return "🔴 Maximum security: nothing goes over the air. Needs six spoken words and good light."
        case .bluetooth:
            return "🟠 Enhanced security: faster, protected by a post-quantum key exchange. You will compare six words."
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - QR Display (Streaming)

private struct QRDisplayView: View {
    @Bindable var viewModel: InitiatorCeremonyViewModel
    let currentFrame: Int
    let totalFrames: Int
    var accentColor: Color = Color.ashAccent
    @State private var previousBrightness: CGFloat = 0.5

    /// Get screen from current window scene (iOS 26+ compatible)
    private var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
    }

    var body: some View {
        GeometryReader { geometry in
            let qrSize = min(geometry.size.width - 32, geometry.size.height * 0.55)

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Text("Streaming QR Codes")
                        .font(.title2.bold())
                    Text("Let the other device scan continuously")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                .padding(.bottom, 12)

                // QR Code Display - maximized
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.1), radius: 16, y: 8)
                    if let qrImage = viewModel.currentQRImage() {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                }
                .frame(width: qrSize, height: qrSize)
                .frame(maxWidth: .infinity)

                // Frame indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isPlaying ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Frame \(currentFrame + 1) of \(totalFrames)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                // Progress bar
                ProgressView(value: Double(currentFrame + 1), total: Double(max(1, totalFrames)))
                    .tint(.accentColor)
                    .padding(.horizontal, 40)
                    .padding(.top, 6)
                    .padding(.bottom, 16)

                // Playback Controls
                VStack(spacing: 12) {
                    // Main controls row
                    HStack(spacing: 12) {
                        // First frame
                        Button { viewModel.goToFirstFrame() } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.subheadline)
                                .frame(width: 36, height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        .disabled(currentFrame == 0)

                        // Previous frame
                        Button { viewModel.previousFrame() } label: {
                            Image(systemName: "backward.fill")
                                .font(.subheadline)
                                .frame(width: 36, height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        .disabled(currentFrame == 0)

                        // Play/Pause
                        Button { viewModel.togglePlayback() } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .frame(width: 52, height: 52)
                                .background(Color.accentColor, in: Circle())
                                .foregroundStyle(.white)
                        }

                        // Next frame
                        Button { viewModel.nextFrame() } label: {
                            Image(systemName: "forward.fill")
                                .font(.subheadline)
                                .frame(width: 36, height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        .disabled(currentFrame >= totalFrames - 1)

                        // Last frame
                        Button { viewModel.goToLastFrame() } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.subheadline)
                                .frame(width: 36, height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        .disabled(currentFrame >= totalFrames - 1)
                    }
                    .foregroundStyle(.primary)

                    // Speed and Reset row
                    HStack(spacing: 12) {
                        // Reset button
                        Button {
                            viewModel.goToFirstFrame()
                            if !viewModel.isPlaying {
                                viewModel.resumePlayback()
                            }
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                        .foregroundStyle(.primary)

                        // FPS selector
                        Menu {
                            ForEach(InitiatorCeremonyViewModel.fpsOptions, id: \.self) { fps in
                                Button {
                                    viewModel.selectedFPS = fps
                                } label: {
                                    HStack {
                                        Text("\(Int(fps)) fps")
                                        if viewModel.selectedFPS == fps {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("\(Int(viewModel.selectedFPS)) fps", systemImage: "speedometer")
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Spacer()

                // Receiver Ready button
                Button { viewModel.finishSending() } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Receiver Ready")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.green, in: Capsule())
                }
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            if let screen = currentScreen {
                previousBrightness = screen.brightness
                screen.brightness = 1.0
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            if let screen = currentScreen {
                screen.brightness = previousBrightness
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - QR Scan

private struct QRScanView: View {
    @Bindable var viewModel: ReceiverCeremonyViewModel
    var accentColor: Color = Color.ashAccent

    private var progressPercent: Int {
        Int(viewModel.progress * 100)
    }

    private var isComplete: Bool {
        viewModel.progress >= 1.0
    }

    private var decodedBlocks: Int {
        Int(viewModel.progress * Double(viewModel.sourceBlockCount))
    }

    private let scanFrameSize: CGFloat = 280
    private var cornerOffset: CGFloat { scanFrameSize / 2 - 15 }

    var body: some View {
        GeometryReader { geometry in
            let cameraHeight = min(geometry.size.height * 0.55, 400)

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Circle()
                        .fill(isComplete ? Color.green : accentColor)
                        .frame(width: 10, height: 10)
                        .animation(.easeInOut, value: isComplete)
                    Text(isComplete ? "Transfer Complete" : "Scanning...")
                        .font(.headline)
                }
                .padding(.top, 16)
                .padding(.bottom, 12)

                if viewModel.passphraseLooksWrong {
                    Label("Nothing decodes: check the six words with the other person.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                // Camera view - larger
                ZStack {
                    QRScannerView(onFrameScanned: { viewModel.processScannedFrame($0) }, onError: { _ in })
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    // Semi-transparent overlay with cutout
                    ScannerOverlay(frameSize: scanFrameSize, cornerRadius: 16)
                        .fill(Color.black.opacity(0.4))

                    // Scanning frame border
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isComplete ? Color.green : accentColor,
                            lineWidth: 3
                        )
                        .frame(width: scanFrameSize, height: scanFrameSize)
                        .animation(.easeInOut, value: isComplete)

                    // Corner markers - larger and more visible
                    ForEach(0..<4, id: \.self) { corner in
                        CornerMarker(isComplete: isComplete, accentColor: accentColor)
                            .rotationEffect(.degrees(Double(corner) * 90))
                            .offset(
                                x: (corner == 0 || corner == 3) ? -cornerOffset : cornerOffset,
                                y: (corner == 0 || corner == 1) ? -cornerOffset : cornerOffset
                            )
                    }

                    // Scanning animation line
                    if !isComplete && viewModel.sourceBlockCount > 0 {
                        ScanningLine(accentColor: accentColor)
                            .frame(width: scanFrameSize - 20, height: 2)
                    }
                }
                .frame(height: cameraHeight)
                .padding(.horizontal, 16)

                // Progress section - more compact
                VStack(spacing: 12) {
                    if viewModel.sourceBlockCount > 0 {
                        // Progress ring - smaller
                        ZStack {
                            Circle()
                                .stroke(Color(.systemGray5), lineWidth: 6)
                                .frame(width: 90, height: 90)

                            Circle()
                                .trim(from: 0, to: viewModel.progress)
                                .stroke(
                                    isComplete ? Color.green : accentColor,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                )
                                .frame(width: 90, height: 90)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.2), value: viewModel.progress)

                            VStack(spacing: 0) {
                                Text("\(progressPercent)%")
                                    .font(.system(size: 24, weight: .bold).monospacedDigit())

                                if isComplete {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                }
                            }
                        }

                        // Blocks received
                        Text("\(decodedBlocks) of \(viewModel.sourceBlockCount) blocks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // Waiting state
                        VStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(1.3)

                            Text("Looking for QR codes...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 100)
                    }
                }
                .padding(.top, 16)

                Spacer()

                // Tip
                if !isComplete {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                            .foregroundStyle(.secondary)
                        Text("Align QR code within the frame")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private struct CornerMarker: View {
    let isComplete: Bool
    var accentColor: Color = Color.ashAccent

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 28))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 28, y: 0))
        }
        .stroke(
            isComplete ? Color.green : accentColor,
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 28, height: 28)
    }
}

/// Overlay shape with transparent center cutout for scanner
private struct ScannerOverlay: Shape {
    let frameSize: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Full rectangle
        path.addRect(rect)

        // Center cutout
        let cutoutRect = CGRect(
            x: (rect.width - frameSize) / 2,
            y: (rect.height - frameSize) / 2,
            width: frameSize,
            height: frameSize
        )
        path.addRoundedRect(in: cutoutRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        return path
    }

    var fillStyle: FillStyle {
        FillStyle(eoFill: true)
    }
}

/// Animated scanning line
private struct ScanningLine: View {
    let accentColor: Color
    @State private var offset: CGFloat = -100

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        accentColor.opacity(0),
                        accentColor.opacity(0.8),
                        accentColor.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .offset(y: offset)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    offset = 100
                }
            }
    }
}

/// Helper to control screen brightness using proper window context (iOS 26+ compatible)
private struct BrightnessController: UIViewRepresentable {
    let onAppear: (UIScreen) -> Void
    let onDisappear: (UIScreen) -> Void

    func makeUIView(context: Context) -> BrightnessControlView {
        BrightnessControlView(onAppear: onAppear, onDisappear: onDisappear)
    }

    func updateUIView(_ uiView: BrightnessControlView, context: Context) {}
}

private class BrightnessControlView: UIView {
    let onAppearHandler: (UIScreen) -> Void
    let onDisappearHandler: (UIScreen) -> Void

    init(onAppear: @escaping (UIScreen) -> Void, onDisappear: @escaping (UIScreen) -> Void) {
        self.onAppearHandler = onAppear
        self.onDisappearHandler = onDisappear
        super.init(frame: .zero)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.windowScene?.screen else { return }
        if window != nil {
            onAppearHandler(screen)
        } else {
            onDisappearHandler(screen)
        }
    }
}

// MARK: - Verification

private struct VerificationView: View {
    let mnemonic: [String]
    var accentColor: Color = Color.ashAccent
    @Binding var conversationName: String
    let onConfirm: () -> Void
    let onReject: () -> Void

    // Optional metadata display for receiver
    var receivedTTL: String?
    var receivedDisappearing: String?
    var receivedRelay: String?
    var receivedNotifications: [String]?

    // Persistence/Face ID requirements (receiver only)
    var receivedPersistenceEnabled: Bool = false
    var requiresFaceIDForPersistence: Bool = false
    var canProceed: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header with icon
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(accentColor)
                        .padding(20)
                        .background(accentColor.opacity(0.1), in: Circle())

                    Text("Verify Checksum")
                        .font(.title2.bold())

                    Text("Both devices must show the same words")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.bottom, 24)
                .padding(.horizontal, 20)

                // Mnemonic words card
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "key.horizontal")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 32)
                        Text("Security Words")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    // Words in a 2-column grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(Array(mnemonic.enumerated()), id: \.offset) { i, word in
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(accentColor, in: Circle())
                                Text(word)
                                    .font(.body.weight(.medium))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Received metadata (for receiver)
                if let ttl = receivedTTL {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(accentColor)
                                .frame(width: 32)
                            Text("Received Settings")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        SettingsRow(label: "Message Timeout", value: ttl)

                        if let disappearing = receivedDisappearing {
                            Divider().padding(.leading, 56)
                            SettingsRow(label: "Disappearing", value: disappearing)
                        }

                        if let notifications = receivedNotifications, !notifications.isEmpty {
                            Divider().padding(.leading, 56)
                            HStack(alignment: .top) {
                                Text("Notifications")
                                    .font(.subheadline)
                                Spacer()
                                Text(notifications.joined(separator: ", "))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        if let relay = receivedRelay {
                            Divider().padding(.leading, 56)
                            HStack {
                                Text("Relay")
                                    .font(.subheadline)
                                Spacer()
                                Text(relay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Conversation name
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "person.2")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 32)
                        Text("Name (Optional)")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    TextField("Enter a name for this conversation", text: $conversationName)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Face ID requirement warning (receiver only)
                if requiresFaceIDForPersistence {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Face ID Required")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Text("This conversation has local message storage enabled, which requires Face ID. Please enable Face ID in Settings before proceeding.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                } else if receivedPersistenceEnabled {
                    // Show persistence info when enabled and Face ID is on
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.iphone")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Local Storage Enabled")
                                    .font(.subheadline.bold())
                                Text("Messages will be stored locally on your device, protected by Face ID.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button { onConfirm() } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Words Match")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canProceed ? Color.green : Color.gray, in: Capsule())
                    }
                    .disabled(!canProceed)

                    Button(role: .destructive) { onReject() } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Words Don't Match")
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
    }
}

private struct SettingsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Completed

private struct CompletedView: View {
    let conversation: Conversation
    let onContinue: () -> Void
    var accentColor: Color = Color.ashAccent

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Success header
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.1))
                            .frame(width: 100, height: 100)

                        Image(systemName: "checkmark")
                            .font(.system(size: 48, weight: .medium))
                            .foregroundStyle(.green)
                    }

                    Text("Conversation Created!")
                        .font(.title2.bold())

                    Text(conversation.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                .padding(.bottom, 32)

                // Conversation details card
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 32)
                        Text("Details")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    // Pad size with visual indicator
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                            Text("Pad Size")
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(conversation.totalBytes), countStyle: .binary))
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().padding(.leading, 56)

                    // Role
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: conversation.role == .initiator ? "star" : "person")
                                .foregroundStyle(.secondary)
                            Text("Your Role")
                        }
                        Spacer()
                        Text(conversation.role == .initiator ? "Creator" : "Joiner")
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Disappearing messages (if enabled)
                    if conversation.disappearingMessages.isEnabled {
                        Divider().padding(.leading, 56)
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: "timer")
                                    .foregroundStyle(.secondary)
                                Text("Disappearing")
                            }
                            Spacer()
                            Text(conversation.disappearingMessages.displayName)
                                .fontWeight(.medium)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                // Security reminder
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "lock.shield")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 32)
                        Text("Security Active")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(16)

                    Divider().padding(.leading, 56)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("End-to-end encrypted", systemImage: "checkmark")
                        Label("One-time pad encryption", systemImage: "checkmark")
                        Label("No message recovery possible", systemImage: "checkmark")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Start button
                Button { onContinue() } label: {
                    HStack {
                        Image(systemName: "message.fill")
                        Text("Start Messaging")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(accentColor, in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Failed

private struct FailedView: View {
    let error: CeremonyError
    let onRetry: () -> Void
    let onCancel: () -> Void
    var accentColor: Color = Color.ashAccent

    private var errorIcon: String {
        switch error {
        case .checksumMismatch:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        case .insufficientEntropy:
            return "hand.draw"
        case .qrScanFailed, .frameDecodingFailed:
            return "qrcode"
        default:
            return "xmark.circle"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Error icon
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.1))
                        .frame(width: 100, height: 100)

                    Image(systemName: errorIcon)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.red)
                }

                Text("Setup Failed")
                    .font(.title2.bold())

                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            // Help section
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "lightbulb")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 32)
                    Text("Troubleshooting")
                        .font(.subheadline.bold())
                    Spacer()
                }
                .padding(16)

                Divider().padding(.leading, 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(troubleshootingTip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            // Action buttons
            VStack(spacing: 12) {
                Button { onRetry() } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(accentColor, in: Capsule())
                }

                Button { onCancel() } label: {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }

    private var troubleshootingTip: String {
        switch error {
        case .checksumMismatch:
            return "The security words didn't match. Both devices must complete the ceremony at the same time. Start fresh and try again."
        case .insufficientEntropy:
            return "Draw more random patterns on the screen to generate enough randomness. Move your finger in varied, unpredictable ways."
        case .qrScanFailed, .frameDecodingFailed:
            return "Make sure the camera can clearly see the QR code. Good lighting and holding steady helps. Try moving closer or further."
        case .qrGenerationFailed:
            return "There was an issue generating QR codes. This is rare - try restarting the ceremony."
        case .padReconstructionFailed:
            return "Some QR frames may have been missed. Try again and ensure all frames are captured."
        case .cancelled:
            return "The ceremony was cancelled. You can start again when ready."
        }
    }
}

// MARK: - Screenshot Previews

@MainActor
private enum CeremonyPreview {
    static let dependencies = Dependencies()

    static var ceremonyVM: CeremonyViewModel {
        CeremonyViewModel(dependencies: dependencies)
    }

    static var initiatorVM: InitiatorCeremonyViewModel {
        InitiatorCeremonyViewModel(dependencies: dependencies)
    }

    static var receiverVM: ReceiverCeremonyViewModel {
        let vm = ReceiverCeremonyViewModel(dependencies: dependencies)
        vm.passphrase = "able acid aged also area army"
        return vm
    }
}

#Preview("1. Role Selection") {
    NavigationStack {
        RoleSelectionView(viewModel: CeremonyPreview.ceremonyVM)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.ashAccent)
}

#Preview("2. Pad Size") {
    NavigationStack {
        PadSizeView(viewModel: CeremonyPreview.initiatorVM)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.indigo)
}

#Preview("3. Options") {
    NavigationStack {
        OptionsView(viewModel: CeremonyPreview.initiatorVM)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.indigo)
}

#Preview("4. Consent") {
    NavigationStack {
        ConsentView(viewModel: CeremonyPreview.initiatorVM, accentColor: Color.indigo)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.indigo)
}

#Preview("5. Entropy") {
    NavigationStack {
        EntropyView(viewModel: CeremonyPreview.initiatorVM, accentColor: Color.indigo)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.indigo)
}

#Preview("6. Generating") {
    NavigationStack {
        GeneratingView(
            title: "Generating QR Codes",
            subtitle: "Preparing 72 frames for transfer...",
            current: 45,
            total: 72,
            accentColor: Color.indigo
        )
        .navigationTitle("New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}
            }
        }
    }
    .tint(Color.indigo)
}

#Preview("7. QR Display") {
    NavigationStack {
        QRDisplayView(
            viewModel: CeremonyPreview.initiatorVM,
            currentFrame: 24,
            totalFrames: 72,
            accentColor: Color.indigo
        )
        .navigationTitle("New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}
            }
        }
    }
    .tint(Color.indigo)
}

#Preview("8. Receiver Setup") {
    NavigationStack {
        ReceiverSetupView(viewModel: CeremonyPreview.receiverVM)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.ashAccent)
}

#Preview("9. QR Scan") {
    NavigationStack {
        QRScanView(viewModel: CeremonyPreview.receiverVM, accentColor: Color.indigo)
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {}
                }
            }
    }
    .tint(Color.indigo)
}

#Preview("10. Verification") {
    NavigationStack {
        VerificationView(
            mnemonic: ["whisper", "phoenix", "ember", "shadow", "cipher", "vault"],
            accentColor: Color.indigo,
            conversationName: .constant(""),
            onConfirm: {},
            onReject: {}
        )
        .navigationTitle("New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}
            }
        }
    }
    .tint(Color.indigo)
}

#Preview("11. Completed") {
    NavigationStack {
        CompletedView(
            conversation: Conversation.screenshotSamples[0],
            onContinue: {},
            accentColor: Color.indigo
        )
        .navigationTitle("New Conversation")
        .navigationBarTitleDisplayMode(.inline)
    }
    .tint(Color.indigo)
}

#Preview("12. Failed") {
    NavigationStack {
        FailedView(
            error: .checksumMismatch,
            onRetry: {},
            onCancel: {},
            accentColor: Color.indigo
        )
        .navigationTitle("New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {}
            }
        }
    }
    .tint(Color.indigo)
}
