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
    /// BUG-74: the reporter saw "no streams" on titles that played fine on mobile, and the one
    /// fact that would have settled it in a day — the id we sent the addons was `tmdb:…`, not
    /// `tt…` — was only ever written to a console no sideloaded tester has. Same release-safe
    /// toggle pattern as the two probes above; live in-session (no relaunch), since the capture
    /// protocol is "turn on, open the failing title, press Play, come back here, photograph".
    @AppStorage("debug.streamProbe") private var streamDiagnostics = false

    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    /// BUG-81 (Wave F item C): same release-safe toggle pattern as the three probes above — a
    /// tester on a release sideload can't `defaults write com.nuvio.media.NuvioTV debug.trailerProbe
    /// -bool YES`, so `TrailerZoomProbe`'s buffer gets its own switch, live in-session (no relaunch:
    /// the capture protocol is "turn on, open the zoomed title, let it play ~10s, come back here and
    /// photograph").
    @AppStorage("debug.trailerDiagnostics") private var trailerDiagnostics = false
    /// Bumped by the "Reset trailer zoom cache" button so `trailerZoomCacheCount` below — a plain
    /// read of a non-`@Published` singleton — has a `@State` dependency to invalidate on, the same
    /// way `heroProbeLines`/`StreamProbe.lines` get their re-renders from a toggle or a `TimelineView`
    /// tick rather than from Combine.
    @State private var trailerZoomCacheGeneration = 0

    /// BUG-41 (Wave F item D, DetailView.swift): `debug.detailScrollAB`/`debug.detailScrollProbe`
    /// are both LIVE reads on the DetailView side (`DetailScrollAB.leg`, `DetailScrollProbe.enabled`)
    /// — F-C only owns the About-pane control surface here, not the probe or the A/B legs themselves.
    @AppStorage("debug.detailScrollAB") private var detailScrollAB = 0
    @AppStorage("debug.detailScrollProbe") private var detailScrollProbeEnabled = false

    /// FEAT-33 (Wave 1, agent C): same release-safe toggle pattern as the probes above —
    /// `CollectionFocusFrameProbe`'s buffer and `CollectionFocusAB`'s knob (`CollectionsUI.swift`,
    /// `CollectionFocusFrameProbe.swift`) are both keyed off these two, live in-session except the
    /// A/B leg, which is read once at launch (`CollectionFocusAB.leg`) — flipping the picker here
    /// only takes effect on the next launch, hence the subtitle below.
    @AppStorage("debug.collectionFrameProbe") private var collectionFrameProbe = false
    @AppStorage("debug.collectionFocusAB") private var collectionFocusAB = 0

    private var trailerZoomCacheCount: Int {
        _ = trailerZoomCacheGeneration // dependency only — see the property's doc comment
        return TrailerZoomCache.shared.count
    }

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
                    ? String(localized: "Relaunch, wait 90 seconds without touching the remote, then photograph this pane.")
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

                SettingsToggleRow(
                    title: String(localized: "Stream Diagnostics"),
                    subtitle: streamDiagnostics
                        ? String(localized: "Stream lookups are logged below \u{2014} open the title that fails, press Play, then come back and photograph")
                        : String(localized: "Turn on if asked to capture why a title finds no streams"),
                    isOn: $streamDiagnostics
                )

                if streamDiagnostics {
                    // 1 Hz re-read for the same reason the tab-bar readout has one: `StreamProbe`
                    // is a plain static buffer with no publisher, and this pane stays mounted
                    // while the tester goes off to reproduce. A static render would show an empty
                    // log forever, which reads as "the probe is broken".
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 2) {
                            if StreamProbe.lines.isEmpty {
                                Text(String(localized: "No stream lookups yet \u{2014} press Play on the title that fails."))
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                ForEach(Array(StreamProbe.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("stream_probe_lines")
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
                // FEAT-31 attribution: the font ships in this same branch (Theme.Font.uiFont,
                // used by FEAT-33's own CollectionsUI.swift caption measurement). Added here
                // rather than the plain About/credits rows above so this Group's ViewBuilder
                // absorbs it without pushing the outer SettingsSection past its 10-child
                // @ViewBuilder ceiling (see this file's header comment on that constraint).
                SettingsValueRow(
                    title: String(localized: "Fonts"),
                    value: "Open Sans — SIL Open Font License 1.1"
                )
            }

            // Grouped so this whole block (Trailer Diagnostics + BUG-41's Detail Scroll controls)
            // occupies one slot in `SettingsSection`'s own @ViewBuilder, same reasoning as the
            // block above it.
            Group {
                SettingsToggleRow(
                    title: String(localized: "Trailer Diagnostics"),
                    subtitle: trailerDiagnostics
                        ? String(localized: "Open the title whose trailer looks zoomed, let it play 10 seconds, come back and photograph this pane.")
                        : String(localized: "Turn on if asked to capture why a trailer looks zoomed or letterboxed"),
                    isOn: $trailerDiagnostics
                )

                if trailerDiagnostics {
                    // 1 Hz re-read, same reasoning as the tab-bar/stream readouts above:
                    // `TrailerZoomProbe` is a plain lock-guarded buffer with no publisher.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let lines = TrailerZoomProbe.lines
                        VStack(alignment: .leading, spacing: 2) {
                            if lines.isEmpty {
                                Text(String(localized: "No trailer measurements yet \u{2014} open a title and let its trailer play."))
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        // Hidden single-Text blob (mirrors `hero_probe_blob`): the visible
                        // per-line `Text` children beyond the List row's clipped height never
                        // enter the accessibility tree, so a UITest reads the WHOLE buffer
                        // through this one element instead.
                        .overlay(alignment: .topLeading) {
                            Text(lines.joined(separator: "\n"))
                                .font(.system(size: 4))
                                .opacity(0.011)
                                .accessibilityIdentifier("trailer_probe_blob")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("trailer_probe_lines")
                }

                SettingsValueRow(
                    title: String(localized: "Trailer zoom cache"),
                    value: trailerZoomCacheCount == 1
                        ? String(localized: "1 entry")
                        : String(localized: "\(trailerZoomCacheCount) entries")
                )

                SettingsActionRow(title: String(localized: "Reset trailer zoom cache")) {
                    TrailerZoomCache.shared.removeAll()
                    trailerZoomCacheGeneration += 1
                }

                // BUG-41 (Wave F item D): the five-leg on-device A/B knob DetailView reads live —
                // this pane is the only lawful lever a sideloaded tester has over it.
                SettingsPickerRow(
                    title: String(localized: "Detail Scroll A/B"),
                    selection: $detailScrollAB,
                    options: [0, 1, 2, 3, 4],
                    label: { leg in
                        leg == 0 ? String(localized: "Off") : "\(leg)"
                    }
                )

                SettingsToggleRow(
                    title: String(localized: "Detail Scroll Probe"),
                    subtitle: String(localized: "BUG-41: logs a hitch counter for one Detail visit on Menu-back"),
                    isOn: $detailScrollProbeEnabled
                )

                // FEAT-33 (Wave 1, agent C): release-safe frame-timing probe for the Home
                // collection row's focus-step animation. Same live-toggle pattern as the trailer
                // diagnostics above it; only the A/B leg is launch-latched (`CollectionFocusAB`
                // reads it once at process start), hence the relaunch note in the picker's row.
                SettingsToggleRow(
                    title: String(localized: "Collection Frame Probe"),
                    subtitle: String(localized: "Frame timing per focus step on collection rows; requires relaunch to change the A/B leg"),
                    isOn: $collectionFrameProbe
                )

                if collectionFrameProbe {
                    // 1 Hz re-read, same reasoning as the trailer/stream readouts above:
                    // `CollectionFocusFrameProbe` is a plain lock-guarded buffer with no publisher.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let lines = CollectionFocusFrameProbe.lines
                        VStack(alignment: .leading, spacing: 2) {
                            Text("refresh=\(UIScreen.main.maximumFramesPerSecond) leg=\(CollectionFocusAB.leg)")
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                            if lines.isEmpty {
                                Text(String(localized: "No focus steps measured yet \u{2014} walk a collection row on Home."))
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            } else {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        // Hidden single-Text blob (mirrors `hero_probe_blob`/`trailer_probe_blob`):
                        // the visible per-line `Text` children beyond the List row's clipped
                        // height never enter the accessibility tree, so a UITest reads the WHOLE
                        // buffer through this one element instead.
                        .overlay(alignment: .topLeading) {
                            Text(lines.joined(separator: "\n"))
                                .font(.system(size: 4))
                                .opacity(0.011)
                                .accessibilityIdentifier("collection_frame_blob")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("collection_frame_probe_lines")

                    SettingsActionRow(title: String(localized: "Clear")) {
                        CollectionFocusFrameProbe.clear()
                    }
                }

                SettingsPickerRow(
                    title: String(localized: "Collection Focus A/B"),
                    selection: $collectionFocusAB,
                    options: [0, 1, 2, 3],
                    label: { leg in
                        switch leg {
                        case 0: return String(localized: "0 as shipped")
                        case 1: return String(localized: "1 defer hero")
                        case 2: return String(localized: "2 no tile animation")
                        default: return String(localized: "3 both")
                        }
                    }
                )
            }
        }
        .onAppear {
            heroProbeLines = UserDefaults.standard.stringArray(forKey: "debug.homeHeroProbe.lines") ?? []
        }
        // The shared-side sink is installed/removed here rather than at the toggle, so it also
        // recovers if the switch was flipped in a previous session (startup does the same call).
        .onChange(of: streamDiagnostics) { _, _ in StreamProbe.syncSink() }
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
