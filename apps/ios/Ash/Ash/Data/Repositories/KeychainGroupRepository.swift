//
//  KeychainGroupRepository.swift
//  Ash
//
//  Group conversations and their pads, sealed in the vaulted Keychain like
//  two-person conversations.
//

import Foundation

protocol GroupRepository: Sendable {
    func getAll() async throws -> [GroupConversation]
    func save(_ group: GroupConversation) async throws
    /// Persist after every send and receive (`PadGroup.exportState()`).
    /// Synchronous, like the Keychain: pad state and `PadGroup` are not
    /// Sendable, so they stay on the caller's actor.
    func savePads(_ states: [MemberPadState], for groupId: String) throws
    func loadPads(for group: GroupConversation) throws -> PadGroup
    func delete(_ groupId: String) throws
}

enum GroupRepositoryError: Error {
    case padsMissing
}

final class KeychainGroupRepository: GroupRepository, @unchecked Sendable {
    private let keychain: KeychainServiceProtocol
    private let groupPrefix = "group."
    private let padsPrefix = "grouppads."
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    func getAll() async throws -> [GroupConversation] {
        try keychain.allKeys(withPrefix: groupPrefix)
            .compactMap { try keychain.retrieve(for: $0) }
            .compactMap { try? decoder.decode(GroupConversation.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ group: GroupConversation) async throws {
        try keychain.store(data: encoder.encode(group), for: groupPrefix + group.id)
    }

    func savePads(_ states: [MemberPadState], for groupId: String) throws {
        try keychain.store(data: encoder.encode(states.map(StoredMemberPad.init)), for: padsPrefix + groupId)
    }

    func loadPads(for group: GroupConversation) throws -> PadGroup {
        guard let data = try keychain.retrieve(for: padsPrefix + group.id) else {
            throw GroupRepositoryError.padsMissing
        }
        let states = try decoder.decode([StoredMemberPad].self, from: data).map(\.state)
        return try PadGroup.restore(me: group.me, states: states)
    }

    func delete(_ groupId: String) throws {
        try keychain.delete(for: groupPrefix + groupId)
        try keychain.delete(for: padsPrefix + groupId)
    }
}

/// Codable copy of the generated `MemberPadState`.
private struct StoredMemberPad: Codable {
    let member: UInt8
    let pad: Data
    let used: [[UInt64]]
    let checksums: [UInt32]
    let level: String

    init(_ state: MemberPadState) {
        member = state.member
        pad = Data(state.pad)
        used = state.used.map { [$0.start, $0.end] }
        checksums = state.checksums
        switch state.level {
        case .standard: level = "standard"
        case .enhanced: level = "enhanced"
        case .maximum: level = "maximum"
        }
    }

    var state: MemberPadState {
        MemberPadState(
            member: member,
            pad: [UInt8](pad),
            used: used.compactMap { $0.count == 2 ? UsedRange(start: $0[0], end: $0[1]) : nil },
            checksums: checksums,
            level: level == "maximum" ? .maximum : level == "enhanced" ? .enhanced : .standard
        )
    }
}
