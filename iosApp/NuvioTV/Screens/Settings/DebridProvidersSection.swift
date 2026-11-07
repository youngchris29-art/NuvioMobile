import Foundation
import SwiftUI
import SharedCore

/// The Debrid section's body (native TorBox/Premiumize resolution via the shared debrid stack),
/// moved out of `ServicesSettingsPane` so the Add-ons hub can host it too. The pane wraps it in
/// `SettingsSection("Debrid")`; the disconnect alert stays owned by `SettingsView` through
/// `debridDisconnectId`.
struct DebridProvidersSection: View {
    @ObservedObject var debrid: DebridViewModel
    /// Provider id pending a debrid disconnect confirmation (drives the alert owned by SettingsView).
    @Binding var debridDisconnectId: String?
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

    // MARK: - Debrid (native TorBox/Premiumize resolution via the shared debrid stack)

    var body: some View {
        Group {
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
                    isOn: Binding(
                        get: { debrid.resolverEnabled },
                        set: { debrid.setResolverEnabled($0) }
                    ),
                    descriptionID: .servicesDebridResolve
                )
            }

            if debrid.hasAnyKey, debrid.resolverEnabled {
                SettingsPickerRow(
                    title: String(localized: "Prepare Links for Instant Playback"),
                    subtitle: String(localized: "Resolve the top cached sources to direct links while a source list is open, so Play starts at once."),
                    selection: Binding(get: { debrid.prepareLimit }, set: { debrid.setPrepareLimit($0) }),
                    options: [0, 1, 2, 3, 4, 5],
                    descriptionID: .servicesDebridPrepare,
                    label: Self.prepareLimitLabel
                )
                Text("Use a lower count when possible. Debrid services rate-limit how many links can be resolved in a time period, and opening a source list can count toward those limits even if you do not press Play, because the links are prepared ahead of time.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            if debrid.resolverProviders.count > 1 {
                SettingsPickerRow(
                    title: String(localized: "Preferred resolver"),
                    selection: Binding(
                        get: { debrid.activeResolverId ?? debrid.resolverProviders[0].id },
                        set: { debrid.setPreferredResolver($0) }
                    ),
                    options: debrid.resolverProviders.map(\.id),
                    descriptionID: .servicesDebridResolver,
                    label: { id in
                        debrid.resolverProviders.first { $0.id == id }?.displayName ?? id
                    }
                )
            }
        }
        // BUG-21 follow-up: verify each connected provider's stored credential the moment the
        // pane opens, so an expired token reads "Session expired" instead of "Connected".
        .onAppear { debrid.revalidateConnected() }
    }

    private static func prepareLimitLabel(_ n: Int) -> String {
        switch n {
        case 0: return String(localized: "Off")
        case 1: return String(localized: "1 link")
        default: return String(localized: "\(n) links")
        }
    }

    @ViewBuilder
    private func debridProviderRows(_ provider: DebridProvider) -> some View {
        if debrid.isConnected(provider.id) {
            // BUG-213 hand-off: this row replaces the key field and Save rows after a manual Save
            // (and claims focus then); pressing it arms the key field for after a confirmed
            // Disconnect. The disconnect goes through SettingsView's alert, so a Cancel there must
            // disarm it: the row is still here after a Cancel, and a confirmed Disconnect has
            // removed the provider's key by the time the check runs (the settings watcher hops to
            // the main queue once; the check waits half a second).
            Group {
                // Session-expired beats Connected (BUG-21 follow-up): the stored token failed auth
                // on a real provider call or the pane-open revalidation. Same disconnect action —
                // reconnecting mints a fresh token, which is the entire fix.
                if debrid.authFailedIds.contains(provider.id) {
                    SettingsDestructiveRow(
                        title: String(localized: "\(provider.displayName) \u{00B7} Session expired"),
                        subtitle: String(localized: "\(provider.displayName) rejected the saved sign-in. Press to disconnect, then connect again."),
                        systemImage: "exclamationmark.triangle.fill",
                        descriptionID: .servicesDebridProvider
                    ) {
                        activationFocusHandOff = "debrid:\(provider.id):key"
                        debridDisconnectId = provider.id
                    }
                } else {
                    SettingsDestructiveRow(
                        title: String(localized: "\(provider.displayName) \u{00B7} Connected"),
                        subtitle: debrid.activeResolverId == provider.id
                            ? String(localized: "Active resolver \u{00B7} press to disconnect")
                            : String(localized: "Press to disconnect"),
                        systemImage: "checkmark.circle.fill",
                        descriptionID: .servicesDebridProvider
                    ) {
                        activationFocusHandOff = "debrid:\(provider.id):key"
                        debridDisconnectId = provider.id
                    }
                }
            }
            .claimsFocusAfterSwap(handOff("debrid:\(provider.id):connected"))
            .onChange(of: debridDisconnectId) { old, new in
                guard old == provider.id, new == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if debrid.isConnected(provider.id), activationFocusHandOff == "debrid:\(provider.id):key" {
                        activationFocusHandOff = nil
                    }
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
                        verificationUrl: session.friendlyVerificationUrl,
                        focusHandOff: handOff("debrid:\(provider.id)")
                    ) {
                        activationFocusHandOff = "debrid:\(provider.id):connect"
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
                    systemImage: "xmark.circle",
                    descriptionID: .servicesDebridDismiss
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
                systemImage: "antenna.radiowaves.left.and.right",
                descriptionID: .servicesDebridProvider
            ) {
                activationFocusHandOff = "debrid:\(provider.id)"
                debrid.connect(provider)
            }
            .claimsFocusAfterSwap(handOff("debrid:\(provider.id):connect"))
            // BUG-213 hand-off, both directions: Save swaps these rows for the Connected row (which
            // then takes focus), and a confirmed Disconnect swaps them back (the key field takes
            // it). `saveManualKey` ignores a blank key, so nothing is armed for one.
            DebridKeyEntryRow(
                providerName: provider.displayName,
                descriptionID: .servicesDebridKey,
                fieldFocusHandOff: handOff("debrid:\(provider.id):key")
            ) { key in
                if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    activationFocusHandOff = "debrid:\(provider.id):connected"
                }
                debrid.saveManualKey(provider.id, key: key)
            }
        }
    }
}

/// Shown while a debrid device-code flow awaits approval (mirrors `TraktActivationCard`).
private struct DebridActivationCard: View {
    let providerName: String
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
                    Text("Waiting for \(providerName) approval\u{2026} this screen updates automatically.")
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
