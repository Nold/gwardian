//
//  MessagingScreen.swift
//  Ash
//
//  Messaging interface - Modern redesign with custom colors
//

import SwiftUI

struct MessagingScreen: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    let onBurn: () -> Void
    let onRename: (String) -> Void
    let onUpdateRelayURL: (String) -> Void
    var onDismiss: (() async -> Void)?

    @State private var viewModel: MessagingViewModel?
    @State private var isShowingBurnConfirmation = false
    @State private var isShowingRename = false
    @State private var renameText = ""
    @State private var isShowingSettings = false
    @State private var isShowingInfo = false

    var body: some View {
        Group {
            if let vm = viewModel {
                MessagingContent(
                    viewModel: vm,
                    accentColor: conversation.accentColor.color
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(conversation.accentColor.color.opacity(0.1), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isShowingInfo = true
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }

                    Button {
                        renameText = conversation.customName ?? ""
                        isShowingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Divider()

                    Button(role: .destructive) {
                        isShowingBurnConfirmation = true
                    } label: {
                        Label("Burn Conversation", systemImage: "flame.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(conversation.accentColor.color)
                }
            }
        }
        .alert("Rename Conversation", isPresented: $isShowingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                onRename(renameText)
            }
        } message: {
            Text("Enter a custom name or leave empty to use mnemonic words")
        }
        .sheet(isPresented: $isShowingBurnConfirmation) {
            BurnConfirmationView(
                burnType: .conversation(name: conversation.displayName),
                onConfirm: {
                    isShowingBurnConfirmation = false
                    onBurn()
                },
                onCancel: {
                    isShowingBurnConfirmation = false
                }
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            ConversationSettingsSheet(
                conversation: viewModel?.currentConversation ?? conversation,
                onSave: { url in
                    onUpdateRelayURL(url)
                    isShowingSettings = false
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingInfo) {
            ConversationInfoScreen(
                conversation: viewModel?.currentConversation ?? conversation
            )
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel?.isShowingBurnedScreen ?? false },
            set: { viewModel?.isShowingBurnedScreen = $0 }
        )) {
            BurnedConversationScreen(
                conversationName: conversation.displayName,
                onDismiss: {
                    viewModel?.isShowingBurnedScreen = false
                    dismiss()
                }
            )
        }
        .task {
            viewModel = MessagingViewModel(conversation: conversation, dependencies: dependencies)
            await viewModel?.onAppear()
        }
        .onDisappear {
            Task {
                await viewModel?.onDisappear()
                await onDismiss?()
            }
        }
    }
}

// MARK: - Conversation Settings Sheet

private struct ConversationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    let onSave: (String) -> Void

    @State private var relayURL: String = ""
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: SettingsScreen.ConnectionTestResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(conversation.accentColor.color)
                            .padding(20)
                            .background(conversation.accentColor.color.opacity(0.1), in: Circle())

                        Text("Relay Settings")
                            .font(.title2.bold())

                        Text("Configure the relay server for this conversation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)

                    // Server URL
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "link")
                                .font(.title3)
                                .foregroundStyle(conversation.accentColor.color)
                                .frame(width: 32)
                            Text("Server URL")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(16)

                        Divider().padding(.leading, 56)

                        TextField("https://relay.example.com", text: $relayURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                        Divider().padding(.leading, 56)

                        // Test connection
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.subheadline)
                                Spacer()
                                if isTestingConnection {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if let result = connectionTestResult {
                                    switch result {
                                    case .success:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .failure:
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .disabled(isTestingConnection || relayURL.isEmpty)

                        if let result = connectionTestResult {
                            Divider().padding(.leading, 56)
                            HStack {
                                switch result {
                                case .success(let version, let latencyMs):
                                    Label("Connected - \(version) (\(latencyMs)ms)", systemImage: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                case .failure(let error):
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                    // Info
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Messages are stored in server RAM for \(conversation.messageRetention.displayName) and deleted on delivery or expiry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    // Save button
                    Button {
                        onSave(relayURL)
                    } label: {
                        Text("Save")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(conversation.accentColor.color, in: Capsule())
                    }
                    .disabled(relayURL.isEmpty)
                    .opacity(relayURL.isEmpty ? 0.5 : 1)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                relayURL = conversation.relayURL
            }
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil

        defer { isTestingConnection = false }

        guard let url = URL(string: relayURL)?.appendingPathComponent("health") else {
            connectionTestResult = .failure(error: "Invalid URL")
            return
        }

        let startTime = Date()

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                connectionTestResult = .failure(error: "Server returned error")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                connectionTestResult = .success(version: "v\(version)", latencyMs: latencyMs)
            } else {
                connectionTestResult = .success(version: "OK", latencyMs: latencyMs)
            }
        } catch {
            connectionTestResult = .failure(error: error.localizedDescription)
        }
    }
}

// MARK: - Content

private struct MessagingContent: View {
    @Bindable var viewModel: MessagingViewModel
    let accentColor: Color
    @FocusState private var isInputFocused: Bool
    @State private var selectedMessageForInfo: Message?

    var body: some View {
        VStack(spacing: 0) {
            // Peer burned warning
            if viewModel.peerBurned {
                PeerBurnedBanner()
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Spacing.sm) {
                        PadUsageHeaderView(
                            conversation: viewModel.currentConversation,
                            isConnected: viewModel.isConnected,
                            relayError: viewModel.relayError
                        )
                        .padding(.top, Spacing.md)

                        if viewModel.messages.isEmpty {
                            EmptyMessagesView(accentColor: accentColor)
                                .padding(.top, Spacing.xxl)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    accentColor: accentColor,
                                    onRetry: {
                                        if case .failed = message.deliveryStatus {
                                            Task { await viewModel.retryMessage(message) }
                                        }
                                    },
                                    onInfo: {
                                        selectedMessageForInfo = message
                                    },
                                    onDeleteForMe: { viewModel.deleteForMe(message) },
                                    onDeleteForEveryone: viewModel.canDeleteForEveryone(message)
                                        ? { Task { await viewModel.deleteForEveryone(message) } }
                                        : viewModel.deleteFailedIds.contains(message.id)
                                            ? { Task { await viewModel.retryDeleteForEveryone(message) } }
                                            : nil
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }

            // Input - disabled if peer burned
            if !viewModel.peerBurned {
                MessageInputView(
                    text: $viewModel.messageText,
                    lifetime: $viewModel.lifetime,
                    isFocused: $isInputFocused,
                    accentColor: accentColor,
                    canSend: viewModel.canSendMessage,
                    currentBytes: viewModel.currentMessageBytes,
                    isApproachingLimit: viewModel.isApproachingLimit,
                    isMessageTooLarge: viewModel.isMessageTooLarge,
                    formattedSize: viewModel.formattedMessageSize,
                    sizeError: viewModel.messageSizeError,
                    locationError: viewModel.locationError,
                    isGettingLocation: viewModel.isGettingLocation,
                    onSend: {
                        Task { await viewModel.sendMessage() }
                    },
                    onSendLocation: {
                        Task { await viewModel.sendLocation() }
                    }
                )
            }
        }
        .navigationDestination(item: $selectedMessageForInfo) { message in
            MessageDetailView(
                message: message,
                accentColor: accentColor,
                onExtendTTL: nil  // TODO: Implement extend TTL when backend supports it
            )
        }
    }
}

// MARK: - Empty Messages View

private struct EmptyMessagesView: View {
    let accentColor: Color

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(accentColor.opacity(0.5))

            VStack(spacing: 4) {
                Text("No Messages")
                    .font(.headline)
                Text("Messages are ephemeral and disappear after viewing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }
}

// MARK: - Peer Burned Banner

private struct PeerBurnedBanner: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.white)
            Text("This conversation has been burned")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(Spacing.md)
        .background(Color.ashDanger)
    }
}

// MARK: - Pad Usage Header

private struct PadUsageHeaderView: View {
    let conversation: Conversation
    var isConnected: Bool = false
    var relayError: String?

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(conversation.accentColor.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(conversation.formattedRemaining) remaining")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.primary)

                    DualUsageBar(
                        myUsage: conversation.myUsagePercentage,
                        peerUsage: conversation.peerUsagePercentage,
                        accentColor: conversation.accentColor.color,
                        height: 4
                    )
                    .frame(width: 80)
                }

                Spacer()

                // Relay status indicator
                RelayStatusIndicator(isConnected: isConnected, error: relayError)

                MnemonicDisplay(words: Array(conversation.mnemonicChecksum.prefix(3)))
            }
        }
        .padding(Spacing.sm)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }
}

// MARK: - Relay Status Indicator

private struct RelayStatusIndicator: View {
    let isConnected: Bool
    let error: String?

    var body: some View {
        HStack(spacing: 4) {
            if let error = error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
                    .help(error)
            } else if isConnected {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                    .font(.caption2)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .frame(width: 20)
    }
}

// MARK: - Message Bubble

private struct MessageBubbleView: View {
    let message: Message
    let accentColor: Color
    let onRetry: (() -> Void)?
    let onInfo: (() -> Void)?
    let onDeleteForMe: (() -> Void)?
    /// Set only for the author's own sent messages
    let onDeleteForEveryone: (() -> Void)?

    init(
        message: Message,
        accentColor: Color,
        onRetry: (() -> Void)? = nil,
        onInfo: (() -> Void)? = nil,
        onDeleteForMe: (() -> Void)? = nil,
        onDeleteForEveryone: (() -> Void)? = nil
    ) {
        self.message = message
        self.accentColor = accentColor
        self.onRetry = onRetry
        self.onInfo = onInfo
        self.onDeleteForMe = onDeleteForMe
        self.onDeleteForEveryone = onDeleteForEveryone
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
                    .contextMenu {
                        Button {
                            onInfo?()
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }

                        // Don't show copy for expired/wiped messages
                        if !message.isContentWiped {
                            Button {
                                copyToClipboard(message.content)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }

                        if case .failed = message.deliveryStatus {
                            Button {
                                onRetry?()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }

                        if let onDeleteForMe {
                            Button(role: .destructive, action: onDeleteForMe) {
                                Label("Delete for Me", systemImage: "trash")
                            }
                        }
                        if let onDeleteForEveryone {
                            Button(role: .destructive, action: onDeleteForEveryone) {
                                Label("Delete for Everyone", systemImage: "trash.slash")
                            }
                        }
                    }

                // Status row
                HStack(spacing: 6) {
                    // Show appropriate countdown based on message state
                    if message.isAwaitingDelivery, let serverExpiresAt = message.serverExpiresAt {
                        // Sent message waiting for delivery - show server TTL
                        ServerTTLIndicatorView(expiresAt: serverExpiresAt, accentColor: accentColor)
                    } else if let expiresAt = message.expiresAt {
                        // Disappearing message, with the lifetime its author chose
                        ExpiryIndicatorView(expiresAt: expiresAt, accentColor: accentColor)
                    }

                    Text(message.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)

                    // Delivery status for outgoing messages
                    if message.isOutgoing {
                        DeliveryStatusView(status: message.deliveryStatus, onRetry: onRetry)
                    }
                }
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
    }

    private func copyToClipboard(_ content: MessageContent) {
        switch content {
        case .text(let text):
            UIPasteboard.general.string = text
        case .location(let lat, let lon):
            UIPasteboard.general.string = "\(lat), \(lon)"
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        Group {
            if message.isContentWiped {
                // Message has expired and content is securely wiped
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.caption)
                    Text("Message Expired")
                        .font(.subheadline)
                        .italic()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            } else {
                switch message.content {
                case .text(let text):
                    Text(text)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)

                case .location(let lat, let lon):
                    LocationBubbleContent(
                        latitude: lat,
                        longitude: lon,
                        isOutgoing: message.isOutgoing,
                        accentColor: accentColor
                    )
                }
            }
        }
        .background(message.isContentWiped
            ? Color(uiColor: .tertiarySystemBackground)
            : (message.isOutgoing ? accentColor : Color(uiColor: .secondarySystemBackground))
        )
        .foregroundStyle(message.isContentWiped
            ? Color.secondary
            : (message.isOutgoing ? Color.white : Color.primary)
        )
    }
}

// MARK: - Location Bubble Content

private struct LocationBubbleContent: View {
    let latitude: Double
    let longitude: Double
    let isOutgoing: Bool
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "location.fill")
                    .font(.caption)
                Text(L10n.Messaging.location)
                    .font(.caption.bold())
            }

            Text(String(format: "%.6f, %.6f", latitude, longitude))
                .font(.system(.caption, design: .monospaced))

            Button {
                openInMaps()
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "map.fill")
                        .font(.caption2)
                    Text("Open in Maps")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(
                    Capsule()
                        .fill(isOutgoing ? Color.white.opacity(0.2) : accentColor.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func openInMaps() {
        let urlString = "maps://?ll=\(latitude),\(longitude)&q=Shared%20Location"
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Delivery Status View

private struct DeliveryStatusView: View {
    let status: DeliveryStatus
    let onRetry: (() -> Void)?

    var body: some View {
        switch status {
        case .sending:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .sent:
            // Single check - sent to server, awaiting delivery
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)

        case .delivered:
            // Double check - delivered to recipient
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.ashSuccess)

        case .failed(let reason):
            Button {
                onRetry?()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ashDanger)

                    if reason != nil {
                        Text(L10n.Error.relayError)
                            .font(.caption2)
                            .foregroundStyle(Color.ashDanger)
                    }
                }
            }
            .buttonStyle(.plain)

        case .none:
            EmptyView()
        }
    }
}

// MARK: - Server TTL Indicator (for sent messages awaiting delivery)

private struct ServerTTLIndicatorView: View {
    let expiresAt: Date
    let accentColor: Color
    @State private var remainingTime: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var indicatorColor: Color {
        if remainingTime < 60 {
            return Color.ashDanger
        } else if remainingTime < 300 {
            return Color.ashWarning
        }
        return Color.secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 10))
                .foregroundStyle(indicatorColor)

            Text(formatHumanReadable(remainingTime))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(indicatorColor)
        }
        .onAppear {
            remainingTime = max(0, expiresAt.timeIntervalSinceNow)
        }
        .onReceive(timer) { _ in
            remainingTime = max(0, expiresAt.timeIntervalSinceNow)
        }
        .accessibilityLabel("Server expires in \(formatHumanReadable(remainingTime))")
    }

    private func formatHumanReadable(_ seconds: TimeInterval) -> String {
        if seconds <= 0 {
            return "expired"
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            return "\(mins)m"
        } else if seconds < 86400 {
            let hours = Int(seconds) / 3600
            return "\(hours)h"
        } else {
            let days = Int(seconds) / 86400
            return "\(days)d"
        }
    }
}

