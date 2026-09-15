import Combine
import SwiftUI
import SharedCore

/// Watches the shared `ThemeSettingsRepository.selectedTheme` (persisted by the tvOS
/// `ThemeSettingsStore` adapter, profile-scoped, default CRIMSON) and applies it to the static
/// palette. ContentView puts `.id(themeName)` on the root so a theme change rebuilds the tree,
/// re-reading `Theme.Palette.accent`/`accentFocus` everywhere.
@MainActor
final class AppThemeModel: ObservableObject {
    @Published private(set) var themeName: String
    /// FEAT-38 (OLED True Black), seeded/watched the same way as `themeName`.
    @Published private(set) var oled: Bool
    /// Combines `themeName` + `oled` into the one key `ContentView` re-identifies its root on —
    /// a plain theme rename is not enough to also react to an OLED toggle.
    @Published private(set) var paletteKey: String

    private var watcher: FlowWatcher?
    private var oledWatcher: FlowWatcher?

    /// H-1B follow-up (beta.15, probe-verified): seed from the repository's CURRENT value
    /// synchronously instead of hard-coding "CRIMSON". With the hard-coded seed, every profile
    /// whose stored theme differed got a GUARANTEED whole-tree remount ~3s after cold launch when
    /// the first repository emission landed (`theme CRIMSON→OCEAN` in the probe capture) — tearing
    /// Home down and restarting its pipeline on every single launch. `ensureLoaded()` is a cheap
    /// disk read the `start()` path performed moments later anyway.
    init() {
        ThemeSettingsRepository.shared.ensureLoaded()
        let name = ThemeSettingsRepository.shared.currentThemeName()
        themeName = name
        // FEAT-38: `amoledEnabled` is a plain `StateFlow<Boolean>` with no `currentThemeName()`-
        // style synchronous accessor (unlike `selectedTheme`) — read `.value_` directly and cast,
        // the same idiom `HeroTrailerAudioState.muted` (also a bare `StateFlow<Boolean>`) uses at
        // `TrailerHeroPlayerView.swift` (`audioState.muted.value_ as? KotlinBoolean)?.boolValue`).
        let amoled = (ThemeSettingsRepository.shared.amoledEnabled.value_ as? KotlinBoolean)?.boolValue ?? false
        oled = amoled
        paletteKey = Self.makePaletteKey(themeName: name, oled: amoled)
        Theme.Palette.applyTheme(named: name)
        Theme.Palette.applyOled(amoled)
    }

    func start() {
        ThemeSettingsRepository.shared.ensureLoaded()
        if watcher == nil {
            watcher = FlowWatcherKt.watch(ThemeSettingsRepository.shared.selectedTheme) { [weak self] emitted in
                guard let self, let theme = emitted as? AppTheme else { return }
                Theme.Palette.applyTheme(named: theme.name)
                // H-1A (beta.15): guarded assignment, same pattern as `HomeHeroSettingsObserver`'s
                // `heroEnabled` watcher (HomeView.swift, `start()` ~L1401) — a profile-scoped cloud
                // sync pull can republish this SAME theme minutes after cold launch even though
                // nothing visibly changed, and `@Published` fires `objectWillChange` on every
                // assignment regardless of value equality. `ContentView` pins `.id(appTheme.paletteKey)`
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
                self.paletteKey = Self.makePaletteKey(themeName: theme.name, oled: self.oled)
            }
        }
        if oledWatcher == nil {
            // Same H-1A guarded-assignment rule as the theme watcher above: a profile-scoped sync
            // pull can republish the SAME value, and an unconditional write would remount the tree
            // via `paletteKey` for no visible change.
            oledWatcher = FlowWatcherKt.watch(ThemeSettingsRepository.shared.amoledEnabled) { [weak self] emitted in
                guard let self, let boxed = emitted as? KotlinBoolean else { return }
                let enabled = boxed.boolValue
                guard self.oled != enabled else { return }
                Theme.Palette.applyOled(enabled)
                self.oled = enabled
                self.paletteKey = Self.makePaletteKey(themeName: self.themeName, oled: enabled)
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        oledWatcher?.cancel()
        oledWatcher = nil
    }

    private static func makePaletteKey(themeName: String, oled: Bool) -> String {
        "\(themeName)|\(oled ? "oled" : "std")"
    }

    /// Synchronous re-seed at PROFILE ENTRY (probe-verified fix): theme keys are profile-scoped,
    /// so `init`'s seed reads the boot-time (pre-profile) key. `selectProfile`'s Kotlin fan-out
    /// reloads the repository for the chosen profile synchronously, but the Swift watcher
    /// delivery is async — without this, `MainTabView` mounted under the OLD name and the
    /// watcher's delivery ~70ms later re-identified the whole tree (probe: `theme CRIMSON→OCEAN`
    /// at 3.1s, a full Home pipeline teardown+restart on EVERY cold launch of a non-default-theme
    /// profile). ContentView calls this in `onSelected` BEFORE flipping `entered`, while only
    /// ProfileSelectionView is mounted — the `.id` change is then nearly free. Logged as
    /// `themeSeed` (not `theme …`) so test31's boot-window remount tripwire doesn't fire on the
    /// legitimate pre-mount seed.
    func reseedNow() {
        let name = ThemeSettingsRepository.shared.currentThemeName()
        // FEAT-38: same synchronous `.value_` read as `init` — `amoledEnabled` is profile-scoped
        // too, and `selectProfile`'s Kotlin fan-out has already reloaded it for the new profile by
        // the time this runs, same as `selectedTheme`.
        let amoled = (ThemeSettingsRepository.shared.amoledEnabled.value_ as? KotlinBoolean)?.boolValue ?? false
        let themeChanged = themeName != name
        let oledChanged = oled != amoled
        guard themeChanged || oledChanged else { return }
        if themeChanged, HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "themeSeed %@\u{2192}%@ sinceLaunch=%dms", themeName, name, HomeHeroProbe.sinceLaunchMs))
        }
        if themeChanged {
            Theme.Palette.applyTheme(named: name)
            themeName = name
        }
        if oledChanged {
            Theme.Palette.applyOled(amoled)
            oled = amoled
        }
        paletteKey = Self.makePaletteKey(themeName: themeName, oled: oled)
    }
}
