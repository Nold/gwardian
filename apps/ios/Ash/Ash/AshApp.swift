//
//  AshApp.swift
//  Ash
//
//  Created by Tomas Mihalicka on 29/12/2025.
//

import SwiftUI
import SwiftData

@main
struct AshApp: App {
    /// App delegate for system callbacks (push notifications, etc.)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// SwiftData model container for persistent message storage
    /// Only used when conversation has disappearing messages enabled AND biometric lock is on
    private let modelContainer: ModelContainer

    /// Dependency container - single source of truth for all dependencies
    @StateObject private var dependencies: Dependencies

    init() {
        // Create SwiftData model container for persistent messages
        let deps: Dependencies
        let schema = Schema([PersistedMessage.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainer = container
            // Create Dependencies with model container for persistent repository
            deps = Dependencies(modelContainer: container)
            Log.info(.app, "SwiftData ModelContainer created successfully")
        } catch {
            // If SwiftData fails, continue without persistence
            Log.error(.app, "Failed to create ModelContainer: \(error) - messages won't persist")
            // Create a fallback container (in-memory only)
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            let container = try! ModelContainer(for: schema, configurations: [fallbackConfig])
            self.modelContainer = container
            deps = Dependencies()
        }

        self._dependencies = StateObject(wrappedValue: deps)
        let vaultedKeychain = deps.vaultedKeychain
        self._lockViewModel = State(initialValue: AppLockViewModel(
            vault: deps.vault,
            settingsService: deps.settingsService,
            onConfigured: {
                // Seal pads and conversations stored before the app lock existed
                do {
                    let sealed = try vaultedKeychain.sealLegacyRecords()
                    Log.info(.security, "Sealed \(sealed) existing records")
                } catch {
                    Log.error(.security, "Failed to seal existing records: \(error)")
                }
            }
        ))
    }

    /// Root view model
    @State private var appViewModel: AppViewModel?

    /// App code lock; pads and conversations stay sealed until it is unlocked
    @State private var lockViewModel: AppLockViewModel

    /// Track scene phase for background/foreground detection
    @Environment(\.scenePhase) private var scenePhase

    /// Track if push notifications have been set up
    @State private var pushNotificationsSetUp = false

    /// Track if onboarding has been completed
    @State private var hasCompletedOnboarding: Bool?

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if let completed = hasCompletedOnboarding {
                        if !completed {
                            // Show onboarding for first-time users
                            OnboardingScreen {
                                dependencies.settingsService.hasCompletedOnboarding = true
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    hasCompletedOnboarding = true
                                }
                            }
                        } else {
                            lockedContent
                        }
                    } else {
                        // Loading state while checking onboarding status
                        LoadingScreen()
                            .task {
                                hasCompletedOnboarding = dependencies.settingsService.hasCompletedOnboarding
                            }
                    }
                }
                .tint(Color.ashSecure)
                .preferredColorScheme(nil) // Support both light and dark
            }
            .animation(.easeInOut(duration: 0.2), value: lockViewModel.phase)
            .onChange(of: lockViewModel.isLocked) { _, locked in
                // Drop everything read from the vault while locked
                if locked { appViewModel = nil }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                switch newPhase {
                case .background:
                    lockViewModel.appDidEnterBackground()
                    // Secure wipe ephemeral messages when going to background
                    Task {
                        await dependencies.messageStorageService.secureWipeEphemeral()
                    }
                case .active:
                    lockViewModel.appDidBecomeActive()
                    // Re-register for push when app becomes active
                    if pushNotificationsSetUp {
                        dependencies.pushNotificationService.registerForRemoteNotifications()
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .task {
                await setupPushNotifications()
            }
        }
    }

    // MARK: - Lock

    /// The app code gates everything after onboarding
    @ViewBuilder
    private var lockedContent: some View {
        switch lockViewModel.phase {
        case .setup:
            PasscodeSetupScreen(viewModel: lockViewModel)
                .transition(.opacity)
        case .locked:
            LockScreen(viewModel: lockViewModel)
                .transition(.opacity)
        case .unlocked:
            if let viewModel = appViewModel {
                RootView(viewModel: viewModel, lockViewModel: lockViewModel)
                    .withDependencies(dependencies)
            } else {
                LoadingScreen()
                    .task {
                        appViewModel = AppViewModel(dependencies: dependencies)
                    }
            }
        }
    }

    // MARK: - Push Notification Setup

    @MainActor
    private func setupPushNotifications() async {
        // Connect AppDelegate to push service
        appDelegate.pushNotificationService = dependencies.pushNotificationService

        // Check current authorization status
        let status = await dependencies.pushNotificationService.getAuthorizationStatus()

        switch status {
        case .notDetermined:
            // Request authorization on first launch
            do {
                let granted = try await dependencies.pushNotificationService.requestAuthorization()
                if granted {
                    dependencies.pushNotificationService.registerForRemoteNotifications()
                }
            } catch {
                Log.error(.push, "Failed to request push notification authorization: \(error)")
            }

        case .authorized, .provisional, .ephemeral:
            // Already authorized - register for remote notifications
            dependencies.pushNotificationService.registerForRemoteNotifications()

        case .denied:
            Log.info(.push, "Push notifications denied by user")

        @unknown default:
            break
        }

        pushNotificationsSetUp = true
    }
}

// MARK: - Root View

/// Root navigation container
struct RootView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var lockViewModel: AppLockViewModel

    var body: some View {
        NavigationStack {
            ConversationsScreen(viewModel: viewModel)
                .navigationDestination(item: $viewModel.selectedConversation) { conversation in
                    MessagingScreen(
                        conversation: conversation,
                        onBurn: {
                            Task { await viewModel.burnConversation(conversation) }
                        },
                        onRename: { newName in
                            Task { await viewModel.renameConversation(conversation, to: newName) }
                        },
                        onUpdateRelayURL: { url in
                            Task { await viewModel.updateConversationRelayURL(conversation, url: url) }
                        },
                        onDismiss: {
                            // Reload conversations to get updated state (pad consumption, cursor, etc.)
                            await viewModel.loadConversations()
                        }
                    )
                }
        }
        .sheet(isPresented: $viewModel.isShowingCeremony) {
            CeremonyScreen(
                viewModel: viewModel.ceremonyViewModel,
                onComplete: { conversation in
                    Task { await viewModel.handleCeremonyCompleted(conversation) }
                },
                onCancel: {
                    viewModel.isShowingCeremony = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.groupCeremonyViewModel != nil },
            set: { if !$0 { viewModel.groupCeremonyViewModel = nil } }
        )) {
            if let groupViewModel = viewModel.groupCeremonyViewModel {
                GroupCeremonyScreen(
                    viewModel: groupViewModel,
                    onComplete: { viewModel.handleGroupCeremonyCompleted($0) },
                    onCancel: { viewModel.groupCeremonyViewModel = nil }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsScreen(
                lockViewModel: lockViewModel,
                onBurnAll: {
                    Task { await viewModel.burnAllConversations() }
                },
                onRelaySettingsChanged: {
                    // Settings changed - app needs restart for full effect
                    // Future: implement dynamic relay service refresh
                }
            )
        }
        .task {
            await viewModel.loadConversations()
        }
    }
}