// MARK: - Expiry Indicator (for received messages with disappearing timer)

private struct ExpiryIndicatorView: View {
    let expiresAt: Date
    let accentColor: Color
    @State private var remainingTime: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var estimatedTotalTime: TimeInterval {
        let elapsed = Date().timeIntervalSince(expiresAt.addingTimeInterval(-remainingTime))
        let total = elapsed + remainingTime
        let commonTTLs: [TimeInterval] = [60, 300, 1800, 3600, 21600, 86400, 172800, 604800]
        return commonTTLs.first { $0 >= total * 0.9 } ?? total
    }

    private var progress: Double {
        guard estimatedTotalTime > 0 else { return 0 }
        return max(0, min(1, remainingTime / estimatedTotalTime))
    }

    private var indicatorColor: Color {
        if remainingTime < 60 {
            return Color.ashDanger
        } else if remainingTime < 300 {
            return Color.ashWarning
        }
        return Color.secondary
    }

    private var ringColor: Color {
        if progress < 0.1 {
            return Color.ashDanger
        } else if progress < 0.25 {
            return Color.ashWarning
        }
        return accentColor.opacity(0.6)
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
            }
            .frame(width: 14, height: 14)

            Text(formatHumanReadable(remainingTime))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(indicatorColor)
        }
        .onAppear {
            remainingTime = max(0, expiresAt.timeIntervalSinceNow)
        }
        .onReceive(timer) { _ in
            remainingTime = max(0, expiresAt.timeIntervalSinceNow)
        }
        .accessibilityLabel("Expires in \(formatHumanReadable(remainingTime))")
    }

    private func formatHumanReadable(_ seconds: TimeInterval) -> String {
        if seconds <= 0 {
            return "expired"
        } else if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            if secs == 0 || mins >= 5 {
                return "\(mins)m"
            }
            return "\(mins)m \(secs)s"
        } else if seconds < 86400 {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            if mins == 0 || hours >= 6 {
                return "\(hours)h"
            }
            return "\(hours)h \(mins)m"
        } else {
            let days = Int(seconds) / 86400
            let hours = (Int(seconds) % 86400) / 3600
            if hours == 0 || days >= 2 {
                return "\(days)d"
            }
            return "\(days)d \(hours)h"
        }
    }
}

