import Foundation
import SwiftUI
import SharedCore

/// "Account & Profiles" category rows (detail-settings-revamp W2-B): Sign In / Sign Out, the
/// Server section and Remote Setup, moved out of the old Account & Services and Advanced panes.
/// Rows only: `SettingsPaneScaffold` supplies the `List`. Logic and wiring preserved verbatim.
struct AccountProfilesSettingsPane: View {
    @EnvironmentObject private var auth: AuthViewModel
    /// Active backend (official vs self-hosted) for the Server section.
    @StateObject private var server = ActiveServerObserver()
    /// FEAT-65: "Open Last Profile at Launch" (the shared `rememberLastProfileEnabled` flag).
    @StateObject private var lastProfile = RememberLastProfileModel()

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

            // FEAT-65 (Steven, beta.19-rc3 follow-up 2026-10-08: open straight into his profile).
            // Off by default; a PIN profile still shows the picker. The decision is
            // `ProfileAutoEnter`, applied once per cold launch by `ContentView`.
            SettingsSection(String(localized: "Profiles")) {
                SettingsToggleRow(
                    title: String(localized: "Open Last Profile at Launch"),
                    subtitle: String(localized: "Skips the profile picker and opens the profile you used last. Profiles with a PIN still ask for it. Default: Off."),
                    isOn: Binding(get: { lastProfile.enabled }, set: { lastProfile.set($0) }),
                    descriptionID: .accountRememberLastProfile
                )
                .accessibilityIdentifier("account_row_remember_last_profile")
            }

            SettingsSection(String(localized: "Server")) {
                serverSection
            }

            SettingsSection(String(localized: "Remote Setup")) {
                remoteSetupSection
            }
        }
        .onAppear { lastProfile.start() }
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

    /// Add-ons hub v2 C2: Remote Setup lives in the Add-ons hub's "Manage from phone" section now
    /// (it starts when that section opens and stops when it closes). This row only goes there.
    @ViewBuilder
    private var remoteSetupSection: some View {
        SettingsActionRow(
            title: String(localized: "Manage from phone"),
            subtitle: String(localized: "Opens Add-ons › Manage from phone, where a phone or laptop browser can manage add-ons, Home rows, API keys and badge packs."),
            systemImage: "iphone",
            descriptionID: .accountRemoteSetup
        ) {
            AddonsHubRequests.open(.phone)
        }
        .accessibilityIdentifier("settings_manage_from_phone")
    }
}
