//
//  RelayService.swift
//  Ash
//

import Foundation

/// Result from submitting a message to the relay
struct SubmitResult: Sendable {
    let blobId: UUID
    /// Server-provided expiry time (when the message will be deleted)
    /// Optional for backwards compatibility with older backend versions
    let expiresAt: Date?
}

protocol RelayServiceProtocol: Sendable {
    func submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: Data,
        sequence: UInt64?,
        ttlSeconds: UInt64?,
        extendedTTL: Bool,
        persistent: Bool,
        sender: UInt8?
    ) async throws -> SubmitResult

    /// `member` set for a group: skips this member's own messages and those
    /// it acknowledged
    func pollMessages(
        conversationId: String,
        authToken: String,
        cursor: RelayCursor?,
        member: UInt8?
    ) async throws -> PollResponse

    /// Acknowledge message delivery (tells sender we received it). In a
    /// group, the relay deletes a message once every other member acked it.
    func ackMessages(
        conversationId: String,
        authToken: String,
        blobIds: [UUID],
        member: UInt8?
    ) async throws -> Int

    func registerDevice(
        conversationId: String,
        authToken: String,
        deviceToken: String
    ) async throws

    /// `members` is 2 for a conversation, up to 8 for a group; `ttlSeconds`
    /// is the retention chosen at the ceremony (relay default when nil).
    func registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String,
        ttlSeconds: UInt64?,
        members: UInt8
    ) async throws

    func burnConversation(conversationId: String, burnToken: String) async throws

    func checkBurnStatus(conversationId: String, authToken: String) async throws -> BurnStatus
}

extension RelayServiceProtocol {
    /// Two-person conversations: no sender or member index
    func submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: Data,
        sequence: UInt64?,
        ttlSeconds: UInt64?,
        extendedTTL: Bool,
        persistent: Bool
    ) async throws -> SubmitResult {
        try await submitMessage(
            conversationId: conversationId,
            authToken: authToken,
            ciphertext: ciphertext,
            sequence: sequence,
            ttlSeconds: ttlSeconds,
            extendedTTL: extendedTTL,
            persistent: persistent,
            sender: nil
        )
    }

    func pollMessages(
        conversationId: String,
        authToken: String,
        cursor: RelayCursor?
    ) async throws -> PollResponse {
        try await pollMessages(conversationId: conversationId, authToken: authToken, cursor: cursor, member: nil)
    }

    func ackMessages(
        conversationId: String,
        authToken: String,
        blobIds: [UUID]
    ) async throws -> Int {
        try await ackMessages(conversationId: conversationId, authToken: authToken, blobIds: blobIds, member: nil)
    }

    func registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String
    ) async throws {
        try await registerConversation(
            conversationId: conversationId,
            authTokenHash: authTokenHash,
            burnTokenHash: burnTokenHash,
            ttlSeconds: nil,
            members: 2
        )
    }
}

typealias RelayCursor = String

struct PollResponse: Sendable {
    let messages: [RelayMessage]
    let nextCursor: RelayCursor?
    let burned: Bool
}

struct RelayMessage: Sendable {
    let id: UUID
    let sequence: UInt64?
    let ciphertext: Data
    let receivedAt: Date
}

struct BurnStatus: Sendable {
    let burned: Bool
    let burnedAt: Date?
}

enum RelayError: Error, Sendable {
    case invalidURL
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case conversationBurned
    case conversationNotFound
    case payloadTooLarge
    case queueFull
    case noConnection
}

extension RelayError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let error): return "Network: \(error.localizedDescription)"
        case .serverError(let code, let message): return "Server \(code): \(message ?? "unknown")"
        case .decodingError(let error): return "Decode: \(error)"
        case .conversationBurned: return "Conversation burned"
        case .conversationNotFound: return "Conversation not registered"
        case .payloadTooLarge: return "Payload too large"
        case .queueFull: return "Queue full"
        case .noConnection: return "No connection"
        }
    }
}

