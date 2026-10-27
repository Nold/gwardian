//
//  PasscodeSetupScreen.swift
//  Ash
//
//  Mandatory app code setup, after onboarding or after an update
//

import SwiftUI

struct PasscodeSetupScreen: View {
    @Bindable var viewModel: AppLockViewModel
    @State private var code = ""
    @State private var firstEntry: String?
    @State private var message: String?
    @State private var mismatchCount = 0

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if viewModel.wasErased {
                        erasedNotice
                    }

                    PasscodeEntryView(
                        title: firstEntry == nil ? "Choose an app code" : "Confirm your code",
                        subtitle: firstEntry == nil
                            ? "6 digits, different from your phone's passcode. Someone who can unlock your phone still cannot open your conversations."
                            : "Enter the same code again.",
                        code: $code,
                        message: message ?? viewModel.errorMessage,
                        shakeTrigger: mismatchCount,
                        onComplete: submit
                    )

                    Text("There is no way to recover a forgotten code. Without it, your conversations can only be erased by deleting the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                }
                .padding(.vertical, Spacing.xl)
            }
        }
    }

    private var erasedNotice: some View {
        Label(
            "Too many wrong codes: all conversations and pads were erased.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline)
        .foregroundStyle(Color.ashDanger)
        .padding(Spacing.md)
        .background(Color.ashDanger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
    }

    private func submit(_ entered: String) {
        guard let first = firstEntry else {
            firstEntry = entered
            message = nil
            code = ""
            return
        }
        if entered == first {
            viewModel.configure(code: entered)
        } else {
            message = "The codes don't match. Choose a code again."
            mismatchCount += 1
            firstEntry = nil
        }
        code = ""
    }
}