// MARK: - Message Input

private struct MessageInputView: View {
    @Binding var text: String
    @Binding var lifetime: DisappearingMessages
    var isFocused: FocusState<Bool>.Binding
    let accentColor: Color
    let canSend: Bool
    let currentBytes: Int
    let isApproachingLimit: Bool
    let isMessageTooLarge: Bool
    let formattedSize: String
    let sizeError: String?
    let locationError: String?
    let isGettingLocation: Bool
    let onSend: () -> Void
    let onSendLocation: () -> Void

    private var showSizeIndicator: Bool {
        currentBytes > 1024
    }

    private var sizeIndicatorColor: Color {
        if isMessageTooLarge {
            return Color.ashDanger
        } else if isApproachingLimit {
            return Color.ashWarning
        }
        return Color.secondary
    }

    private var errorMessage: String? {
        sizeError ?? locationError
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = errorMessage {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color.ashDanger)
            }

            HStack(spacing: Spacing.sm) {
                // Location button
                Button(action: onSendLocation) {
                    if isGettingLocation {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(accentColor)
                            .frame(width: 28, height: 28)
                    }
                }
                .disabled(isGettingLocation)
                .accessibilityLabel("Share location")

                LifetimeMenu(lifetime: $lifetime, accent: accentColor)

                VStack(alignment: .trailing, spacing: 2) {
                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(isMessageTooLarge ? Color.ashDanger : Color.clear, lineWidth: 2)
                                )
                        )
                        .lineLimit(1...5)
                        .focused(isFocused)

