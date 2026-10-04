import SwiftUI

/// The left/right edge treatment every horizontal row (`ScrollView(.horizontal)`) wears.
///
/// History: BUG-118 (rc13, Steven's rc12 verdict) found that the "intermittent" fade he saw was
/// tvOS 26's SYSTEM scroll-edge effect on each row's own horizontal `ScrollView`, left at its
/// default `.automatic` style: it only draws where content continues past an edge, so it is absent
/// at rest and present once a row has scrolled, and the leading edge of a catalog row is a hard
/// `RowLeadingEdgeClip` (BUG-92) besides. `scrollEdgeEffectStyle(.hard/.soft/.automatic)` render
/// byte-identical on the simulator and look the same on his Apple TV, so rc14 added an APP-DRAWN
/// fade (`RowSoftEdgeMask`) behind a Developer A/B (`debug.rowEdgeFade`, default System).
///
/// beta.19-rc1 verdict (F, FEAT-54, Steven 2026-10-02): the A/B becomes a real Appearance setting,
/// `row_edge_fade` (`RowEdgeFadeSetting`), with Soft as the default, and the mask itself is
/// reworked: a smootherstep ramp (`EdgeFadeCurve`) measured from the BEZEL inward over
/// `RowEdgeFade.rampLength` (250 pt), so it starts inside the row frame instead of fading only the
/// ~140 pt margin outside it, where the old two-stop linear ramp ended in a hard knee at the frame
/// edge. Margins and ramp length come from the environment (`rowEdgeMargins`,
/// `rowEdgeRampLength`), so a host with different chrome sets them once on its container and no row
/// type changes.
///
///   - Soft   — the app-drawn mask, with the system effect hidden so the two never double up.
///   - System — tvOS's own `.automatic` scroll-edge effect (the pre-rc14 look).
///   - Off    — `scrollEdgeEffectHidden(true)` and no mask: no fade at all.
///
/// The setting is LIVE (`@AppStorage`): a change in Settings applies to every row at once, no
/// relaunch. If the F.5 frame-time gate fails on device, the default flips to Off in ONE place
/// (`RowEdgeFadeSetting.defaultValue`); the setting stays so a viewer can still pick Soft.
struct RowEdgeEffectStyleModifier: ViewModifier {
    /// beta.19-rc1 verdict (F): the Appearance setting (raw value, resolved through
    /// `RowEdgeFadeSetting.resolve`, so an unknown value lands on the default).
    @AppStorage(RowEdgeFadeSetting.defaultsKey) private var rawSetting: String = RowEdgeFadeSetting.defaultValue.rawValue

    /// beta.19-rc1 verdict (F, critique #13): where the screen edges are relative to this row's
    /// frame, and how far in from the bezel the ramp runs. The explicit parameters below override
    /// these when non-nil.
    @Environment(\.rowEdgeMargins) private var environmentMargins
    @Environment(\.rowEdgeRampLength) private var environmentRampLength

    /// beta.18 verdict (BUG-118, R3): the row's own rest-state leading clip allowance (catalog
    /// rows only; 0 = no clip, the mask keeps the full leading bleed). Soft pushes the real clip
    /// out of the way, so the mask reproduces the hard cut at exactly this distance at rest.
    let leadingClipAllowance: CGFloat
    let marginsOverride: RowEdgeMargins?
    let rampLengthOverride: CGFloat?
    /// beta.19-rc1 verdict (review r1, B P2-2): true while the row hosts a wide inline trailer tile
    /// that its morph scroll could not bring clear of the trailing ramp (clamped at the row's end).
    /// Soft then draws the trailing side solid to the bezel, so the tile's right edge is never
    /// faded. Inert in System and Off.
    let holdsTrailingFade: Bool

    init(leadingClipAllowance: CGFloat = 0, margins: RowEdgeMargins? = nil, rampLength: CGFloat? = nil,
         holdsTrailingFade: Bool = false) {
        self.leadingClipAllowance = leadingClipAllowance
        self.marginsOverride = margins
        self.rampLengthOverride = rampLength
        self.holdsTrailingFade = holdsTrailingFade
    }

