//
//  AshTests.swift
//  AshTests
//
//  Main test suite for Ash app
//

import Testing
@testable import Ash

// MARK: - Test Suite Overview
//
// This test suite covers:
// - Services: BiometricService, SettingsService, KeychainService
// - ViewModels: AppLockViewModel
// - Domain Models: Conversation, Message, Ceremony
// - Views: LockScreen, SettingsScreen integration tests
//
// Run all tests with: xcodebuild test -scheme Ash -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

struct AshTests {

    @Test func appCanBeInitialized() async {
        // Basic smoke test - ensure app types can be created
        let biometric = MockBiometricService()
        let settings = MockSettingsService()

        let viewModel = await AppLockViewModel(
            vault: .inMemory(),
            biometricService: biometric,
            settingsService: settings
        )

        await MainActor.run {
            // No app code yet: setup comes first
            #expect(viewModel.phase == .setup)
        }
    }
}
