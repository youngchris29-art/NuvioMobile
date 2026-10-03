import SwiftUI
import SharedCore

/// The Settings tab (FEAT-50 "Native Split + Explainer", detail-settings-revamp W1-B).
///
/// A `NavigationStack` whose root is `SettingsRootView` — a grouped list of ten categories with an
/// explainer column — and whose destinations are the panes, each wrapped in `SettingsPaneScaffold`
/// (explainer column + the pane's native `List`). Each category's rows live in their own
/// `*SettingsPane` file; the shared row primitives live in Settings/SettingsRowViews.swift, the
/// explainer plumbing in Settings/SettingsExplainerModel.swift and the copy in
/// Settings/SettingsDescriptions.swift.
///
/// ## Focus graph (written before the code, per the tvOS skill's workflow)
///
/// **Root.** See `SettingsRootView`: default focus is the last opened category's row (a
/// `.prefersDefaultFocus` inside the root List's `.focusScope`), Up / Down walk the categories,
/// Up from the first row exits to the tab bar, Select pushes the pane.
///
/// **Pane.** See `SettingsPaneScaffold`: push lands on the pane List's first focusable row,
/// Up / Down walk the rows, Left / Right do nothing at row level (the explainer is not
/// focusable).
///
/// **Menu.** Exactly one level per press. Inside an open `Menu`/`Picker` popover it dismisses the
/// popover; on a page pushed by a `SettingsLinkRow` it pops back to the pane; in a pane it pops
/// back to the root with focus on the category just left (tvOS focus memory, backed by the root's
/// preferred focus on `lastCategory`). At the root: in sidebar navigation mode
/// `.sidebarMenuReveal()` reveals the sidebar (FEAT-30); in tabs mode it leaves Settings for the
/// tab bar. Only the root view carries `.sidebarMenuReveal()`; panes are stack destinations, not
/// its descendants, so the stack's pop wins inside them in both modes. An `.alert` is dismissed
/// by its own Cancel button.
///
/// **Theme remount.** `path` and `lastCategory` are `@Binding`s owned by `ContentView`, above the
/// `.id(...)` rebuild boundary. A theme swatch, navigation-style or typeface change remounts this
/// view; the rebuilt `NavigationStack(path:)` starts with `[.appearance]` already in the path and
/// shows Appearance directly (no push animation), where `pendingThemeSwatchFocus` /
/// `pendingAppearanceRowFocus` put focus back on the control that was pressed.
///
/// **Empty / error panes (BUG-47 class).** Every pane rendered here, and every sub-page a
/// `SettingsLinkRow` pushes, must keep at least one focusable control in every state, or a push
/// strands focus. Read-only panes use `SettingsValueRow(focusable: true)`.
struct SettingsView: View {
    @StateObject private var model = SettingsViewModel()
    @StateObject private var trakt = TraktViewModel()
    @StateObject private var simkl = SimklViewModel()
    @StateObject private var debrid = DebridViewModel()
    @StateObject private var remote = RemoteSetupViewModel()
    @StateObject private var plugins = PluginsViewModel()
    @StateObject private var badges = BadgeSettingsViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @State private var confirmingSignOut = false
    @State private var confirmingTraktDisconnect = false
    @State private var confirmingSimklDisconnect = false
    /// Provider id pending a debrid disconnect confirmation (drives the alert).
    @State private var debridDisconnectId: String?
    /// "Use the official server?" confirmation (self-hosted → api.nuvio.tv switch-back).
    @State private var confirmingUseOfficial = false
    /// The open pane (depth 0 or 1; value-less `NavigationLink` sub-pages push on top without
    /// appearing here). A `@Binding` owned by `ContentView`, NOT local `@State`: `ContentView`
    /// re-identifies the app root on a theme / navigation-style / typeface change, which remounts
    /// this whole view. Local state would reset to the root and throw the user out of Appearance
    /// on every swatch press — the "the theme picker doesn't work" report. Same fix, and same
    /// reason, as `selectedTab`.
    @Binding var path: [SettingsCategory]
    /// The category the user last opened: the root's preferred focus after a pop or a remount.
    /// Owned by `ContentView` for the same reason as `path`.
    @Binding var lastCategory: SettingsCategory?
    /// Theme name whose swatch should reclaim focus after a theme-change remount (see
    /// `ContentView.pendingThemeSwatchFocus`); the Appearance pane consumes and clears it.
    @Binding var pendingThemeSwatchFocus: String?
    /// FEAT-30/31: which Appearance row ("navigation" / "typeface") should reclaim focus after a
    /// remount (see `ContentView.pendingAppearanceRowFocus`); the Appearance pane consumes and
    /// clears it, same contract as `pendingThemeSwatchFocus`.
    @Binding var pendingAppearanceRowFocus: String?

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootView(path: $path, lastCategory: $lastCategory)
                // FEAT-30 (Codex r2, internal review r3 P2-8): in sidebar mode the system tab bar
                // is gone from this root too, so Menu at the root needs the same route to the
                // replacement chrome the scrolling roots have. Attached to the ROOT view, inside
                // the stack: pushed panes (and `SettingsLinkRow` sub-pages) are stack
                // destinations, not descendants of this view, so their Menu (pop) is untouched.
                .sidebarMenuReveal()
                .background(Theme.Palette.background.ignoresSafeArea())
                .navigationDestination(for: SettingsCategory.self) { category in
                    SettingsPaneScaffold(category: category) {
                        paneContent(category)
                    }
                }
        }
        // On the stack, not the root view: pushing a pane must NOT stop the view models.
        .onAppear {
            model.start()
            trakt.start()
            simkl.start()
            debrid.start()
            plugins.start()
            badges.start()
        }
        .onDisappear {
            model.stop()
            trakt.stop()
            simkl.stop()
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
        .alert("Disconnect Simkl?", isPresented: $confirmingSimklDisconnect) {
            Button("Disconnect", role: .destructive) { simkl.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Simkl authorization is cleared. Your Simkl history is untouched.")
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
        .alert("Use the official server?", isPresented: $confirmingUseOfficial) {
            Button("Switch", role: .destructive) {
                // Fire-and-forget into the shared controller: clears the session + local data,
                // saves the official config, resets the Supabase client and re-inits auth — the
                // root gate drops to Welcome (which unmounts Settings).
                ServerConnectionController.shared.useOfficial()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You\u{2019}ll be signed out of the self-hosted server and local data on this Apple TV will be cleared. Nuvio will reconnect to api.nuvio.tv.")
        }
    }

    /// A pane's rows, rendered inside the scaffold's `List`. Only the pushed category's pane is
    /// built.
    ///
    @ViewBuilder
    private func paneContent(_ category: SettingsCategory) -> some View {
        switch category {
        case .accountProfiles:
            AccountProfilesSettingsPane(
                remote: remote,
                confirmingSignOut: $confirmingSignOut,
                confirmingUseOfficial: $confirmingUseOfficial
            )
        case .services:
            ServicesSettingsPane(
                trakt: trakt,
                simkl: simkl,
                debrid: debrid,
                confirmingTraktDisconnect: $confirmingTraktDisconnect,
                confirmingSimklDisconnect: $confirmingSimklDisconnect,
                debridDisconnectId: $debridDisconnectId
            )
        case .detailPage:
            DetailPageSettingsPane(model: model)
        case .appearance:
            AppearanceSettingsPane(
                model: model,
                badges: badges,
                pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                pendingAppearanceRowFocus: $pendingAppearanceRowFocus
            )
        case .homeScreen:
            HomeScreenSettingsPane(model: model)
        case .player:
            PlayerSettingsPane(model: model)
        case .sources:
            SourcesSettingsPane(model: model, plugins: plugins)
        case .subtitlesAudio:
            SubtitlesAudioSettingsPane(model: model)
        case .about:
            AboutSettingsPane()
        case .developer:
            DeveloperSettingsPane()
        }
    }
}

/// The four groups of the Settings root, in display order.
enum SettingsCategoryGroup: CaseIterable {
    case you
    case look
    case watch
    case system

    var title: String {
        switch self {
        case .you: return String(localized: "You")
        case .look: return String(localized: "Look")
        case .watch: return String(localized: "Watch")
        case .system: return String(localized: "System")
        }
    }

    /// This group's categories, in root-list order.
    var categories: [SettingsCategory] {
        SettingsCategory.allCases.filter { $0.group == self }
    }
}

/// Settings categories (FEAT-50 re-sort, decision D8: 9 panes in 4 groups, plus Developer).
/// Order here is the root-list order. Raw values are not persisted anywhere (the path lives in
/// `ContentView` `@State`), so renaming cases needs no migration. `subtitle` and `summary` live
/// with the rest of the explainer copy in Settings/SettingsDescriptions.swift.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case accountProfiles
    case services
    case appearance
    case homeScreen
    case detailPage
    case player
    case sources
    case subtitlesAudio
    case about
    case developer

    var id: String { rawValue }

    var group: SettingsCategoryGroup {
        switch self {
        case .accountProfiles, .services: return .you
        case .appearance, .homeScreen, .detailPage: return .look
        case .player, .sources, .subtitlesAudio: return .watch
        case .about, .developer: return .system
        }
    }

    var title: String {
        switch self {
        case .accountProfiles: return String(localized: "Account & Profiles")
        case .services: return String(localized: "Services")
        case .appearance: return String(localized: "Appearance")
        case .homeScreen: return String(localized: "Home Screen")
        case .detailPage: return String(localized: "Detail Page")
        case .player: return String(localized: "Player")
        case .sources: return String(localized: "Sources")
        case .subtitlesAudio: return String(localized: "Subtitles & Audio")
        case .about: return String(localized: "About")
        case .developer: return String(localized: "Developer")
        }
    }

    var icon: String {
        switch self {
        case .accountProfiles: return "person.crop.circle"
        case .services: return "link"
        case .appearance: return "paintbrush"
        case .homeScreen: return "house"
        case .detailPage: return "film"
        case .player: return "play.rectangle"
        case .sources: return "square.stack.3d.up"
        case .subtitlesAudio: return "captions.bubble"
        case .about: return "info.circle"
        case .developer: return "hammer"
        }
    }
}
