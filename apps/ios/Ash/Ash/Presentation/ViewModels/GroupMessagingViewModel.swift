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

    private var sessions: GroupSessions { dependencies.groupSessions }
    private var relay: RelayServiceProtocol?
    private var sseService: SSEService?
    private var sseTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var expiryTimer: Timer?
    private var isPolling = false
    /// A wake-up arrived during a poll: poll once more when it ends
    private var pollAgain = false
    private var hasReregistered = false

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
        guard isLoaded, !text.isEmpty else { return false }
        return sessions.canSend(length: text.utf8.count, in: group)
    }

    var isPadExhausted: Bool {
        isLoaded && !sessions.canSend(length: 1, in: group)
    }

    func senderName(_ message: GroupChatMessage) -> String {
        group.name(of: message.sender)
    }

    // MARK: - Lifecycle

    func onAppear() async {
        do {
            try sessions.open(group)
            isLoaded = true
            remainingFraction = sessions.remainingFraction(in: group)
        } catch {
            Log.error(.storage, "[\(logId)] Failed to load group pads: \(error)")
            loadError = "The pads of this group cannot be read."
            return
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
        guard canSend else { return }

        let frame: [UInt8]
        do {
            // Saved before returning: nothing is sent with unrecorded keys
            frame = try sessions.encrypt(text, msgType: Self.textType, in: group)
        } catch {
            Log.error(.crypto, "[\(logId)] Group message not sent: \(error)")
            dependencies.hapticService.error()
            return
        }
        draft = ""
        remainingFraction = sessions.remainingFraction(in: group)
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
        sessions.setPending(frame, for: message.id, in: group.id)
        refreshMessages()
        await submit(message.id)
    }

    /// Send a failed message again, with the same ciphertext: no key reuse.
    func retry(_ message: GroupChatMessage) async {
        guard message.status == .failed, sessions.pendingFrame(message.id, in: group.id) != nil else { return }
        setStatus(.sending, for: message.id)
        await submit(message.id)
    }

    private func submit(_ id: UUID) async {
        guard let frame = sessions.pendingFrame(id, in: group.id), let relay else {
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
            sessions.clearPending(id, in: group.id)
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
        guard let relay, isLoaded else { return }
        guard !isPolling else {
            pollAgain = true
            return
        }
        isPolling = true
        defer { isPolling = false }

        repeat {
            pollAgain = false
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
            guard !response.messages.isEmpty else { continue }
            guard let toAck = receive(response.messages) else { return }
            do {
                _ = try await relay.ackMessages(
                    conversationId: group.id,
                    authToken: group.authToken,
                    blobIds: toAck,
                    member: group.me
                )
            } catch {
                Log.debug(.relay, "[\(logId)] Group ack failed: \(error)")
            }
        } while pollAgain
    }

    /// Decrypt, save and show in one stretch with no suspension, so a lock or
    /// a deletion cannot slip in between. Returns the messages to acknowledge,
    /// or nil if the pads could not be saved (nothing is shown or acked then).
    private func receive(_ relayMessages: [RelayMessage]) -> [UUID]? {
        let outcomes: [GroupReadOutcome]
        do {
            outcomes = try sessions.read(relayMessages.map { [UInt8]($0.ciphertext) }, in: group)
        } catch {
            Log.warning(.storage, "[\(logId)] Group messages left on the relay: \(error)")
            return nil
        }
        var toAck: [UUID] = []
        var shown = false
        let now = Date()
        for (relayMessage, outcome) in zip(relayMessages, outcomes) {
            switch outcome {
            case .message(let message):
                toAck.append(relayMessage.id)
                guard message.sender != group.me, message.msgType == Self.textType else { continue }
                dependencies.groupMessageStore.append(
                    GroupChatMessage(
                        id: UUID(),
                        sender: message.sender,
                        text: String(decoding: message.plaintext, as: UTF8.self),
                        date: relayMessage.receivedAt,
                        status: .received,
                        expiresAt: group.disappearingMessages.seconds.map { now.addingTimeInterval(TimeInterval($0)) }
                    ),
                    to: group.id
                )
                shown = true
            case .duplicate, .rejected:
                toAck.append(relayMessage.id)
            case .keep:
                Log.warning(.crypto, "[\(logId)] Group message kept on the relay: pad needs repair")
            }
        }
        if shown {
            dependencies.hapticService.light()
            refreshMessages()
        }
        return toAck
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
