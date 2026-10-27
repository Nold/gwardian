//
//  ConversationTests.swift
//  AshTests
//
//  Unit tests for Conversation domain entity including dynamic pad allocation
//

import Testing
import Foundation
@testable import Ash

struct ConversationTests {

    // MARK: - Test Helpers

    private func createConversation(
        role: ConversationRole = .initiator,
        sendOffset: UInt64 = 0,
        peerConsumed: UInt64 = 0,
        totalBytes: UInt64 = 65536,
        mnemonic: [String] = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"],
        relayURL: String = "https://relay.example.com",
        customName: String? = nil
    ) -> Conversation {
        // Calculate remaining bytes safely (avoid UInt64 underflow)
        let consumed = sendOffset + peerConsumed
        let remaining = consumed < totalBytes ? totalBytes - consumed : 0

        return Conversation(
            id: "test-conversation-id",
            createdAt: Date(),
            lastActivity: Date(),
            remainingBytes: remaining,
            totalBytes: totalBytes,
            unreadCount: 0,
            mnemonicChecksum: mnemonic,
            customName: customName,
            role: role,
            sendOffset: sendOffset,
            peerConsumed: peerConsumed,
            relayURL: relayURL,
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )
    }

    // MARK: - Dynamic Pad Allocation Tests

    @Test func dynamicRemainingBytes_bothZero_returnsTotal() {
        let conversation = createConversation(sendOffset: 0, peerConsumed: 0, totalBytes: 65536)

        #expect(conversation.dynamicRemainingBytes == 65536)
    }

    @Test func dynamicRemainingBytes_withSendOffset_subtractsCorrectly() {
        let conversation = createConversation(sendOffset: 1000, peerConsumed: 0, totalBytes: 65536)

        #expect(conversation.dynamicRemainingBytes == 64536)
    }

    @Test func dynamicRemainingBytes_withPeerConsumed_subtractsCorrectly() {
        let conversation = createConversation(sendOffset: 0, peerConsumed: 2000, totalBytes: 65536)

        #expect(conversation.dynamicRemainingBytes == 63536)
    }

    @Test func dynamicRemainingBytes_bothConsuming_subtractsBoth() {
        let conversation = createConversation(sendOffset: 1000, peerConsumed: 2000, totalBytes: 65536)

        #expect(conversation.dynamicRemainingBytes == 62536)
    }

    @Test func dynamicRemainingBytes_overConsumed_returnsZero() {
        // Edge case: should clamp to 0
        let conversation = createConversation(sendOffset: 40000, peerConsumed: 30000, totalBytes: 65536)

        #expect(conversation.dynamicRemainingBytes == 0)
    }

    // MARK: - Usage Percentage Tests

    @Test func myUsagePercentage_calculatesCorrectly() {
        let conversation = createConversation(sendOffset: 16384, peerConsumed: 0, totalBytes: 65536)

        #expect(conversation.myUsagePercentage == 0.25)
    }

    @Test func peerUsagePercentage_calculatesCorrectly() {
        let conversation = createConversation(sendOffset: 0, peerConsumed: 32768, totalBytes: 65536)

        #expect(conversation.peerUsagePercentage == 0.5)
    }

    @Test func usagePercentage_combinesBoth() {
        let conversation = createConversation(sendOffset: 16384, peerConsumed: 16384, totalBytes: 65536)

        #expect(conversation.usagePercentage == 0.5)
    }

    // MARK: - Pad Offset Calculation Tests (Forward/Backward)

    @Test func padOffset_initiator_returnsForwardOffset() {
        let conversation = createConversation(role: .initiator, sendOffset: 100, totalBytes: 65536)

        // Initiator reads forward from sendOffset
        let offset = conversation.padOffset(forMessageLength: 50)

        #expect(offset == 100)
    }

    @Test func padOffset_responder_returnsBackwardOffset() {
        let conversation = createConversation(role: .responder, sendOffset: 100, totalBytes: 65536)

        // Responder reads backward: totalBytes - sendOffset - messageLength
        let offset = conversation.padOffset(forMessageLength: 50)

        // 65536 - 100 - 50 = 65386
        #expect(offset == 65386)
    }