final class RelayService: RelayServiceProtocol, Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private func logId(_ conversationId: String) -> String {
        String(conversationId.prefix(8))
    }

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        }

        Log.debug(.relay, "Relay service initialized: \(baseURL.host ?? "unknown")")
    }

    convenience init(baseURLString: String) throws {
        guard let url = URL(string: baseURLString) else {
            throw RelayError.invalidURL
        }
        self.init(baseURL: url)
    }

    func submitMessage(
        conversationId: String,
        authToken: String,
        ciphertext: Data,
        sequence: UInt64?,
        ttlSeconds: UInt64?,
        extendedTTL: Bool,
        persistent: Bool,
        sender: UInt8?
    ) async throws -> SubmitResult {
        let url = baseURL.appendingPathComponent("v1/messages")
        let id = logId(conversationId)

        Log.debug(.relay, "[\(id)] Submitting: \(ciphertext.count) bytes, seq=\(sequence ?? 0), ttl=\(ttlSeconds ?? 0)s")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let body = SubmitMessageRequest(
            conversationId: conversationId,
            ciphertext: ciphertext.base64EncodedString(),
            sequence: sequence,
            ttlSeconds: ttlSeconds,
            extendedTTL: extendedTTL,
            persistent: persistent,
            sender: sender
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        let result = try decoder.decode(SubmitMessageResponse.self, from: data)

        guard result.accepted else {
            Log.error(.relay, "[\(id)] Message rejected by server")
            throw RelayError.serverError(statusCode: 400, message: "Message not accepted")
        }

        Log.debug(.relay, "[\(id)] Submitted successfully: blob=\(result.blobId.uuidString.prefix(8)), expires=\(result.expiresAt?.description ?? "unknown")")
        return SubmitResult(blobId: result.blobId, expiresAt: result.expiresAt)
    }

    func pollMessages(
        conversationId: String,
        authToken: String,
        cursor: RelayCursor?,
        member: UInt8?
    ) async throws -> PollResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/messages"), resolvingAgainstBaseURL: true)!
        var queryItems = [URLQueryItem(name: "conversation_id", value: conversationId)]
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let member {
            queryItems.append(URLQueryItem(name: "member", value: String(member)))
        }
        components.queryItems = queryItems

        let id = logId(conversationId)

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        let result: PollMessagesResponse
        do {
            result = try decoder.decode(PollMessagesResponse.self, from: data)
        } catch {
            Log.error(.relay, "[\(id)] Failed to decode poll response: \(error)")
            throw RelayError.decodingError(error)
        }

        if !result.messages.isEmpty {
            Log.debug(.relay, "[\(id)] Poll returned \(result.messages.count) messages, burned=\(result.burned)")
        }

        let messages = result.messages.compactMap { msg -> RelayMessage? in
            guard let ciphertext = Data(base64Encoded: msg.ciphertext) else {
                Log.error(.relay, "[\(id)] Invalid base64 in message \(msg.id.uuidString.prefix(8))")
                return nil
            }
            return RelayMessage(
                id: msg.id,
                sequence: msg.sequence,
                ciphertext: ciphertext,
                receivedAt: msg.receivedAt
            )
        }

        return PollResponse(
            messages: messages,
            nextCursor: result.nextCursor,
            burned: result.burned
        )
    }

    func ackMessages(
        conversationId: String,
        authToken: String,
        blobIds: [UUID],
        member: UInt8?
    ) async throws -> Int {
        guard !blobIds.isEmpty else { return 0 }

        let url = baseURL.appendingPathComponent("v1/messages/ack")
        let id = logId(conversationId)

        Log.debug(.relay, "[\(id)] Acknowledging \(blobIds.count) messages")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let body = AckMessageRequest(
            conversationId: conversationId,
            blobIds: blobIds,
            member: member
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        let result = try decoder.decode(AckMessageResponse.self, from: data)
        Log.debug(.relay, "[\(id)] Acknowledged \(result.acknowledged) messages")
        return result.acknowledged
    }

    func registerDevice(
        conversationId: String,
        authToken: String,
        deviceToken: String
    ) async throws {
        let url = baseURL.appendingPathComponent("v1/register")
        let id = logId(conversationId)

        Log.info(.relay, "[\(id)] Registering device for push notifications")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let body = RegisterDeviceRequest(
            conversationId: conversationId,
            deviceToken: deviceToken,
            platform: "ios"
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        Log.info(.relay, "[\(id)] Device registered successfully")
    }

    func registerConversation(
        conversationId: String,
        authTokenHash: String,
        burnTokenHash: String,
        ttlSeconds: UInt64?,
        members: UInt8
    ) async throws {
        let url = baseURL.appendingPathComponent("v1/conversations")
        let id = logId(conversationId)

        Log.info(.relay, "[\(id)] Registering conversation with relay")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RegisterConversationRequest(
            conversationId: conversationId,
            authTokenHash: authTokenHash,
            burnTokenHash: burnTokenHash,
            ttlSeconds: ttlSeconds,
            members: members
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        Log.info(.relay, "[\(id)] Conversation registered successfully")
    }

    func burnConversation(conversationId: String, burnToken: String) async throws {
        let url = baseURL.appendingPathComponent("v1/burn")
        let id = logId(conversationId)

        Log.warning(.relay, "[\(id)] Burning conversation on relay")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = BurnConversationRequest(conversationId: conversationId, burnToken: burnToken)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        Log.warning(.relay, "[\(id)] Conversation burned on relay")
    }

    func checkBurnStatus(conversationId: String, authToken: String) async throws -> BurnStatus {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/burn"), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "conversation_id", value: conversationId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data)

        let result = try decoder.decode(BurnStatusResponse.self, from: data)

        if result.burned {
            Log.warning(.relay, "[\(logId(conversationId))] Conversation marked as burned")
        }

        return BurnStatus(
            burned: result.burned,
            burnedAt: result.burnedAt
        )
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            Log.error(.relay, "Network request failed: \(error.localizedDescription)")
            throw RelayError.networkError(error)
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 400:
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                if errorResponse.error.contains("burned") {
                    throw RelayError.conversationBurned
                } else if errorResponse.error.contains("too large") {
                    throw RelayError.payloadTooLarge
                } else if errorResponse.error.contains("full") {
                    throw RelayError.queueFull
                }
                throw RelayError.serverError(statusCode: 400, message: errorResponse.error)
            }
            throw RelayError.serverError(statusCode: 400, message: nil)
        case 404:
            // Conversation not registered with relay - needs re-registration
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data),
               errorResponse.error.lowercased().contains("not found") {
                throw RelayError.conversationNotFound
            }
            throw RelayError.conversationNotFound
        default:
            let message = String(data: data, encoding: .utf8)
            Log.error(.relay, "Server error \(httpResponse.statusCode): \(message ?? "unknown")")
            throw RelayError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}

private struct SubmitMessageRequest: Encodable {
    let conversationId: String
    let ciphertext: String
    let sequence: UInt64?
    let ttlSeconds: UInt64?
    let extendedTTL: Bool
    let persistent: Bool
    /// Group member index of the sender; omitted for two-person conversations
    let sender: UInt8?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case ciphertext, sequence
        case ttlSeconds = "ttl_seconds"
        case extendedTTL = "extended_ttl"
        case persistent, sender
    }
}

