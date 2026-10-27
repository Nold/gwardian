//
//  BluetoothTransferView.swift
//  Ash
//
//  Pad transfer over Bluetooth (docs/ble-transfer.md): the receiver shows a
//  code, the sender picks it, both compare six words, then the pad is sent.
//

import SwiftUI

/// Sending side: pick the other phone, compare the words, send.
struct BluetoothSendView: View {
    let session: BLEPadSenderSession
    let accentColor: Color
    let onCompleted: () -> Void
    let onWordsRejected: () -> Void
    let onRetry: () -> Void

    var body: some View {
        BluetoothTransferLayout(
            state: session.state,
            accentColor: accentColor,
            onConfirmWords: { session.confirmWords() },
            onRejectWords: onWordsRejected,
            onRetry: onRetry
        ) {
            VStack(spacing: 20) {
                BluetoothHeader(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "Choose the Other Phone",
                    subtitle: "On the other phone, choose Receive with Bluetooth. Then tap the code it shows.",
                    accentColor: accentColor
                )

                if session.nearby.isEmpty {
                    ProgressView("Looking for nearby phones…")
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 10) {
                        ForEach(session.nearby) { receiver in
                            Button {
                                session.connect(to: receiver)
                            } label: {
                                HStack {
                                    Text(receiver.code)
                                        .font(.title2.monospaced().bold())
                                    Spacer()
                                    SignalBars(rssi: receiver.rssi)
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(16)
                                .background(
                                    Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .onChange(of: session.state) { _, state in
            if state == .completed { onCompleted() }
        }
    }
}

/// Receiving side: show a code, compare the words, receive.
struct BluetoothReceiveView: View {
    let session: BLEPadReceiverSession
    let accentColor: Color
    let onCompleted: () -> Void
    let onWordsRejected: () -> Void
    let onRetry: () -> Void

    var body: some View {
        BluetoothTransferLayout(
            state: session.state,
            accentColor: accentColor,
            onConfirmWords: { session.confirmWords() },
            onRejectWords: onWordsRejected,
            onRetry: onRetry
        ) {
            VStack(spacing: 20) {
                BluetoothHeader(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "Waiting for the Other Phone",
                    subtitle: "On the phone creating the conversation, choose this code.",
                    accentColor: accentColor
                )
                if case .advertising(let code) = session.state {
                    Text(code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .padding(.vertical, 20)
                        .padding(.horizontal, 32)
                        .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                }
            }
        }
        .onChange(of: session.state) { _, state in
            if state == .completed { onCompleted() }
        }
    }
}

/// Steps shared by both sides; `waiting` is shown while looking for the other phone.
private struct BluetoothTransferLayout<Waiting: View>: View {
    let state: BLETransferState
    let accentColor: Color
    let onConfirmWords: () -> Void
    let onRejectWords: () -> Void
    let onRetry: () -> Void
    @ViewBuilder let waiting: () -> Waiting

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch state {
                case .idle, .waitingForBluetooth:
                    ProgressView("Starting Bluetooth…")
                        .padding(.top, 80)

                case .advertising, .scanning:
                    waiting()

                case .connecting, .exchanging:
                    BluetoothHeader(
                        systemImage: "lock.rotation",
                        title: "Securing the Connection",
                        subtitle: "Exchanging keys with the other phone…",
                        accentColor: accentColor
                    )
                    ProgressView()

                case .comparingWords(let words):
                    WordsComparison(
                        words: words,
                        accentColor: accentColor,
                        onConfirm: onConfirmWords,
                        onReject: onRejectWords
                    )

                case .transferring(let progress):
                    BluetoothHeader(
                        systemImage: "arrow.left.arrow.right",
                        title: "Transferring",
                        subtitle: "Keep both phones close together.",
                        accentColor: accentColor
                    )
                    ProgressView(value: progress)
                        .padding(.horizontal, 40)
                    Text("\(Int(progress * 100)) %")
                        .font(.headline.monospacedDigit())

                case .completed:
                    BluetoothHeader(
                        systemImage: "checkmark.circle.fill",
                        title: "Transfer Complete",
                        subtitle: "",
                        accentColor: accentColor
                    )

                case .failed(let failure):
                    BluetoothHeader(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Transfer Failed",
                        subtitle: failure.message,
                        accentColor: .orange
                    )
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(accentColor, in: Capsule())
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }
}

/// The six words both people read aloud; a difference means someone may be
/// in the middle, so the transfer must stop.
private struct WordsComparison: View {
    let words: [String]
    let accentColor: Color
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            BluetoothHeader(
                systemImage: "text.bubble",
                title: "Compare These Words",
                subtitle: "Read them aloud. The other phone must show exactly the same words, in the same order.",
                accentColor: accentColor
            )

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(word)
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 20)

            VStack(spacing: 12) {
                Button(action: onConfirm) {
                    Text("The Words Match")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.green, in: Capsule())
                }
                Button(role: .destructive, action: onReject) {
                    Text("They Are Different")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct BluetoothHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(accentColor)
                .padding(20)
                .background(accentColor.opacity(0.1), in: Circle())
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

private struct SignalBars: View {
    let rssi: Int

    /// 1 to 3 bars; closer phones are stronger.
    private var bars: Int {
        switch rssi {
        case (-60)...: return 3
        case (-75)...: return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + level * 4))
            }
        }
        .accessibilityLabel("Signal \(bars) of 3")
    }
}

extension BLETransferFailure {
    var message: String {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is off or not available. Turn it on in Control Center."
        case .bluetoothUnauthorized:
            return "Gwardian is not allowed to use Bluetooth. Allow it in Settings."
        case .disconnected:
            return "The connection was lost. Keep the phones close and try again."
        case .protocolError:
            return "The exchange failed. Start again on both phones."
        }
    }
}
