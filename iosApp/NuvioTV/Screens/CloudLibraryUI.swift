import Combine
import SwiftUI
import SharedCore

/// Debrid cloud library (TorBox / Premiumize cloud files) for the Library tab, backed by the
/// shared `CloudLibraryRepository`. Lists each connected provider's cloud items; selecting a
/// playable file resolves a direct link via `resolvePlayback(item:file:)` and hands a
/// `PlaybackContext` to the standard MPV player.
///
/// Playback keying mirrors mobile (`App.kt` cloud launch): contentType = "cloud",
/// videoId = "\(item.stableKey):\(file.stableKey)" (shared `playbackVideoId` format),
/// parentMetaId = item.stableKey — so watch progress and resume work like any other title.
@MainActor
final class CloudLibraryViewModel: ObservableObject {
    @Published private(set) var state: CloudLibraryUiState?
    /// stableKey of the file currently resolving (spinner on that row; taps ignored meanwhile).
    @Published private(set) var resolvingFileKey: String?
    @Published private(set) var errorMessage: String?
    /// Set when a link resolves — drives the player cover.
    @Published var playback: PlaybackContext?

    private var watcher: FlowWatcher?

    /// W3b (spec 9.1.4, BUG-257): the profile's Cloud-capable providers, read from the repository on
    /// the call's identity at `start()` and on every listing emission, so the chips show at Library
    /// open, before a listing is published.
    @Published private(set) var configured: [DebridProvider] = []
    private let configuredProviders: () -> [DebridProvider]

    #if DEBUG
    /// Pre-cut follow-ups GC: `-debug.libraryCloudFixture YES` gives the Library one synthetic
    /// connected provider with two items, so the source chips draw on the simulator (no debrid key
    /// there). In fixture mode nothing reaches `CloudLibraryRepository`: no subscription, no
    /// `ensureLoaded`, and Refresh and play are no-ops.
    let isFixture: Bool

    init(isFixture: Bool = CloudLibraryDebugFixture.isOn,
         configuredProviders: @escaping () -> [DebridProvider] = { CloudLibraryRepository.shared.configuredProviders() }) {
        self.isFixture = isFixture
        self.configuredProviders = configuredProviders
    }
    #else
    init(configuredProviders: @escaping () -> [DebridProvider] = { CloudLibraryRepository.shared.configuredProviders() }) {
        self.configuredProviders = configuredProviders
    }
    #endif