private struct SubmitMessageResponse: Decodable {
    let accepted: Bool
    let blobId: UUID
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case accepted
        case blobId = "blob_id"
        case expiresAt = "expires_at"
    }
}

private struct PollMessagesResponse: Decodable {
    let messages: [MessageBlob]
    let nextCursor: RelayCursor?
    let burned: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case nextCursor = "next_cursor"
        case burned
    }
}

private struct MessageBlob: Decodable {
    let id: UUID
    let sequence: UInt64?
    let ciphertext: String
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sequence, ciphertext
        case receivedAt = "received_at"
    }
}

private struct RegisterDeviceRequest: Encodable {
    let conversationId: String
    let deviceToken: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case deviceToken = "device_token"
        case platform
    }
}

private struct RegisterConversationRequest: Encodable {
    let conversationId: String
    let authTokenHash: String
    let burnTokenHash: String
    /// Omitted when nil, so the relay keeps its default
    let ttlSeconds: UInt64?
    let members: UInt8

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case authTokenHash = "auth_token_hash"
        case burnTokenHash = "burn_token_hash"
        case ttlSeconds = "ttl_seconds"
        case members
    }
}

private struct BurnConversationRequest: Encodable {
    let conversationId: String
    let burnToken: String

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case burnToken = "burn_token"
    }
}

private struct BurnStatusResponse: Decodable {
    let burned: Bool
    let burnedAt: Date?

    enum CodingKeys: String, CodingKey {
        case burned
        case burnedAt = "burned_at"
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}

private struct AckMessageRequest: Encodable {
    let conversationId: String
    let blobIds: [UUID]
    /// Group member acknowledging; omitted for two-person conversations
    let member: UInt8?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case blobIds = "blob_ids"
        case member
    }
}

private struct AckMessageResponse: Decodable {
    let acknowledged: Int
}
