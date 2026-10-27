//
//  AppDelegate.swift
//  Ash
//
//  Core Layer - Application delegate for system callbacks
//  Handles remote notification registration and delivery
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Push notification service - set by the app on launch
    weak var pushNotificationService: PushNotificationService?

    // MARK: - Application Lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.info(.app, "Application did finish launching")

        // Set up notification center delegate
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    // MARK: - Keyboard

    /// Only Apple's keyboard inside the app: a third-party keyboard with full
    /// access could read and send everything typed.
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }

    // MARK: - Remote Notifications

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Log.info(.push, "Received device token from APNS")
        pushNotificationService?.handleDeviceToken(deviceToken)

        // Post notification for any observers
        NotificationCenter.default.post(name: .deviceTokenUpdated, object: nil)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushNotificationService?.handleRegistrationError(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Handle silent push notification
        PushNotificationHandler.handleSilentPush(
            userInfo: userInfo,
            completionHandler: completionHandler
        )
    }

    // MARK: - Private

    private func handlePushNotification(_ userInfo: [AnyHashable: Any]) {
        // Extract conversation ID if present
        if let conversationId = userInfo["conversation_id"] as? String {
            Log.info(.push, "Push notification for conversation: \(conversationId.prefix(8))")

            NotificationCenter.default.post(
                name: .pushNotificationReceived,
                object: nil,
                userInfo: ["conversation_id": conversationId]
            )
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// Handle notification received while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // ASH uses silent notifications - no UI presentation needed
        Log.debug(.push, "Notification received in foreground")
        completionHandler([])
    }

    /// Handle user interaction with notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Log.debug(.push, "User interacted with notification")

        if let conversationId = userInfo["conversation_id"] as? String {
            NotificationCenter.default.post(
                name: .pushNotificationReceived,
                object: nil,
                userInfo: ["conversation_id": conversationId]
            )
        }

        completionHandler()
    }
}
