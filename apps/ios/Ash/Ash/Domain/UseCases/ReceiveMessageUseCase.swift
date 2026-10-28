//
//  ReceiveMessageUseCase.swift
//  Ash
//

import Foundation

/// What an incoming frame carried
enum ReceivedContent: Sendable {
    case message(Message)
    /// The peer asks to delete its own message with this sequence
    case deleteRequest(sequence: UInt64)
    /// Consumed, nothing to show (malformed control content)
    case ignored
}

private enum DecodedContent {
    case message(MessageContent, lifetime: TimeInterval?)
    case delete(UInt64)
    case ignored
}

protocol ReceiveMessageUseCaseProtocol: Sendable {
    func execute(
        ciphertext: Data,
        sequence: UInt64?,
        blobId: UUID,
        in conversation: Conversation
    ) async throws -> (received: ReceivedContent, updatedConversation: Conversation)
}

enum ReceiveMessageError: Error, Sendable {
    case insufficientPad
    case decryptionFailed
    case conversationExhausted
    case invalidCiphertext
    case missingSequence
    case authenticationFailed
}

final class ReceiveMessageUseCase: ReceiveMessageUseCaseProtocol, Sendable {
    private let padManager: PadManagerProtocol
    private let conversationRepository: ConversationRepository
    private let cryptoService: CryptoServiceProtocol

    init(
        padManager: PadManagerProtocol,
        conversationRepository: ConversationRepository,
        cryptoService: CryptoServiceProtocol
    ) {
        self.padManager = padManager
        self.conversationRepository = conversationRepository
        self.cryptoService = cryptoService
    }

