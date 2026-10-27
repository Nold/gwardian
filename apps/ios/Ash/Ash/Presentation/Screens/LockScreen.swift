//
//  LockScreen.swift
//  Ash
//
//  App code lock screen, with the optional biometric shortcut
//

import SwiftUI

struct LockScreen: View {
    @Bindable var viewModel: AppLockViewModel
    @State private var code = ""
    @State private var hasAttemptedAutoAuth = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.md)

                AppLogo(size: .medium, showTitle: false)

                // Re-evaluated every second so the delay counts down
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let waiting = remaining(at: context.date)
                    PasscodeEntryView(
                        title: "Enter your code",
                        subtitle: subtitle(waiting: waiting),
                        code: $code,
                        message: viewModel.errorMessage,
                        isDisabled: waiting != nil || viewModel.isAuthenticating,
                        shakeTrigger: viewModel.wrongCodeCount,
                        biometricIcon: viewModel.isBiometricUnlockEnabled ? viewModel.biometricType.iconName : nil,
                        onBiometric: { Task { await viewModel.unlockWithBiometrics() } },
                        onComplete: submit
                    )
                }

                Spacer(minLength: Spacing.md)
            }
        }
        .onAppear {
            code = ""
            // Offer biometrics once when the lock screen first shows
            if !hasAttemptedAutoAuth && viewModel.isBiometricUnlockEnabled {
                hasAttemptedAutoAuth = true
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    await viewModel.unlockWithBiometrics()
                }
            }
        }
    }

    private func submit(_ entered: String) {
        let unlocked = viewModel.unlock(code: entered)
        if !unlocked {
            code = ""
        }
    }

    private func remaining(at date: Date) -> TimeInterval? {
        guard let until = viewModel.retryUntil, until > date else { return nil }
        return until.timeIntervalSince(date)
    }

    private func subtitle(waiting: TimeInterval?) -> String? {
        if let waiting {
            return "Too many wrong codes. Try again in \(Self.format(waiting))."
        }
        if let left = viewModel.attemptsBeforeErase, left <= 3 {
            return left == 1
                ? "1 attempt left before everything is erased"
                : "\(left) attempts left before everything is erased"
        }
        return nil
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}
