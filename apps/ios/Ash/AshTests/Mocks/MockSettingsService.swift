//
//  MockSettingsService.swift
//  AshTests
//
//  Mock implementation of SettingsServiceProtocol for testing
//

import Foundation
@testable import Ash

/// Mock settings service for testing
final class MockSettingsService: SettingsServiceProtocol, @unchecked Sendable {
    // MARK: - State

    var isBiometricLockEnabled: Bool = false
    var lockOnBackground: Bool = true
    var isScreenshotProtectionEnabled: Bool = true
    var relayServerURL: String = "http://localhost:8080"
    var defaultExtendedTTL: Bool = false
    var hasCompletedOnboarding: Bool = false
    var isFamilyModeEnabled: Bool = false

    // MARK: - Call Tracking

    private(set) var biometricLockEnabledSetCount = 0
    private(set) var lockOnBackgroundSetCount = 0
    private(set) var screenshotProtectionEnabledSetCount = 0

    // MARK: - Reset

    func reset() {
        isBiometricLockEnabled = false
        lockOnBackground = true
        isScreenshotProtectionEnabled = true
        relayServerURL = "http://localhost:8080"
        defaultExtendedTTL = false
        hasCompletedOnboarding = false
        biometricLockEnabledSetCount = 0
        lockOnBackgroundSetCount = 0
        screenshotProtectionEnabledSetCount = 0
    }
}
