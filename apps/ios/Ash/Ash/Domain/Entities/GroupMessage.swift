//
//  GroupMessage.swift
//  Ash
//
//  A decrypted group message, kept in memory only
//

import Foundation

struct GroupChatMessage: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case sending
        case sent
        case failed
        case received
    }

    let id: UUID
    /// Member index of the author
    let sender: UInt8
    /// Where the keys started in the author's pad: identifies the message in
    /// a delete request
    let offset: UInt64?
    let text: String
    let date: Date
    var status: Status
    /// Set for disappearing messages
    var expiresAt: Date?

    var isOutgoing: Bool { status != .received }
}

/// Decrypted group messages for this app session. Nothing is written to
/// disk; everything is gone when the app quits or the group is deleted.
@MainActor
final class GroupMessageStore {
    private var messagesByGroup: [String: [GroupChatMessage]] = [:]

    func messages(for groupId: String) -> [GroupChatMessage] {
        messagesByGroup[groupId] ?? []
    }

    func append(_ message: GroupChatMessage, to groupId: String) {
        messagesByGroup[groupId, default: []].append(message)
    }

    func update(_ id: UUID, in groupId: String, _ change: (inout GroupChatMessage) -> Void) {
        guard let index = messagesByGroup[groupId]?.firstIndex(where: { $0.id == id }) else { return }
        change(&messagesByGroup[groupId]![index])
    }

    /// Drop disappearing messages whose time is up; returns their ids.
    @discardableResult
    func removeExpired(in groupId: String, now: Date = Date()) -> [UUID] {
        let expired = (messagesByGroup[groupId] ?? []).filter { ($0.expiresAt ?? .distantFuture) <= now }
        guard !expired.isEmpty else { return [] }
        messagesByGroup[groupId]?.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
        return expired.map(\.id)
    }

    func remove(_ id: UUID, from groupId: String) {
        messagesByGroup[groupId]?.removeAll { $0.id == id }
    }

    /// A delete request from `sender`: only that member's own message goes.
    func remove(sender: UInt8, offset: UInt64, from groupId: String) {
        messagesByGroup[groupId]?.removeAll { $0.sender == sender && $0.offset == offset }
    }

    func clear(_ groupId: String) {
        messagesByGroup[groupId] = nil
    }

    func clearAll() {
        messagesByGroup = [:]
    }
}