    private var setting: RowEdgeFadeSetting { RowEdgeFadeSetting.resolve(rawSetting) }
    private var margins: RowEdgeMargins { marginsOverride ?? environmentMargins }
    private var rampLength: CGFloat { rampLengthOverride ?? environmentRampLength }

    /// Plain computed property, not a `@ViewBuilder` switch — see `body` below for why that
    /// distinction matters here. Soft draws its own mask with the system effect hidden, so its
    /// style argument is inert; `.soft` only keeps the argument a real style.
    private var style: ScrollEdgeEffectStyle {
        setting == .system ? .automatic : .soft
    }

    /// rc14 (Soft): true once the row has scrolled off its resting offset. Driven by
    /// `onScrollGeometryChange` below with a Bool transform, so it writes state only when the
    /// offset CROSSES 0 — never per frame (the BUG-19/BUG-41 rule: no per-frame @State writes on a
    /// row ScrollView).
    @State private var scrolled = false

    func body(content: Content) -> some View {
        content
            // Both modifiers are applied unconditionally, with the setting folded into their
            // arguments rather than into an `if`/`switch` over the modifier chain itself. A
            // `@ViewBuilder switch` here would put each leg on a different `_ConditionalContent`
            // branch, which SwiftUI treats as a different view identity — changing the setting
            // would then re-mount the row's `ScrollView` and lose its scroll offset/focus. Passing
            // `style` and the hidden Bool as plain arguments keeps one identity across every leg
            // (except the Soft mask branch, see `RowSoftEdgeMaskModifier` below).
            .scrollEdgeEffectStyle(style, for: .horizontal)
            // Off hides the system effect to remove it; Soft hides it so the app-drawn mask below
            // is the ONLY fade (otherwise the trailing edge would double up).
            .scrollEdgeEffectHidden(setting != .system, for: .horizontal)
            // Applied unconditionally (cheap — the Bool transform only fires its action on a
            // 0-crossing) so the Soft mask can appear without remounting the ScrollView.
            .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.x > 1 }, action: { _, new in
                scrolled = new
            })
            // The Soft/non-Soft split is the only `if` in the chain: the setting is changed from
            // Settings, never while a row is mid-scroll, so the one-time identity change is
            // acceptable. The `.mask` never changes the ScrollView's frame or layout (it paints
            // enlarged, see `RowSoftEdgeMask`).
            .modifier(RowSoftEdgeMaskModifier(active: setting == .soft, leadingActive: scrolled,
                                              trailingActive: !holdsTrailingFade,
                                              restClipAllowance: leadingClipAllowance,
                                              margins: margins, rampLength: rampLength))
            // A UI test cannot tell the legs apart from the accessibility tree, so the hidden
            // probe below states which setting reached this row's own `@AppStorage` (same hidden
            // single-Text pattern as `hero_probe_blob`/`settle_probe_blob`). DEBUG-only, like
            // every other `debug_*` probe; `test70RowEdgeFadeSpike` builds Debug.
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                // Append-only fields (harness-parsed by key): `hold=` is review r1 B P2-2's
                // trailing-fade hold.
                Text("row_edge_fade_probe mode=\(setting.rawValue) ramp=\(Int(rampLength)) margin=\(Int(margins.leading)) hold=\(holdsTrailingFade ? 1 : 0)")
                    .font(.system(size: 4))
                    .opacity(0.011)
                    .accessibilityIdentifier("row_edge_fade_probe")
            }
            #endif
    }
}

/// rc14: applies `RowSoftEdgeMask` only while `active` (the Soft setting).
private struct RowSoftEdgeMaskModifier: ViewModifier {
    let active: Bool
    let leadingActive: Bool
    let trailingActive: Bool
    let restClipAllowance: CGFloat
    let margins: RowEdgeMargins
    let rampLength: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask {
                RowSoftEdgeMask(restClipAllowance: restClipAllowance, leadingActive: leadingActive,
                                trailingActive: trailingActive, margins: margins, rampLength: rampLength)
                    // beta.18 verdict (BUG-118, R3): softens the rest-cut -> ramp flip when the row
                    // first scrolls; the device pass may remove it.
                    .animation(.easeOut(duration: 0.15), value: leadingActive)
                    // beta.19-rc1 verdict (review r1, B P2-2): the same ease for the trailing hold,
                    // which flips once at a morph's `.wide` edge and once at its collapse.
                    .animation(.easeOut(duration: 0.15), value: trailingActive)
            }
        } else {
            content
        }
    }
}

