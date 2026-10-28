//
//  Dependencies.swift
//  Ash
//
//  Core Layer - Dependency Injection Container
//  Provides all dependencies via SwiftUI Environment
//

import SwiftUI
import SwiftData

// MARK: - Dependency Container

/// Central container holding all app dependencies
/// Instantiated once at app launch, injected via Environment
final class Dependencies: ObservableObject, @unchecked Sendable {
    // MARK: - Repositories

    let conversationRepository: ConversationRepository
    /// Group conversations and their pads, sealed like conversations
    let groupRepository: GroupRepository

    // MARK: - Message Storage (decoupled via factory pattern)

    /// Factory for creating message repositories
    let messageRepositoryFactory: MessageRepositoryFactoryProtocol

    /// High-level message storage service (handles repository selection)
    let messageStorageService: MessageStorageServiceProtocol

    /// In-memory message repository (for backward compatibility and direct access)
    var inMemoryMessageRepository: MessageRepository {
        messageRepositoryFactory.inMemoryRepository
    }

    // MARK: - Services

    /// Raw Keychain, for data that must stay readable while locked (push token)
    let keychainService: KeychainServiceProtocol
    /// Holds the vault key that seals pads and conversations (docs/app-lock.md)
    let vault: PasscodeVault
    /// Keychain sealed with the vault key, used for pads and conversations
    let vaultedKeychain: VaultedKeychainService
    let cryptoService: CryptoServiceProtocol
    @MainActor let hapticService: HapticServiceProtocol
    let settingsService: SettingsServiceProtocol
    let locationService: LocationServiceProtocol
    let relayService: RelayServiceProtocol?
    let pushNotificationService: PushNotificationService

    /// Pad manager using Rust core for allocation logic (shared with Android)
    let padManager: PadManagerProtocol

    // MARK: - Use Cases

    let sendMessageUseCase: SendMessageUseCaseProtocol
    let receiveMessageUseCase: ReceiveMessageUseCaseProtocol
    let burnConversationUseCase: BurnConversationUseCaseProtocol
    let performCeremonyUseCase: PerformCeremonyUseCaseProtocol

    // MARK: - Fresh Install Detection

    private static let hasLaunchedKey = "com.monadial.ash.hasLaunchedBefore"

    /// Check if this is a fresh install and wipe Keychain if so
    /// UserDefaults is deleted on uninstall, but Keychain persists
    private static func handleFreshInstallIfNeeded(keychain: KeychainServiceProtocol) {
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: hasLaunchedKey)

