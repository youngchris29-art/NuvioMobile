import SwiftUI
import SharedCore

/// The Settings tab: Account (sign in / sign out), Playback (Skip Intro toggle) and Home Rows
/// (enable/disable + reorder the Home catalog rows).
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        Text("Settings")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)

                        section("Account") {
                            if auth.isAnonymous {
                                SettingsActionRow(
                                    title: "Sign In to Nuvio",
                                    subtitle: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared.",
                                    systemImage: "person.crop.circle.badge.plus"
                                ) {
                                    confirmingSignOut = true
                                }
                            } else {
                                SettingsActionRow(
                                    title: "Sign Out",
                                    subtitle: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared.",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                ) {
                                    confirmingSignOut = true
                                }
                            }
                        }

                        section("Playback") {
                            SettingsToggleRow(
                                title: "Skip Intro",
                                subtitle: "Show a Skip button during intros and outros",
                                isOn: model.skipIntroEnabled
                            ) {
                                model.setSkipIntro(!model.skipIntroEnabled)
                            }
                        }

                        section("Home Rows") {
                            if model.catalogs.isEmpty {
                                Text("Install add-ons to customize your Home rows.")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                ForEach(model.catalogs, id: \.key) { item in
                                    CatalogSettingRow(
                                        item: item,
                                        onToggle: { model.toggleCatalog(item) },
                                        onUp: { model.moveUp(item) },
                                        onDown: { model.moveDown(item) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: 1500, alignment: .leading)
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(
            auth.isAnonymous ? "Switch to a Nuvio account?" : "Sign out?",
            isPresented: $confirmingSignOut
        ) {
            Button(auth.isAnonymous ? "Continue" : "Sign Out", role: .destructive) {
                // Clears the session AND wipes local data (AccountDataCleaner seam), then the root
                // gate drops to the Welcome screen where an account can be signed in.
                auth.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                auth.isAnonymous
                    ? "Guest data on this Apple TV (profiles, library, watch progress) will be cleared. You can then sign in on the welcome screen."
                    : "Local data on this Apple TV will be cleared. Your synced data stays in your Nuvio account."
            )
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            content()
        }
    }
}

/// A focusable settings row that performs an action on select (chevron affordance).
private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: systemImage)
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
    }
}

/// A focusable settings row that toggles a boolean on select.
private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 34))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
    }
}

/// A Home-catalog row: title + add-on, with reorder (up/down) and an enable toggle.
private struct CatalogSettingRow: View {
    let item: HomeCatalogSettingsItem
    let onToggle: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.displayTitle)
                    .font(Theme.Font.body)
                    .foregroundStyle(item.enabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                Text(item.addonName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)

            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)

            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)

            Button(action: onToggle) {
                Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.enabled ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity)
    }
}