    func start() {
        #if DEBUG
        if isFixture {
            if state == nil { state = CloudLibraryDebugFixture.state() }
            return
        }
        #endif
        configured = configuredProviders()
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(CloudLibraryRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? CloudLibraryUiState else { return }
            self.state = value
            self.configured = self.configuredProviders()
        }
        CloudLibraryRepository.shared.ensureLoaded()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func refresh() {
        #if DEBUG
        if isFixture { return }
        #endif
        CloudLibraryRepository.shared.refresh()
    }

    deinit { watcher?.cancel() }

    /// The listing's providers, plus a loading section for each configured provider the listing does
    /// not carry yet (W3b: the existing loading style until its listing is published).
    var providers: [CloudLibraryProviderState] {
        Self.displayedProviders(listed: state?.providers ?? [], configured: configured, isLoaded: state?.isLoaded ?? false)
    }

    /// Review r3 #2: placeholders only while nothing is loaded. Once the repository reports loaded
    /// (a listing, including a provider's failure state), a
    /// missing provider shows no spinner, so the screen never spins with nothing in flight. Pure.
    nonisolated static func displayedProviders(listed: [CloudLibraryProviderState],
                                               configured: [DebridProvider],
                                               isLoaded: Bool) -> [CloudLibraryProviderState] {
        guard !isLoaded else { return listed }
        let pending = configured
            .filter { provider in !listed.contains { $0.providerId == provider.id } }
            .map { CloudLibraryProviderState(provider: $0, isLoading: true, errorMessage: nil, items: []) }
        return listed + pending
    }

    var hasConnectedProvider: Bool {
        #if DEBUG
        if isFixture { return state?.hasConnectedProvider ?? false }
        #endif
        return !configured.isEmpty
    }
    var isRefreshing: Bool { state?.isRefreshing ?? false }

    func play(item: CloudLibraryItem, file: CloudLibraryFile) {
        #if DEBUG
        if isFixture { return }
        #endif
        guard resolvingFileKey == nil else { return }
        resolvingFileKey = file.stableKey
        errorMessage = nil

        CloudLibraryRepository.shared.resolvePlayback(item: item, file: file) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvingFileKey = nil

                if let success = result as? CloudLibraryPlaybackResultSuccess {
                    self.startPlayback(item: item, file: file, success: success)
                } else if result is CloudLibraryPlaybackResultMissingCredentials {
                    self.errorMessage = String(localized: "Missing provider credentials \u{2014} reconnect in Settings \u{2192} Services \u{2192} Debrid.")
                } else if result is CloudLibraryPlaybackResultNotPlayable {
                    self.errorMessage = String(localized: "This file isn't playable.")
                } else if let failed = result as? CloudLibraryPlaybackResultFailed {
                    let message: String? = failed.message
                    self.errorMessage = message ?? String(localized: "Couldn't resolve a playback link.")
                } else {
                    self.errorMessage = error?.localizedDescription ?? String(localized: "Couldn't resolve a playback link.")
                }
            }
        }
    }

    private func startPlayback(item: CloudLibraryItem, file: CloudLibraryFile, success: CloudLibraryPlaybackResultSuccess) {
        guard let url = URL(string: success.url) else {
            errorMessage = String(localized: "The provider returned an unplayable link.")
            return
        }
        let filename: String? = success.filename
        let fallbackName = file.name.isEmpty ? item.name : file.name
        let title = (filename?.isEmpty == false ? filename : nil) ?? fallbackName

        playback = PlaybackContext(
            url: url,
            title: title,
            contentType: CloudLibraryModelsKt.CloudLibraryContentType,
            parentMetaId: item.stableKey,
            videoId: "\(item.stableKey):\(file.stableKey)",
            season: nil,
            episode: nil,
            poster: CloudLibraryModelsKt.cloudLibraryProviderPosterUrl(providerIdOrContentId: item.providerId),
            background: nil,
            providerName: item.providerName,
            providerAddonId: "cloud:\(item.providerId)",
            streamTitle: title,
            streamSubtitle: item.name == title ? nil : item.name,
            externalSubtitles: []
        )
    }
}

#if DEBUG
/// Pre-cut follow-ups GC: the Library's DEBUG cloud fixture (one provider, two items), for the
/// filter bar's chip UI leg. Synthetic data only; never in a Release build.
enum CloudLibraryDebugFixture {
    /// `-debug.libraryCloudFixture YES`.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "debug.libraryCloudFixture") }

    static func state() -> CloudLibraryUiState {
        let provider = DebridProvider(
            id: "fixture-cloud",
            displayName: "Fixture Cloud",
            shortName: "FX",
            visibleInUi: true,
            authMethod: .apikey,
            capabilities: []
        )
        let items = (1...2).map { n in
            CloudLibraryItem(
                providerId: provider.id,
                providerName: provider.displayName,
                id: "fx-cloud-\(n)",
                type: .file,
                name: "Fixture Cloud File \(n)",
                status: nil,
                sizeBytes: nil,
                progressFraction: nil,
                files: [CloudLibraryFile(id: "fx-cloud-\(n)-file", name: "Fixture Cloud File \(n).mkv", sizeBytes: nil,
                                         mimeType: nil, playable: true, playbackUrl: nil)]
            )
        }
        return CloudLibraryUiState(
            isLoaded: true,
            isEnabled: true,
            isRefreshing: false,
            providers: [CloudLibraryProviderState(provider: provider, isLoading: false, errorMessage: nil, items: items)]
        )
    }
}
#endif

