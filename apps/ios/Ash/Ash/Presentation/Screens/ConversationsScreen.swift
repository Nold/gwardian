//
//  ConversationsScreen.swift
//  Ash
//
//  Conversations list - Modern redesign
//

import SwiftUI

struct ConversationsScreen: View {
    @Bindable var viewModel: AppViewModel
    @State private var conversationToBurn: Conversation?
    @State private var conversationForInfo: Conversation?
    @State private var groupForInfo: GroupConversation?

    var body: some View {
        Group {
            if viewModel.conversations.isEmpty && viewModel.groups.isEmpty {
                emptyState
            } else {
                conversationsList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.showSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                }
                .tint(Color.ashAccent)
            }

            ToolbarItem(placement: .topBarTrailing) {
                newMenu {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .tint(Color.ashAccent)
            }
        }
        .sheet(item: $groupForInfo) { group in
            GroupInfoScreen(group: group) {
                groupForInfo = nil
                Task { await viewModel.deleteGroup(group) }
            }
        }
        .sheet(item: $conversationToBurn) { conversation in
            BurnConfirmationView(
                burnType: .conversation(name: conversation.displayName),
                onConfirm: {
                    let conversationToDelete = conversation
                    conversationToBurn = nil
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await viewModel.burnConversation(conversationToDelete)
                    }
                },
                onCancel: {
                    conversationToBurn = nil
                }
            )
        }
        .sheet(item: $conversationForInfo) { conversation in
            ConversationInfoScreen(
                conversation: conversation,
                onBurn: {
                    conversationForInfo = nil
                    // Small delay to allow sheet dismissal
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        conversationToBurn = conversation
                    }
                }
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            // ASH Logo
            ZStack {
                Circle()
                    .fill(Color.ashAccent.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image("ash_logo")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Color.ashAccent)
            }

            VStack(spacing: 8) {
                Text("No Conversations")
                    .font(.title2.bold())

                Text("Start a secure conversation by performing\na ceremony with another device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.startNewConversation()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Conversation")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.ashAccent, in: Capsule())
            }
            .padding(.top, 8)

            newMenu {
                Text("New Group")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Color.ashAccent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Two-person conversation, or a group to create or join
    private func newMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button {
                viewModel.startNewConversation()
            } label: {
                SwiftUI.Label("New Conversation", systemImage: "person.2")
            }
            Button {
                viewModel.startNewGroup(role: .creator)
            } label: {
                SwiftUI.Label("New Group", systemImage: "person.3")
            }
            Button {
                viewModel.startNewGroup(role: .joiner)
            } label: {
                SwiftUI.Label("Join a Group", systemImage: "qrcode.viewfinder")
            }
        } label: {
            label()
        }
    }

    // MARK: - List

    private var conversationsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.groups) { group in
                    GroupCard(
                        group: group,
                        onTap: { viewModel.selectGroup(group) },
                        onShowInfo: { groupForInfo = group }
                    )
                }
                ForEach(viewModel.conversations) { conversation in
                    ConversationCard(
                        conversation: conversation,
                        onTap: { viewModel.selectConversation(conversation) },
                        onShowInfo: { conversationForInfo = conversation },
                        onBurn: { conversationToBurn = conversation }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await viewModel.loadConversations()
        }
    }
}

// MARK: - Conversation Card

private struct ConversationCard: View {
    let conversation: Conversation
    let onTap: () -> Void
    let onShowInfo: () -> Void
    let onBurn: () -> Void

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.lastActivity, relativeTo: Date())
    }

    private var padStatusColor: Color {
        if conversation.isExhausted { return .red }
        let remaining = 1 - conversation.usagePercentage
        if remaining < 0.1 { return .red }
        if remaining < 0.3 { return .orange }
        return conversation.accentColor.color
    }

    private var remainingPercentage: Int {
        Int((1 - conversation.usagePercentage) * 100)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Top row: name and time
                HStack {
                    // Color indicator
                    Circle()
                        .fill(conversation.accentColor.color)
                        .frame(width: 10, height: 10)

                    Text(conversation.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if conversation.isExhausted {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    Text(timeAgo)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Burn button
                    Button {
                        onBurn()
                    } label: {
                        Image(systemName: "flame")
                            .font(.body)
                            .foregroundStyle(Color.ashDanger.opacity(0.7))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                // Middle row: mnemonic words
                HStack {
                    Text(conversation.mnemonicChecksum.prefix(3).joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // Pad usage section
                VStack(spacing: 6) {
                    // Header
                    HStack {
                        Text("Pad Usage")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }

                    // Usage bar with labels
                    HStack(spacing: 8) {
                        // Visual bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                // Background
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(.systemFill))

                                // My usage (from left)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(conversation.accentColor.color)
                                    .frame(width: geo.size.width * min(1, conversation.myUsagePercentage))

                                // Peer usage (from right)
                                HStack {
                                    Spacer()
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.5))
                                        .frame(width: geo.size.width * min(1, conversation.peerUsagePercentage))
                                }
                            }
                        }
                        .frame(height: 6)

                        // Remaining indicator
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10))
                            Text("\(remainingPercentage)%")
                                .font(.caption.weight(.medium).monospacedDigit())
                        }
                        .foregroundStyle(padStatusColor)
                        .frame(width: 50, alignment: .trailing)
                    }

                    // Labels row
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(conversation.accentColor.color)
                                .frame(width: 6, height: 6)
                            Text("You \(Int(conversation.myUsagePercentage * 100))%")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(conversation.formattedRemaining)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        HStack(spacing: 4) {
                            Text("Them \(Int(conversation.peerUsagePercentage * 100))%")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onShowInfo()
            } label: {
                Label("Conversation Info", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive) {
                onBurn()
            } label: {
                Label("Burn Conversation", systemImage: "flame.fill")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onBurn()
            } label: {
                Label("Burn", systemImage: "flame.fill")
            }
            .tint(Color.ashDanger)
        }
    }
}

// MARK: - Group Card

private struct GroupCard: View {
    let group: GroupConversation
    let onTap: () -> Void
    let onShowInfo: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .font(.subheadline)
                    .foregroundStyle(group.accentColor.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(group.members.count) members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onShowInfo) {
                Label("Group Info", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Screenshot Previews

#Preview("Conversations - With Data") {
    NavigationStack {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Conversation.screenshotSamples) { conversation in
                    ConversationCard(
                        conversation: conversation,
                        onTap: {},
                        onShowInfo: {},
                        onBurn: {}
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                }
                .tint(Color.ashAccent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .tint(Color.ashAccent)
            }
        }
    }
}

#Preview("Conversations - Empty") {
    NavigationStack {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.ashAccent.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image("ash_logo")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Color.ashAccent)
            }

            VStack(spacing: 8) {
                Text("No Conversations")
                    .font(.title2.bold())

                Text("Start a secure conversation by performing\na ceremony with another device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button { } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New Conversation")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.ashAccent, in: Capsule())
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.body)
                }
                .tint(Color.ashAccent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .tint(Color.ashAccent)
            }
        }
    }
}

#Preview("Conversation Card") {
    ConversationCard(
        conversation: Conversation.screenshotSamples[0],
        onTap: {},
        onShowInfo: {},
        onBurn: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
