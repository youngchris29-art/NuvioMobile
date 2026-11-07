import Foundation
import SwiftUI
import SharedCore

/// "Services" category rows (detail-settings-revamp W2-B): Trakt, Simkl, MDBList, More Like This
/// and Debrid, split out of the old Account & Services pane. Rows only: `SettingsPaneScaffold`
/// supplies the `List`. Logic and wiring preserved verbatim.
struct ServicesSettingsPane: View {
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var simkl: SimklViewModel
    @ObservedObject var debrid: DebridViewModel
    /// Owned here (not injected from SettingsView) so the MDBList card needs no SettingsView change.
    @StateObject private var mdblist = MdbListViewModel()
    @State private var confirmingMdbListDisconnect = false
    /// Set by every Connect press (the provider's key): the activation card that replaces the
    /// Connect row then takes focus on its Cancel. Not on plain appearance: the pane is a lazy List, so a pending card
    /// scrolling into view would otherwise yank focus (review r1 P2).
    @State private var activationFocusHandOff: String?

    /// The hand-off flag for one provider's card: armed only by that provider's Connect press, so
    /// a failed Connect elsewhere can't make a pending card steal focus (review r2 P3).
    private func handOff(_ provider: String) -> Binding<Bool> {
        Binding(
            get: { activationFocusHandOff == provider },
            set: { if !$0, activationFocusHandOff == provider { activationFocusHandOff = nil } }
        )
    }

    /// Drives the shared Trakt-disconnect confirmation alert owned by SettingsView.
    @Binding var confirmingTraktDisconnect: Bool
    /// Drives the shared Simkl-disconnect confirmation alert owned by SettingsView.
    @Binding var confirmingSimklDisconnect: Bool
    /// Provider id pending a debrid disconnect confirmation (drives the alert owned by SettingsView).
    @Binding var debridDisconnectId: String?