/// Identifiable wrapper so a multi-file item can drive a `.fullScreenCover(item:)` file picker.
struct CloudFilePickerRoute: Identifiable {
    let item: CloudLibraryItem
    var id: String { item.stableKey }
}

/// One provider's cloud items as a titled section of focusable rows.
struct CloudProviderSection: View {
    let provider: CloudLibraryProviderState
    let resolvingFileKey: String?
    let onSelect: (CloudLibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Text(provider.providerName)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if provider.isLoading {
                    ProgressView()
                }
            }

            if let error = providerError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.red)
            }

            if provider.items.isEmpty && !provider.isLoading {
                Text("No files in your \(provider.providerName) cloud.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(provider.items, id: \.stableKey) { item in
                        CloudItemRow(
                            item: item,
                            isResolving: isResolving(item)
                        ) {
                            onSelect(item)
                        }
                    }
                }
            }
        }
    }

    private var providerError: String? {
        let message: String? = provider.errorMessage
        return message
    }

    private func isResolving(_ item: CloudLibraryItem) -> Bool {
        guard let resolvingFileKey else { return false }
        return item.playableFiles.contains { $0.stableKey == resolvingFileKey }
    }
}

/// One cloud item (torrent/usenet/web download) as a focusable row: name, size, status, file count.
struct CloudItemRow: View {
    let item: CloudLibraryItem
    let isResolving: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: iconName)
                    .font(Theme.Font.body)
                    .rowAccentTint()
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.name)
                        .font(Theme.Font.body)
                        .rowTextColor()
                        .lineLimit(2)
                    Text(detailLine)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isResolving {
                    ProgressView()
                } else if !item.playableFiles.isEmpty {
                    Image(systemName: "play.circle")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
        .disabled(item.playableFiles.isEmpty)
    }

    private var iconName: String {
        // Kotlin enum instances — compare with ==, don't pattern-match (proven codebase pattern).
        if item.type == CloudLibraryItemType.torrent { return "arrow.down.circle" }
        if item.type == CloudLibraryItemType.usenet { return "shippingbox" }
        if item.type == CloudLibraryItemType.webdownload { return "globe" }
        return "doc"
    }

    private var detailLine: String {
        var parts: [String] = []
        if let size = item.sizeBytes?.int64Value, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        let playableCount = item.playableFiles.count
        if playableCount > 1 {
            parts.append(String(localized: "\(playableCount) playable files"))
        } else if playableCount == 0 {
            parts.append(String(localized: "No playable files"))
        }
        let status: String? = item.status
        if let status, !status.isEmpty {
            parts.append(status)
        }
        if let progress = item.progressFraction?.floatValue, progress < 1.0 {
            parts.append("\(Int(progress * 100))%")
        }
        return parts.isEmpty ? item.providerName : parts.joined(separator: " \u{00B7} ")
    }
}

/// Full-screen chooser for multi-file items: pick which file to play.
struct CloudFilePickerView: View {
    let item: CloudLibraryItem
    let onPick: (CloudLibraryFile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(item.name)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                Text("Choose a file to play")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(item.playableFiles.enumerated()), id: \.element.stableKey) { _, file in
                        Button {
                            dismiss()
                            onPick(file)
                        } label: {
                            HStack(spacing: Theme.Spacing.lg) {
                                Image(systemName: "play.circle")
                                    .rowAccentTint()
                                Text(file.name)
                                    .font(Theme.Font.body)
                                    .rowTextColor()
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if let size = file.sizeBytes?.int64Value, size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(Theme.Font.caption)
                                        .rowTextColor(secondary: true)
                                }
                            }
                            .padding(Theme.Spacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.settingsRow)
                    }
                }
            }
            .padding(Theme.Spacing.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background.ignoresSafeArea())
    }
}
