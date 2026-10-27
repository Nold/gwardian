//
//  SettingsService.swift
//  Ash
//

import Foundation

private enum SettingsKey: String {
    case biometricLockEnabled = "ash.settings.biometricLockEnabled"
    case lockOnBackground = "ash.settings.lockOnBackground"
    case relayServerURL = "ash.settings.relayServerURL"
    case defaultExtendedTTL = "ash.settings.defaultExtendedTTL"
    case hasCompletedOnboarding = "ash.settings.hasCompletedOnboarding"
}

protocol SettingsServiceProtocol: AnyObject, Sendable {
    var isBiometricLockEnabled: Bool { get set }
    var lockOnBackground: Bool { get set }
    var relayServerURL: String { get set }
    var defaultExtendedTTL: Bool { get set }
    var hasCompletedOnboarding: Bool { get set }
}

final class SettingsService: SettingsServiceProtocol, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isBiometricLockEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.biometricLockEnabled.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.biometricLockEnabled.rawValue) }
    }

    var lockOnBackground: Bool {
        get {
            if defaults.object(forKey: SettingsKey.lockOnBackground.rawValue) == nil { return true }
            return defaults.bool(forKey: SettingsKey.lockOnBackground.rawValue)
        }
        set { defaults.set(newValue, forKey: SettingsKey.lockOnBackground.rawValue) }
    }

    /// Default relay URL - can be overridden via ASH_RELAY_URL environment variable or Info.plist
    static var defaultRelayURL: String {
        // Check environment variable first (useful for development/testing)
        if let envURL = ProcessInfo.processInfo.environment["ASH_RELAY_URL"], !envURL.isEmpty {
            return envURL
        }
        // Check Info.plist (useful for build configurations)
        if let plistURL = Bundle.main.object(forInfoDictionaryKey: "ASH_RELAY_URL") as? String, !plistURL.isEmpty {
            return plistURL
        }
        // Fallback to hardcoded default
        return "https://eu.relay.ashprotocol.app"
    }

    var relayServerURL: String {
        get { defaults.string(forKey: SettingsKey.relayServerURL.rawValue) ?? Self.defaultRelayURL }
        set { defaults.set(newValue, forKey: SettingsKey.relayServerURL.rawValue) }
    }

    var defaultExtendedTTL: Bool {
        get { defaults.bool(forKey: SettingsKey.defaultExtendedTTL.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.defaultExtendedTTL.rawValue) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: SettingsKey.hasCompletedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.hasCompletedOnboarding.rawValue) }
    }
}
