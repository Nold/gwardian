//
//  GroupSessionsTests.swift
//  AshTests
//
//  The single shared copy of a group's pads.
//

import Testing
import Foundation
@testable import Ash

@MainActor
struct GroupSessionsTests {

    private func pad(_ seed: UInt8) -> [UInt8] {
        (0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }
    }

    private func group(me: UInt8) -> GroupConversation {
        GroupConversation(
            id: "g",
            authToken: "a",
            burnToken: "b",
            relayURL: "https://relay.example",
            me: me,
            members: [GroupMember(index: 0, name: "Léa"), GroupMember(index: 1, name: "Sam")],
            createdAt: Date(),
            messageRetention: .oneDay,
            disappearingMessages: .off,
            accentColor: .teal,
            isFamilyConversation: false
        )
    }

    /// Sessions for member `me` of a two-member group, pads already stored.
    private func sessions(me: UInt8, keychain: MockKeychainService = MockKeychainService()) throws -> GroupSessions {
        let repository = KeychainGroupRepository(keychain: keychain)
        let pads = PadGroup(me: me, ownPad: pad(me), level: .maximum)
        try pads.addMember(member: 1 - me, padBytes: pad(1 - me), level: .maximum)
        try repository.savePads(pads.exportState(), for: "g")
        return GroupSessions(repository: repository)
    }

    private func text(_ outcome: GroupReadOutcome) -> String? {
        guard case .message(let message) = outcome else { return nil }
        return String(decoding: message.plaintext, as: UTF8.self)
    }

    @Test func messagesAreReadOnceThenAsDuplicates() throws {
        let sender = try sessions(me: 0)
        let reader = try sessions(me: 1)
        let first = try sender.encrypt("one", msgType: 1, in: group(me: 0))
        let second = try sender.encrypt("two", msgType: 1, in: group(me: 0))

        #expect(try reader.read([first, second], in: group(me: 1)).map(text) == ["one", "two"])
        let again = try reader.read([first], in: group(me: 1))
        guard case .duplicate = again.first else {
            Issue.record("expected a duplicate")
            return
        }
    }

    @Test func nothingIsReadWhenThePadsCannotBeSaved() throws {
        let frame = try sessions(me: 0).encrypt("x", msgType: 1, in: group(me: 0))
        let keychain = MockKeychainService()
        let reader = try sessions(me: 1, keychain: keychain)
        try reader.open(group(me: 1))
        keychain.storeError = .encodingFailed

        #expect(throws: GroupSessionError.self) {
            _ = try reader.read([frame], in: group(me: 1))
        }
    }

    @Test func aDeletedGroupIsNeverWrittenBack() throws {
        let keychain = MockKeychainService()
        let sessions = try sessions(me: 0, keychain: keychain)
        try sessions.open(group(me: 0))
        try sessions.delete("g")

        #expect(throws: GroupSessionError.self) {
            _ = try sessions.encrypt("x", msgType: 1, in: group(me: 0))
        }
        #expect(keychain.storedKeys.isEmpty)
    }
}
