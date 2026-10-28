//
//  GroupMessagingViewModel.swift
//  Ash
//
//  Presentation Layer - Messaging in a group (core/src/group.rs): each member
//  sends with their own pad; the relay keeps a message until every other
//  member acknowledged it.
//

import CryptoKit
import SwiftUI

@MainActor
@Observable
final class GroupMessagingViewModel {

    private let dependencies: Dependencies
    let group: GroupConversation

    // MARK: - State

    private(set) var messages: [GroupChatMessage] = []
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// Share of this phone's pad still available for sending
    private(set) var remainingFraction: Double = 1
    private(set) var isConnected = false
    var draft = ""

    // MARK: - Private

    private var pads: PadGroup?
    private var relay: RelayServiceProtocol?
    private var sseService: SSEService?
    private var sseTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var expiryTimer: Timer?
    private var isPolling = false
    private var hasReregistered = false
    /// Encrypted frames not yet accepted by the relay, to retry as they are:
    /// resending the same ciphertext reuses no key
    private var pendingFrames: [UUID: [UInt8]] = [:]

    private var logId: String { String(group.id.prefix(8)) }

    /// Wire type of a text message (core MessageType::Text)
    private static let textType: UInt8 = 0x01

    // MARK: - Initialization

    init(group: GroupConversation, dependencies: Dependencies) {
        self.group = group
        self.dependencies = dependencies
        self.relay = dependencies.createRelayService(for: group.relayURL)
        self.sseService = SSEService(baseURLString: group.relayURL)
    }

    // MARK: - Computed Properties

