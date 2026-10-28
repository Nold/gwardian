//
//  LoadingScreen.swift
//  Ash
//
//  Loading screen shown during app initialization
//

import SwiftUI

struct LoadingScreen: View {
    @State private var showContent = false

    var body: some View {
        ZStack {
            // Background
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                AppLogo(size: .large)
                    .opacity(showContent ? 1 : 0)
                    .scaleEffect(showContent ? 1 : 0.9)

                Spacer()

                // Loading indicator
                ProgressView()
                    .controlSize(.regular)
                    .tint(.secondary)
                    .opacity(showContent ? 1 : 0)
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                showContent = true
            }
        }
    }
}

// MARK: - App Logo Component

struct AppLogo: View {
    enum Size {
        case small, medium, large

        var iconSize: CGFloat {
            switch self {
            case .small: return 40
            case .medium: return 64
            case .large: return 80
            }
        }

        var titleFont: Font {
            switch self {
            case .small: return .title3.bold()
            case .medium: return .title.bold()
            case .large: return .system(size: 36, weight: .bold, design: .rounded)
            }
        }

        var spacing: CGFloat {
            switch self {
            case .small: return 8
            case .medium: return 12
            case .large: return 16
            }
        }
    }

    let size: Size
    var showTitle: Bool = true

    var body: some View {
        VStack(spacing: size.spacing) {
            // ASH Logo (tinted)
            Image("ash_logo")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.iconSize, height: size.iconSize)
                .foregroundStyle(Color.ashSecure)

            if showTitle {
                // App name
                Text("Gwardian")
                    .font(size.titleFont)
                    .foregroundStyle(Color.primary)
                    .tracking(4)
            }
        }
    }
}

#Preview {
    LoadingScreen()
}

#Preview("Dark") {
    LoadingScreen()
        .preferredColorScheme(.dark)
}

