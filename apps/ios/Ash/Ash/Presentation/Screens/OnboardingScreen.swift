//
//  OnboardingScreen.swift
//  Ash
//
//  First-time user onboarding flow explaining security model, ceremony, and usage
//

import SwiftUI

// MARK: - Onboarding Page Model

struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String?  // SF Symbol name (nil for custom image)
    let customImage: String?  // Asset image name
    let iconColor: Color
    let title: String
    let subtitle: String
    let points: [OnboardingPoint]

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        points: [OnboardingPoint]
    ) {
        self.icon = icon
        self.customImage = nil
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.points = points
    }

    init(
        customImage: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        points: [OnboardingPoint]
    ) {
        self.icon = nil
        self.customImage = customImage
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.points = points
    }
}

struct OnboardingPoint: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let description: String
}

// MARK: - Onboarding Screen

struct OnboardingScreen: View {
    let onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [OnboardingPage] = [
        // Page 1: Welcome
        OnboardingPage(
            customImage: "ash_logo",
            iconColor: .ashAccent,
            title: "Welcome to Gwardian",
            subtitle: "Secure ephemeral messaging with mathematically proven encryption",
            points: [
                OnboardingPoint(
                    icon: "lock.shield.fill",
                    title: "One-Time Pad Encryption",
                    description: "The only encryption method mathematically proven unbreakable, even against quantum computers"
                ),
                OnboardingPoint(
                    icon: "eye.slash.fill",
                    title: "No Metadata Leakage",
                    description: "Messages are indistinguishable from random noise without the key"
                ),
                OnboardingPoint(
                    icon: "server.rack",
                    title: "Zero Trust Infrastructure",
                    description: "Servers never see your messages - they only relay encrypted blobs"
                )
            ]
        ),

        // Page 2: The Ceremony
        OnboardingPage(
            icon: "qrcode.viewfinder",
            iconColor: .ashAccent,
            title: "The Ceremony",
            subtitle: "Establish a secure channel by meeting in person",
            points: [
                OnboardingPoint(
                    icon: "person.2.fill",
                    title: "Meet In Person",
                    description: "True security requires physical presence - no remote key exchange"
                ),
                OnboardingPoint(
                    icon: "qrcode",
                    title: "Scan QR Codes",
                    description: "One person displays animated QR codes, the other scans them"
                ),
                OnboardingPoint(
                    icon: "checkmark.seal.fill",
                    title: "Verify Mnemonic",
                    description: "Both devices show the same 6 words to confirm successful transfer"
                )
            ]
        ),

        // Page 3: Message Capacity
        OnboardingPage(
            icon: "chart.bar.fill",
            iconColor: .ashAccent,
            title: "Limited Capacity",
            subtitle: "Each key has a finite message budget",
            points: [
                OnboardingPoint(
                    icon: "key.fill",
                    title: "Choose Your Key Size",
                    description: "64KB (~25 messages), 256KB (~100 messages), or 1MB (~400 messages)"
                ),
                OnboardingPoint(
                    icon: "arrow.counterclockwise",
                    title: "No Reuse",
                    description: "Each byte of the key is used exactly once, then destroyed"
                ),
                OnboardingPoint(
                    icon: "flame.fill",
                    title: "Burn When Done",
                    description: "Destroy the conversation permanently when you no longer need it"
                )
            ]
        ),

        // Page 4: Customization & Protection
        OnboardingPage(
            icon: "gearshape.2.fill",
            iconColor: .ashAccent,
            title: "Your Control",
            subtitle: "Customize security settings to your needs",
            points: [
                OnboardingPoint(
                    icon: "server.rack",
                    title: "Choose Your Relay",
                    description: "Use our default server or run your own - change it anytime in Settings"
                ),
                OnboardingPoint(
                    icon: "faceid",
                    title: "Biometric Lock",
                    description: "Protect the app with Face ID or Touch ID for an extra layer of security"
                ),
                OnboardingPoint(
                    icon: "clock.badge.checkmark.fill",
                    title: "Extended Message TTL",
                    description: "Keep messages on the relay longer for delayed reading when needed"
                )
            ]
        ),

        // Page 5: Important Trade-offs
        OnboardingPage(
            icon: "exclamationmark.triangle.fill",
            iconColor: .ashWarning,
            title: "Important Trade-offs",
            subtitle: "Perfect security comes with constraints",
            points: [
                OnboardingPoint(
                    icon: "xmark.circle.fill",
                    title: "No Recovery",
                    description: "If you lose your device, there is no way to recover your conversations"
                ),
                OnboardingPoint(
                    icon: "text.bubble.fill",
                    title: "Text Only",
                    description: "Images and files would consume too much key material"
                ),
                OnboardingPoint(
                    icon: "person.fill",
                    title: "One-to-One Only",
                    description: "No group chats - each conversation requires its own ceremony"
                )
            ]
        )
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            // Page content
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.3), value: currentPage)

            // Floating glass bottom controls
            VStack(spacing: Spacing.md) {
                // Page indicator pills
                HStack(spacing: Spacing.xs) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? Color.ashAccent : Color.primary.opacity(0.2))
                            .frame(width: index == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                    }
                }

                // Navigation buttons
                HStack(spacing: Spacing.sm) {
                    if currentPage > 0 {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                currentPage -= 1
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button {
                        if currentPage < pages.count - 1 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                currentPage += 1
                            }
                        } else {
                            onComplete()
                        }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Text(currentPage < pages.count - 1 ? "Continue" : "Get Started")
                            Image(systemName: currentPage < pages.count - 1 ? "arrow.right" : "checkmark")
                                .font(.body.weight(.bold))
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.ashAccent, in: Capsule())
                        .shadow(color: Color.ashAccent.opacity(0.3), radius: 8, y: 4)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentPage)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 20, y: -5)
            )
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.md)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - Onboarding Page View

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer(minLength: Spacing.xl)

                // Icon or custom image
                Group {
                    if let customImage = page.customImage {
                        Image(customImage)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                            .foregroundStyle(page.iconColor)
                    } else if let icon = page.icon {
                        Image(systemName: icon)
                            .font(.system(size: 64))
                            .foregroundStyle(page.iconColor)
                    }
                }
                .padding(.bottom, Spacing.sm)

                // Title
                Text(page.title)
                    .font(.ashLargeTitle)
                    .multilineTextAlignment(.center)

                // Subtitle
                Text(page.subtitle)
                    .font(.ashBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)

                Spacer(minLength: Spacing.lg)

                // Points
                VStack(spacing: Spacing.md) {
                    ForEach(page.points) { point in
                        OnboardingPointRow(point: point)
                    }
                }
                .padding(.horizontal, Spacing.lg)

                // Bottom padding for floating controls
                Spacer(minLength: 140)
            }
            .padding(.vertical, Spacing.lg)
        }
    }
}

// MARK: - Onboarding Point Row

private struct OnboardingPointRow: View {
    let point: OnboardingPoint

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.ashAccent.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: point.icon)
                    .font(.title3)
                    .foregroundStyle(Color.ashAccent)
            }

            // Text
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(point.title)
                    .font(.ashHeadline)

                Text(point.description)
                    .font(.ashSubheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
}

// MARK: - Preview

#Preview {
    OnboardingScreen {
        print("Onboarding completed")
    }
}
