//
//  GroupMessagingScreen.swift
//  Ash
//
//  Messages of a group, with the author's name above each message
//

import SwiftUI

struct GroupMessagingScreen: View {
    @State private var viewModel: GroupMessagingViewModel
    let onDelete: () -> Void

    @State private var isShowingInfo = false
    @FocusState private var isInputFocused: Bool

    init(group: GroupConversation, dependencies: Dependencies, onDelete: @escaping () -> Void) {
        _viewModel = State(initialValue: GroupMessagingViewModel(group: group, dependencies: dependencies))
        self.onDelete = onDelete
    }

    private var accent: Color { viewModel.group.accentColor.color }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.loadError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                messageList
                if viewModel.isPadExhausted {
                    Text("Your pad is used up. Create a new group to keep writing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(Spacing.sm)
                } else {
                    inputBar
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(viewModel.group.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .tint(accent)
            }
        }
        .sheet(isPresented: $isShowingInfo) {
            GroupInfoScreen(group: viewModel.group) {
                isShowingInfo = false
                onDelete()
            }
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.xs) {
                    header
                    ForEach(viewModel.messages) { message in
                        GroupBubble(
                            message: message,
                            senderName: viewModel.senderName(message),
                            accent: accent,
                            onRetry: { Task { await viewModel.retry(message) } }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .refreshable { await viewModel.poll() }
            .onChange(of: viewModel.messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text("\(Int(viewModel.remainingFraction * 100)) % of your pad left")
            }
            if let seconds = viewModel.group.disappearingMessages.seconds {
                Label("Messages disappear \(viewModel.group.disappearingMessages.displayName.lowercased()) after they arrive", systemImage: "timer")
                    .accessibilityLabel("Messages disappear after \(seconds) seconds")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, Spacing.sm)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Spacing.xs) {
            TextField("Message", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            Button {
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .tint(accent)
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
        }
        .padding(Spacing.sm)
        .background(.bar)
    }
}

private struct GroupBubble: View {
    let message: GroupChatMessage
    let senderName: String
    let accent: Color
    let onRetry: () -> Void

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .background(
                        message.isOutgoing ? accent : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                status
            }
            if !message.isOutgoing { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch message.status {
        case .sending:
            Text("Sending…").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Button("Not sent. Tap to retry.", action: onRetry)
                .font(.caption2)
                .foregroundStyle(Color.ashDanger)
        case .sent, .received:
            Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Navigation destination: takes the dependencies from the environment.
struct GroupMessagingDestination: View {
    let group: GroupConversation
    let onDelete: () -> Void
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        GroupMessagingScreen(group: group, dependencies: dependencies, onDelete: onDelete)
    }
}
