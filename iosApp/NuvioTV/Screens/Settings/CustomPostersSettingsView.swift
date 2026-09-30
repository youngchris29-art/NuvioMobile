import Combine
import SwiftUI
import SharedCore

/// Observes `CustomPosterUrlRepository` for the Custom Posters screen. Its own small view model
/// (rather than `SettingsViewModel`) so this screen stays self-contained.
@MainActor
final class CustomPostersViewModel: ObservableObject {
    @Published private(set) var pattern: String = ""
    @Published private(set) var enabledScreens: Set<CustomPosterScreen> = []

    private var patternWatcher: FlowWatcher?
    private var screensWatcher: FlowWatcher?

    static let allScreens: [CustomPosterScreen] = [
        .home, .continueWatching, .collections, .library, .search, .details,
    ]

    func start() {
        guard patternWatcher == nil else { return }
        patternWatcher = FlowWatcherKt.watch(CustomPosterUrlRepository.shared.pattern) { [weak self] emitted in
            guard let self, let value = emitted as? String else { return }
            self.pattern = value
        }
        screensWatcher = FlowWatcherKt.watch(CustomPosterUrlRepository.shared.enabledScreens) { [weak self] emitted in
            guard let self, let set = emitted as? NSSet else { return }
            self.enabledScreens = Set(set.compactMap { $0 as? CustomPosterScreen })
        }
        CustomPosterUrlRepository.shared.ensureLoaded()
    }

    func stop() {
        patternWatcher?.cancel(); patternWatcher = nil
        screensWatcher?.cancel(); screensWatcher = nil
    }

    var hasPattern: Bool { !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func clearPattern() {
        CustomPosterUrlRepository.shared.clearPattern()
    }

    func isEnabled(_ screen: CustomPosterScreen) -> Bool {
        enabledScreens.contains(screen)
    }

    /// The shared resolver reads an EMPTY enabled set as "all screens" (`fromKeys`), so turning
    /// off the last enabled screen would silently turn everything back on. Refuse that switch-off
    /// and re-publish the current set so the toggle snaps back to on.
    func setEnabled(_ screen: CustomPosterScreen, _ enabled: Bool) {
        if !enabled, enabledScreens.contains(screen), enabledScreens.count <= 1 {
            let current = enabledScreens
            enabledScreens = current
            objectWillChange.send()
            return
        }
        CustomPosterUrlRepository.shared.setScreenEnabled(screen: screen, enabled: enabled)
    }

    deinit {
        patternWatcher?.cancel()
        screensWatcher?.cancel()
    }
}

/// Settings > Appearance > Custom Posters. The URL pattern is never typed on the TV: it arrives
/// through profile-settings sync from the mobile app or through Remote Setup on a phone. The
/// screen shows it read-only, offers Clear, and carries six per-screen toggles (which also
/// guarantee the screen always has a focusable control).
struct CustomPostersSettingsView: View {
    @StateObject private var model = CustomPostersViewModel()
    /// Own Remote Setup instance: the Settings-wide one lives in `SettingsView` and is not
    /// reachable from a pushed screen. Started on demand, stopped when this screen goes away.
    @StateObject private var remote = RemoteSetupViewModel()

    private static func title(for screen: CustomPosterScreen) -> String {
        switch screen {
        case .home: return String(localized: "Home")
        case .continueWatching: return String(localized: "Continue Watching")
        case .collections: return String(localized: "Collections")
        case .library: return String(localized: "Library")
        case .search: return String(localized: "Search")
        default: return String(localized: "Details")
        }
    }

    var body: some View {
        List {
            SettingsSection(
                String(localized: "Pattern"),
                footer: String(localized: "Set the pattern from your phone with Remote Setup, or it syncs from the mobile app. Placeholders such as {id}, {type} and {shape} are replaced for each title. When the service has no artwork, the original poster is shown.")
            ) {
                SettingsValueRow(
                    title: String(localized: "Poster URL Pattern"),
                    value: model.hasPattern ? model.pattern : String(localized: "Not set")
                )
                .lineLimit(3)
                .truncationMode(.middle)
                SettingsActionRow(
                    title: String(localized: "Set from Your Phone\u{2026}"),
                    subtitle: String(localized: "Opens a config page you can use from a phone on the same network."),
                    systemImage: "iphone"
                ) {
                    remote.start()
                }
                if remote.serverURL != nil || remote.startFailed {
                    remoteDetails
                }
                SettingsDestructiveRow(
                    title: String(localized: "Clear Pattern"),
                    systemImage: "trash"
                ) {
                    model.clearPattern()
                }
                .disabled(!model.hasPattern)
            }

            SettingsSection(
                String(localized: "Apply To"),
                footer: String(localized: "At least one screen must stay on.")
            ) {
                ForEach(CustomPostersViewModel.allScreens, id: \.self) { screen in
                    SettingsToggleRow(
                        title: Self.title(for: screen),
                        isOn: Binding(
                            get: { model.isEnabled(screen) },
                            set: { model.setEnabled(screen, $0) }
                        )
                    )
                }
            }
        }
        .navigationTitle(String(localized: "Custom Posters"))
        .onAppear { model.start() }
        .onDisappear {
            model.stop()
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
    }

    @ViewBuilder
    private var remoteDetails: some View {
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
                        .foregroundStyle(.secondary)
                    Text(url)
                        .font(Theme.Font.caption.monospaced())
                    Text("Keep this screen open while you make changes.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsActionRow(
                title: String(localized: "Stop Remote Setup"),
                subtitle: String(localized: "Closes the local config page."),
                systemImage: "stop.circle"
            ) {
                remote.stop()
            }
        } else if remote.startFailed {
            Text("Couldn't start the local server. Check the network connection and try again.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}
