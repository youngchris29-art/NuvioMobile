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
}

@MainActor
final class MdbListLibraryListsViewModel: ObservableObject {
    @Published private(set) var options: [MdbListLibraryListOption] = []
    @Published var errorMessage: String?

    private var watcher: FlowWatcher?

    var rows: [MdbListLibraryListOption] { MdbListLibraryListsPolicy.rows(options) }

    func start() {
        guard watcher == nil else { return }
        MdbListTracker.shared.ensureLoaded(profileId: ProfileRepository.shared.activeProfileId)
        // `listOptions` is a plain Flow (a `map` over the snapshot StateFlow), so it takes the
        // Flow overload; the first value arrives once the snapshot has loaded.
        watcher = FlowWatcherKt.watchFlow(MdbListTracker.shared.library.listOptions) { [weak self] emitted in
            guard let list = emitted as? [MdbListLibraryListOption] else { return }
            Task { @MainActor in self?.options = list }
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
    /// and shows the message.
    func setVisible(key: String, visible: Bool) {
        guard let index = options.firstIndex(where: { $0.key == key }) else { return }
        let previous = options[index]
        errorMessage = nil
        options[index] = MdbListLibraryListOption(key: previous.key, name: previous.name, visible: visible)
        MdbListTracker.shared.library.setListVisibilityAsync(key: key, visible: visible) { [weak self] (message: String?) in
            guard let message else { return }
            Task { @MainActor in
                guard let self else { return }
                if let i = self.options.firstIndex(where: { $0.key == key }) {
                    self.options[i] = MdbListLibraryListOption(key: previous.key, name: previous.name, visible: previous.visible)
                }
                self.errorMessage = message.isEmpty ? String(localized: "Couldn't update this list. Try again.") : message
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
