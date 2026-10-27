//
//  MessageStorageService.swift
//  Ash
//
//  Core Layer - Message storage abstraction with factory pattern
//  Handles switching between in-memory (ephemeral) and persistent (SwiftData) storage
//

import Foundation
import SwiftData

// MARK: - Storage Type

/// Represents the type of message storage to use
enum MessageStorageType: Equatable, Sendable {
    /// Ephemeral in-memory storage (wiped on app termination)
    case inMemory
    /// Persistent SwiftData storage (survives app restarts)
    case persistent
}

// MARK: - Storage Configuration

/// Configuration that determines storage behavior
/// Extracted from conversation + settings to make the decision testable
struct MessageStorageConfiguration: Sendable {
    let conversationAllowsPersistence: Bool
    let biometricLockEnabled: Bool
    let persistentStorageAvailable: Bool

    var recommendedStorageType: MessageStorageType {
        // Use persistent storage only when ALL conditions are met:
        // 1. Conversation allows persistence (user opted in)
        // 2. Biometric lock is enabled (security requirement)
        // 3. Persistent storage is available (SwiftData configured)
        if conversationAllowsPersistence && biometricLockEnabled && persistentStorageAvailable {
            return .persistent
        }
        return .inMemory
    }
}

// MARK: - Message Repository Factory Protocol

/// Factory protocol for creating message repositories
/// Decouples repository creation from consumers
protocol MessageRepositoryFactoryProtocol: Sendable {
    /// Get the appropriate repository for a conversation based on configuration
    @MainActor func repository(for configuration: MessageStorageConfiguration) -> MessageRepository

    /// Get the in-memory repository (always available)
    var inMemoryRepository: MessageRepository { get }

    /// Get the persistent repository (may be nil if not configured)
    @MainActor var persistentRepository: MessageRepository? { get }

    /// Check if persistent storage is available
    var isPersistentStorageAvailable: Bool { get }
}

// MARK: - Message Repository Factory Implementation

/// Default implementation of MessageRepositoryFactory
/// Manages both in-memory and persistent repositories
final class MessageRepositoryFactory: MessageRepositoryFactoryProtocol, @unchecked Sendable {
    // MARK: - Private Properties

    private let _inMemoryRepository: InMemoryMessageRepository
    private let modelContainer: ModelContainer?
    private var _persistentRepository: SwiftDataMessageRepository?

    // MARK: - Initialization

    init(modelContainer: ModelContainer? = nil) {
        self._inMemoryRepository = InMemoryMessageRepository()
        self.modelContainer = modelContainer

        Log.info(.storage, "MessageRepositoryFactory initialized: persistent=\(modelContainer != nil)")
    }

    // MARK: - MessageRepositoryFactoryProtocol

    var inMemoryRepository: MessageRepository {
        _inMemoryRepository
    }

    @MainActor
    var persistentRepository: MessageRepository? {
        // Lazy initialization of persistent repository on main actor
        if _persistentRepository == nil, let container = modelContainer {
            _persistentRepository = SwiftDataMessageRepository(modelContainer: container)
            Log.debug(.storage, "Persistent repository created lazily")
        }
        return _persistentRepository
    }

    var isPersistentStorageAvailable: Bool {
        modelContainer != nil
    }

    @MainActor
    func repository(for configuration: MessageStorageConfiguration) -> MessageRepository {
        switch configuration.recommendedStorageType {
        case .inMemory:
            Log.debug(.storage, "Using in-memory repository")
            return _inMemoryRepository
        case .persistent:
            if let persistent = persistentRepository {
                Log.debug(.storage, "Using persistent repository")
                return persistent
            }
            // Fall back to in-memory if persistent unavailable
            Log.warning(.storage, "Persistent requested but unavailable, falling back to in-memory")
            return _inMemoryRepository
        }
    }

    // MARK: - Secure Wipe

    /// Securely wipe all in-memory messages (call on app background/termination)
    func secureWipeInMemory() async {
        await _inMemoryRepository.secureWipeAll()
    }
}

// MARK: - Message Storage Service Protocol

/// High-level service for message storage operations
/// Provides a simplified interface for consumers
protocol MessageStorageServiceProtocol: Sendable {
    /// Get the repository for a specific conversation
    @MainActor func repository(for conversation: Conversation) -> MessageRepository

    /// Check if persistence is enabled for a conversation
    @MainActor func isPersistenceEnabled(for conversation: Conversation) -> Bool

    /// Securely wipe all ephemeral messages
    func secureWipeEphemeral() async

    /// Clear all messages for a conversation (both storages)
    func clearAll(for conversationId: String) async

    /// Clear all messages from all storages
    @MainActor func clearAllStorages() async
}

// MARK: - Message Storage Service Implementation

/// Concrete implementation of MessageStorageService
/// Coordinates between factory, settings, and conversations
final class MessageStorageService: MessageStorageServiceProtocol, @unchecked Sendable {
    // MARK: - Dependencies

    private let factory: MessageRepositoryFactoryProtocol
    private let settingsProvider: () -> Bool  // Returns whether the app lock is set up

    // MARK: - Initialization

    init(
        factory: MessageRepositoryFactoryProtocol,
        settingsProvider: @escaping @Sendable () -> Bool
    ) {
        self.factory = factory
        self.settingsProvider = settingsProvider
    }

    // MARK: - MessageStorageServiceProtocol

    @MainActor
    func repository(for conversation: Conversation) -> MessageRepository {
        let configuration = MessageStorageConfiguration(
            conversationAllowsPersistence: conversation.allowsMessagePersistence,
            biometricLockEnabled: settingsProvider(),
            persistentStorageAvailable: factory.isPersistentStorageAvailable
        )
        return factory.repository(for: configuration)
    }

    @MainActor
    func isPersistenceEnabled(for conversation: Conversation) -> Bool {
        let configuration = MessageStorageConfiguration(
            conversationAllowsPersistence: conversation.allowsMessagePersistence,
            biometricLockEnabled: settingsProvider(),
            persistentStorageAvailable: factory.isPersistentStorageAvailable
        )
        return configuration.recommendedStorageType == .persistent
    }

    func secureWipeEphemeral() async {
        await factory.inMemoryRepository.secureWipeAll()
    }

    func clearAll(for conversationId: String) async {
        // Clear from both storages to ensure complete cleanup
        await factory.inMemoryRepository.clear(for: conversationId)
        await factory.persistentRepository?.clear(for: conversationId)
    }

    @MainActor
    func clearAllStorages() async {
        await factory.inMemoryRepository.clearAll()
        await factory.persistentRepository?.clearAll()
    }
}
