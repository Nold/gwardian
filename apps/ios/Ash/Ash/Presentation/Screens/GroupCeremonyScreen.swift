//
//  GroupCeremonyScreen.swift
//  Ash
//
//  Group ceremony around the table (docs/group-ceremony.md): one phone shows
//  its card, every other phone scans it, then the next member takes a turn.
//

import SwiftUI

struct GroupCeremonyScreen: View {
    @Bindable var viewModel: GroupCeremonyViewModel
    let onComplete: (GroupConversation) -> Void
    let onCancel: () -> Void

    private var accentColor: Color { viewModel.selectedColor.color }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(viewModel.role == .creator ? "New Group" : "Join a Group")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            viewModel.cancel()
                            onCancel()
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .setup:
            GroupSetupView(viewModel: viewModel)
        case .collectingEntropy:
            GroupEntropyView(progress: viewModel.entropyProgress, accentColor: accentColor) { point in
                viewModel.addEntropy(from: point)
            }
        case .generating:
            VStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large)
                Text("Preparing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .showing:
            GroupShowCardView(viewModel: viewModel, accentColor: accentColor)
        case .scanning:
            GroupScanCardView(viewModel: viewModel)
        case .waiting:
            GroupTurnView(viewModel: viewModel, accentColor: accentColor)
        case .completed(let group):
            GroupCompletedView(group: group) { onComplete(group) }
        case .failed(let message):
            GroupFailedView(message: message) {
                viewModel.cancel()
                onCancel()
            }
        }
    }
}

// MARK: - Setup