    var body: some View {
        Group {
            SettingsSection(String(localized: "Trakt")) {
                traktSection
            }

            SettingsSection(String(localized: "Simkl")) {
                simklSection
            }

            SettingsSection(String(localized: "MDBList")) {
                mdblistSection
            }
            .onAppear { mdblist.start() }
            .onDisappear { mdblist.stop() }
            .alert("Disconnect MDBList?", isPresented: $confirmingMdbListDisconnect) {
                Button("Disconnect", role: .destructive) { mdblist.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MDBList will stop syncing on this Apple TV.")
            }

            SettingsSection(String(localized: "More Like This")) {
                SettingsPickerRow(
                    title: String(localized: "Source"),
                    subtitle: String(localized: "Falls back to TMDB when the selected account isn't connected."),
                    selection: Binding(
                        get: { simkl.moreLikeThisSource },
                        set: { simkl.setMoreLikeThisSource($0) }
                    ),
                    options: ["trakt", "simkl", "tmdb"],
                    descriptionID: .servicesMoreLikeThisSource,
                    label: { key in
                        switch key {
                        case "simkl": return String(localized: "Simkl")
                        case "tmdb": return String(localized: "TMDB")
                        default: return String(localized: "Trakt")
                        }
                    }
                )
            }

            SettingsSection(String(localized: "Debrid")) {
                DebridProvidersSection(debrid: debrid, debridDisconnectId: $debridDisconnectId)
            }
        }
        // BUG-21 follow-up: verify each connected provider's stored credential the moment the
        // pane opens, so an expired token reads "Session expired" instead of "Connected".
        .onAppear { debrid.revalidateConnected() }
    }

    /// The Trakt section body — four states: keys missing / connected / awaiting code approval /
    /// disconnected. The device flow runs in the shared repo; this just renders its uiState.
    @ViewBuilder
    private var traktSection: some View {
        if !trakt.credentialsConfigured {
            Text("Trakt isn't configured in this build. Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to local.properties, then rebuild the shared framework.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else if trakt.isConnected {
            SettingsDestructiveRow(
                title: String(localized: "Disconnect Trakt"),
                subtitle: String(localized: "Connected as \(trakt.username ?? "your Trakt account") \u{00B7} watched history is scrobbled automatically as you play."),
                systemImage: "checkmark.circle.fill",
                descriptionID: .servicesTrakt
            ) {
                confirmingTraktDisconnect = true
            }
        } else if let code = trakt.deviceUserCode {
            TraktActivationCard(
                code: code,
                verificationUrl: trakt.deviceVerificationUrl ?? "https://trakt.tv/activate",
                focusHandOff: handOff("trakt")
            ) {
                activationFocusHandOff = "trakt:connect"
                trakt.cancelActivation()
            }
        } else {
            Text("Scrobble what you watch on this Apple TV to your Trakt profile (movies and episodes are marked watched automatically).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: trakt.isLoading ? String(localized: "Requesting code\u{2026}") : String(localized: "Connect Trakt"),
                subtitle: String(localized: "Shows a short code to enter at trakt.tv/activate on your phone or computer."),
                systemImage: "antenna.radiowaves.left.and.right",
                descriptionID: .servicesTrakt
            ) {
                activationFocusHandOff = "trakt"
                trakt.connect()
            }
            .claimsFocusAfterSwap(handOff("trakt:connect"))
            if let error = trakt.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The Simkl section body — same four states as `traktSection`. Simkl uses a PIN code (not
    /// Trakt's device code) but the shared repo publishes the same uiState shape, so the pane logic
    /// mirrors Trakt's exactly.
    ///
    /// Once connected the section also carries the deferred-parity set ported from upstream's
    /// Compose tracking settings: Sync Now, "How syncing works", and the anime ID preference —
    /// the last two gated on CONNECTED exactly as upstream gates its "Simkl features" section.
    /// The attribution footnote below is unconditional (upstream keeps it on the licenses page,
    /// which tvOS doesn't have).
    @ViewBuilder
    private var simklSection: some View {
        if !simkl.credentialsConfigured {
            Text("Simkl isn't configured in this build. Add SIMKL_CLIENT_ID to local.properties, then rebuild the shared framework.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        } else if simkl.isConnected {
            SettingsDestructiveRow(
                title: String(localized: "Disconnect Simkl"),
                subtitle: String(localized: "Connected as \(simkl.username ?? "your Simkl account") \u{00B7} watched history is scrobbled automatically as you play."),
                systemImage: "checkmark.circle.fill",
                descriptionID: .servicesSimkl
            ) {
                confirmingSimklDisconnect = true
            }

            SimklSyncNowRow(
                isSyncing: simkl.isSyncing,
                lastSyncedAt: simkl.lastSyncedAt
            ) {
                simkl.syncNow()
            }

            // Non-destructive failure surface: the row above stays pressable, this is just a
            // caption. A sync that fails fast (no client id in this build, no network) leaves the
            // section fully usable.
            if let syncError = simkl.syncErrorMessage {
                Text(syncError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            SimklSyncInfoRow()

            SettingsPickerRow(
                title: String(localized: "Anime ID Preference"),
                subtitle: String(localized: "Which external ID identifies anime entries. MyAnimeList and Kitsu keep each season separate; IMDB and TVDB group the seasons."),
                selection: Binding(
                    get: { simkl.animeIdPreference },
                    set: { simkl.setAnimeIdPreference($0) }
                ),
                options: SimklAnimeIdOptions.keys,
                descriptionID: .servicesSimklAnimeId,
                label: SimklAnimeIdOptions.name(forKey:)
            )
        } else if let code = simkl.deviceUserCode {
            SimklActivationCard(
                code: code,
                verificationUrl: simkl.deviceVerificationUrl ?? "https://simkl.com/pin/",
                focusHandOff: handOff("simkl")
            ) {
                activationFocusHandOff = "simkl:connect"
                simkl.cancelActivation()
            }
        } else {
            Text("Track what you watch on this Apple TV to your Simkl profile (movies and episodes are marked watched automatically).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: simkl.isLoading ? String(localized: "Requesting code\u{2026}") : String(localized: "Connect Simkl"),
                subtitle: String(localized: "Shows a short code to enter at simkl.com/pin on your phone or computer."),
                systemImage: "antenna.radiowaves.left.and.right",
                descriptionID: .servicesSimkl
            ) {
                activationFocusHandOff = "simkl"
                simkl.connect()
            }
            .claimsFocusAfterSwap(handOff("simkl:connect"))
            if let error = simkl.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }

        // Data-source attribution (upstream's `settings_licenses_attributions_simkl_body`, kept
        // verbatim). Upstream shows it on its Licenses & Attributions page; tvOS has no such page,
        // so the credit lives with the integration it describes and shows in every state — the
        // claim is about the integration, not about being signed in.
        Text("Nuvio connects to Simkl for account authentication, watchlists, watched history, playback progress, and scrobbling. Movie, TV, and anime tracking data is provided by Simkl. Nuvio is not affiliated with or endorsed by Simkl.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)
    }

    /// The MDBList section body: not configured / connected / awaiting approval / disconnected.
    @ViewBuilder
    private var mdblistSection: some View {
        if !mdblist.hasClientId {
            SettingsValueRow(
                title: String(localized: "MDBList"),
                value: String(localized: "Not configured"),
                subtitle: String(localized: "MDBList isn't configured in this build.")
            )
        } else if mdblist.isConnected {
            SettingsDestructiveRow(
                title: String(localized: "Disconnect"),
                subtitle: mdblist.revokeFailed
                    ? String(localized: "Couldn't revoke on MDBList; the local token was removed.")
                    : mdblistConnectedSubtitle,
                systemImage: "checkmark.circle.fill",
                descriptionID: .servicesMdblist
            ) {
                guard !mdblist.isBusy else { return }
                confirmingMdbListDisconnect = true
            }
            // Search & Discover batch (B7, upstream a9797ff8): pick which lists show in the Library.
            SettingsLinkRow(
                title: String(localized: "Library lists"),
                subtitle: String(localized: "Pick which lists show in the Library."),
                systemImage: "list.bullet.rectangle",
                descriptionID: .servicesMdblistLists
            ) {
                MdbListLibraryListsView()
            }
            // While connected, `errorMessage` carries only our own failed call (a disconnect that
            // threw); without this caption the failure was never shown.
            if let error = mdblist.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        } else if mdblist.isAwaitingApproval, let code = mdblist.userCode {
            MdbListActivationCard(
                code: code,
                verificationUrl: mdblist.verificationUrl ?? "https://mdblist.com/device",
                focusHandOff: handOff("mdblist")
            ) {
                activationFocusHandOff = "mdblist:connect"
                mdblist.cancel()
            }
        } else {
            SettingsActionRow(
                title: mdblist.isBusy ? String(localized: "Requesting code\u{2026}") : String(localized: "Connect MDBList"),
                subtitle: String(localized: "Sync your watchlist and history with MDBList."),
                systemImage: "antenna.radiowaves.left.and.right",
                descriptionID: .servicesMdblist
            ) {
                // Not `.disabled(isBusy)`: the pressed row lost focus while the code was requested.
                guard !mdblist.isBusy else { return }
                activationFocusHandOff = "mdblist"
                mdblist.connect()
            }
            .claimsFocusAfterSwap(handOff("mdblist:connect"))
            if let error = mdblist.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    private var mdblistConnectedSubtitle: String {
        let name = mdblist.username ?? String(localized: "your MDBList account")
        return mdblist.isSupporter
            ? String(localized: "Connected as \(name) \u{00B7} Supporter")
            : String(localized: "Connected as \(name)")
    }
}

/// Manual "Sync now" for Simkl (upstream's primary button on the connected provider card).
///
/// Deliberately NOT `.disabled(isSyncing)`: disabling a focused tvOS row throws focus somewhere
/// else mid-sync and then takes it back when the sync ends. The double-press guard lives in
/// `SimklViewModel.syncNow()` instead, so a press during a sync is a harmless no-op.
private struct SimklSyncNowRow: View {
    let isSyncing: Bool
    let lastSyncedAt: Date?
    let action: () -> Void

    /// 15 minutes is `SIMKL_AUTOMATIC_REFRESH_INTERVAL_MINUTES` in the shared refresh policy. That
    /// constant is `internal` in Kotlin, so it isn't in the SharedCore framework header and can't
    /// be read here — if the shared interval ever changes, this copy has to change with it.
    private static let automaticIntervalMinutes = 15

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var subtitle: String {
        if isSyncing {
            return String(localized: "Checking Simkl for changes made in another app or on the website\u{2026}")
        }
        guard let lastSyncedAt else {
            return String(localized: "Check Simkl now instead of waiting for the next automatic check (every \(Self.automaticIntervalMinutes) minutes).")
        }
        let relative = Self.relativeFormatter.localizedString(for: lastSyncedAt, relativeTo: Date())
        return String(localized: "Last synced \(relative) \u{00B7} Nuvio checks on its own at most every \(Self.automaticIntervalMinutes) minutes.")
    }

    var body: some View {
        SettingsActionRow(
            title: isSyncing ? String(localized: "Syncing\u{2026}") : String(localized: "Sync Now"),
            subtitle: subtitle,
            systemImage: "arrow.triangle.2.circlepath",
            descriptionID: .servicesSimklSyncNow,
            action: action
        )
    }
}

/// "How Syncing Works" — upstream's `SimklSyncInfoDialog` adapted to tvOS.
///
/// Rendered as an expanding row rather than an alert: it is four paragraphs of explanation with no
/// decision attached, and a tvOS alert with that much body text is unreadable at 10 feet. The
/// collapsed/expanded header is a kit `SettingsActionRow` that toggles `isExpanded`, with the
/// paragraphs below it as plain body text when expanded — a "few rows" inline sub-flow per the
/// beta.15 §C3 conversion rules, not a pushed page.
///
/// Upstream's "Read the Simkl sync guide" button is dropped: it calls `UriHandler.openUri`, and
/// tvOS has no browser to hand the URL to. The URL is printed instead so it can be opened on a
/// phone — the same escape hatch the activation cards above use for simkl.com/pin.
private struct SimklSyncInfoRow: View {
    @State private var isExpanded = false

    /// Same 15 as `SimklSyncNowRow.automaticIntervalMinutes` (upstream substitutes it into the
    /// dialog's first paragraph).
    private static let automaticIntervalMinutes = 15

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SettingsActionRow(
                title: String(localized: "How Syncing Works"),
                subtitle: String(localized: "What Nuvio sends to Simkl, when it checks back, and why some shows leave Continue Watching."),
                systemImage: "info.circle",
                descriptionID: .servicesSimklSyncInfo
            ) {
                isExpanded.toggle()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Nuvio automatically checks Simkl at most once every \(Self.automaticIntervalMinutes) minutes. Changes made through another app or the Simkl website may take that long to appear.")
                    Text("Each refresh first checks whether Simkl reports any changes and downloads only the updates. This follows Simkl\u{2019}s API rules, reduces unnecessary data use, and helps keep the service stable.")
                    Text("Changes made in Nuvio are sent to Simkl immediately. Use Sync Now whenever you want Nuvio to check for remote changes sooner.")
                    Text("Shows placed in Simkl\u{2019}s On Hold or Dropped lists are hidden from Continue Watching. They remain hidden for as long as they stay in either list.")
                    Text("Full sync guide: api.simkl.org/guides/sync")
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.leading, Theme.Spacing.md)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

/// Anime ID preference options for the `SettingsPickerRow` in `simklSection` — which external ID
/// is the canonical content ID for anime resolved through Simkl (`SimklAnimeIdPreference`).
/// MyAnimeList or Kitsu give each season its own entry; IMDB groups a franchise's seasons under
/// one ID (the trade-off folded into the picker row's subtitle since a tvOS `Menu` item can't
/// carry upstream's per-option descriptions).
private enum SimklAnimeIdOptions {
    static let keys = ["imdb", "mal", "kitsu", "tvdb"]

    private static let names: [String: String] = [
        "imdb": String(localized: "Prefer IMDB"),
        "mal": String(localized: "Prefer MyAnimeList"),
        "kitsu": String(localized: "Prefer Kitsu"),
        "tvdb": String(localized: "Prefer TVDB")
    ]

    static func name(forKey key: String) -> String {
        names[key] ?? key
    }
}

/// Shown while a Trakt device-code flow awaits approval: the big user code, where to enter it,
/// a waiting spinner (the shared repo polls in the background), and a Cancel row.
private struct TraktActivationCard: View {
    let code: String
    let verificationUrl: String
    var focusHandOff: Binding<Bool> = .constant(false)
    let onCancel: () -> Void

    var body: some View {
        // Two List rows, not one: as a single row, focusing Cancel lit the whole card with the
        // focus platter and the instructions went white-on-white (device pass 2026-10-17). The
        // text row has nothing focusable, so it never takes the platter.
        Group {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("On your phone or computer, go to")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(verificationUrl)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("and enter this code:")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(code)
                    .font(Theme.Font.hero.monospaced())
                    .kerning(12)
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.vertical, Theme.Spacing.md)
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Waiting for approval\u{2026} this screen updates automatically.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: String(localized: "Cancel"),
                subtitle: String(localized: "Stop waiting and dismiss the code."),
                systemImage: "xmark.circle",
                descriptionID: .servicesActivationCancel
            ) {
                onCancel()
            }
            .claimsFocusAfterSwap(focusHandOff)
        }
    }
}

/// Shown while a Simkl PIN flow awaits approval: same layout as `TraktActivationCard` (the shared
/// repo publishes the same code/verificationUrl shape), kept as its own sibling struct rather than
/// a shared/generic component — `DebridActivationCard` below establishes that as the precedent for
/// this file, so a provider-specific card doesn't need parameterizing into a generic one.
private struct SimklActivationCard: View {
    let code: String
    let verificationUrl: String
    var focusHandOff: Binding<Bool> = .constant(false)
    let onCancel: () -> Void

    var body: some View {
        // Two List rows, not one: as a single row, focusing Cancel lit the whole card with the
        // focus platter and the instructions went white-on-white (device pass 2026-10-17). The
        // text row has nothing focusable, so it never takes the platter.
        Group {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("On your phone or computer, go to")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(verificationUrl)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("and enter this code:")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(code)
                    .font(Theme.Font.hero.monospaced())
                    .kerning(12)
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.vertical, Theme.Spacing.md)
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Waiting for approval\u{2026} this screen updates automatically.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            SettingsActionRow(
                title: String(localized: "Cancel"),
                subtitle: String(localized: "Stop waiting and dismiss the code."),
                systemImage: "xmark.circle",
                descriptionID: .servicesActivationCancel
            ) {
                onCancel()
            }
            .claimsFocusAfterSwap(focusHandOff)
        }
    }
}