    func execute(
        ciphertext: Data,
        sequence: UInt64?,
        blobId: UUID,
        in conversation: Conversation
    ) async throws -> (received: ReceivedContent, updatedConversation: Conversation) {
        let frameBytes = Array(ciphertext)

        // Frame format: [version: 1][type: 1][length: 2][ciphertext: N][tag: 32] = N + 36 bytes overhead
        let frameOverhead = 36  // 4 header + 32 tag
        guard frameBytes.count > frameOverhead else {
            Log.warning(.crypto, "Frame too short: \(frameBytes.count) bytes")
            throw ReceiveMessageError.invalidCiphertext
        }

        let plaintextLength = frameBytes.count - frameOverhead
        let totalPadConsumption = cryptoService.calculatePadConsumption(plaintextLength: plaintextLength)
        Log.debug(.crypto, "Decrypting message (\(frameBytes.count) bytes frame, \(plaintextLength) bytes plaintext, \(totalPadConsumption) bytes pad)")

        // Sequence is required to know which pad offset the sender used
        guard let offset = sequence else {
            Log.warning(.crypto, "Missing sequence!")
            throw ReceiveMessageError.missingSequence
        }

        // Validate offset is within pad bounds
        guard offset + UInt64(totalPadConsumption) <= conversation.totalBytes else {
            Log.warning(.crypto, "Invalid pad offset")
            throw ReceiveMessageError.insufficientPad
        }

        // Get pad bytes for decryption: 64 auth + plaintext_length encryption
        let keyBytes = try await padManager.getBytesForDecryption(
            offset: offset,
            length: UInt64(totalPadConsumption),
            for: conversation.id
        )

        // Split key material: first 64 bytes for auth, rest for encryption
        let authKey = Array(keyBytes.prefix(AUTH_OVERHEAD))
        let encryptionKey = Array(keyBytes.dropFirst(AUTH_OVERHEAD))
        Log.verbose(.crypto, "Key material split: \(authKey.count) auth + \(encryptionKey.count) encryption bytes")

        // Decrypt and verify the message
        let decryptResult: AuthenticatedDecryptResult
        do {
            decryptResult = try cryptoService.decryptAuthenticated(
                encodedFrame: frameBytes,
                authKey: authKey,
                encryptionKey: encryptionKey
            )
            Log.verbose(.crypto, "Authenticated decryption complete")
        } catch CryptoError.authenticationFailed {
            Log.error(.crypto, "Authentication failed - message may have been tampered!")
            throw ReceiveMessageError.authenticationFailed
        } catch {
            Log.error(.crypto, "Decryption failed: \(error)")
            throw ReceiveMessageError.decryptionFailed
        }

        // Decode plaintext based on message type from frame, before any state
        // is committed, so nothing can fail after it. The author chooses each
        // text's lifetime; plain text does not disappear. Locations keep the
        // conversation's setting. Malformed control content is consumed and
        // ignored: it is authenticated, so only a broken peer sends it.
        let decoded: DecodedContent
        switch decryptResult.messageType {
        case .delete:
            decoded = (try? decodeDeleteRequest(payload: decryptResult.plaintext)).map(DecodedContent.delete) ?? .ignored
        case .expiringText:
            if let expiring = try? decodeExpiringText(payload: decryptResult.plaintext) {
                decoded = .message(.text(expiring.text), lifetime: TimeInterval(expiring.seconds))
            } else {
                decoded = .ignored
            }
        case .text:
            decoded = .message(.text(String(decoding: decryptResult.plaintext, as: UTF8.self)), lifetime: nil)
        case .location:
            decoded = .message(decodeLocation(decryptResult.plaintext), lifetime: conversation.disappearingMessages.seconds)
        }

        // Calculate peer's consumption and update Rust Pad
        let peerRole: Role = conversation.role == .initiator ? .responder : .initiator
        let peerConsumed = calculatePeerConsumed(
            sequence: offset,
            length: UInt64(totalPadConsumption),
            totalBytes: conversation.totalBytes,
            myRole: conversation.role
        )

        try await padManager.updatePeerConsumption(
            peerRole: peerRole,
            consumed: peerConsumed,
            for: conversation.id
        )

        // Update conversation state with total pad consumption
        let updatedConversation = conversation.afterReceiving(
            sequence: offset,
            length: UInt64(totalPadConsumption)
        )
        try await conversationRepository.save(updatedConversation)
        Log.debug(.crypto, "Conversation state updated")

        switch decoded {
        case .delete(let target):
            Log.debug(.crypto, "Content type: delete request")
            return (.deleteRequest(sequence: target), updatedConversation)
        case .ignored:
            Log.warning(.crypto, "Malformed message content ignored")
            return (.ignored, updatedConversation)
        case .message(let content, let lifetime):
            // Create the incoming message with the sequence for deduplication
            var message = Message.incoming(
                content: content,
                sequence: offset,
                disappearingSeconds: lifetime,
                blobId: blobId,
                authTag: decryptResult.authTag
            )
            message.padLength = UInt64(totalPadConsumption)
            return (.message(message), updatedConversation)
        }
    }

    /// Location messages are prefixed with "LOC:" followed by "lat,lon"
    private func decodeLocation(_ plaintext: [UInt8]) -> MessageContent {
        let text = String(decoding: plaintext, as: UTF8.self)
        // Parse location: "LOC:lat,lon" or just "lat,lon"
        let coordString = text.hasPrefix("LOC:") ? String(text.dropFirst(4)) : text
        let parts = coordString.split(separator: ",")
        if parts.count == 2,
           let lat = Double(parts[0]),
           let lon = Double(parts[1]) {
            return .location(latitude: lat, longitude: lon)
        }
        // Fall back to text if parsing fails
        return .text(text)
    }

    /// Calculate how much the peer has consumed based on their message sequence
    private func calculatePeerConsumed(
        sequence: UInt64,
        length: UInt64,
        totalBytes: UInt64,
        myRole: ConversationRole
    ) -> UInt64 {
        switch myRole {
        case .initiator:
            // We're initiator, peer is responder (consumes backward)
            // Peer's sequence is the START of their consumption from the END
            // peerConsumed = totalBytes - sequence
            return totalBytes - sequence
        case .responder:
            // We're responder, peer is initiator (consumes forward)
            // Peer's sequence is the START of their consumption from the FRONT
            // peerConsumed = sequence + length
            return sequence + length
        }
    }
}
