//
//  SendMessageUseCaseTests.swift
//  AshTests
//
//  Unit tests for SendMessageUseCase, especially sequence calculation
//  for Initiator vs Responder roles.
//
//  The key issue being tested:
//  - Initiator: sequence = consumed_front (offset where key STARTS)
//  - Responder: sequence = total_size - consumed_back - message_size (offset where key STARTS)
//
//  Previously, Responder was incorrectly using next_send_offset BEFORE consume,
//  which returned total_size (e.g., 32768 for a 32KB pad), causing out-of-bounds errors.
//
//  Every message consumes AUTH_OVERHEAD (64) bytes of auth key followed by
//  plaintext-length bytes of encryption key, so message_size = 64 + plaintext length.
//

import Testing
import Foundation
@testable import Ash

// MARK: - SendMessageUseCase Sequence Tests

struct SendMessageUseCaseTests {

    // MARK: - Test Helpers

    private func createConversation(
        role: ConversationRole,
        totalBytes: UInt64 = 32768,  // 32KB like Tiny pad
        sendOffset: UInt64 = 0,
        peerConsumed: UInt64 = 0
    ) -> Conversation {
        let remaining = totalBytes - sendOffset - peerConsumed
        return Conversation(
            id: "test-conversation",
            createdAt: Date(),
            lastActivity: Date(),
            remainingBytes: remaining,
            totalBytes: totalBytes,
            unreadCount: 0,
            mnemonicChecksum: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"],
            customName: nil,
            role: role,
            sendOffset: sendOffset,
            peerConsumed: peerConsumed,
            relayURL: "https://relay.test",
            authToken: "test-auth-token",
            burnToken: "test-burn-token"
        )
    }

    // MARK: - Initiator Sequence Tests

