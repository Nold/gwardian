//
//  SettingsScreen.swift
//  Ash
//
//  App settings with modern design
//

import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    @Bindable var lockViewModel: AppLockViewModel
    let onBurnAll: () -> Void
    let onRelaySettingsChanged: () -> Void

    @State private var isShowingBurnAllConfirmation = false
    @State private var isShowingEmergencyBurn = false
    @State private var biometricEnabled = false
    @State private var familyMode = false
    @State private var isShowingBiometricWarning = false
    @State private var isShowingEraseWarning = false
    @State private var isShowingChangeCode = false
    @State private var defaultRelayURL = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?

    enum ConnectionTestResult {
        case success(version: String, latencyMs: Int)
        case failure(error: String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Security Section
                    securitySection

                    // Relay Section
                    relaySection

                    // About Section
                    aboutSection

                    // Danger Zone
                    dangerSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.lg)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Burn All Conversations?",
                isPresented: $isShowingBurnAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Burn All", role: .destructive) {
                    onBurnAll()
                    dismiss()
                }
            } message: {
                Text("This will permanently destroy all conversations and encryption pads. This cannot be undone.")
            }
            .onAppear {
                biometricEnabled = lockViewModel.isBiometricUnlockEnabled
                familyMode = dependencies.settingsService.isFamilyModeEnabled
                defaultRelayURL = dependencies.settingsService.relayServerURL
            }
            .sheet(isPresented: $isShowingEmergencyBurn) {
                BurnConfirmationView(
                    burnType: .all,
                    onConfirm: {
                        isShowingEmergencyBurn = false
                        onBurnAll()
                        dismiss()
                    },
                    onCancel: {
                        isShowingEmergencyBurn = false
                    }
                )
            }
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            Label("Security", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)

            VStack(spacing: 1) {
                Button {
                    isShowingChangeCode = true
                } label: {
                    SettingsNavigationRow(
                        icon: "lock.fill",
                        iconColor: Color.ashSecure,
                        title: "Change App Code",
                        subtitle: "The 6-digit code that opens the app",
                        isFirst: true,
                        isLast: false
                    )
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 56)

                if lockViewModel.canUseBiometrics {
                    SettingsToggleRow(
                        icon: lockViewModel.biometricType.iconName,
                        iconColor: Color.ashAccent,
                        title: lockViewModel.biometricType.displayName,
                        subtitle: "Shortcut instead of the app code",
                        isOn: Binding(
                            get: { biometricEnabled },
                            set: { newValue in
                                if newValue {
                                    isShowingBiometricWarning = true
                                } else {
                                    biometricEnabled = false
                                    Task { await lockViewModel.setBiometricUnlock(false) }
                                }
                            }
                        ),
                        isFirst: false,
                        isLast: false
                    )

                    Divider()
                        .padding(.leading, 56)
                }

                SettingsToggleRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    iconColor: .secondary,
                    title: "Lock on Background",
                    subtitle: "Ask for the code when the app returns",
                    isOn: Binding(
                        get: { lockViewModel.lockOnBackground },
                        set: { lockViewModel.lockOnBackground = $0 }
                    ),
                    isFirst: false,
                    isLast: false
                )

                Divider()
                    .padding(.leading, 56)

                SettingsToggleRow(
                    icon: "house.fill",
                    iconColor: Color.ashAccent,
                    title: "Family Mode",
                    subtitle: "QR ceremonies start without the six words",
                    isOn: Binding(
                        get: { familyMode },
                        set: { newValue in
                            familyMode = newValue
                            let settings = dependencies.settingsService
                            settings.isFamilyModeEnabled = newValue
                        }
                    ),
                    isFirst: false,
                    isLast: false
                )

                Divider()
                    .padding(.leading, 56)

                SettingsToggleRow(
                    icon: "trash.fill",
                    iconColor: Color.ashDanger,
                    title: "Erase After \(LockPolicy.eraseThreshold) Wrong Codes",
                    subtitle: "Destroy all conversations and pads",
                    isOn: Binding(
                        get: { lockViewModel.eraseAfterFailures },
                        set: { newValue in
                            if newValue {
                                isShowingEraseWarning = true
                            } else {
                                lockViewModel.setEraseAfterFailures(false)
                            }
                        }
                    ),
                    isFirst: false,
                    isLast: true
                )
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .sheet(isPresented: $isShowingChangeCode) {
            ChangePasscodeScreen(viewModel: lockViewModel)
        }
        .alert("Unlock with \(lockViewModel.biometricType.displayName)?", isPresented: $isShowingBiometricWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                Task {
                    biometricEnabled = await lockViewModel.setBiometricUnlock(true)
                }
            }
        } message: {
            Text("Anyone whose face or fingerprint is registered on this phone will be able to open the app. If a face or fingerprint is added later, the app code will be required again.")
        }
        .alert("Erase After \(LockPolicy.eraseThreshold) Wrong Codes?", isPresented: $isShowingEraseWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Enable", role: .destructive) {
                lockViewModel.setEraseAfterFailures(true)
            }
        } message: {
            Text("After \(LockPolicy.eraseThreshold) wrong codes in a row, all conversations and pads are destroyed and cannot be recovered. Someone could trigger this on purpose by entering wrong codes.")
        }
    }

    // MARK: - Relay Section

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            Label("Relay Server", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)

            VStack(spacing: 0) {
                // Server URL
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "link")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.ashAccent)
                            .frame(width: 24)

                        TextField("Server URL", text: $defaultRelayURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.body)
                            .onChange(of: defaultRelayURL) { _, _ in
                                connectionTestResult = nil
                            }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)

                    // Modified indicator
                    if defaultRelayURL != dependencies.settingsService.relayServerURL {
                        HStack {
                            Spacer()
                            Text("Modified")
                                .font(.caption)
                                .foregroundStyle(Color.ashWarning)
                                .padding(.trailing, Spacing.md)
                                .padding(.bottom, Spacing.xs)
                        }
                    }
                }

                Divider()
                    .padding(.leading, 56)

                // Connection status
                HStack(spacing: Spacing.sm) {
                    Image(systemName: connectionStatusIcon)
                        .font(.body.weight(.medium))
                        .foregroundStyle(connectionStatusColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection Status")
                            .font(.body)
                        Text(connectionStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if let result = connectionTestResult {
                        switch result {
                        case .success(let version, let latencyMs):
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(version)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.ashSuccess)
                                Text("\(latencyMs)ms")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.ashDanger)
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                Divider()
                    .padding(.leading, 56)

                // Action buttons
                HStack(spacing: Spacing.sm) {
                    // Test button
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Test")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ashAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.ashAccent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    }
                    .disabled(isTestingConnection || defaultRelayURL.isEmpty)

                    // Save button
                    Button {
                        saveDefaultRelayURL()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Save")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(canSave ? Color.ashAccent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                        .background(canSave ? Color.ashAccent.opacity(0.1) : Color(uiColor: .systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    }
                    .disabled(!canSave)

                    // Reset button
                    if defaultRelayURL != SettingsService.defaultRelayURL {
                        Button {
                            defaultRelayURL = SettingsService.defaultRelayURL
                            saveDefaultRelayURL()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                            .background(Color(uiColor: .systemFill))
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

            // Footer
            Text("Default server for new conversations. Each conversation can use a different relay.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.xs)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            Label("About", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)

            VStack(spacing: 1) {
                // Version info
                SettingsInfoRow(
                    icon: "app.badge",
                    iconColor: Color.ashAccent,
                    title: "Version",
                    value: "1.0.0",
                    isFirst: true,
                    isLast: false
                )

                Divider()
                    .padding(.leading, 56)

                // Encryption info
                SettingsInfoRow(
                    icon: "lock.fill",
                    iconColor: Color.ashSecure,
                    title: "Encryption",
                    value: "One-Time Pad",
                    isFirst: false,
                    isLast: false
                )

                Divider()
                    .padding(.leading, 56)

                // Security model link
                NavigationLink {
                    SecurityInfoView()
                } label: {
                    SettingsNavigationRow(
                        icon: "shield.checkered",
                        iconColor: Color.ashSuccess,
                        title: "Security Model",
                        subtitle: "How ASH protects your messages",
                        isFirst: false,
                        isLast: false
                    )
                }

                Divider()
                    .padding(.leading, 56)

                // Privacy link
                NavigationLink {
                    PrivacyInfoView()
                } label: {
                    SettingsNavigationRow(
                        icon: "hand.raised.fill",
                        iconColor: .purple,
                        title: "Privacy",
                        subtitle: "What data we collect (none)",
                        isFirst: false,
                        isLast: true
                    )
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ashDanger)
                .padding(.horizontal, Spacing.xs)

            Button {
                isShowingEmergencyBurn = true
            } label: {
                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.ashDanger.opacity(0.15))
                            .frame(width: 44, height: 44)

                        Image(systemName: "flame.fill")
                            .font(.title3)
                            .foregroundStyle(Color.ashDanger)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Emergency Burn All")
                            .font(.headline)
                            .foregroundStyle(Color.ashDanger)

                        Text("Instantly destroy all conversations and keys")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.md)
                .background(Color.ashDanger.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(Color.ashDanger.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Footer
            Text("Emergency burn permanently destroys all conversations, encryption pads, and messages. This cannot be undone.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.xs)
        }
    }

    // MARK: - Computed Properties

    private var canSave: Bool {
        !defaultRelayURL.isEmpty && defaultRelayURL != dependencies.settingsService.relayServerURL
    }

    private var connectionStatusIcon: String {
        if isTestingConnection { return "antenna.radiowaves.left.and.right" }
        switch connectionTestResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .none: return "circle.dashed"
        }
    }

    private var connectionStatusColor: Color {
        if isTestingConnection { return .secondary }
        switch connectionTestResult {
        case .success: return Color.ashSuccess
        case .failure: return Color.ashDanger
        case .none: return .secondary
        }
    }

    private var connectionStatusText: String {
        if isTestingConnection { return "Testing..." }
        switch connectionTestResult {
        case .success(let version, let latencyMs):
            return "Connected to \(version) • \(latencyMs)ms"
        case .failure(let error):
            return error
        case .none:
            return "Not tested"
        }
    }

    // MARK: - Helpers

    private func saveDefaultRelayURL() {
        let settings = dependencies.settingsService
        settings.relayServerURL = defaultRelayURL
        connectionTestResult = nil
        onRelaySettingsChanged()
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        guard let url = URL(string: defaultRelayURL)?.appendingPathComponent("health") else {
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
                connectionTestResult = .failure(error: "Server error")
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

// MARK: - Settings Row Components

private struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Color.ashAccent)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

private struct SettingsInfoRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Security Info

private struct SecurityInfoView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                VStack(spacing: Spacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.ashSecure.opacity(0.15))
                            .frame(width: 80, height: 80)

                        Image(systemName: "shield.checkered")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.ashSecure)
                    }

                    Text("Security Model")
                        .font(.title2.bold())

                    Text("How ASH protects your communications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Spacing.lg)

                // Security cards
                VStack(spacing: Spacing.md) {
                    SecurityCard(
                        icon: "lock.shield.fill",
                        iconColor: Color.ashAccent,
                        title: "One-Time Pad Encryption",
                        description: "Mathematically proven unbreakable encryption. Each byte of key material is used exactly once, making it impossible to decrypt without the pad."
                    )

                    SecurityCard(
                        icon: "qrcode.viewfinder",
                        iconColor: .blue,
                        title: "Offline Key Exchange",
                        description: "Keys are exchanged in person via QR codes. No encryption keys ever touch the network, eliminating remote interception."
                    )

                    SecurityCard(
                        icon: "person.2.fill",
                        iconColor: .green,
                        title: "Human Verification",
                        description: "Both devices display matching words that users verify verbally. This ensures you're connecting with the intended person."
                    )

                    SecurityCard(
                        icon: "clock.arrow.circlepath",
                        iconColor: .purple,
                        title: "Ephemeral Messages",
                        description: "Messages are never stored on disk and disappear after viewing. No message history can be recovered from your device."
                    )

                    SecurityCard(
                        icon: "server.rack",
                        iconColor: .orange,
                        title: "Zero-Trust Backend",
                        description: "The relay server only sees encrypted blobs. Even if compromised, message content is mathematically unrecoverable."
                    )
                }
                .padding(.horizontal, Spacing.md)

                Spacer(minLength: Spacing.xxl)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SecurityCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }
}

// MARK: - Privacy Info

private struct PrivacyInfoView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Header
                VStack(spacing: Spacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 80, height: 80)

                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.purple)
                    }

                    Text("Privacy")
                        .font(.title2.bold())

                    Text("What data we collect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Spacing.lg)

                // Privacy sections
                VStack(spacing: Spacing.md) {
                    PrivacySection(
                        title: "No Accounts Required",
                        icon: "person.slash.fill",
                        iconColor: .green,
                        items: [
                            "No phone number required",
                            "No email required",
                            "No identity verification"
                        ]
                    )

                    PrivacySection(
                        title: "No Tracking",
                        icon: "eye.slash.fill",
                        iconColor: .blue,
                        items: [
                            "No analytics or telemetry",
                            "No crash reporting",
                            "No advertising"
                        ]
                    )

                    PrivacySection(
                        title: "No Persistence",
                        icon: "trash.fill",
                        iconColor: .orange,
                        items: [
                            "Messages never written to disk",
                            "No message history stored",
                            "No cloud backup"
                        ]
                    )

                    PrivacySection(
                        title: "Minimal Network",
                        icon: "network.slash",
                        iconColor: .purple,
                        items: [
                            "Keys exchanged offline only",
                            "Backend sees only encrypted data",
                            "No metadata collection"
                        ]
                    )
                }
                .padding(.horizontal, Spacing.md)

                Spacer(minLength: Spacing.xxl)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySection: View {
    let title: String
    let icon: String
    let iconColor: Color
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(Color.ashSuccess)

                        Text(item)
                            .font(.body)

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
    }
}

#Preview {
    SettingsScreen(lockViewModel: AppLockViewModel(vault: PasscodeVault()), onBurnAll: {}, onRelaySettingsChanged: {})
}
