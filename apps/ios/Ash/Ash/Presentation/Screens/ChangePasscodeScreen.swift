//
//  ChangePasscodeScreen.swift
//  Ash
//
//  Change the app code from settings
//

import SwiftUI

struct ChangePasscodeScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: AppLockViewModel

    private enum Step {
        case current
        case new
        case confirm(current: String, new: String)
    }

    @State private var step = Step.current
    @State private var current = ""
    @State private var code = ""
    @State private var message: String?
    @State private var shakeCount = 0

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let waiting = viewModel.retryUntil.map { $0 > context.date } ?? false
                PasscodeEntryView(
                    title: title,
                    subtitle: waiting ? "Too many wrong codes. Wait before trying again." : nil,
                    code: $code,
                    message: message,
                    isDisabled: waiting,
                    shakeTrigger: shakeCount,
                    onComplete: submit
                )
            }
            .padding(.vertical, Spacing.lg)
            .navigationTitle("Change Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onChange(of: viewModel.isLocked) { _, locked in
            // Erased after too many wrong codes
            if locked { dismiss() }
        }
    }

    private var title: String {
        switch step {
        case .current: return "Enter your current code"
        case .new: return "Enter a new code"
        case .confirm: return "Confirm the new code"
        }
    }

    private func submit(_ entered: String) {
        code = ""
        switch step {
        case .current:
            // Checked right away; a wrong code counts as a failed attempt
            guard viewModel.unlock(code: entered) else {
                message = viewModel.errorMessage
                viewModel.clearError()
                shakeCount += 1
                return
            }
            current = entered
            message = nil
            step = .new
        case .new:
            step = .confirm(current: current, new: entered)
        case .confirm(let current, let new):
            guard entered == new else {
                message = "The codes don't match."
                shakeCount += 1
                step = .new
                return
            }
            if viewModel.changeCode(current: current, new: new) {
                dismiss()
            } else {
                // Refused (delay running or code changed meanwhile); start over
                message = viewModel.errorMessage
                viewModel.clearError()
                shakeCount += 1
                self.current = ""
                step = .current
            }
        }
    }
}
