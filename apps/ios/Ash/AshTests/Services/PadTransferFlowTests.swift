//
//  PadTransferFlowTests.swift
//  AshTests
//
//  Pad transfer flows wired together without Bluetooth, through the same
//  packet framing the BLE sessions use.
//

import Testing
import Foundation
@testable import Ash

struct PadTransferFlowTests {

    /// Packetize and reassemble a message as it would cross the BLE link.
    private func overBLE(_ message: [UInt8], maxPacket: Int = 182) throws -> [UInt8] {
        var outbox = BLEPacketOutbox()
        try outbox.enqueue(message, maxPacket: maxPacket)
        let reassembler = BlePacketReassembler()
        var result: [UInt8]?
        while let packet = outbox.next {
            result = try reassembler.push(packet: packet)
            outbox.markSent()
        }
        return try #require(result)
    }

    private func sentMessage(_ events: [PadTransferEvent]) throws -> [UInt8] {
        for case .send(let message) in events {
            return message
        }
        throw PadTransferFlowError.unexpectedMessage
    }

    private func words(_ events: [PadTransferEvent]) -> [String]? {
        for case .compareWords(let words) in events {
            return words
        }
        return nil
    }

    @Test func fullTransfer_deliversPadAtEnhancedLevel() throws {
        let pad = try SecureRandom.bytes(64 * 1024)
        let receiver = try PadReceiverFlow()
        let sender = try PadSenderFlow(offer: overBLE(receiver.offer))

        let nonce = try sentMessage(receiver.handle(overBLE(sender.response)))
        let senderEvents = try sender.handle(overBLE(nonce))
        let receiverEvents = try receiver.handle(overBLE(sentMessage(senderEvents)))

        let senderWords = try #require(words(senderEvents))
        #expect(senderWords.count == 6)
        #expect(words(receiverEvents) == senderWords)

        // The sender confirms first: the receiver keeps the pad sealed until it confirms too
        let sealed = try sender.confirmWordsAndSeal(pad: pad, level: .enhanced)
        #expect(try receiver.handle(overBLE(sealed)).isEmpty)
        #expect(receiver.hasSealedPad)
        #expect(try receiver.confirmWords() == [.receivedPad(pad: pad, level: .enhanced)])
        #expect(!receiver.hasSealedPad)
    }

    @Test func receiverConfirmingFirst_opensWhenPadArrives() throws {
        let receiver = try PadReceiverFlow()
        let sender = try PadSenderFlow(offer: receiver.offer)
        let nonce = try sentMessage(receiver.handle(sender.response))
        let reveal = try sentMessage(sender.handle(nonce))
        _ = try receiver.handle(reveal)

        #expect(try receiver.confirmWords().isEmpty)
        let sealed = try sender.confirmWordsAndSeal(pad: [1, 2, 3], level: .enhanced)
        #expect(try receiver.handle(sealed) == [.receivedPad(pad: [1, 2, 3], level: .enhanced)])
    }

    @Test func confirmingBeforeWords_isRejected() throws {
        let receiver = try PadReceiverFlow()
        #expect(throws: PadTransferFlowError.wordsNotShownYet) {
            try receiver.confirmWords()
        }
        let sender = try PadSenderFlow(offer: receiver.offer)
        #expect(throws: PadTransferFlowError.wordsNotShownYet) {
            try sender.confirmWordsAndSeal(pad: [1], level: .enhanced)
        }
    }

    @Test func maximumLevel_isRefusedOverBluetooth() throws {
        let receiver = try PadReceiverFlow()
        let sender = try PadSenderFlow(offer: receiver.offer)
        _ = try sender.handle(sentMessage(receiver.handle(sender.response)))
        #expect(throws: (any Error).self) {
            try sender.confirmWordsAndSeal(pad: [1], level: .maximum)
        }
    }

    @Test func sessionCode_isReadableAndValidated() throws {
        let code = try BLESessionCode.generate()
        #expect(code.count == 7)
        #expect(BLESessionCode.isValid(code))
        #expect(!BLESessionCode.isValid("GW-ABCI"))
        #expect(!BLESessionCode.isValid("XX-ABCD"))
        #expect(!BLESessionCode.isValid(nil))
    }

    @Test func outbox_numbersMessagesAndSplitsPackets() throws {
        var outbox = BLEPacketOutbox()
        try outbox.enqueue([UInt8](repeating: 7, count: 100), maxPacket: 20)
        let first = try #require(outbox.next)
        #expect(first.count <= 20)
        #expect(first[1] == 0)
        #expect(outbox.count > 5)
        outbox.clear()
        try outbox.enqueue([1], maxPacket: 20)
        #expect(outbox.next?[1] == 1)
    }
}