private struct GroupSetupView: View {
    @Bindable var viewModel: GroupCeremonyViewModel

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $viewModel.myName)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
            } header: {
                Text("Your Name")
            } footer: {
                Text("Shown to the other members next to your messages.")
            }

            if viewModel.role == .creator {
                creatorSections
            } else {
                joinerSections
            }

            Section {
                Button {
                    viewModel.start()
                } label: {
                    Text(viewModel.role == .creator ? "Create My Card" : "Scan the Creator's Card")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .disabled(!viewModel.canStart)
            }
        }
    }

    @ViewBuilder
    private var creatorSections: some View {
        Section {
            Stepper(value: $viewModel.memberCount, in: 2...GroupCeremonyViewModel.maxMembers) {
                Text("\(viewModel.memberCount) members, including you")
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Everyone must be in the same room. Each phone shows its card in turn and scans all the others.")
        }

        Section("Settings for Everyone") {
            Picker("Pad size", selection: $viewModel.selectedPadSizeOption) {
                ForEach(PadSizeOption.allCases.filter { $0.presetBytes != nil }) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Picker("Messages wait on the relay", selection: $viewModel.serverRetention) {
                ForEach(MessageRetention.allCases, id: \.self) { retention in
                    Text(retention.displayName).tag(retention)
                }
            }
            Picker("Disappearing messages", selection: $viewModel.disappearingMessages) {
                ForEach(DisappearingMessages.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Picker("Color", selection: $viewModel.selectedColor) {
                ForEach(ConversationColor.allCases) { color in
                    Label(color.name, systemImage: "circle.fill")
                        .tint(color.color)
                        .tag(color)
                }
            }
            TextField("Relay", text: $viewModel.selectedRelayURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }

        Section {
            Toggle("Family group", isOn: $viewModel.isFamilyConversation)
            Toggle("Protect the codes with six words", isOn: $viewModel.usesPassphrase)
            if viewModel.usesPassphrase {
                GroupWordsGrid(words: viewModel.passphraseWords)
                Button("Draw Other Words") { viewModel.regeneratePassphrase() }
            }
        } header: {
            Text("Protection")
        } footer: {
            Text(viewModel.usesPassphrase
                 ? "Read these words aloud once. The others type them, so a camera filming the codes learns nothing."
                 : "Without words, make sure no camera can film the screens.")
        }
    }

    @ViewBuilder
    private var joinerSections: some View {
        Section {
            TextField("Six words, only if the creator reads some", text: $viewModel.typedPassphrase, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Six Words")
        } footer: {
            Text("The creator chooses every setting. Your place in the group is set by the order of the turns.")
        }
    }
}

private struct GroupWordsGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xs) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: Spacing.xs) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(word)
                        .font(.body.weight(.semibold).monospaced())
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entropy

private struct GroupEntropyView: View {
    let progress: Double
    let accentColor: Color
    let onPoint: (CGPoint) -> Void
    @State private var points: [CGPoint] = []

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.xs) {
                Text("Draw Random Patterns")
                    .font(.title2.bold())
                Text("Your movements mix extra randomness into your pad.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    if points.isEmpty {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            points.append(value.location)
                            if points.count > 400 { points.removeFirst(100) }
                            onPoint(CGPoint(
                                x: value.location.x / max(geometry.size.width, 1),
                                y: value.location.y / max(geometry.size.height, 1)
                            ))
                        }
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            ProgressView(value: progress)
                .tint(accentColor)
        }
        .padding(Spacing.lg)
    }
}

// MARK: - Showing

private struct GroupShowCardView: View {
    let viewModel: GroupCeremonyViewModel
    let accentColor: Color

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                VStack(spacing: Spacing.xs) {
                    Text("Member \(Int(viewModel.me ?? 0) + 1) of \(viewModel.totalMembers)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                    Text("Everyone Scans This Card")
                        .font(.title2.bold())
                    Text("Hold your phone so the others can scan it, one or several at once.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white)
                    if let image = viewModel.currentQRImage {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360)

                Button {
                    viewModel.finishShowing()
                } label: {
                    Text("Everyone Has Scanned")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.md)
                        .background(accentColor, in: Capsule())
                }
            }
            .padding(Spacing.lg)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Scanning

private struct GroupScanCardView: View {
    let viewModel: GroupCeremonyViewModel

    private var title: String {
        guard let place = viewModel.nextPlaceToScan else { return "Scan a Card" }
        return place == 0 ? "Scan the Creator's Card" : "Scan Member \(Int(place) + 1)'s Card"
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Text(title)
                .font(.title3.bold())
                .padding(.top, Spacing.md)

            QRScannerView(
                onFrameScanned: { viewModel.processScannedFrame($0) },
                onError: { _ in }
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Spacing.lg)

            ProgressView(value: viewModel.scanProgress)
                .padding(.horizontal, Spacing.lg)

            if let message = viewModel.scanMessage {
                notice(message)
            } else if viewModel.passphraseRequired {
                notice("These codes are protected by six words. Cancel and type the words the creator read aloud.")
            } else if viewModel.passphraseLooksWrong {
                notice("Nothing can be read. Check the six words.")
            }

            Spacer()

            Button("Back") { viewModel.stopScanning() }
                .padding(.bottom, Spacing.lg)
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .padding(.horizontal, Spacing.lg)
    }
}

// MARK: - Turns

private struct GroupTurnView: View {
    let viewModel: GroupCeremonyViewModel
    let accentColor: Color

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                VStack(spacing: Spacing.xs) {
                    Text("\(viewModel.knownCount) of \(viewModel.totalMembers) Cards")
                        .font(.title2.bold())
                    Text("One phone shows its card at a time. Every other phone scans it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    ForEach(0..<viewModel.totalMembers, id: \.self) { index in
                        memberRow(UInt8(index))
                        if index < viewModel.totalMembers - 1 { Divider() }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                VStack(spacing: Spacing.sm) {
                    if viewModel.isReadyToFinish {
                        Button {
                            viewModel.finish()
                        } label: {
                            Text("Create the Group")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.md)
                                .background(accentColor, in: Capsule())
                        }
                        Text("Once every phone has all the cards.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let place = viewModel.nextPlaceToScan {
                        Button {
                            viewModel.startScanning()
                        } label: {
                            Text("Scan Member \(Int(place) + 1)'s Card")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.md)
                                .background(accentColor, in: Capsule())
                        }
                    }
                    if viewModel.canTakeTurn {
                        Button {
                            viewModel.takeTurn()
                        } label: {
                            Text("It's My Turn to Show")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.md)
                        }
                        Text("Only when nobody else is showing a card.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.me != nil {
                        Button("Show My Card Again") { viewModel.showCardAgain() }
                            .font(.subheadline)
                    }
                }
            }
            .padding(Spacing.lg)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func memberRow(_ index: UInt8) -> some View {
        HStack {
            Text("\(Int(index) + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)
            if index == viewModel.me {
                Text(viewModel.trimmedName + " (you)")
            } else if let card = viewModel.cards[index] {
                Text(card.name)
            } else {
                Text("Waiting").foregroundStyle(.secondary)
            }
            Spacer()
            if index == viewModel.me || viewModel.cards[index] != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(Spacing.sm)
    }
}

// MARK: - End

private struct GroupCompletedView: View {
    let group: GroupConversation
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "person.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(group.accentColor.color)
            Text("Group Ready")
                .font(.title.bold())
            Text("With \(group.displayName).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(group.accentColor.color, in: Capsule())
            }
        }
        .padding(Spacing.lg)
    }
}

private struct GroupFailedView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Close", action: onClose)
                .font(.headline)
        }
        .padding(Spacing.lg)
    }
}
