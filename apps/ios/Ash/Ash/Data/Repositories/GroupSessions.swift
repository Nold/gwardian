//
//  GroupSessions.swift
//  Ash
//
//  The single in-memory copy of each group's pads. Every screen goes through
//  it, so two copies can never send from the same offset or overwrite each
//  other's saved state. Main actor only: every pad operation and its save run
//  without suspension in between.
//

import Foundation

enum GroupSessionError: Error {
    case deleted
    case saveFailed
}

/// Result of reading one message from the relay
enum GroupReadOutcome {
    case message(GroupMessage)
    /// Already read: acknowledge so the relay can drop it
    case duplicate
    /// Never readable (tampered or not for this group): acknowledge
    case rejected
    /// May become readable once the pad is repaired: leave on the relay
    case keep
}

@MainActor
final class GroupSessions {
    private let repository: GroupRepository
    private var pads: [String: PadGroup] = [:]
    /// Ciphertexts not yet accepted by the relay, by group and message
    private var pending: [String: [UUID: [UInt8]]] = [:]
    private var deleted: Set<String> = []

    init(repository: GroupRepository) {
        self.repository = repository
    }

    // MARK: - Pads

    private func pads(for group: GroupConversation) throws -> PadGroup {
        if deleted.contains(group.id) { throw GroupSessionError.deleted }
        if let cached = pads[group.id] { return cached }
        let loaded = try repository.loadPads(for: group)
        pads[group.id] = loaded
        return loaded
    }

    /// Load the pads now, to report a damaged group on opening.
    func open(_ group: GroupConversation) throws {
        _ = try pads(for: group)
    }

    func canSend(length: Int, in group: GroupConversation) -> Bool {
        (try? pads(for: group).canSend(plaintextLength: UInt32(length))) ?? false
    }

    /// Share of this phone's pad still available for sending
    func remainingFraction(in group: GroupConversation) -> Double {
        guard let own = try? pads(for: group).exportState().first(where: { $0.member == group.me }),
              !own.pad.isEmpty else { return 0 }
        let used = own.used.reduce(UInt64(0)) { $0 + ($1.end - $1.start) }
        return max(0, 1 - Double(used) / Double(own.pad.count))
    }

    private func save(_ group: GroupConversation, _ pads: PadGroup) throws {
        if deleted.contains(group.id) { throw GroupSessionError.deleted }
        do {
            try repository.savePads(pads.exportState(), for: group.id)
        } catch {
            throw GroupSessionError.saveFailed
        }
    }

    // MARK: - Messages

    /// Encrypt and save before returning: a frame is never sent unless its
    /// keys are recorded as used. If saving fails the keys stay burned in
    /// memory, which is safe, and nothing is sent.
    func encrypt(_ payload: [UInt8], msgType: UInt8, in group: GroupConversation) throws -> [UInt8] {
        let pads = try pads(for: group)
        let frame = try pads.encrypt(msgType: msgType, plaintext: payload)
        try save(group, pads)
        return frame
    }

    /// Read frames, then save once. If saving fails nothing is returned, so
    /// nothing is shown or acknowledged and the relay keeps the messages.
    func read(_ frames: [[UInt8]], in group: GroupConversation) throws -> [GroupReadOutcome] {
        let pads = try pads(for: group)
        var outcomes: [GroupReadOutcome] = []
        var burned = false
        for frame in frames {
            do {
                outcomes.append(.message(try pads.decrypt(frame: frame)))
                burned = true
            } catch AshError.PadRangeAlreadyUsed {
                outcomes.append(.duplicate)
            } catch AshError.PadCorrupted, AshError.UnknownMember {
                outcomes.append(.keep)
            } catch {
                outcomes.append(.rejected)
            }
        }
        if burned { try save(group, pads) }
        return outcomes
    }

    // MARK: - Pending Frames

    func setPending(_ frame: [UInt8], for id: UUID, in groupId: String) {
        pending[groupId, default: [:]][id] = frame
    }

    func pendingFrame(_ id: UUID, in groupId: String) -> [UInt8]? {
        pending[groupId]?[id]
    }

    func clearPending(_ id: UUID, in groupId: String) {
        pending[groupId]?[id] = nil
    }

    // MARK: - Lifecycle

    /// Forget the group and erase its pads. Later saves from work still in
    /// flight are refused, so the pads are not written back.
    func delete(_ groupId: String) throws {
        deleted.insert(groupId)
        pads[groupId] = nil
        pending[groupId] = nil
        try repository.delete(groupId)
    }

    /// Drop every pad from memory when the app locks.
    func lock() {
        pads = [:]
        pending = [:]
    }
}
