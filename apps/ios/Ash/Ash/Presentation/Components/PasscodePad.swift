//
//  PasscodePad.swift
//  Ash
//
//  Digit pad and dots for entering the app code
//

import SwiftUI

/// Title, dots, message and digit pad. Calls `onComplete` once all digits
/// are entered; the caller clears `code` to start over.
struct PasscodeEntryView: View {
    let title: String
    var subtitle: String?
    @Binding var code: String
    var message: String?
    var isDisabled = false
    /// Changing this value shakes the dots
    var shakeTrigger = 0
    var biometricIcon: String?
    var onBiometric: () -> Void = {}
    let onComplete: (String) -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            PasscodeDots(filled: code.count)
                .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
                .animation(.default, value: shakeTrigger)

            Text(message ?? " ")
                .font(.subheadline)
                .foregroundStyle(Color.ashDanger)
                .multilineTextAlignment(.center)
                .frame(minHeight: 40, alignment: .top)

            PasscodePad(
                isDisabled: isDisabled,
                biometricIcon: biometricIcon,
                onDigit: append,
                onDelete: { if !code.isEmpty { code.removeLast() } },
                onBiometric: onBiometric
            )
        }
        .padding(.horizontal, Spacing.md)
    }

    private func append(_ digit: Int) {
        guard code.count < LockPolicy.codeLength else { return }
        code.append(String(digit))
        if code.count == LockPolicy.codeLength {
            onComplete(code)
        }
    }
}

struct PasscodeDots: View {
    let filled: Int

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(0..<LockPolicy.codeLength, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                    .background(Circle().fill(index < filled ? Color.primary : Color.clear))
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(filled) of \(LockPolicy.codeLength) digits entered")
    }
}

struct PasscodePad: View {
    var isDisabled = false
    var biometricIcon: String?
    let onDigit: (Int) -> Void
    let onDelete: () -> Void
    var onBiometric: () -> Void = {}

    private var rows: [[Int]] { [[1, 2, 3], [4, 5, 6], [7, 8, 9]] }

    var body: some View {
        VStack(spacing: Spacing.md) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Spacing.lg) {
                    ForEach(row, id: \.self) { digit in
                        digitButton(digit)
                    }
                }
            }
            HStack(spacing: Spacing.lg) {
                if let biometricIcon {
                    keyButton(accessibilityLabel: "Unlock with biometrics", action: onBiometric) {
                        Image(systemName: biometricIcon).font(.title2)
                    }
                } else {
                    Color.clear.frame(width: 76, height: 76)
                }
                digitButton(0)
                keyButton(accessibilityLabel: "Delete", action: onDelete) {
                    Image(systemName: "delete.left").font(.title2)
                }
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text("\(digit)")
                .font(.system(size: 32, weight: .regular, design: .rounded))
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private func keyButton<Label: View>(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label().frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

#Preview {
    PasscodeEntryView(title: "Enter your code", code: .constant("12"), onComplete: { _ in })
}