        if !hasLaunchedBefore {
            Log.info(.app, "Fresh install detected - wiping stale Keychain data")

            // Wipe all Keychain data from previous install
            do {
                try keychain.deleteAll()
                Log.info(.app, "Keychain wiped successfully")
            } catch {
                Log.warning(.app, "Failed to wipe Keychain")
            }
            try? KeychainVaultKeyStore().deleteAll()
            KeychainLockAttemptStore().save(LockAttemptState())

            // Mark as launched
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
            UserDefaults.standard.synchronize()
        }
    }

    // MARK: - Initialization

    @MainActor
    init(
        conversationRepository: ConversationRepository? = nil,
        padManager: PadManagerProtocol? = nil,
        messageRepositoryFactory: MessageRepositoryFactoryProtocol? = nil,
        modelContainer: ModelContainer? = nil,
        keychainService: KeychainServiceProtocol? = nil,
        cryptoService: CryptoServiceProtocol? = nil,
        hapticService: HapticServiceProtocol? = nil,
        settingsService: SettingsServiceProtocol? = nil,
        locationService: LocationServiceProtocol? = nil,
        relayService: RelayServiceProtocol? = nil,
        pushNotificationService: PushNotificationService? = nil
    ) {
        // Create services
        let keychain = keychainService ?? KeychainService()

        // Handle fresh install - wipe stale Keychain data
        Self.handleFreshInstallIfNeeded(keychain: keychain)

        let crypto = cryptoService ?? CryptoService()
        let haptic = hapticService ?? HapticService()
        let settings = settingsService ?? SettingsService()
        let location = locationService ?? LocationService()
        let push = pushNotificationService ?? PushNotificationService(keychainService: keychain)

        // Pads and conversations are sealed with the vault key
        let vault = PasscodeVault()
        let vaulted = VaultedKeychainService(base: keychain, vault: vault)

        // Create repositories
        let convRepo = conversationRepository ?? KeychainConversationRepository(keychainService: vaulted)
        let padMgr = padManager ?? PadManager(keychainService: vaulted)

        // Create message storage factory (handles both in-memory and persistent)
        let factory = messageRepositoryFactory ?? MessageRepositoryFactory(modelContainer: modelContainer)

        // Create message storage service (high-level API with repository selection logic)
        let storageService = MessageStorageService(
            factory: factory,
            settingsProvider: { vault.isConfigured }
        )

        // Too many wrong codes: the vault key is gone, delete what it sealed
        vault.onErase = {
            do {
                try keychain.deleteAll()
            } catch {
                Log.error(.security, "Failed to delete records after erase: \(error)")
            }
            Task { @MainActor in
                await storageService.clearAllStorages()
            }
        }

        self.keychainService = keychain
        self.vault = vault
        self.vaultedKeychain = vaulted
        self.conversationRepository = convRepo
        self.groupRepository = KeychainGroupRepository(keychain: vaulted)
        self.padManager = padMgr
        self.messageRepositoryFactory = factory
        self.messageStorageService = storageService

        self.cryptoService = crypto
        self.hapticService = haptic
        self.settingsService = settings
        self.locationService = location
        self.pushNotificationService = push

        // Relay service is created dynamically per conversation
        // This is just a default/fallback for testing
        self.relayService = relayService

        // Create use cases
        self.sendMessageUseCase = SendMessageUseCase(
            padManager: padMgr,
            conversationRepository: convRepo,
            cryptoService: crypto
        )

        self.receiveMessageUseCase = ReceiveMessageUseCase(
            padManager: padMgr,
            conversationRepository: convRepo,
            cryptoService: crypto
        )

        self.burnConversationUseCase = BurnConversationUseCase(
            conversationRepository: convRepo,
            padManager: padMgr,
            messageStorageService: storageService,
            relayServiceFactory: { url in
                try? RelayService(baseURLString: url)
            }
        )

        self.performCeremonyUseCase = PerformCeremonyUseCase(
            cryptoService: crypto,
            conversationRepository: convRepo,
            padManager: padMgr,
            relayServiceFactory: { url in
                try? RelayService(baseURLString: url)
            }
        )
    }

    /// Create a relay service for a specific URL
    func createRelayService(for url: String) -> RelayServiceProtocol? {
        return try? RelayService(baseURLString: url)
    }

    /// Create a relay service using the default settings
    func createDefaultRelayService() -> RelayServiceProtocol? {
        return try? RelayService(baseURLString: settingsService.relayServerURL)
    }

    /// Get the appropriate message repository for a conversation
    /// Delegates to MessageStorageService for proper decoupling
    @MainActor
    func messageRepository(for conversation: Conversation) -> MessageRepository {
        messageStorageService.repository(for: conversation)
    }

    /// Check if message persistence is enabled for a conversation
    /// Delegates to MessageStorageService for proper decoupling
    @MainActor
    func isMessagePersistenceEnabled(for conversation: Conversation) -> Bool {
        messageStorageService.isPersistenceEnabled(for: conversation)
    }
}


// MARK: - Environment Key

private struct DependenciesKey: EnvironmentKey {
    static var defaultValue: Dependencies {
        // Create on main actor when first accessed
        MainActor.assumeIsolated {
            Dependencies()
        }
    }
}

extension EnvironmentValues {
    var dependencies: Dependencies {
        get { self[DependenciesKey.self] }
        set { self[DependenciesKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// Inject dependencies into the view hierarchy
    func withDependencies(_ dependencies: Dependencies) -> some View {
        self.environment(\.dependencies, dependencies)
    }
}
