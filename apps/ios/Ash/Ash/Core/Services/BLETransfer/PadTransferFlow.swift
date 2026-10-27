//
//  PadTransferFlow.swift
//  Ash
//
//  Transport-independent steps of a pad transfer (docs/ble-transfer.md).
//  The Bluetooth sessions feed received messages in and carry out the
//  resulting events; keeping this logic apart makes it testable without radios.
//

import Foundation
import Security

/// Errors raised by the transfer flows, beyond those of the Rust core.
enum PadTransferFlowError: Error, Equatable, Sendable {
    case randomUnavailable
    case unexpectedMessage
    case wordsNotShownYet
}

/// Bytes from the system's secure random number generator.
enum SecureRandom {
    static func bytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw PadTransferFlowError.randomUnavailable
        }
        return bytes
    }
}

/// Short code advertised as the BLE local name so people pick the right phone.
/// Not a secret: the six words protect the transfer.
enum BLESessionCode {
    static let prefix = "GW-"
    /// Crockford base32: no I, L, O or U, so the code is easy to read aloud.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() throws -> String {
        // 256 is a multiple of 32, so the modulo introduces no bias
        let symbols = try SecureRandom.bytes(4).map { alphabet[Int($0) % alphabet.count] }
        return prefix + String(symbols)
    }

    static func isValid(_ name: String?) -> Bool {
        guard let name, name.hasPrefix(prefix) else { return false }
        let code = name.dropFirst(prefix.count)
        return code.count == 4 && code.allSatisfy { alphabet.contains($0) }
    }
}

/// What a flow asks its transport or its UI to do.
enum PadTransferEvent: Equatable {
    /// Send this protocol message to the other phone.
    case send([UInt8])
    /// Show these words; both people must confirm they match.
    case compareWords([String])
    /// The pad arrived and was authenticated.
    case receivedPad(pad: [UInt8], level: SecurityLevel)
}

/// Packets waiting to go out, one protocol message after another.
struct BLEPacketOutbox {
    private var nextMessageId: UInt8 = 0
    private var packets: [[UInt8]] = []

    var next: [UInt8]? { packets.first }
    var count: Int { packets.count }
    var isEmpty: Bool { packets.isEmpty }

    mutating func enqueue(_ message: [UInt8], maxPacket: Int) throws {
        let size = UInt32(clamping: max(maxPacket, 20))
        packets += try splitIntoBlePackets(message: message, messageId: nextMessageId, maxPacket: size)
        nextMessageId &+= 1
    }

    mutating func markSent() {
        packets.removeFirst()
    }

    mutating func clear() {
        packets.removeAll()
    }
}

/// Receiving side: the phone getting a copy of someone's pad.
final class PadReceiverFlow {
    private enum Step {
        case awaitingResponse
        case awaitingReveal
        case awaitingPad
        case done
    }

    let offer: [UInt8]
    private let transfer: PadTransferReceiver
    private var step = Step.awaitingResponse
    private var wordsConfirmed = false
    private var pendingSealedPad: [UInt8]?

    /// The sealed pad arrived and waits for this person to confirm the words.
    var hasSealedPad: Bool { pendingSealedPad != nil }

    init() throws {
        transfer = try PadTransferReceiver(seed: SecureRandom.bytes(32))
        offer = transfer.offer()
    }

    func handle(_ message: [UInt8]) throws -> [PadTransferEvent] {
        switch step {
        case .awaitingResponse:
            let nonce = try transfer.onResponse(response: message, nonce: SecureRandom.bytes(32))
            step = .awaitingReveal
            return [.send(nonce)]
        case .awaitingReveal:
            let words = try transfer.onReveal(reveal: message)
            step = .awaitingPad
            return [.compareWords(words)]
        case .awaitingPad:
            guard pendingSealedPad == nil else { throw PadTransferFlowError.unexpectedMessage }
            // The sender may confirm first; keep the pad sealed until this person confirms too
            pendingSealedPad = message
            return try openIfReady()
        case .done:
            throw PadTransferFlowError.unexpectedMessage
        }
    }

    /// The person confirmed the words match.
    func confirmWords() throws -> [PadTransferEvent] {
        guard step == .awaitingPad else { throw PadTransferFlowError.wordsNotShownYet }
        wordsConfirmed = true
        return try openIfReady()
    }

    private func openIfReady() throws -> [PadTransferEvent] {
        guard wordsConfirmed, let sealed = pendingSealedPad else { return [] }
        pendingSealedPad = nil
        step = .done
        let received = try transfer.openPad(sealed: sealed)
        return [.receivedPad(pad: received.pad, level: received.level)]
    }
}

/// Sending side: the pad owner handing over a copy.
final class PadSenderFlow {
    private enum Step {
        case awaitingNonce
        case awaitingConfirmation
        case done
    }

    let response: [UInt8]
    private let transfer: PadTransferSender
    private var step = Step.awaitingNonce

    init(offer: [UInt8]) throws {
        transfer = try PadTransferSender(
            offer: offer,
            encapsulationSeed: SecureRandom.bytes(64),
            nonce: SecureRandom.bytes(32)
        )
        response = transfer.response()
    }

    func handle(_ message: [UInt8]) throws -> [PadTransferEvent] {
        guard step == .awaitingNonce else { throw PadTransferFlowError.unexpectedMessage }
        let reveal = try transfer.onNonce(nonce: message)
        step = .awaitingConfirmation
        return [.send(reveal.reveal), .compareWords(reveal.words)]
    }

    /// The person confirmed the words match: returns the sealed pad to send.
    func confirmWordsAndSeal(pad: [UInt8], level: SecurityLevel) throws -> [UInt8] {
        guard step == .awaitingConfirmation else { throw PadTransferFlowError.wordsNotShownYet }
        step = .done
        return try transfer.sealPad(pad: pad, level: level)
    }
}