                    // Size indicator
                    if showSizeIndicator {
                        HStack(spacing: 4) {
                            Text(formattedSize)
                            Text("/")
                            Text("\(MessageLimits.maxMessageKB) KB")
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(sizeIndicatorColor)
                        .padding(.trailing, Spacing.xs)
                    }
                }

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSend ? accentColor : Color.secondary)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Material.bar)
        }
    }
}

// MARK: - Screenshot Previews

#Preview("Messaging - With Messages") {
    MessagingPreviewContainer()
}

#Preview("Message Bubble - Outgoing") {
    MessageBubbleView(
        message: Message.screenshotSamples[1],
        accentColor: Conversation.screenshotSamples[0].accentColor.color
    )
    .padding()
}

#Preview("Message Bubble - Incoming") {
    MessageBubbleView(
        message: Message.screenshotSamples[0],
        accentColor: Conversation.screenshotSamples[0].accentColor.color
    )
    .padding()
}

/// Preview container to avoid issues with let bindings in #Preview
private struct MessagingPreviewContainer: View {
    let conversation = Conversation.screenshotSamples[0]
    let messages = Message.screenshotSamples

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: Spacing.sm) {
                        // Pad usage header - same as real messaging screen
                        PadUsageHeaderView(
                            conversation: conversation,
                            isConnected: true,
                            relayError: nil
                        )
                        .padding(.top, Spacing.md)

                        ForEach(messages) { message in
                            MessageBubbleView(
                                message: message,
                                accentColor: conversation.accentColor.color
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
                }

                // Static input bar for screenshot
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)

                    Text("Message")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                        )

                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Material.bar)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(conversation.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(conversation.accentColor.color.opacity(0.1), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(conversation.accentColor.color)
                }
            }
        }
    }
}
