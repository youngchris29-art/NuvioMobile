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
            // H-1A (beta.15): guarded assignment, same pattern as `HomeHeroSettingsObserver`'s
            // `heroEnabled` watcher (HomeView.swift, `start()` ~L1401) — a profile-scoped cloud
            // sync pull can republish this SAME theme minutes after cold launch even though
            // nothing visibly changed, and `@Published` fires `objectWillChange` on every
            // assignment regardless of value equality. `ContentView` pins `.id(appTheme.themeName)`
            // on its root, so an unconditional write here remounts the whole tree — and on Home
            // that remount spins up a SECOND `HomeHeroFocusModel`/`HeroCrossfadeImage` instance,
            // which is the "hero painted twice" report's actual root cause. Only assign — and only
            // remount — when the incoming name genuinely differs.
            guard self.themeName != theme.name else { return }
            // Permanent recurrence tripwire: any future regression that reintroduces an
            // unconditional theme republish shows up here as a `theme A→B` line minutes into a
            // probe capture, well after the cold-launch head — exactly the signal H-1A's
            // head-preserving ring buffer (`HomeHeroProbe`) was built to keep from being evicted.
            if HomeHeroProbe.enabled {
                HomeHeroProbe.log(String(format: "theme %@\u{2192}%@ sinceLaunch=%dms", self.themeName, theme.name, HomeHeroProbe.sinceLaunchMs))
            }
            self.themeName = theme.name
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }
}