    @Test func initiator_firstMessage_sequenceIsZero() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        // Create 32KB pad with sequential bytes for verification
        let padBytes: [UInt8] = (0..<32768).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .initiator)

        // Send a 3-byte message
        let result = try await useCase.execute(
            content: .text("Hi!"),
            in: conversation
        )

        // Initiator's first message should have sequence = 0
        #expect(result.sequence == 0, "Initiator first message sequence should be 0")

        // Verify encryption key was from bytes [64, 65, 66] (after the 64-byte auth key)
        #expect(cryptoService.lastEncryptKey == [64, 65, 66])
    }

    @Test func initiator_secondMessage_sequenceIncrements() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padBytes: [UInt8] = (0..<32768).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        // First message: 64 + 3 bytes
        var conversation = createConversation(role: .initiator)
        let result1 = try await useCase.execute(content: .text("Hi!"), in: conversation)
        #expect(result1.sequence == 0)

        // Second message: 64 + 5 bytes (simulate state update)
        conversation = result1.updatedConversation
        let result2 = try await useCase.execute(content: .text("Hello"), in: conversation)
        #expect(result2.sequence == 67, "Second message should start at offset 67")

        // Verify encryption key was from bytes [131, 132, 133, 134, 135] (67 + 64 auth)
        #expect(cryptoService.lastEncryptKey == [131, 132, 133, 134, 135])
    }

    @Test func initiator_multipleMessages_sequenceTracksCorrectly() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padBytes: [UInt8] = (0..<32768).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        var conversation = createConversation(role: .initiator)

        // First message: "Hi!" (3 bytes) - sequence 0
        let result1 = try await useCase.execute(content: .text("Hi!"), in: conversation)
        #expect(result1.sequence == 0)
        conversation = result1.updatedConversation

        // Second message: "Hey" (64 + 3 bytes) - sequence 67
        let result2 = try await useCase.execute(content: .text("Hey"), in: conversation)
        #expect(result2.sequence == 67)
        conversation = result2.updatedConversation

        // Third message: "Test" (64 + 4 bytes) - sequence 134
        let result3 = try await useCase.execute(content: .text("Test"), in: conversation)
        #expect(result3.sequence == 134)
    }

    // MARK: - Responder Sequence Tests (The bug fix)

    @Test func responder_firstMessage_sequenceIsNotTotal() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        // 32KB pad
        let padBytes: [UInt8] = (0..<32768).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder)

        // Send a 3-byte message
        let result = try await useCase.execute(
            content: .text("Hi!"),
            in: conversation
        )

        // BUG FIX: Responder's first message should have sequence = 32768 - (64 + 3) = 32701
        // NOT 32768 (which would be out of bounds!)
        #expect(result.sequence == 32701, "Responder first message sequence should be 32701, not 32768")

        // Verify encryption key was from bytes [32765, 32766, 32767] (last 3 bytes)
        #expect(cryptoService.lastEncryptKey == [253, 254, 255])  // 32765 % 256, 32766 % 256, 32767 % 256
    }

    @Test func responder_sequenceIsWithinPadBounds() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padSize: UInt64 = 32768
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder, totalBytes: padSize)
        let messageSize = 3

        let result = try await useCase.execute(
            content: .text("Hi!"),
            in: conversation
        )

        // Sequence should be valid: sequence + messageSize <= padSize
        #expect(result.sequence + UInt64(messageSize) <= padSize,
               "Sequence \(result.sequence) + \(messageSize) should be <= \(padSize)")

        // Sequence should NOT be equal to padSize (the old bug)
        #expect(result.sequence != padSize,
               "Sequence should not equal padSize (\(padSize))")
    }

    @Test func responder_secondMessage_sequenceDecrements() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padBytes: [UInt8] = (0..<32768).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        // First message: 64 + 3 bytes
        var conversation = createConversation(role: .responder)
        let result1 = try await useCase.execute(content: .text("Hi!"), in: conversation)
        #expect(result1.sequence == 32701)  // 32768 - 0 - 67

        // Second message: 64 + 5 bytes
        conversation = result1.updatedConversation
        let result2 = try await useCase.execute(content: .text("Hello"), in: conversation)
        #expect(result2.sequence == 32632)  // 32768 - 67 - 69 = 32632

        // Third message: 64 + 4 bytes
        conversation = result2.updatedConversation
        let result3 = try await useCase.execute(content: .text("Test"), in: conversation)
        #expect(result3.sequence == 32564)  // 32768 - 136 - 68 = 32564
    }

    // MARK: - Cross-party Communication Tests

    @Test func initiatorAndResponder_sequencesDontOverlap() async throws {
        // This test simulates a full conversation where Alice (initiator)
        // and Bob (responder) send messages, verifying their sequences
        // don't overlap and point to distinct pad regions.

        let padSize: UInt64 = 1000
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }

        // Alice (Initiator) setup
        let alicePadManager = MockPadManager()
        let aliceConvRepo = MockConversationRepository()
        let aliceCrypto = MockCryptoService()
        try await alicePadManager.storePad(bytes: padBytes, for: "test-conversation")
        let aliceUseCase = SendMessageUseCase(
            padManager: alicePadManager,
            conversationRepository: aliceConvRepo,
            cryptoService: aliceCrypto
        )

        // Bob (Responder) setup
        let bobPadManager = MockPadManager()
        let bobConvRepo = MockConversationRepository()
        let bobCrypto = MockCryptoService()
        try await bobPadManager.storePad(bytes: padBytes, for: "test-conversation")
        let bobUseCase = SendMessageUseCase(
            padManager: bobPadManager,
            conversationRepository: bobConvRepo,
            cryptoService: bobCrypto
        )

        var aliceConversation = createConversation(role: .initiator, totalBytes: padSize)
        var bobConversation = createConversation(role: .responder, totalBytes: padSize)

        // Alice sends (64 + 3 bytes) - should use sequence 0
        let aliceResult1 = try await aliceUseCase.execute(content: .text("Hi!"), in: aliceConversation)
        aliceConversation = aliceResult1.updatedConversation

        // Bob sends (64 + 3 bytes) - should use sequence 933 (1000 - 0 - 67)
        let bobResult1 = try await bobUseCase.execute(content: .text("Hi!"), in: bobConversation)
        bobConversation = bobResult1.updatedConversation

        // Alice sends again (64 + 5 bytes) - should use sequence 67
        let aliceResult2 = try await aliceUseCase.execute(content: .text("Hello"), in: aliceConversation)

        // Bob sends again (64 + 5 bytes) - should use sequence 864 (1000 - 67 - 69)
        let bobResult2 = try await bobUseCase.execute(content: .text("Hello"), in: bobConversation)

        // Verify sequences
        #expect(aliceResult1.sequence == 0)
        #expect(aliceResult2.sequence == 67)
        #expect(bobResult1.sequence == 933)  // 1000 - 0 - 67
        #expect(bobResult2.sequence == 864)  // 1000 - 67 - 69

        // Verify no overlap: Alice uses [0-135], Bob uses [864-999]
        let aliceRanges = [(0, 66), (67, 135)]  // First msg [0-66], second [67-135]
        let bobRanges = [(933, 999), (864, 932)]  // First msg [933-999], second [864-932]

        for aliceRange in aliceRanges {
            for bobRange in bobRanges {
                let overlap = max(aliceRange.0, bobRange.0) <= min(aliceRange.1, bobRange.1)
                #expect(!overlap, "Alice range \(aliceRange) and Bob range \(bobRange) should not overlap")
            }
        }
    }

    @Test func responder_canDecryptWithCorrectOffset() async throws {
        // This test verifies that when Bob (responder) sends a message with
        // sequence X, Alice (initiator) can decrypt it by reading bytes starting
        // at offset X.

        let padSize: UInt64 = 100
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }

        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder, totalBytes: padSize)

        // Bob sends "Hi!" (64 + 3 bytes)
        let result = try await useCase.execute(content: .text("Hi!"), in: conversation)
        let sequence = result.sequence

        // Sequence should be 33 (100 - 0 - 67)
        #expect(sequence == 33)

        // Alice would read the 64-byte auth key at offset 33 and the
        // encryption key right after it, at offset 97
        // Let's verify the key bytes are correct
        let decryptionKey = try await padManager.getBytesForDecryption(
            offset: sequence + UInt64(AUTH_OVERHEAD),
            length: 3,
            for: "test-conversation"
        )

        // Bytes at [97, 98, 99] should be [97, 98, 99] (since padBytes[i] = i % 256)
        #expect(decryptionKey == [97, 98, 99])

        // The encryption key used should match
        #expect(cryptoService.lastEncryptKey == [97, 98, 99])
    }

    // MARK: - Edge Cases

    @Test func responder_singleByte_message() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padSize: UInt64 = 100
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder, totalBytes: padSize)

        // Single byte message
        let result = try await useCase.execute(content: .text("X"), in: conversation)

        // Sequence should be 35 (100 - 0 - 65)
        #expect(result.sequence == 35)
        #expect(cryptoService.lastEncryptKey == [99])
    }

    @Test func responder_largeMessage() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padSize: UInt64 = 1000
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder, totalBytes: padSize)

        // 100-byte message
        let longText = String(repeating: "X", count: 100)
        let result = try await useCase.execute(content: .text(longText), in: conversation)

        // Sequence should be 836 (1000 - 0 - 164)
        #expect(result.sequence == 836)
    }

    @Test func responder_afterPeerConsumption() async throws {
        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        let padSize: UInt64 = 1000
        let padBytes: [UInt8] = (0..<Int(padSize)).map { UInt8($0 % 256) }
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        // Simulate peer (initiator) having consumed 200 bytes
        try await padManager.updatePeerConsumption(peerRole: .initiator, consumed: 200, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        // Responder with sendOffset=0 but aware of peer consumption
        let conversation = createConversation(
            role: .responder,
            totalBytes: padSize,
            sendOffset: 0,
            peerConsumed: 200
        )

        // Send 3-byte message
        let result = try await useCase.execute(content: .text("Hi!"), in: conversation)

        // Sequence should be 933 (1000 - 0 - 67)
        // The peer consumption affects remaining bytes but not our sequence calculation
        #expect(result.sequence == 933)
    }

    // MARK: - Regression Test: The Original Bug

    @Test func responder_sequenceNotEqualToPadSize_regression() async throws {
        // This is the exact regression test for the bug:
        // Before fix: Responder's first message had sequence = 32768 (pad size)
        // After fix: Responder's first message has sequence = 32701 (pad size - (64 + msg length))

        let padManager = MockPadManager()
        let conversationRepo = MockConversationRepository()
        let cryptoService = MockCryptoService()

        // Use exact Tiny pad size
        let padSize: UInt64 = 32768
        let padBytes: [UInt8] = Array(repeating: 0xAB, count: Int(padSize))
        try await padManager.storePad(bytes: padBytes, for: "test-conversation")

        let useCase = SendMessageUseCase(
            padManager: padManager,
            conversationRepository: conversationRepo,
            cryptoService: cryptoService
        )

        let conversation = createConversation(role: .responder, totalBytes: padSize)

        // Send 3-byte message (like "Hi!")
        let result = try await useCase.execute(content: .text("abc"), in: conversation)

        // THE FIX: sequence should be 32701, NOT 32768
        #expect(result.sequence != padSize,
               "REGRESSION: Sequence should NOT equal pad size! Got \(result.sequence)")
        #expect(result.sequence == padSize - 67,
               "Sequence should be padSize - (64 + messageLength) = \(padSize - 67), got \(result.sequence)")

        // Verify it's a valid offset: sequence + length <= padSize
        let messageLength: UInt64 = 3
        #expect(result.sequence + messageLength <= padSize,
               "Offset \(result.sequence) + length \(messageLength) should be <= \(padSize)")
    }
}
