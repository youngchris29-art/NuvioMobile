import Combine
import Foundation
import SharedCore

/// Manages installed addons: lists them, installs a new one by manifest URL, removes, and toggles
/// enabled. Backed by the shared `AddonRepository` (NSUserDefaults-persisted on tvOS).
@MainActor
final class AddonsViewModel: ObservableObject {
    @Published private(set) var addons: [ManagedAddon] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isInstalling = false

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(AddonRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? AddonsUiState else { return }
            self.addons = state.addons
        }
        AddonRepository.shared.initialize()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func install(_ rawUrl: String) {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isInstalling = true
        statusMessage = nil

        AddonRepository.shared.addAddon(rawUrl: url) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.isInstalling = false
                if let error {
                    self.statusMessage = String(localized: "Couldn't install: \(error.localizedDescription)")
                } else if let failure = result as? AddAddonResultError {
                    self.statusMessage = String(localized: "Couldn't install: \(failure.message)")
                } else if let success = result as? AddAddonResultSuccess {
                    self.statusMessage = String(localized: "Installed \(success.manifest.name).")
                } else {
                    self.statusMessage = String(localized: "Couldn't install that URL.")
                }
            }
        }
    }

    func remove(_ addon: ManagedAddon) {
        AddonRepository.shared.removeAddon(manifestUrl: addon.manifestUrl)
    }

    func setEnabled(_ addon: ManagedAddon, _ enabled: Bool) {
        AddonRepository.shared.setAddonEnabled(manifestUrl: addon.manifestUrl, enabled: enabled)
    }

    /// Display name: manifest name once loaded, otherwise the URL.
    func displayName(_ addon: ManagedAddon) -> String {
        if let name = addon.manifest?.name, !name.isEmpty { return name }
        return addon.manifestUrl
    }

    deinit {
        watcher?.cancel()
    }
}
