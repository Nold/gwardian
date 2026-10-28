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
    /// Lifetime of the next message, chosen by its author; starts at the
    /// group's setting
    var lifetime: DisappearingMessages

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

    /// Wire types (core MessageType)
    private static let textType: UInt8 = 0x01
    private static let deleteType: UInt8 = 0x03
    private static let expiringTextType: UInt8 = 0x04

    // MARK: - Initialization

    init(group: GroupConversation, dependencies: Dependencies) {
        self.group = group
        self.dependencies = dependencies
        self.lifetime = group.disappearingMessages
        self.relay = dependencies.createRelayService(for: group.relayURL)
        self.sseService = SSEService(baseURLString: group.relayURL)
    }

    // MARK: - Computed Properties

    var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !text.isEmpty else { return false }
        return sessions.canSend(length: text.utf8.count + 4, in: group)
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

        let seconds = lifetime.seconds
        let frame: [UInt8]
        do {
            // The author decides how long the message lives: plain text never
            // disappears on its own
            var msgType = Self.textType
            var payload = Array(text.utf8)
            if let seconds {
                msgType = Self.expiringTextType
                payload = try encodeExpiringText(seconds: UInt32(seconds), text: text)
            }
            // Saved before returning: nothing is sent with unrecorded keys
            frame = try sessions.encrypt(payload, msgType: msgType, in: group)
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
            offset: try? groupFrameOffset(frame: frame),
            text: text,
            date: Date(),
            status: .sending,
            expiresAt: seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
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
                guard message.sender != group.me else { continue }
                switch message.msgType {
                case Self.deleteType:
                    // Only the author's own message can be deleted this way
                    if let offset = try? decodeDeleteRequest(payload: message.plaintext) {
                        dependencies.groupMessageStore.remove(sender: message.sender, offset: offset, from: group.id)
                        shown = true
                    }
                case Self.textType, Self.expiringTextType:
                    var text = String(decoding: message.plaintext, as: UTF8.self)
                    var expiresAt: Date?
                    if message.msgType == Self.expiringTextType {
                        guard let expiring = try? decodeExpiringText(payload: message.plaintext) else { continue }
                        text = expiring.text
                        expiresAt = now.addingTimeInterval(TimeInterval(expiring.seconds))
                    }
                    dependencies.groupMessageStore.append(
                        GroupChatMessage(
                            id: UUID(),
                            sender: message.sender,
                            offset: message.offset,
                            text: text,
                            date: relayMessage.receivedAt,
                            status: .received,
                            expiresAt: expiresAt
                        ),
                        to: group.id
                    )
                    shown = true
                default:
                    break
                }
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

    // MARK: - Deletion

    /// Remove the message from this phone only.
    func deleteForMe(_ message: GroupChatMessage) {
        dependencies.groupMessageStore.remove(message.id, from: group.id)
        sessions.clearPending(message.id, in: group.id)
        refreshMessages()
    }

    /// Only the author can ask the other phones to delete a message. This is
    /// a request: a modified app or an earlier screenshot can keep it.
    func canDeleteForEveryone(_ message: GroupChatMessage) -> Bool {
        message.isOutgoing && message.status == .sent && message.offset != nil
    }

    func deleteForEveryone(_ message: GroupChatMessage) async {
        guard canDeleteForEveryone(message), let offset = message.offset else { return }
        let request: [UInt8]
        do {
            request = try sessions.encrypt(encodeDeleteRequest(offset: offset), msgType: Self.deleteType, in: group)
        } catch {
            Log.error(.crypto, "[\(logId)] Delete request not sent: \(error)")
            dependencies.hapticService.error()
            return
        }
        deleteForMe(message)
        remainingFraction = sessions.remainingFraction(in: group)
        // Sent like a message, without a bubble; a failure is felt as a haptic
        let id = UUID()
        sessions.setPending(request, for: id, in: group.id)
        await submit(id)
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
        // Any message can carry its own lifetime, so the timer always runs
        guard expiryTimer == nil else { return }
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