    @Test func padOffset_responderFirstMessage_startsFromEnd() {
        let conversation = createConversation(role: .responder, sendOffset: 0, totalBytes: 65536)

        let offset = conversation.padOffset(forMessageLength: 100)

        // First message from responder: 65536 - 0 - 100 = 65436
        #expect(offset == 65436)
    }

    // MARK: - canSendMessage Tests (Dynamic Collision Detection)

    @Test func canSendMessage_withPlentyRoom_returnsTrue() {
        let conversation = createConversation(sendOffset: 1000, peerConsumed: 1000, totalBytes: 65536)

        #expect(conversation.canSendMessage(ofLength: 100) == true)
    }

    @Test func canSendMessage_wouldCollide_returnsFalse() {
        // sendOffset + length + peerConsumed > totalBytes
        let conversation = createConversation(sendOffset: 30000, peerConsumed: 30000, totalBytes: 65536)

        // 30000 + 10000 + 30000 = 70000 > 65536
        #expect(conversation.canSendMessage(ofLength: 10000) == false)
    }

    @Test func canSendMessage_exactlyFits_returnsTrue() {
        let conversation = createConversation(sendOffset: 30000, peerConsumed: 30000, totalBytes: 65536)

        // 30000 + (64 auth overhead + 5472) + 30000 = 65536 (exactly fits)
        #expect(conversation.canSendMessage(ofLength: 5472) == true)
    }

    @Test func canSendMessage_dynamicAllocation_allowsMoreThanHalf() {
        // If peer hasn't used much, we can use more than half
        let conversation = createConversation(sendOffset: 40000, peerConsumed: 0, totalBytes: 65536)

        // Old half-split would reject this, but dynamic allows it
        #expect(conversation.canSendMessage(ofLength: 10000) == true)
    }

    // MARK: - afterSending Tests

    @Test func afterSending_incrementsSendOffset() {
        let conversation = createConversation(sendOffset: 100, peerConsumed: 0, totalBytes: 65536)

        let updated = conversation.afterSending(bytes: 50)

        #expect(updated.sendOffset == 150)
    }

    @Test func afterSending_updatesRemainingBytes() {
        let conversation = createConversation(sendOffset: 100, peerConsumed: 200, totalBytes: 65536)

        let updated = conversation.afterSending(bytes: 50)

        // New remaining = 65536 - 150 - 200 = 65186
        #expect(updated.remainingBytes == 65186)
    }

    // MARK: - afterReceiving Tests (Peer Consumption Tracking)

    @Test func afterReceiving_initiatorReceivesFromResponder_tracksPeerConsumption() {
        let conversation = createConversation(role: .initiator, sendOffset: 100, peerConsumed: 0, totalBytes: 65536)

        // Responder sends with sequence = totalBytes - responderSendOffset - length
        // First message from responder (10 bytes): sequence = 65536 - 0 - 10 = 65526
        let updated = conversation.afterReceiving(sequence: 65526, length: 10)

        // peerConsumed = totalBytes - sequence = 65536 - 65526 = 10
        #expect(updated.peerConsumed == 10)
    }

    @Test func afterReceiving_responderReceivesFromInitiator_tracksPeerConsumption() {
        let conversation = createConversation(role: .responder, sendOffset: 100, peerConsumed: 0, totalBytes: 65536)

        // Initiator sends with sequence = initiatorSendOffset
        // First message from initiator (10 bytes): sequence = 0
        let updated = conversation.afterReceiving(sequence: 0, length: 10)

        // peerConsumed = sequence + length = 0 + 10 = 10
        #expect(updated.peerConsumed == 10)
    }

    @Test func afterReceiving_multipleMessages_tracksMaxConsumption() {
        var conversation = createConversation(role: .responder, sendOffset: 0, peerConsumed: 0, totalBytes: 65536)

        // First message: sequence 0, length 10 -> peerConsumed = 10
        conversation = conversation.afterReceiving(sequence: 0, length: 10)
        #expect(conversation.peerConsumed == 10)

        // Second message: sequence 10, length 20 -> peerConsumed = 30
        conversation = conversation.afterReceiving(sequence: 10, length: 20)
        #expect(conversation.peerConsumed == 30)
    }

