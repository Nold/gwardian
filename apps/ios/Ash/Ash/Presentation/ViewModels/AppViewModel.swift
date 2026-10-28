//
//  AppViewModel.swift
//  Ash
//
//  Presentation Layer - Root application view model
//

import SwiftUI

/// Root view model managing app-wide state
@MainActor
@Observable
final class AppViewModel {
    // MARK: - Dependencies

    private let dependencies: Dependencies

    // MARK: - State

    private(set) var conversations: [Conversation] = []
    private(set) var groups: [GroupConversation] = []
    var selectedGroup: GroupConversation?
    /// Group ceremony in progress, shown as a sheet
    var groupCeremonyViewModel: GroupCeremonyViewModel?
    var selectedConversation: Conversation?
    var isShowingCeremony = false
    var isShowingSettings = false

    // Child view models
    private(set) var ceremonyViewModel: CeremonyViewModel

    // Push notification observer
    private var pushNotificationObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.ceremonyViewModel = CeremonyViewModel(dependencies: dependencies)
        setupPushNotificationHandling()
    }

    // MARK: - Push Notification Handling

    private func setupPushNotificationHandling() {
        pushNotificationObserver = NotificationCenter.default.addObserver(
            forName: .pushNotificationReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            // Check if this notification is for a specific conversation
            if let conversationId = notification.userInfo?["conversation_id"] as? String {
                Task { @MainActor in
                    await self.checkBurnStatusForConversation(id: conversationId)
                }
            }
        }
    }

    /// Check burn status for a conversation and handle if burned
    private func checkBurnStatusForConversation(id conversationId: String) async {
        // Find the conversation
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            return
        }

        // Skip if this is the currently selected conversation (MessagingViewModel handles it)
        if selectedConversation?.id == conversationId {
            return
        }

        // Create relay service to check burn status
        guard let relay = dependencies.createRelayService(for: conversation.relayURL) else {
            return
        }
        do {
            let status = try await relay.checkBurnStatus(
                conversationId: conversationId,
                authToken: conversation.authToken
            )

            if status.burned {
                Log.warning(.push, "Conversation \(conversationId.prefix(8)) was burned by peer")

                // Mark conversation as peer-burned (wipes local data)
                _ = try await dependencies.burnConversationUseCase.markPeerBurned(conversation: conversation)

                // Remove from local state
                withAnimation {
                    conversations.removeAll { $0.id == conversationId }
                }
            }
        } catch {
            // Silently ignore errors - burn check is best effort
            Log.debug(.push, "Failed to check burn status for \(conversationId.prefix(8)): \(error)")
        }
    }

    // MARK: - Actions

    func loadConversations() async {
        do {
            conversations = try await dependencies.conversationRepository.getAll()
        } catch {
            // Handle error - in production, show error state
            conversations = []
        }
        do {
            groups = try await dependencies.groupRepository.getAll()
        } catch {
            groups = []
        }
    }

    func selectConversation(_ conversation: Conversation) {
        dependencies.hapticService.selection()
        selectedConversation = conversation
    }

    func startNewConversation() {
        dependencies.hapticService.medium()
        ceremonyViewModel.reset()
        isShowingCeremony = true
    }

    func selectGroup(_ group: GroupConversation) {
        dependencies.hapticService.selection()
        selectedGroup = group
    }

    func startNewGroup(role: GroupCeremonyViewModel.Role) {
        dependencies.hapticService.medium()
        groupCeremonyViewModel = GroupCeremonyViewModel(dependencies: dependencies, role: role)
    }

    func handleGroupCeremonyCompleted(_ group: GroupConversation) {
        groupCeremonyViewModel = nil
        withAnimation {
            groups.removeAll { $0.id == group.id }
            groups.insert(group, at: 0)
        }
        selectedGroup = group
    }

    /// Delete the group and its pads from this phone.
    func deleteGroup(_ group: GroupConversation) async {
        dependencies.hapticService.heavy()
        if selectedGroup?.id == group.id {
            selectedGroup = nil
        }
        dependencies.groupMessageStore.clear(group.id)
        do {
            try dependencies.groupSessions.delete(group.id)
        } catch {
            Log.error(.storage, "Group deletion failed for \(group.id.prefix(8)): \(error)")
        }
        withAnimation {
            groups.removeAll { $0.id == group.id }
        }
    }

    func showSettings() {
        isShowingSettings = true
    }

    func burnConversation(_ conversation: Conversation) async {
        dependencies.hapticService.heavy()

        do {
            try await dependencies.burnConversationUseCase.execute(conversation: conversation)
            Log.info(.storage, "Burn completed for \(conversation.id.prefix(8))")

            // Conversation was burned - deselect if currently selected
            // This must happen BEFORE removing from list to ensure navigation pops
            if selectedConversation?.id == conversation.id {
                selectedConversation = nil
            }

            // Update UI with animation to prevent List inconsistency crashes
            withAnimation {
                conversations.removeAll { $0.id == conversation.id }
            }
        } catch {
            Log.error(.storage, "Burn failed for \(conversation.id.prefix(8)): \(error)")
            // Even if burn fails, try to clean up UI state
            if selectedConversation?.id == conversation.id {
                selectedConversation = nil
            }
            withAnimation {
                conversations.removeAll { $0.id == conversation.id }
            }
        }
    }

    func renameConversation(_ conversation: Conversation, to newName: String) async {
        dependencies.hapticService.selection()

        do {
            let renamed = conversation.renamed(to: newName.isEmpty ? nil : newName)
            try await dependencies.conversationRepository.save(renamed)
            await loadConversations()

            // Update selected conversation if it was renamed
            if selectedConversation?.id == conversation.id {
                selectedConversation = renamed
            }
        } catch {
            // Handle error
        }
    }

    func updateConversationRelayURL(_ conversation: Conversation, url: String) async {
        dependencies.hapticService.selection()

        do {
            let updated = conversation.withRelayURL(url)
            try await dependencies.conversationRepository.save(updated)
            await loadConversations()

            // Update selected conversation if it was modified
            if selectedConversation?.id == conversation.id {
                selectedConversation = updated
            }
        } catch {
            // Handle error
        }
    }

    func updateConversationColor(_ conversation: Conversation, color: ConversationColor) async {
        dependencies.hapticService.selection()

        do {
            let updated = conversation.withAccentColor(color)
            try await dependencies.conversationRepository.save(updated)
            await loadConversations()

            // Update selected conversation if it was modified
            if selectedConversation?.id == conversation.id {
                selectedConversation = updated
            }
        } catch {
            // Handle error
        }
    }

    func burnAllConversations() async {
        dependencies.hapticService.heavy()

        do {
            try await dependencies.burnConversationUseCase.executeAll()
            conversations = []
            selectedConversation = nil
            for group in groups {
                try? dependencies.groupSessions.delete(group.id)
            }
            dependencies.groupMessageStore.clearAll()
            selectedGroup = nil
            groups = []
        } catch {
            // Handle error
        }
    }

    // MARK: - Ceremony Completion

    func handleCeremonyCompleted(_ conversation: Conversation) async {
        isShowingCeremony = false

        // Add the new conversation with animation to prevent List inconsistency crashes
        withAnimation {
            // Only add if not already present (safety check)
            if !conversations.contains(where: { $0.id == conversation.id }) {
                conversations.insert(conversation, at: 0)
            }
        }

        selectedConversation = conversation
    }
}