// MARK: - Curve, ramp length, setting, environment (beta.19-rc1 verdict, F)

/// F (Steven beta.19-rc1 verdict, 2026-10-03; FEAT-54): the one edge-fade curve, shared by the row
/// mask and the folder page's vertical fades. Smootherstep: zero slope at both ends, so there is no
/// knee where the ramp meets the solid part or the bezel.
nonisolated enum EdgeFadeCurve {
    /// How many gradient stops a ramp is drawn with. SwiftUI interpolates linearly between stops;
    /// nine (every 1/8) keep the drawn ramp within ~0.01 alpha of the curve.
    static let stopCount = 9

    /// Smootherstep on `u` clamped to 0…1: `6t⁵ − 15t⁴ + 10t³`. NaN reads as 0.
    static func alpha(_ u: Double) -> Double {
        guard !u.isNaN else { return 0 }
        let t = min(max(u, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// `stopCount` stops at 0, 1/8 … 1. `rising` goes from clear (location 0) to solid (location
    /// 1); otherwise solid to clear. `color` is the solid colour: black for a `.mask`, the page
    /// background for a painted fade.
    static func stops(rising: Bool, color: Color = .black) -> [Gradient.Stop] {
        (0..<stopCount).map { index in
            let location = Double(index) / Double(stopCount - 1)
            let opacity = alpha(rising ? location : 1 - location)
            return Gradient.Stop(color: color.opacity(opacity), location: location)
        }
    }
}

nonisolated enum RowEdgeFade {
    /// F: the ramp, measured from the BEZEL inward. With the standard 140 pt margin it starts
    /// 110 pt inside the row frame; the focused card's outer edge rests ≈221 pt from the bezel
    /// (Medium, `bug118-auto-12.png`), where the curve is already 0.987. If the Wave-0 measurement
    /// finds a focused card closer to the edge, lower THIS until alpha there is ≥ 0.94.
    static let rampLength: CGFloat = 250

    /// beta.19-rc1 verdict (review r1, B P2-2): how far inside a row's trailing edge an expanded
    /// inline trailer tile must end so the Soft ramp never touches it — the trailing ramp's inner
    /// extent (110 pt with the standard 140 pt margin and 250 pt ramp), 0 in System and Off. The
    /// host passes the SAME margins and ramp length its `rowEdgeEffectStyle()` reads (the
    /// `rowEdgeMargins` / `rowEdgeRampLength` environment), so a host with other chrome (the Stage
    /// strip) inherits the right inset with no row change. `rowWidth` is the row ScrollView's frame
    /// width (the mask is proposed exactly that size).
    static func trailingTileInset(setting: RowEdgeFadeSetting, rowWidth: CGFloat, margins: RowEdgeMargins,
                                  rampLength: CGFloat) -> CGFloat {
        guard setting == .soft else { return 0 }
        return RowSoftEdgeMask.trailingInnerExtent(width: rowWidth, margins: margins, rampLength: rampLength)
    }
}

/// F (FEAT-54): the row edge fade setting, `row_edge_fade` (device-local, not synced — like every
/// other Appearance look key read with `@AppStorage`). `-row_edge_fade off` works as a launch
/// argument.
nonisolated enum RowEdgeFadeSetting: String, CaseIterable, Sendable {
    /// The app-drawn eased mask, system scroll-edge effect hidden. Opt-in: the F.5 frame-time gate
    /// (Living Room Apple TV, 2026-10-04) measured it at +1.1 ms vertical p95 and +6 dropped frames
    /// against Off, past the 1.0 ms / max(2, 10 %) bar, so it is not the default.
    case soft
    /// tvOS's own `.automatic` scroll-edge effect.
    case system
    /// `scrollEdgeEffectHidden(true)`, no mask. DEFAULT (the F.5 gate, see `soft`).
    case off

    static let defaultsKey = "row_edge_fade"
    /// The BUG-118 Developer A/B this setting replaces (Int: 0 hard, 1 soft, 2 automatic, 3 off).
    static let legacyKey = "debug.rowEdgeFade"
    /// The legacy A/B's legs that carry across (`legacySetting`); 0 (Hard) does not.
    static let legacySoftValue = 1
    static let legacyAutomaticValue = 2
    static let legacyOffValue = 3
    static let defaultValue: RowEdgeFadeSetting = .off

    /// Unknown, blank or nil → `defaultValue`. Trimmed and lower-cased, so a hand-typed launch
    /// argument (`-row_edge_fade Soft`) still resolves.
    static func resolve(_ raw: String?) -> RowEdgeFadeSetting {
        guard let raw else { return defaultValue }
        return RowEdgeFadeSetting(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? defaultValue
    }

    static func current(_ defaults: UserDefaults = .standard) -> RowEdgeFadeSetting {
        resolve(defaults.string(forKey: defaultsKey))
    }

    /// Carries the BUG-118 Developer A/B (`debug.rowEdgeFade`) across as `row_edge_fade` per
    /// `legacySetting`. The legacy key is removed either way. Never overwrites an existing
    /// `row_edge_fade`. Runs once per launch from `NuvioTVApp.init`; a no-op once the legacy key is
    /// gone.
    static func migrateLegacy(_ defaults: UserDefaults) {
        guard defaults.object(forKey: legacyKey) != nil else { return }
        if defaults.object(forKey: defaultsKey) == nil,
           let carried = legacySetting(defaults.integer(forKey: legacyKey)) {
            defaults.set(carried.rawValue, forKey: defaultsKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    /// The setting an old A/B value (0 hard, 1 soft, 2 automatic, 3 off) carries across as, or nil
    /// to land on `defaultValue`. Christian 2026-10-04, once the F.5 gate made Off the default: an
    /// explicit Soft, Automatic (now System) or Off choice carries across, so a tester who picked
    /// Soft keeps it and an Off pick stays Off if the default ever moves again. Hard has no
    /// counterpart and follows the default.
    static func legacySetting(_ legacy: Int) -> RowEdgeFadeSetting? {
        switch legacy {
        case legacySoftValue: return .soft
        case legacyAutomaticValue: return .system
        case legacyOffValue: return .off
        default: return nil
        }
    }

    /// The picker label. All three strings already exist in the catalog (the Developer A/B used
    /// them).
    var label: String {
        switch self {
        case .soft: return String(localized: "Soft")
        case .system: return String(localized: "System")
        case .off: return String(localized: "Off")
        }
    }
}

/// F (critique #13): the distance from a row ScrollView's frame edges to the visible screen edges
/// (a nav rail's edge counts as the leading screen edge). Every row reads it through
/// `rowEdgeEffectStyle()`, so a host with different chrome (the Stage strip with the rail Always
/// Visible) sets it ONCE on its container and no row type changes.
nonisolated struct RowEdgeMargins: Equatable, Sendable {
    var leading: CGFloat
    var trailing: CGFloat

    init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }

    static var standard: RowEdgeMargins {
        RowEdgeMargins(leading: RowSoftEdgeMask.margin, trailing: RowSoftEdgeMask.margin)
    }
}

// Manual keys rather than `@Entry`, matching every other environment key in this target (default
// MainActor isolation).
private struct RowEdgeMarginsKey: EnvironmentKey {
    static let defaultValue: RowEdgeMargins = .standard
}

private struct RowEdgeRampLengthKey: EnvironmentKey {
    static let defaultValue: CGFloat = RowEdgeFade.rampLength
}

extension EnvironmentValues {
    /// F: see `RowEdgeMargins`. Default `.standard` (140 pt each side).
    var rowEdgeMargins: RowEdgeMargins {
        get { self[RowEdgeMarginsKey.self] }
        set { self[RowEdgeMarginsKey.self] = newValue }
    }

    /// F: the ramp length from the bezel inward. Default `RowEdgeFade.rampLength` (250 pt).
    var rowEdgeRampLength: CGFloat {
        get { self[RowEdgeRampLengthKey.self] }
        set { self[RowEdgeRampLengthKey.self] = newValue }
    }
}

// MARK: - The mask

/// rc14 (BUG-118, Steven rc13 verdict, 2026-09-30): the app-drawn symmetric edge fade behind Soft.
///
/// beta.18 verdict (BUG-118, R3): a `.mask` hides everything outside its own bounds, and the real
/// margin to the bezel is `Theme.Spacing.screen` + the side safe area (~140 pt), so the mask
/// extends that margin past both sides of the row frame. At rest the leading piece reproduces
/// BUG-92's hard cut at exactly `−restClipAllowance` (clear before it, solid after); with allowance
/// 0 (rows without a clip) it is solid across the whole margin, so the first card is never faded
/// at offset 0.
///
/// beta.19-rc1 verdict (F, FEAT-54): each ramp now runs `rampLength` in from the bezel (clamped to
/// the margin plus half the row, so the two ramps never overlap), drawn with `EdgeFadeCurve`'s
/// smootherstep stops instead of a two-stop linear gradient. The vertical overdraw drops from
/// 400 pt to `verticalOverdraw` (160): a smaller offscreen pass per row that still covers every
/// pixel the focus engine treats as part of the focused card (see the constant).
struct RowSoftEdgeMask: View {
    let restClipAllowance: CGFloat
    let leadingActive: Bool
    /// beta.19-rc1 verdict (review r1, B P2-2): false while the host holds the trailing fade off
    /// (a wide inline trailer tile its morph scroll could not bring clear of the ramp).
    var trailingActive: Bool = true
    var margins: RowEdgeMargins = .standard
    var rampLength: CGFloat = RowEdgeFade.rampLength

    nonisolated static var margin: CGFloat { Theme.Spacing.screen + PinnedRowGeometry.sideSafeArea }

    /// F (critique #12) sized it at 72: the focus lift (20) + the card shadow radius (22) + its y
    /// offset (10) + the ring (4) + 16 slack, everything a focused card DRAWS past the row frame.
    /// Gate 4 (main session, 2026-10-03): that was too tight for the focus engine. In pinned mode a
    /// card's focus frame carries the row's top reach (88 pt), and a mask that clipped it moved the
    /// engine's rest by 14 pt (FA87: Off and Soft@400/@160 rest at y=51, Soft@72 at y=37, title
    /// margin 6 vs 20). 160 = 88 reach + 20 lift + 52 slack keeps the rest identical to Off.
    nonisolated static let verticalOverdraw: CGFloat = 160

    nonisolated enum Kind: Equatable { case clear, solid, rampIn, rampOut }

    nonisolated struct Segment: Equatable {
        let start: CGFloat
        let end: CGFloat
        let kind: Kind
    }

    /// The ramp actually drawn on one side: `rampLength`, at most that side's margin plus half the
    /// row width (so the leading and trailing ramps never overlap on a narrow row), never negative.
    nonisolated static func effectiveRamp(_ rampLength: CGFloat, margin: CGFloat, width: CGFloat) -> CGFloat {
        max(0, min(rampLength, margin + max(width, 0) / 2))
    }

    /// beta.19-rc1 verdict (review r1, B P2-2): how far INSIDE the row frame the trailing ramp
    /// starts (the drawn ramp minus the margin outside the frame), 0 when it ends at or outside the
    /// frame. With the standard 140 pt margin and 250 pt ramp: 110.
    nonisolated static func trailingInnerExtent(width: CGFloat, margins: RowEdgeMargins, rampLength: CGFloat) -> CGFloat {
        let mt = max(margins.trailing, 0)
        return max(0, effectiveRamp(rampLength, margin: mt, width: width) - mt)
    }

    /// Pure geometry in row-local x: the leading piece starts at −margins.leading (the bezel), the
    /// trailing one ends at width + margins.trailing.
    ///
    /// - Scrolled: `[−ml, −ml + L] rampIn`, then `solid` up to `width + mt − L`.
    /// - At rest: unchanged since BUG-92 — `[−ml, −allowance] clear` + `[−allowance, 0] solid`
    ///   (or `[−ml, 0] solid` with no allowance), then `solid` from 0.
    /// - Trailing active (the normal case): `[width + mt − L, width + mt] rampOut`.
    /// - Trailing held (review r1, B P2-2): `solid` all the way to `width + mt`, then a zero-width
    ///   `rampOut` there, so the segment count never changes and the hold eases in and out as a
    ///   width change instead of a piece appearing.
    nonisolated static func segments(width: CGFloat, margins: RowEdgeMargins, rampLength: CGFloat,
                                     restClipAllowance: CGFloat, leadingActive: Bool,
                                     trailingActive: Bool = true) -> [Segment] {
        let width = max(width, 0)
        let ml = max(margins.leading, 0)
        let mt = max(margins.trailing, 0)
        let leadRamp = effectiveRamp(rampLength, margin: ml, width: width)
        let trailRamp = trailingActive ? effectiveRamp(rampLength, margin: mt, width: width) : 0
        let trailStart = width + mt - trailRamp

        var out: [Segment] = []
        let solidFrom: CGFloat
        if leadingActive {
            out.append(Segment(start: -ml, end: -ml + leadRamp, kind: .rampIn))
            solidFrom = -ml + leadRamp
        } else {
            let allowance = min(max(restClipAllowance, 0), ml)
            if allowance > 0 {
                out.append(Segment(start: -ml, end: -allowance, kind: .clear))
                out.append(Segment(start: -allowance, end: 0, kind: .solid))
            } else {
                out.append(Segment(start: -ml, end: 0, kind: .solid))
            }
            solidFrom = 0
        }
        // `solidFrom ≤ trailStart` always holds (both ramps are capped at margin + width/2), so the
        // middle piece is never negative; it can be zero-width on a very narrow row.
        out.append(Segment(start: solidFrom, end: max(solidFrom, trailStart), kind: .solid))
        out.append(Segment(start: max(solidFrom, trailStart), end: width + mt, kind: .rampOut))
        return out
    }

    var body: some View {
        // The row's own size (a mask is proposed the masked view's size). Read once per layout of
        // the ScrollView's frame, which does not change while the row scrolls.
        GeometryReader { geo in
            let parts = Self.segments(width: geo.size.width, margins: margins, rampLength: rampLength,
                                      restClipAllowance: restClipAllowance, leadingActive: leadingActive,
                                      trailingActive: trailingActive)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, seg in
                    Self.piece(seg.kind)
                        .frame(width: max(0, seg.end - seg.start))
                }
            }
            // Paint past the frame: `margins` sideways (the pieces sum to exactly
            // width + leading + trailing), `verticalOverdraw` above and below.
            .padding(.leading, -max(margins.leading, 0))
            .padding(.trailing, -max(margins.trailing, 0))
            .padding(.vertical, -Self.verticalOverdraw)
        }
    }

    @ViewBuilder
    private static func piece(_ kind: Kind) -> some View {
        switch kind {
        case .clear:
            Color.clear
        case .solid:
            Color.black
        case .rampIn:
            LinearGradient(stops: EdgeFadeCurve.stops(rising: true), startPoint: .leading, endPoint: .trailing)
        case .rampOut:
            LinearGradient(stops: EdgeFadeCurve.stops(rising: false), startPoint: .leading, endPoint: .trailing)
        }
    }
}

extension View {
    /// Attach to a row's horizontal `ScrollView` (the same receiver `.scrollClipDisabled()`
    /// already sits on) — see `RowEdgeEffectStyleModifier` for the setting and its legs.
    ///
    /// `leadingClipAllowance`: the row's rest-state `RowLeadingEdgeClip` allowance (catalog rows),
    /// which Soft's mask reproduces itself; 0 for rows with no leading clip.
    /// `margins` / `rampLength`: override the environment (`rowEdgeMargins`, `rowEdgeRampLength`)
    /// for this one row when non-nil. Prefer setting the environment on the host container.
    /// `holdsTrailingFade`: Soft draws the trailing side solid while true (a wide inline trailer
    /// tile the row could not scroll clear of the ramp, review r1 B P2-2). Default false.
    func rowEdgeEffectStyle(leadingClipAllowance: CGFloat = 0, margins: RowEdgeMargins? = nil,
                            rampLength: CGFloat? = nil, holdsTrailingFade: Bool = false) -> some View {
        modifier(RowEdgeEffectStyleModifier(leadingClipAllowance: leadingClipAllowance,
                                            margins: margins, rampLength: rampLength,
                                            holdsTrailingFade: holdsTrailingFade))
    }
}
