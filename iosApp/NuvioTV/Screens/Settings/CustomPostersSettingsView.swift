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

    /// "All off" is a legitimate, syncable state (the shared side stores it as a "none" sentinel),
    /// so the last toggle is allowed to turn off.
    func setEnabled(_ screen: CustomPosterScreen, _ enabled: Bool) {
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
                    value: model.hasPattern ? CustomPosterPatternMask.masked(model.pattern) : String(localized: "Not set")
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

            SettingsSection(String(localized: "Apply To")) {
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

/// Display-only masking of a poster URL pattern: the TV never shows an API key the phone page
/// deliberately never echoes. Pure, so it is unit-tested (`CustomPosterPatternMaskTests`).
///
/// Rule: the scheme and host are never touched. Any path segment that has no `{placeholder}` and is
/// at least 16 characters of letters, digits, `-` or `_` is replaced by `\u{2022}\u{2022}\u{2022}\u{2022}`;
/// in the query, values of key-like parameter names (`key`, `apikey`, `api_key`, `token`, `secret`)
/// and values that look like a key by the same 16-character rule are masked too. Placeholders such
/// as `{id}` stay visible.
enum CustomPosterPatternMask {
    static let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
    private static let keyParams: Set<String> = ["key", "apikey", "api_key", "token", "secret"]

    static func masked(_ pattern: String) -> String {
        guard let schemeEnd = pattern.range(of: "://") else { return pattern }
        let restStart = pattern[schemeEnd.upperBound...]
            .firstIndex(where: { "/?#".contains($0) }) ?? pattern.endIndex
        let head = String(pattern[..<restStart])
        let rest = String(pattern[restStart...])

        let tailStart = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let path = String(rest[..<tailStart])
        let tail = String(rest[tailStart...])

        let maskedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { looksLikeKey(String($0)) ? mask : String($0) }
            .joined(separator: "/")

        var maskedTail = tail
        if tail.hasPrefix("?") {
            let fragmentStart = tail.firstIndex(of: "#") ?? tail.endIndex
            let query = String(tail[tail.index(after: tail.startIndex)..<fragmentStart])
            let fragment = String(tail[fragmentStart...])
            let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
                let name = String(pair[..<eq])
                let value = String(pair[pair.index(after: eq)...])
                let hide = !value.contains("{")
                    && !value.isEmpty
                    && (keyParams.contains(name.lowercased()) || looksLikeKey(value))
                return hide ? "\(name)=\(mask)" : String(pair)
            }
            maskedTail = "?" + pairs.joined(separator: "&") + fragment
        }
        return head + maskedPath + maskedTail
    }

    private static func looksLikeKey(_ segment: String) -> Bool {
        guard segment.count >= 16, !segment.contains("{") else { return false }
        return segment.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }
}
