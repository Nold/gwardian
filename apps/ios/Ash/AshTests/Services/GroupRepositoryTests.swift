//
//  GroupRepositoryTests.swift
//  AshTests
//
//  Group cards and group pads stored and restored as after a ceremony.
//

import Testing
import Foundation
@testable import Ash

struct GroupRepositoryTests {

    private func pad(_ seed: UInt8, size: Int = 8192) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }
    }

    /// The view of `me` in a group of `count` members, tokens taken.
    private func formGroup(me: UInt8, count: UInt8) throws -> (PadGroup, AuthTokens) {
        let group = PadGroup(me: me, ownPad: pad(me), level: .maximum)
        for other in (0..<count) where other != me {
            try group.addMember(member: other, padBytes: pad(other), level: .maximum)
        }
        return (group, try group.takeRelayTokens())
    }

    private func sample(id: String, me: UInt8) -> GroupConversation {
        GroupConversation(
            id: id,
            authToken: "auth",
            burnToken: "burn",
            relayURL: "https://relay.example",
            me: me,
            members: [
                GroupMember(index: 0, name: "Léa"),
                GroupMember(index: 1, name: "Sam"),
                GroupMember(index: 2, name: "Noé"),
            ],
            createdAt: Date(),
            messageRetention: .oneDay,
            disappearingMessages: .off,
            accentColor: .teal,
            isFamilyConversation: true
        )
    }

    @Test func memberCardRoundTrip() throws {
        let card = GroupMemberCard(member: 2, members: 4, name: "Noé", pad: pad(2, size: 64))
        let decoded = try decodeMemberCard(bytes: encodeMemberCard(card: card))
        #expect(decoded.member == 2)
        #expect(decoded.members == 4)
        #expect(decoded.name == "Noé")
        #expect(decoded.pad == card.pad)
    }

    @Test func everyMemberDerivesTheSameTokens() throws {
        let tokens = try (UInt8(0)..<3).map { try formGroup(me: $0, count: 3).1 }
        #expect(Set(tokens.map(\.conversationId)).count == 1)
        #expect(Set(tokens.map(\.authToken)).count == 1)
    }

    @Test func padsSurviveStorage() async throws {
        let repository = KeychainGroupRepository(keychain: MockKeychainService())
        let (alice, tokens) = try formGroup(me: 0, count: 3)
        let (sam, _) = try formGroup(me: 1, count: 3)
        let group = sample(id: tokens.conversationId, me: 0)

        let first = try alice.encrypt(msgType: 1, plaintext: Array("one".utf8))
        try await repository.save(group)
        try repository.savePads(alice.exportState(), for: group.id)

        let restored = try repository.loadPads(for: group)
        let second = try restored.encrypt(msgType: 1, plaintext: Array("two".utf8))
        #expect(try sam.decrypt(frame: first).plaintext == Array("one".utf8))
        #expect(try sam.decrypt(frame: second).plaintext == Array("two".utf8))

        let all = try await repository.getAll()
        #expect(all == [group])
        #expect(all.first?.displayName == "Sam and Noé")
    }

    @Test func deleteRemovesPads() async throws {
        let repository = KeychainGroupRepository(keychain: MockKeychainService())
        let (alice, tokens) = try formGroup(me: 0, count: 2)
        let group = sample(id: tokens.conversationId, me: 0)
        try await repository.save(group)
        try repository.savePads(alice.exportState(), for: group.id)

        try repository.delete(group.id)
        #expect(try await repository.getAll().isEmpty)
        #expect(throws: GroupRepositoryError.self) {
            _ = try repository.loadPads(for: group)
        }
    }
}
