//
//  Message.swift
//  Ash
//
//  Domain Entity - Ephemeral message
//

import Foundation

// MARK: - Message Content

/// Content types that can be sent in a message
enum MessageContent: Equatable, Hashable, Sendable, Codable {
    case text(String)
    case location(latitude: Double, longitude: Double)

    var byteCount: Int {
        switch self {
        case .text(let text):
            return text.utf8.count
        case .location:
            // "LOC:" prefix (4) + 6 decimal precision: "-123.123456,-123.123456" (~24) = 28 bytes max
            return 28
        }
    }

    /// Message type for authenticated encryption frame
    var messageType: MessageType {
        switch self {
        case .text: return .text
        case .location: return .location
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, text, latitude, longitude
    }

    private enum ContentType: String, Codable {
        case text, location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)
        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .location:
            let latitude = try container.decode(Double.self, forKey: .latitude)
            let longitude = try container.decode(Double.self, forKey: .longitude)
            self = .location(latitude: latitude, longitude: longitude)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .location(let latitude, let longitude):
            try container.encode(ContentType.location, forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
        }
    }
}

// MARK: - Delivery Status

/// Delivery status for outgoing messages
enum DeliveryStatus: Equatable, Hashable, Sendable {
    case sending
    case sent           // Sent to server, awaiting delivery
    case delivered      // Delivered to recipient (ACK received)
    case failed(reason: String?)
    case none           // For incoming messages
}

// MARK: - Message

/// Represents an ephemeral message in a conversation
struct Message: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let content: MessageContent
    let timestamp: Date
    let isOutgoing: Bool
    /// When this message expires (disappearing timer for received, or display TTL)
    let expiresAt: Date?
    /// When this message expires on the server (for sent messages awaiting delivery)
    var serverExpiresAt: Date?
    var deliveryStatus: DeliveryStatus
    /// Pad sequence (offset) used for this message - used for deduplication
    let sequence: UInt64?
    /// Server blob ID - used for ACK (nil for messages not yet submitted)
    var blobId: UUID?
    /// Whether the message content has been securely wiped (pad bytes zeroed)
    /// When true, the original content should not be displayed
    var isContentWiped: Bool = false
    /// Authentication tag (32 bytes) for message integrity verification display
    /// Present for incoming messages with authenticated encryption
    let authTag: [UInt8]?
    /// Pad bytes this message used from its sequence (auth key + encryption
    /// key), to wipe exactly those once it is gone. Nil when unknown.
    var padLength: UInt64? = nil

    // MARK: - Computed Properties

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var remainingTime: TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSinceNow)
    }

    /// Remaining time on server before message expires (for undelivered sent messages)
    var serverRemainingTime: TimeInterval? {
        guard let serverExpiresAt else { return nil }
        return max(0, serverExpiresAt.timeIntervalSinceNow)
    }

    /// Whether this sent message is awaiting delivery (has server TTL countdown)
    /// Shows countdown during sending and sent states (until delivered or failed)
    var isAwaitingDelivery: Bool {
        guard isOutgoing, let _ = serverExpiresAt else { return false }
        switch deliveryStatus {
        case .sending, .sent:
            return true
        case .delivered, .failed, .none:
            return false
        }
    }

    /// Whether delivery was confirmed (no more server countdown needed)
    var isDelivered: Bool {
        deliveryStatus == .delivered
    }

    var formattedTime: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Factory

extension Message {
    /// Create an outgoing text message
    static func outgoing(
        text: String,
        sequence: UInt64,
        serverTTLSeconds: TimeInterval = 300,
        lifetimeSeconds: UInt32? = nil
    ) -> Message {
        Message(
            id: UUID(),
            content: .text(text),
            timestamp: Date(),
            isOutgoing: true,
            // The author's chosen lifetime applies on this phone too
            expiresAt: lifetimeSeconds.map { Date().addingTimeInterval(TimeInterval($0)) },
            serverExpiresAt: Date().addingTimeInterval(serverTTLSeconds),
            deliveryStatus: .sending,
            sequence: sequence,
            blobId: nil,
            authTag: nil  // Outgoing messages don't have auth tag
        )
    }

    /// Create an outgoing location message
    static func outgoingLocation(
        latitude: Double,
        longitude: Double,
        sequence: UInt64,
        serverTTLSeconds: TimeInterval = 300
    ) -> Message {
        Message(
            id: UUID(),
            content: .location(latitude: latitude, longitude: longitude),
            timestamp: Date(),
            isOutgoing: true,
            expiresAt: nil,
            serverExpiresAt: Date().addingTimeInterval(serverTTLSeconds),
            deliveryStatus: .sending,
            sequence: sequence,
            blobId: nil,
            authTag: nil  // Outgoing messages don't have auth tag
        )
    }

    /// Create an incoming message
    /// - Parameters:
    ///   - disappearingSeconds: If set, message will expire after this many seconds (disappearing messages)
    ///   - blobId: Server blob ID for ACK
    ///   - authTag: Authentication tag (32 bytes) for integrity verification display
    static func incoming(
        content: MessageContent,
        sequence: UInt64,
        disappearingSeconds: TimeInterval?,
        blobId: UUID,
        authTag: [UInt8]? = nil
    ) -> Message {
        Message(
            id: UUID(),
            content: content,
            timestamp: Date(),
            isOutgoing: false,
            expiresAt: disappearingSeconds.map { Date().addingTimeInterval($0) },
            serverExpiresAt: nil,  // Incoming messages don't need server expiry tracking
            deliveryStatus: .none,
            sequence: sequence,
            blobId: blobId,
            authTag: authTag
        )
    }

    /// Create a copy with updated delivery status
    func withDeliveryStatus(_ status: DeliveryStatus) -> Message {
        var copy = self
        copy.deliveryStatus = status
        // Clear server expiry when delivered (no more countdown needed)
        if status == .delivered {
            copy.serverExpiresAt = nil
        }
        return copy
    }

    /// Create a copy with blob ID set (after server submission)
    func withBlobId(_ blobId: UUID) -> Message {
        var copy = self
        copy.blobId = blobId
        return copy
    }

    /// Create a copy with server-provided expiry time
    /// This replaces the client-calculated estimate with the actual server expiry
    func withServerExpiresAt(_ expiresAt: Date) -> Message {
        var copy = self
        copy.serverExpiresAt = expiresAt
        return copy
    }

    /// Create a copy marked as content wiped (for expired messages)
    /// The content is kept but should not be displayed - show "[Message Expired]" instead
    func withContentWiped() -> Message {
        var copy = self
        copy.isContentWiped = true
        return copy
    }
}

// MARK: - Comparable

extension Message: Comparable {
    /// Sort messages by timestamp (oldest first)
    static func < (lhs: Message, rhs: Message) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}
