import Foundation
import SwiftUI
import SharedCore

/// "Account & Profiles" category rows (detail-settings-revamp W2-B): Sign In / Sign Out, the
/// Server section and Remote Setup, moved out of the old Account & Services and Advanced panes.
/// Rows only: `SettingsPaneScaffold` supplies the `List`. Logic and wiring preserved verbatim.
struct AccountProfilesSettingsPane: View {
    @ObservedObject var remote: RemoteSetupViewModel
    @EnvironmentObject private var auth: AuthViewModel
    /// Active backend (official vs self-hosted) for the Server section.
    @StateObject private var server = ActiveServerObserver()

    /// Drives the shared sign-in/sign-out confirmation alert owned by SettingsView.
    @Binding var confirmingSignOut: Bool
    /// Drives the shared "Use the official server?" confirmation alert owned by SettingsView.
    @Binding var confirmingUseOfficial: Bool

    var body: some View {
        Group {
            SettingsSection(String(localized: "Account")) {
                if auth.isAnonymous {
                    SettingsActionRow(
                        title: String(localized: "Sign In to Nuvio"),
                        subtitle: String(localized: "Sync your library, watch progress, and profiles across devices. Local guest data on this Apple TV will be cleared."),
                        systemImage: "person.crop.circle.badge.plus",
                        descriptionID: .accountSignInOut
                    ) {
                        confirmingSignOut = true
                    }
                } else {
                    SettingsDestructiveRow(
                        title: String(localized: "Sign Out"),
                        subtitle: String(localized: "Signed in as \(auth.accountEmail ?? "your Nuvio account"). Local data on this Apple TV will be cleared."),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        descriptionID: .accountSignInOut
                    ) {
                        confirmingSignOut = true
                    }
                }
            }

            SettingsSection(String(localized: "Server")) {
                serverSection
            }

            SettingsSection(String(localized: "Remote Setup")) {
                remoteSetupSection
            }
        }
    }

    /// The Server section: which backend this Apple TV talks to, plus the self-hosted discovery
    /// entry point and (when on a custom server) the way back to api.nuvio.tv. Both switches are
    /// destructive (sign-out + local wipe) — the "Use Official Server" confirm is a `.alert` on
    /// SettingsView; the connect flow confirms inside `ServerConnectionView`.
    @ViewBuilder
    private var serverSection: some View {
        SettingsValueRow(
            title: String(localized: "Server"),
            value: server.isCustom
                ? server.displayHost
                : String(localized: "Official Nuvio (\(server.displayHost))"),
            systemImage: "server.rack"
        )
        SettingsLinkRow(
            title: server.isCustom
                ? String(localized: "Connect to Another Server")
                : String(localized: "Connect to a Self-Hosted Server"),
            subtitle: String(localized: "Point this Apple TV at a self-hosted Nuvio backend. Switching servers signs you out and clears local data on this Apple TV."),
            systemImage: "network",
            descriptionID: .accountConnectServer
        ) {
            ServerConnectionView()
        }
        if server.isCustom {
            SettingsDestructiveRow(
                title: String(localized: "Use Official Server"),
                subtitle: String(localized: "Switch back to api.nuvio.tv. You\u{2019}ll be signed out and local data on this Apple TV will be cleared."),
                systemImage: "arrow.uturn.backward",
                descriptionID: .accountUseOfficialServer
            ) {
                confirmingUseOfficial = true
            }
        }
    }

    /// The Remote Setup section body: start/stop the LAN config server and, while it runs, show
    /// the URL + QR a phone/laptop browser uses to manage add-ons, Home rows, API keys, and
    /// badge packs. Changes proposed from the browser surface as a confirm alert on SettingsView.
    @ViewBuilder
    private var remoteSetupSection: some View {
        Text("Manage add-ons, Home rows, API keys, and stream badge packs from a phone or laptop browser on the same network \u{2014} no on-screen keyboard. Changes only apply after you confirm them here.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        if let url = remote.serverURL {
            HStack(alignment: .top, spacing: 40) {
                if let qr = remote.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan the code, or open in any browser:")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(url)
                        .font(Theme.Font.screenTitle.monospaced())
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Keep this Settings screen open while you make changes.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            SettingsActionRow(
                title: String(localized: "Stop Remote Setup"),
                subtitle: String(localized: "Closes the local config page."),
                systemImage: "stop.circle",
                descriptionID: .accountRemoteSetup
            ) {
                remote.stop()
            }
        } else {
            SettingsActionRow(
                title: String(localized: "Start Remote Setup"),
                subtitle: remote.startFailed
                    ? String(localized: "Couldn't start the local server. Check the network connection and try again.")
                    : String(localized: "Starts a local config page on your network."),
                systemImage: "network",
                descriptionID: .accountRemoteSetup
            ) {
                remote.start()
            }
        }
    }
}
