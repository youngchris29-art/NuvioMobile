import SwiftUI
import SharedCore

/// "Account & Services" category content: Sign In/Out, Trakt scrobbling, and Debrid resolver
/// connections. Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and
/// wiring preserved verbatim, only regrouped into a per-category pane.
struct AccountServicesSettingsPane: View {
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var debrid: DebridViewModel
    @EnvironmentObject private var auth: AuthViewModel

    /// Drives the shared sign-in/sign-out confirmation alert owned by SettingsView.
    @Binding var confirmingSignOut: Bool
    /// Drives the shared Trakt-disconnect confirmation alert owned by SettingsView.
    @Binding var confirmingTraktDisconnect: Bool
    /// Provider id pending a debrid disconnect confirmation (drives the alert owned by SettingsView).
    @Binding var debridDisconnectId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
            settingsSection(String(localized: "Account")) {
                if auth.isAnonymous {
                    SettingsActionRow(
                        title: String(localized: "Sign In to Nuvio"),
                        subtitle: String(localized: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared."),
                        systemImage: "person.crop.circle.badge.plus"
                    ) {
                        confirmingSignOut = true
                    }
                } else {
                    SettingsActionRow(
                        title: String(localized: "Sign Out"),
                        subtitle: String(localized: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared."),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    ) {
                        confirmingSignOut = true
                    }
                }
            }

            settingsSection(String(localized: "Trakt")) {
                traktSection
            }

            settingsSection(String(localized: "Debrid")) {
                debridSection
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
            SettingsActionRow(
                title: String(localized: "Disconnect Trakt"),
                subtitle: String(localized: "Connected as \(trakt.username ?? "your Trakt account") \u{00B7} watched history is scrobbled automatically as you play."),
                systemImage: "checkmark.circle.fill"
            ) {
                confirmingTraktDisconnect = true
            }
        } else if let code = trakt.deviceUserCode {
            TraktActivationCard(
                code: code,
                verificationUrl: trakt.deviceVerificationUrl ?? "https://trakt.tv/activate"
            ) {
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
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                trakt.connect()
            }
            if let error = trakt.errorMessage {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Debrid (native TorBox/Premiumize resolution via the shared debrid stack)

    @ViewBuilder
    private var debridSection: some View {
        Text("Connect a debrid service to resolve cached torrent results into direct streaming links on this Apple TV \u{2014} no pre-configured addon URL needed. Keys are per profile and sync between Apple TVs.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        ForEach(debrid.providers, id: \.id) { provider in
            debridProviderRows(provider)
        }

        if debrid.hasAnyKey {
            SettingsToggleRow(
                title: String(localized: "Resolve Streams with Debrid"),
                subtitle: String(localized: "Turn cached torrent results into direct links automatically"),
                isOn: debrid.resolverEnabled
            ) {
                debrid.setResolverEnabled(!debrid.resolverEnabled)
            }
        }

        if debrid.resolverProviders.count > 1 {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Preferred resolver")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(debrid.resolverProviders, id: \.id) { provider in
                        Button {
                            debrid.setPreferredResolver(provider.id)
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                if debrid.activeResolverId == provider.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(provider.displayName)
                            }
                            .font(Theme.Font.meta)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.chip(selected: debrid.activeResolverId == provider.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func debridProviderRows(_ provider: DebridProvider) -> some View {
        if debrid.isConnected(provider.id) {
            // Session-expired beats Connected (BUG-21 follow-up): the stored token failed auth
            // on a real provider call or the pane-open revalidation. Same disconnect action —
            // reconnecting mints a fresh token, which is the entire fix.
            if debrid.authFailedIds.contains(provider.id) {
                SettingsActionRow(
                    title: String(localized: "\(provider.displayName) \u{00B7} Session expired"),
                    subtitle: String(localized: "\(provider.displayName) rejected the saved sign-in. Press to disconnect, then connect again."),
                    systemImage: "exclamationmark.triangle.fill"
                ) {
                    debridDisconnectId = provider.id
                }
            } else {
                SettingsActionRow(
                    title: String(localized: "\(provider.displayName) \u{00B7} Connected"),
                    subtitle: debrid.activeResolverId == provider.id
                        ? String(localized: "Active resolver \u{00B7} press to disconnect")
                        : String(localized: "Press to disconnect"),
                    systemImage: "checkmark.circle.fill"
                ) {
                    debridDisconnectId = provider.id
                }
            }
        } else if debrid.authProviderId == provider.id {
            switch debrid.authPhase {
            case .starting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Requesting a sign-in code from \(provider.displayName)\u{2026}")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            case .waiting:
                if let session = debrid.activeSession {
                    DebridActivationCard(
                        providerName: provider.displayName,
                        code: session.userCode,
                        verificationUrl: session.friendlyVerificationUrl
                    ) {
                        debrid.cancelActivation()
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1100, alignment: .leading)
                SettingsActionRow(
                    title: String(localized: "Dismiss"),
                    subtitle: String(localized: "Back to the connect options for \(provider.displayName)."),
                    systemImage: "xmark.circle"
                ) {
                    debrid.cancelActivation()
                }
            case .idle:
                EmptyView()
            }
        } else {
            SettingsActionRow(
                title: String(localized: "Connect \(provider.displayName)"),
                subtitle: String(localized: "Shows a short code to enter on your phone (device sign-in)."),
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                debrid.connect(provider)
            }
            DebridKeyEntryRow(providerName: provider.displayName) { key in
                debrid.saveManualKey(provider.id, key: key)
            }
        }
    }
}

/// Shown while a Trakt device-code flow awaits approval: the big user code, where to enter it,
/// a waiting spinner (the shared repo polls in the background), and a Cancel row.
private struct TraktActivationCard: View {
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
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
            SettingsActionRow(
                title: String(localized: "Cancel"),
                subtitle: String(localized: "Stop waiting and dismiss the code."),
                systemImage: "xmark.circle"
            ) {
                onCancel()
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

/// Shown while a debrid device-code flow awaits approval (mirrors `TraktActivationCard`).
private struct DebridActivationCard: View {
    let providerName: String
    let code: String
    let verificationUrl: String
    let onCancel: () -> Void

    var body: some View {
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
                Text("Waiting for \(providerName) approval\u{2026} this screen updates automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            SettingsActionRow(
                title: String(localized: "Cancel"),
                subtitle: String(localized: "Stop waiting and dismiss the code."),
                systemImage: "xmark.circle"
            ) {
                onCancel()
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }
}