    @Test func afterReceiving_outOfOrderMessages_takesMax() {
        var conversation = createConversation(role: .responder, sendOffset: 0, peerConsumed: 0, totalBytes: 65536)

        // Second message arrives first: sequence 10, length 10 -> peerConsumed = 20
        conversation = conversation.afterReceiving(sequence: 10, length: 10)
        #expect(conversation.peerConsumed == 20)

        // First message arrives late: sequence 0, length 10 -> peerConsumed should stay 20 (max)
        conversation = conversation.afterReceiving(sequence: 0, length: 10)
        #expect(conversation.peerConsumed == 20) // Should NOT decrease
    }

    // MARK: - Display Properties Tests

    @Test func displayName_withCustomName_usesCustomName() {
        let conversation = createConversation(customName: "Alice")

        #expect(conversation.displayName == "Alice")
    }

    @Test func displayName_withoutCustomName_usesFirstThreeWords() {
        let conversation = createConversation(mnemonic: ["alpha", "beta", "gamma", "delta"], customName: nil)

        #expect(conversation.displayName == "alpha beta gamma")
    }

    @Test func isExhausted_whenZeroRemaining_returnsTrue() {
        let conversation = createConversation(sendOffset: 32768, peerConsumed: 32768, totalBytes: 65536)

        #expect(conversation.isExhausted == true)
    }

    @Test func isExhausted_whenBytesRemaining_returnsFalse() {
        let conversation = createConversation(sendOffset: 1000, peerConsumed: 1000, totalBytes: 65536)

        #expect(conversation.isExhausted == false)
    }

    // MARK: - Factory Tests

    @Test func fromCeremony_initiator_setsCorrectRole() {
        let padBytes = [UInt8](repeating: 0xAB, count: 65536)
        let mnemonic = ["word1", "word2", "word3", "word4", "word5", "word6"]

        let conversation = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: mnemonic,
            role: .initiator,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )

        #expect(conversation.role == .initiator)
        #expect(conversation.sendOffset == 0)
        #expect(conversation.peerConsumed == 0)
        #expect(conversation.remainingBytes == 65536)
        #expect(conversation.totalBytes == 65536)
    }

    @Test func fromCeremony_responder_setsCorrectRole() {
        let padBytes = [UInt8](repeating: 0xCD, count: 65536)
        let mnemonic = ["word1", "word2", "word3", "word4", "word5", "word6"]

        let conversation = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: mnemonic,
            role: .responder,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )

        #expect(conversation.role == .responder)
    }

    @Test func fromCeremony_sameBytes_sameId() {
        let padBytes = [UInt8](repeating: 0x42, count: 65536)
        let mnemonic = ["word1", "word2", "word3", "word4", "word5", "word6"]

        let initiator = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: mnemonic,
            role: .initiator,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )

        let responder = Conversation.fromCeremony(
            padBytes: padBytes,
            mnemonic: mnemonic,
            role: .responder,
            relayURL: "https://relay.test",
            authToken: "test-auth-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567",
            burnToken: "test-burn-token-0123456789abcdef0123456789abcdef0123456789abcdef01234567"
        )

        // Both parties should derive the same conversation ID
        #expect(initiator.id == responder.id)
    }

    // MARK: - Codable Tests

    @Test func codable_encodesAndDecodes_withNewFields() throws {
        let original = createConversation(
            role: .responder,
            sendOffset: 1000,
            peerConsumed: 500,
            totalBytes: 65536
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Conversation.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.role == .responder)
        #expect(decoded.sendOffset == 1000)
        #expect(decoded.peerConsumed == 500)
        #expect(decoded.totalBytes == 65536)
    }

    @Test func codable_backwardsCompatibility_defaultsRole() throws {
        // Simulate old data without role field
        let json = """
        {
            "id": "test-id",
            "createdAt": 0,
            "lastActivity": 0,
            "remainingBytes": 1000,
            "totalBytes": 2000,
            "unreadCount": 0,
            "mnemonicChecksum": ["a", "b", "c"],
            "relayURL": "https://relay.test",
            "useExtendedTTL": true,
            "secretMode": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Conversation.self, from: json)

        // Should default to initiator for backwards compatibility
        #expect(decoded.role == .initiator)
        #expect(decoded.sendOffset == 0)
        #expect(decoded.peerConsumed == 0)
    }
}
