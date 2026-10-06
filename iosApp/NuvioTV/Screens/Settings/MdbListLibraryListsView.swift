import Combine
import SwiftUI
import SharedCore

/// Pure rules for the MDBList "Library lists" page (upstream a9797ff8).
nonisolated enum MdbListLibraryListsPolicy {
    /// The shared Watchlist key. `listOptions` already leaves the Watchlist out; this keeps the
    /// page correct if that ever changes, because the Watchlist can never be hidden.
    static let watchlistKey = "mdblist:watchlist"

    static func rows(_ options: [MdbListLibraryListOption]) -> [MdbListLibraryListOption] {
        options.filter { $0.key != watchlistKey }
    }

    static func summary(shown: Int, total: Int) -> String {
        String(format: String(localized: "%lld of %lld shown"), shown, total)
    }

    /// Review r2 P3-3: a `listOptions` emission that lands while a toggle is in flight carries
    /// the old value; the pending (optimistic) value wins until the shared service answers.
    static func applying(
        pending: [String: Bool],
        to options: [MdbListLibraryListOption]
    ) -> [MdbListLibraryListOption] {
        guard !pending.isEmpty else { return options }
        return options.map { option in
            guard let visible = pending[option.key], visible != option.visible else { return option }
            return MdbListLibraryListOption(key: option.key, name: option.name, visible: visible)
        }
    }

    /// Review r2 P3-2: the shared service passes `require`'s English text through
    /// (`mdbListListVisibilityFailureMessage`); the one text it can send is localized here.
    /// Empty → the generic failure copy.
    static func failureCopy(_ message: String) -> String {
        switch message.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": return String(localized: "Couldn't update this list. Try again.")
        case "This list is no longer available": return String(localized: "This list is no longer available")
        default: return message
        }
    }
}

@MainActor
final class MdbListLibraryListsViewModel: ObservableObject {
    @Published private(set) var options: [MdbListLibraryListOption] = []
    @Published var errorMessage: String?

    private var watcher: FlowWatcher?
    /// Keys whose toggle is in flight → the optimistic value (review r2 P3-3).
    private var pendingKeys: [String: Bool] = [:]
    /// Per-key generation: each `setVisible` call captures its own number, so an A→B→A toggle
    /// inside one round trip cannot let the first call clear or revert the third (review r3).
    private var pendingGeneration: [String: Int] = [:]

    var rows: [MdbListLibraryListOption] { MdbListLibraryListsPolicy.rows(options) }

    func start() {
        guard watcher == nil else { return }
        MdbListTracker.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        // `listOptions` is a plain Flow (a `map` over the snapshot StateFlow), so it takes the
        // Flow overload; the first value arrives once the snapshot has loaded.
        watcher = FlowWatcherKt.watchFlow(MdbListTracker.shared.library.listOptions) { [weak self] emitted in
            guard let list = emitted as? [MdbListLibraryListOption] else { return }
            Task { @MainActor in
                guard let self else { return }
                self.options = MdbListLibraryListsPolicy.applying(pending: self.pendingKeys, to: list)
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func isVisible(_ key: String) -> Bool {
        options.first { $0.key == key }?.visible ?? true
    }

    /// Optimistic: flips locally, then asks the shared service. A failure puts the old value back
    /// and shows the message. While the call is in flight the key's value is held in
    /// `pendingKeys`, so a concurrent `listOptions` emission cannot flick the switch back.
    func setVisible(key: String, visible: Bool) {
        guard let index = options.firstIndex(where: { $0.key == key }) else { return }
        let previous = options[index]
        errorMessage = nil
        pendingKeys[key] = visible
        let generation = (pendingGeneration[key] ?? 0) &+ 1
        pendingGeneration[key] = generation
        options[index] = MdbListLibraryListOption(key: previous.key, name: previous.name, visible: visible)
        MdbListTracker.shared.library.setListVisibilityAsync(key: key, visible: visible) { [weak self] (message: String?) in
            Task { @MainActor in
                guard let self else { return }
                // A newer toggle of the same key owns the override (and its own revert): compare
                // the captured generation, not the value, so A→B→A is told apart from A.
                guard self.pendingGeneration[key] == generation else { return }
                self.pendingKeys[key] = nil
                self.pendingGeneration[key] = nil
                guard let message else { return }
                if let i = self.options.firstIndex(where: { $0.key == key }) {
                    self.options[i] = MdbListLibraryListOption(key: previous.key, name: previous.name, visible: previous.visible)
                }
                self.errorMessage = MdbListLibraryListsPolicy.failureCopy(message)
            }
        }
    }
}

/// Settings > Services > MDBList > Library lists: one switch per list (the Watchlist is not
/// listed, it is always shown).
struct MdbListLibraryListsView: View {
    @StateObject private var model = MdbListLibraryListsViewModel()

    var body: some View {
        let rows = model.rows
        List {
            SettingsSection(
                String(localized: "Library lists"),
                footer: rows.isEmpty ? nil : MdbListLibraryListsPolicy.summary(
                    shown: rows.filter(\.visible).count,
                    total: rows.count
                )
            ) {
                if rows.isEmpty {
                    Text("No lists found in your MDBList account yet. Sync to load them.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                } else {
                    ForEach(rows, id: \.key) { option in
                        SettingsToggleRow(
                            title: option.name,
                            isOn: Binding(
                                get: { model.isVisible(option.key) },
                                set: { model.setVisible(key: option.key, visible: $0) }
                            )
                        )
                        .accessibilityIdentifier("mdblist.list.\(option.key)")
                    }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .navigationTitle(String(localized: "Library lists"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
