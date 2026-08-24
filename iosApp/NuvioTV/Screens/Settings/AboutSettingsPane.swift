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

    /// T5 (BUG-30/42): the reporter is on a sideload and can't `defaults write`, so the one
    /// lawful A/B lever over the clipped tab-bar reappearance —
    /// `HomeScrollEdgeStyleModifier` (HomeView.swift ~L1307-1325; its own comment records it is
    /// NOT one of the six banned scroll-changing rounds) — needs a Settings switch too.
    /// `@AppStorage` on both ends (this toggle and `HomeView.homeScrollEdgeHard`), unlike the
    /// hero probe above: the change is LIVE, not launch-latched, so a tester can A/B it without
    /// relaunching between tries. Default stays off — shipped behavior is byte-identical until
    /// toggled.
    @AppStorage("debug.homeScrollEdgeHard") private var scrollEdgeHard = false

    /// BUG-64: both raw toggles `CardFocusMode.resolve` reads, so this pane can show the resolved
    /// mode next to the settings a tester's photo needs to be checked against.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    var body: some View {
        SettingsSection(String(localized: "About")) {
            SettingsValueRow(
                title: String(localized: "Version"),
                value: "\(Self.marketingVersion) (\(Self.buildNumber))"
            )
            SettingsValueRow(
                title: String(localized: "Build"),
                value: Self.betaTag
            )
            SettingsValueRow(
                title: String(localized: "Commit"),
                value: Self.commitSHA
            )
            SettingsValueRow(
                title: String(localized: "tvOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
            SettingsValueRow(
                title: String(localized: "Device"),
                value: Self.deviceModelIdentifier
            )
            SettingsValueRow(
                title: String(localized: "Source"),
                value: "github.com/youngchris29-art/NuvioTV"
            )

            SettingsToggleRow(
                title: String(localized: "Hero Paint Diagnostics"),
                subtitle: heroDiagnostics
                    ? String(localized: "After relaunching, this launch's hero paint log appears below \u{2014} photograph it when reporting")
                    : String(localized: "Turn on if asked to capture a hero artwork report, then relaunch the app"),
                isOn: $heroDiagnostics
            )

            if heroDiagnostics, !heroProbeLines.isEmpty {
                // H-1A (beta.15): `heroProbeLines` is now head-preserving — the first 16 lines
                // (the launch head a tester's photo needs) plus, once the tail actually evicts,
                // one "… N lines elided …" marker and the most recent 32 (see `HomeHeroProbe.log`)
                // — up to 49 rows total. No special-casing needed here: the marker is just another
                // string in the array, this `ForEach` already renders any count, and `SettingsSection`
                // lives inside a native `List`, so the section scrolls naturally as the row count grows.
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
                // The XCUI harness reads the WHOLE buffer through the hidden single-Text probe
                // below (`hero_probe_blob`) — the List row clips to visible height, so the
                // per-line `Text` children beyond the fold never enter the accessibility tree and
                // a snapshot walk of this container sees only the first line or two. (An
                // `.accessibilityElement(children: .combine)` + `.accessibilityValue` variant was
                // tried first and did not surface the value on the tvOS 26.5 runtime.) Same
                // one-hidden-Text pattern as `debug_ux6` (DetailView.swift).
                .overlay(alignment: .topLeading) {
                    Text(heroProbeLines.joined(separator: "\n"))
                        .font(.system(size: 4))
                        .opacity(0.011)
                        .accessibilityIdentifier("hero_probe_blob")
                }
            }

            // Grouped so this whole block occupies one slot in `SettingsSection`'s own
            // @ViewBuilder — PlaybackSettingsPane's "Playback" section already sits at the
            // 10-child ViewBuilder ceiling, and the six rows above plus the hero probe's two
            // slots leave no room to add these six ungrouped.
            Group {
                SettingsToggleRow(
                    title: String(localized: "Tab Bar Diagnostics"),
                    subtitle: tabBarDiagnostics
                        ? String(localized: "Scroll-geometry and push/pop counters below \u{2014} photograph after testing")
                        : String(localized: "Turn on before walking Home down and back up, or running Detail push/pop cycles"),
                    isOn: $tabBarDiagnostics
                )

                // T5 (BUG-30/42): the lawful A/B lever for the clipped-reappear bug, next to the
                // diagnostics toggle above since a device pass runs the two together — diagnose,
                // then try the lever.
                SettingsToggleRow(
                    title: String(localized: "Hard Top Scroll Edge (A/B)"),
                    subtitle: String(localized: "BUG-30: try if Home's tab bar still reappears clipped after scrolling up"),
                    isOn: $scrollEdgeHard
                )

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
                                // T1: y/i/r (offsetY / insetTop / residual) replace the old single
                                // "off=" reading — the sign-fixed residual alone can't tell a
                                // device pass whether the bar was expanded or minimized when it
                                // fired, and that's exactly the distinction BUG-66 turns on.
                                Text("\(tab) f=\(state.fireCount) t=\(state.lastFireMs) y=\(Int(state.lastOffsetY.rounded())) i=\(Int(state.lastInsetTop.rounded())) r=\(Int(state.lastResidual.rounded()))")
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

                SettingsValueRow(
                    title: String(localized: "Focus Mode"),
                    value: "\(CardFocusMode.resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus))"
                )
                SettingsValueRow(
                    title: String(localized: "No Zoom on Focus"),
                    value: noZoomOnFocus ? String(localized: "On") : String(localized: "Off")
                )
                SettingsValueRow(
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
