import SwiftUI
import SharedCore

/// The Settings tab: Account (sign in / sign out), Playback (Skip Intro toggle) and Home Rows
/// (enable/disable + reorder the Home catalog rows).
///
/// Split across NuvioTV/Screens/Settings/ (Phase 2 HIG revamp): this file owns the NavigationStack,
/// the two-pane split-view (sidebar + detail), the category enum/selection state, and the pane
/// switch. Each sidebar category's rows live in their own `*SettingsPane` file; small shared row
/// views live in Settings/SettingsRowViews.swift.
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var trakt = TraktViewModel()
    @StateObject private var debrid = DebridViewModel()
    @StateObject private var remote = RemoteSetupViewModel()
    @StateObject private var plugins = PluginsViewModel()
    @StateObject private var badges = BadgeSettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false
    @State private var confirmingTraktDisconnect = false
    /// Provider id pending a debrid disconnect confirmation (drives the alert).
    @State private var debridDisconnectId: String?
    /// Which category's sections are shown in the detail pane (split-view, tvOS-Settings style).
    @State private var selectedCategory: SettingsCategory = .accountServices
    @FocusState private var focusedCategory: SettingsCategory?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                HStack(alignment: .top, spacing: 0) {
                    categorySidebar
                        .frame(width: 460)
                        .focusSection()

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                            Text(selectedCategory.title)
                                .font(Theme.Font.screenTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)

                            pane
                        }
                        .padding(Theme.Spacing.screen)
                        .frame(maxWidth: 1500, alignment: .leading)
                    }
                    .focusSection()
                }
            }
        }
        .onAppear {
            model.start()
            trakt.start()
            debrid.start()
            plugins.start()
            badges.start()
        }
        .onDisappear {
            model.stop()
            trakt.stop()
            debrid.stop()
            plugins.stop()
            badges.stop()
            remote.stop()
        }
        .alert(
            "Apply changes from browser?",
            isPresented: Binding(
                get: { remote.pendingChange != nil },
                set: { if !$0 { remote.rejectPending() } }
            )
        ) {
            Button("Apply") { remote.confirmPending() }
            Button("Decline", role: .cancel) { remote.rejectPending() }
        } message: {
            Text(remote.pendingSummary)
        }
        .alert("Disconnect Trakt?", isPresented: $confirmingTraktDisconnect) {
            Button("Disconnect", role: .destructive) { trakt.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Trakt access token is revoked. Your Trakt history is untouched.")
        }
        .alert(
            "Disconnect debrid provider?",
            isPresented: Binding(
                get: { debridDisconnectId != nil },
                set: { if !$0 { debridDisconnectId = nil } }
            )
        ) {
            Button("Disconnect", role: .destructive) {
                if let id = debridDisconnectId { debrid.disconnect(id) }
                debridDisconnectId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this provider's key from this profile. Streams will no longer resolve through it.")
        }
        .alert(
            auth.isAnonymous ? "Switch to a Nuvio account?" : "Sign out?",
            isPresented: $confirmingSignOut
        ) {
            Button(auth.isAnonymous ? String(localized: "Continue") : String(localized: "Sign Out"), role: .destructive) {
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

    /// The detail pane's content for the currently selected sidebar category. Only the selected
    /// category's pane is built (not the others), matching the previous per-section filtering —
    /// keeps focus + perf clean.
    @ViewBuilder
    private var pane: some View {
        switch selectedCategory {
        case .accountServices:
            AccountServicesSettingsPane(
                trakt: trakt,
                debrid: debrid,
                confirmingSignOut: $confirmingSignOut,
                confirmingTraktDisconnect: $confirmingTraktDisconnect,
                debridDisconnectId: $debridDisconnectId
            )
        case .playback:
            PlaybackSettingsPane(model: model)
        case .appearance:
            AppearanceSettingsPane(model: model, badges: badges)
        case .homeScreen:
            HomeScreenSettingsPane(model: model)
        case .contentSources:
            ContentSourcesSettingsPane(model: model, plugins: plugins)
        case .advanced:
            AdvancedSettingsPane(remote: remote)
        }
    }

    /// Left column: one focusable row per category. Focusing a row live-updates the detail pane
    /// (tvOS Settings pattern); swiping right enters the pane.
    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Settings")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.bottom, Theme.Spacing.md)

            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: category.icon)
                            .font(Theme.Font.body)
                            .frame(width: 40)
                        Text(category.title)
                            .font(Theme.Font.body)
                        Spacer(minLength: 0)
                    }
                    .rowAccentTint(
                        category == selectedCategory,
                        inactiveColor: Theme.Palette.textPrimary
                    )
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.settingsRow)
                .focused($focusedCategory, equals: category)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.screen)
        .onChange(of: focusedCategory) { _, newValue in
            // Live-preview the focused category in the detail pane.
            if let newValue { selectedCategory = newValue }
        }
    }
}

/// Settings categories for the split-view sidebar. Order here is the sidebar order.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case accountServices
    case playback
    case appearance
    case homeScreen
    case contentSources
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accountServices: return String(localized: "Account & Services")
        case .playback: return String(localized: "Playback")
        case .appearance: return String(localized: "Appearance")
        case .homeScreen: return String(localized: "Home Screen")
        case .contentSources: return String(localized: "Content Sources")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var icon: String {
        switch self {
        case .accountServices: return "person.crop.circle"
        case .playback: return "play.rectangle"
        case .appearance: return "paintbrush"
        case .homeScreen: return "house"
        case .contentSources: return "square.stack.3d.up"
        case .advanced: return "gearshape.2"
        }
    }
}
