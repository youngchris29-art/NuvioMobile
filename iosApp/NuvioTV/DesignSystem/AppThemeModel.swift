import Combine
import SwiftUI
import SharedCore

/// Watches the shared `ThemeSettingsRepository.selectedTheme` (persisted by the tvOS
/// `ThemeSettingsStore` adapter, profile-scoped, default CRIMSON) and applies it to the static
/// palette. ContentView puts `.id(themeName)` on the root so a theme change rebuilds the tree,
/// re-reading `Theme.Palette.accent`/`accentFocus` everywhere.
@MainActor
final class AppThemeModel: ObservableObject {
    @Published private(set) var themeName = "CRIMSON"

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        ThemeSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(ThemeSettingsRepository.shared.selectedTheme) { [weak self] emitted in
            guard let self, let theme = emitted as? AppTheme else { return }
            Theme.Palette.applyTheme(named: theme.name)
            self.themeName = theme.name
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }
}