    var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !text.isEmpty, let pads else { return false }
        return pads.canSend(plaintextLength: UInt32(text.utf8.count))
    }

    var isPadExhausted: Bool {
        guard isLoaded, let pads else { return false }
        return !pads.canSend(plaintextLength: 1)
    }

    func senderName(_ message: GroupChatMessage) -> String {
        group.name(of: message.sender)
    }

    // MARK: - Lifecycle

    func onAppear() async {
        if pads == nil {
            do {
                pads = try await dependencies.groupRepository.loadPads(for: group)
                updateRemaining()
                isLoaded = true
            } catch {
                Log.error(.storage, "[\(logId)] Failed to load group pads: \(error)")
                loadError = "The pads of this group cannot be read."
                return
            }
        }
        refreshMessages()
        startExpiryTimer()
        connect()
        await poll()
    }

    func onDisappear() {
        sseTask?.cancel()
        sseTask = nil
        sseService?.disconnect()
        pollTimer?.invalidate()
        pollTimer = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        isConnected = false
    }

    // MARK: - Sending

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let pads else { return }

        let frame: [UInt8]
        do {
            frame = try pads.encrypt(msgType: Self.textType, plaintext: Array(text.utf8))
        } catch {
            Log.error(.crypto, "[\(logId)] Group encryption failed: \(error)")
            dependencies.hapticService.error()
            return
        }
        // The keys are burned: persist before anything else can fail
        await savePads()
        draft = ""
        dependencies.hapticService.light()

        let message = GroupChatMessage(
            id: UUID(),
            sender: group.me,
            text: text,
            date: Date(),
            status: .sending,
            expiresAt: nil
        )
        dependencies.groupMessageStore.append(message, to: group.id)
        refreshMessages()
        pendingFrames[message.id] = frame
        await submit(message.id)
    }

    /// Send a failed message again, with the same ciphertext.
    func retry(_ message: GroupChatMessage) async {
        guard message.status == .failed, pendingFrames[message.id] != nil else { return }
        setStatus(.sending, for: message.id)
        await submit(message.id)
    }

    private func submit(_ id: UUID) async {
        guard let frame = pendingFrames[id], let relay else {
            setStatus(.failed, for: id)
            return
        }
        do {
            _ = try await relay.submitMessage(
                conversationId: group.id,
                authToken: group.authToken,
                ciphertext: Data(frame),
                sequence: nil,
                ttlSeconds: group.messageRetention.seconds,
                extendedTTL: false,
                persistent: false,
                sender: group.me
            )
            pendingFrames[id] = nil
            setStatus(.sent, for: id)
        } catch RelayError.conversationNotFound where !hasReregistered {
            hasReregistered = true
            if await reregister() {
                await submit(id)
            } else {
                setStatus(.failed, for: id)
            }
        } catch {
            Log.warning(.relay, "[\(logId)] Group submit failed: \(error)")
            dependencies.hapticService.error()
            setStatus(.failed, for: id)
        }
    }

    // MARK: - Receiving

    /// Fetch what the other members sent, decrypt it, then acknowledge it so
    /// the relay can delete it once everyone has it.
    func poll() async {
        guard let relay, let pads, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let response: PollResponse
        do {
            response = try await relay.pollMessages(
                conversationId: group.id,
                authToken: group.authToken,
                cursor: nil,
                member: group.me
            )
        } catch RelayError.conversationNotFound where !hasReregistered {
            hasReregistered = true
            _ = await reregister()
            return
        } catch {
            Log.debug(.poll, "[\(logId)] Group poll failed: \(error)")
            return
        }
        guard !response.messages.isEmpty else { return }

        var processed: [UUID] = []
        var decrypted = false
        for relayMessage in response.messages {
            do {
                let message = try pads.decrypt(frame: [UInt8](relayMessage.ciphertext))
                decrypted = true
                processed.append(relayMessage.id)
                guard message.sender != group.me, message.msgType == Self.textType else { continue }
                let text = String(decoding: message.plaintext, as: UTF8.self)
                let now = Date()
                dependencies.groupMessageStore.append(
                    GroupChatMessage(
                        id: UUID(),
                        sender: message.sender,
                        text: text,
                        date: relayMessage.receivedAt,
                        status: .received,
                        expiresAt: group.disappearingMessages.seconds.map { now.addingTimeInterval(TimeInterval($0)) }
                    ),
                    to: group.id
                )
            } catch AshError.PadRangeAlreadyUsed {
                // Already read: acknowledge again so the relay can drop it
                processed.append(relayMessage.id)
            } catch {
                // Unreadable (tampered or damaged): acknowledged so it does
                // not come back on every poll
                Log.warning(.crypto, "[\(logId)] Group message rejected: \(error)")
                processed.append(relayMessage.id)
            }
        }

        if decrypted {
            await savePads()
            dependencies.hapticService.light()
            refreshMessages()
        }
        do {
            _ = try await relay.ackMessages(
                conversationId: group.id,
                authToken: group.authToken,
                blobIds: processed,
                member: group.me
            )
        } catch {
            Log.debug(.relay, "[\(logId)] Group ack failed: \(error)")
        }
    }

    // MARK: - Connection

    /// The stream only wakes this phone; messages are fetched by polling with
    /// this member's index. Polling also runs on a timer in case the stream drops.
    private func connect() {
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
        }
        guard sseTask == nil, let sseService else { return }
        let id = group.id
        let token = group.authToken
        sseTask = Task { [weak self] in
            for await event in sseService.connect(conversationId: id, authToken: token) {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: SSEEvent) async {
        switch event {
        case .connected:
            isConnected = true
        case .disconnected, .error:
            isConnected = false
        case .message:
            await poll()
        case .delivered, .burned, .ping:
            break
        }
    }

    private func reregister() async -> Bool {
        guard let relay else { return false }
        do {
            try await relay.registerConversation(
                conversationId: group.id,
                authTokenHash: Self.sha256Hex(group.authToken),
                burnTokenHash: Self.sha256Hex(group.burnToken),
                ttlSeconds: group.messageRetention.seconds,
                members: UInt8(group.members.count)
            )
            return true
        } catch {
            Log.warning(.relay, "[\(logId)] Group re-registration failed: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private func savePads() async {
        guard let pads else { return }
        do {
            try await dependencies.groupRepository.savePads(pads.exportState(), for: group.id)
        } catch {
            Log.error(.storage, "[\(logId)] Failed to save group pads: \(error)")
        }
        updateRemaining()
    }

    private func updateRemaining() {
        guard let own = pads?.exportState().first(where: { $0.member == group.me }), !own.pad.isEmpty else { return }
        let used = own.used.reduce(UInt64(0)) { $0 + ($1.end - $1.start) }
        remainingFraction = max(0, 1 - Double(used) / Double(own.pad.count))
    }

    private func setStatus(_ status: GroupChatMessage.Status, for id: UUID) {
        dependencies.groupMessageStore.update(id, in: group.id) { $0.status = status }
        refreshMessages()
    }

    private func refreshMessages() {
        messages = dependencies.groupMessageStore.messages(for: group.id)
    }

    private func startExpiryTimer() {
        guard expiryTimer == nil, group.disappearingMessages.seconds != nil else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.dependencies.groupMessageStore.removeExpired(in: self.group.id) {
                    self.refreshMessages()
                }
            }
        }
    }

    private static func sha256Hex(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
