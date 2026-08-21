import SwiftUI
import SharedCore

/// "About" category content: build/version truth (FEAT-13). Reads the version straight out of the
/// running bundle instead of any hand-maintained constant, so this pane can never drift from what
/// was actually built — the "Stamp Build Metadata" run-script build phase writes NuvioCommitSHA /
/// NuvioBetaTag into Info.plist at build time (see project.pbxproj, NuvioTV target).
struct AboutSettingsPane: View {
    /// BUG-42 (beta.13.5): the reporter can't `defaults write` on a sideload, so the release-safe
    /// hero probe gets a visible switch. Read once at launch by `HomeHeroProbe.enabled`, hence the
    /// relaunch note in the subtitle.
    @AppStorage("debug.homeHeroProbe") private var heroDiagnostics = false
    @State private var heroProbeLines: [String] = []

    /// BUG-30/66/62 (beta.14): same release-safe pattern as the hero probe above, but the readout
    /// is a live in-memory snapshot (`TabBarProbe`) rather than a persisted log — see that type's
    /// doc comment for why.
    @AppStorage("debug.tabBarProbe") private var tabBarDiagnostics = false
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    /// BUG-64: both raw toggles `CardFocusMode.resolve` reads, so this pane can show the resolved
    /// mode next to the settings a tester's photo needs to be checked against.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    var body: some View {
        settingsSection(String(localized: "About")) {
            SettingsInfoRow(
                title: String(localized: "Version"),
                value: "\(Self.marketingVersion) (\(Self.buildNumber))"
            )
            SettingsInfoRow(
                title: String(localized: "Build"),
                value: Self.betaTag
            )
            SettingsInfoRow(
                title: String(localized: "Commit"),
                value: Self.commitSHA
            )
            SettingsInfoRow(
                title: String(localized: "tvOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
            SettingsInfoRow(
                title: String(localized: "Device"),
                value: Self.deviceModelIdentifier
            )
            SettingsInfoRow(
                title: String(localized: "Source"),
                value: "github.com/youngchris29-art/NuvioTV"
            )

            SettingsToggleRow(
                title: String(localized: "Hero Paint Diagnostics"),
                subtitle: heroDiagnostics
                    ? String(localized: "On \u{00B7} After relaunching, this launch's hero paint log appears below \u{2014} photograph it when reporting")
                    : String(localized: "Off \u{00B7} Turn on if asked to capture a hero artwork report, then relaunch the app"),
                isOn: heroDiagnostics
            ) {
                heroDiagnostics.toggle()
            }

            if heroDiagnostics, !heroProbeLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(heroProbeLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("hero_probe_lines")
            }

            // Grouped so this whole block occupies one slot in `settingsSection`'s own
            // @ViewBuilder — PlaybackSettingsPane's "Playback" section already sits at the
            // 10-child ViewBuilder ceiling, and the six rows above plus the hero probe's two
            // slots leave no room to add these five ungrouped.
            Group {
                SettingsToggleRow(
                    title: String(localized: "Tab Bar Diagnostics"),
                    subtitle: tabBarDiagnostics
                        ? String(localized: "On \u{00B7} Scroll-geometry and push/pop counters below \u{2014} photograph after testing")
                        : String(localized: "Off \u{00B7} Turn on before walking Home down and back up, or running Detail push/pop cycles"),
                    isOn: tabBarDiagnostics
                ) {
                    tabBarDiagnostics.toggle()
                }

                if tabBarDiagnostics {
                    // Live readout (Codex beta.14 r6): the probe's counters are plain statics
                    // with no publisher, and this pane can stay mounted while the tester bounces
                    // to Home, runs the protocol, and comes back — a static render would keep
                    // showing the pre-test values, which fakes the exact "callbacks stopped
                    // firing" signature the probe exists to detect. The 1 Hz TimelineView
                    // re-render is the entire invalidation story: every tick re-reads the
                    // statics. It only ticks while the toggle is on and the pane is on screen.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(TabBarProbe.tabNames, id: \.self) { tab in
                                let state = TabBarProbe.scrollStates[tab] ?? TabBarProbe.ScrollState()
                                Text("\(tab) fires=\(state.fireCount) last=\(state.lastFireMs)ms off=\(Int(state.lastOffset.rounded()))")
                                    .font(.system(size: 20, design: .monospaced))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("depth=\(tabBarVisibility.immersiveDepth) cycles=\(TabBarProbe.pushPopCycles)")
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("tab_bar_probe_lines")
                }

                SettingsInfoRow(
                    title: String(localized: "Focus Mode"),
                    value: "\(CardFocusMode.resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus))"
                )
                SettingsInfoRow(
                    title: String(localized: "No Zoom on Focus"),
                    value: noZoomOnFocus ? String(localized: "On") : String(localized: "Off")
                )
                SettingsInfoRow(
                    title: String(localized: "Accent Focus Ring"),
                    value: accentFocusRing ? String(localized: "On") : String(localized: "Off")
                )
            }
        }
        .onAppear {
            heroProbeLines = UserDefaults.standard.stringArray(forKey: "debug.homeHeroProbe.lines") ?? []
        }
    }

    private static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
    }

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    /// Stamped by the "Stamp Build Metadata" run-script build phase from `NUVIO_BETA_TAG` (set by
    /// scripts/release-beta.sh). Empty on plain Xcode Debug builds, which never set that env var.
    private static var betaTag: String {
        let tag = (Bundle.main.object(forInfoDictionaryKey: "NuvioBetaTag") as? String) ?? ""
        return tag.isEmpty ? String(localized: "Dev build") : tag
    }

    /// Stamped by the same build phase from `git rev-parse --short=8 HEAD`.
    private static var commitSHA: String {
        let sha = (Bundle.main.object(forInfoDictionaryKey: "NuvioCommitSHA") as? String) ?? ""
        return sha.isEmpty ? "\u{2014}" : sha
    }

    /// The hardware model identifier (e.g. "AppleTV6,2"), read via `uname(2)` — `UIDevice.current`
    /// only exposes the marketing/user-assigned name, not the model.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }
}
