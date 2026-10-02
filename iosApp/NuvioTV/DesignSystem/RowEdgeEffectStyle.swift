import SwiftUI

/// BUG-118 (rc13, Steven's rc12 verdict): "the row edge fade is intermittent". There is no
/// app-drawn fade anywhere on Home's rows (rc14 adds one, behind Soft, mode 1 — see below) — the leading edge of a catalog row is a hard
/// `RowLeadingEdgeClip` (BUG-92, see that type), the trailing edge is unclipped
/// (`.scrollClipDisabled()`), and what he is actually seeing is tvOS 26's SYSTEM scroll-edge
/// effect on each row's own horizontal `ScrollView`, left at its default `.automatic` style. That
/// system effect only draws where content continues PAST the edge — present once a row has been
/// scrolled a few cards in, absent at rest (offset 0), and it interacts unevenly with
/// `RowLeadingEdgeClip` on catalog rows (the clip and the system effect are computed
/// independently, so a scrolled catalog row can show the effect on one edge and not the other).
/// That presence-dependent flicker is the "intermittent" he is describing.
///
/// This mirrors `HomeScrollEdgeStyleModifier` (`HomeView.swift`), the existing vertical-scroll
/// analogue already shipped as a Settings A/B for the tab bar's top edge (BUG-30) — same shape,
/// same reasoning: `scrollEdgeEffectStyle(_:for:)` is the only supported lever over this system
/// behavior on tvOS 26, and it can only be judged on real hardware, so it ships as a knob rather
/// than a silent default change.
///
/// `debug.rowEdgeFade` (Int, LIVE `@AppStorage` — reacts immediately, no relaunch, same as
/// `debug.homeScrollEdgeHard`):
///   0 = `.hard`      — a hard-EDGED effect style. This is NOT "no effect" (an earlier version of
///                      this comment claimed it was, citing "Apple's docs: `.hard` always
///                      suppresses the effect" — that was wrong; `.hard` still draws an edge
///                      treatment, it is just a crisp one rather than a soft gradient, the same
///                      "draws a crisp line" behavior `HomeScrollEdgeStyleModifier`'s own BUG-30
///                      note records for the vertical analogue). The API that actually removes the
///                      effect is `scrollEdgeEffectHidden(_:for:)`, mode 3 below.
///   1 = Soft         — rc14 (Steven rc13 verdict, 2026-09-30): an APP-DRAWN symmetric fade, no
///                      longer the system `.soft` style. He sees no difference between the four
///                      settings on hardware: tvOS renders `.hard`/`.soft`/`.automatic` the same
///                      (the sim evidence below says the same), and the only fade he does see is the
///                      system effect at the TRAILING screen edge while the LEADING edge is a hard
///                      clip. Soft therefore hides the system effect
///                      (`scrollEdgeEffectHidden(true)`, so the two do not double up) and masks the
///                      row itself: a 48 pt `.clear → .black` ramp on the leading edge (only once the
///                      row has scrolled — at rest the leading piece is solid so the first card is
///                      never faded) and a 48 pt `.black → .clear` ramp on the trailing edge. See
///                      `RowSoftEdgeMask` for the geometry and why it must not clip the overflow.
///   2 = `.automatic` — today's un-set behavior (present only past the edge, absent at rest).
///                      SHIPPED DEFAULT — byte-identical to what every build before this one
///                      already renders, until Steven's device A/B picks a different leg.
///   3 = hidden       — `scrollEdgeEffectHidden(true, for: .horizontal)`, the actual "no fade,
///                      ever" lever.
///
/// Sim spike evidence (`docs/research/rc13-sim-evidence/bug118-{hard,soft,auto}-{0,3,12}.png`,
/// same catalog row via `test70RowEdgeFadeSpike`, at scroll offset 0 / after 3 Rights / after 12
/// Rights): the three screenshots at offset 3 are BYTE-IDENTICAL across all three legs (same MD5),
/// and so are the three at offset 12 — `scrollEdgeEffectStyle(_:for:.horizontal)` renders no
/// visible difference at all between `.hard`, `.soft` and `.automatic` on this simulator/OS build.
/// That is consistent with, not a contradiction of, `HomeScrollEdgeStyleModifier`'s own note that
/// its vertical analogue "draws a crisp line ... which no simulator gate can judge" — the sim
/// proves nothing about which of the four legs is right, only that the knob compiles, reaches the
/// row, and breaks nothing. The default therefore stays at today's behavior (`.automatic`, mode 2)
/// rather than guessing; Steven's own A/B on his Apple TV (the rc13 DM ask) is what decides.
struct RowEdgeEffectStyleModifier: ViewModifier {
    @AppStorage("debug.rowEdgeFade") private var mode = 2

    /// beta.18 verdict (BUG-118, R3): the row's own rest-state leading clip allowance (catalog
    /// rows only; 0 = no clip, the mask keeps the full leading bleed). Soft pushes the real clip
    /// out of the way, so the mask reproduces the hard cut at exactly this distance at rest.
    let leadingClipAllowance: CGFloat

    init(leadingClipAllowance: CGFloat = 0) {
        self.leadingClipAllowance = leadingClipAllowance
    }

    /// Plain computed property, not a `@ViewBuilder` switch — see `body` below for why that
    /// distinction matters here.
    private var style: ScrollEdgeEffectStyle {
        switch mode {
        case 0: return .hard
        // rc14: Soft is app-drawn (the mask below) with the system effect hidden, so the style
        // argument is inert for mode 1 — `.soft` is kept only so the argument stays a real style.
        case 1: return .soft
        default: return .automatic
        }
    }

    /// rc14 (Soft, mode 1): true once the row has scrolled off its resting offset. Driven by
    /// `onScrollGeometryChange` below with a Bool transform, so it writes state only when the
    /// offset CROSSES 0 — never per frame (the BUG-19/BUG-41 rule: no per-frame @State writes on a
    /// row ScrollView).
    @State private var scrolled = false

    func body(content: Content) -> some View {
        content
            // Both modifiers are applied unconditionally, with the mode folded into their
            // arguments rather than into an `if`/`switch` over the modifier chain itself. A
            // `@ViewBuilder switch` here would put each leg on a different `_ConditionalContent`
            // branch, which SwiftUI treats as a different view identity — flipping this picker
            // would then re-mount the row's `ScrollView` and lose its scroll offset/focus. Passing
            // `style` and the `mode == 3 || mode == 1` Bool as plain arguments keeps one identity
            // across every leg (rc14: except the Soft mask branch, see `RowSoftEdgeMaskModifier`
            // below).
            .scrollEdgeEffectStyle(style, for: .horizontal)
            // Off (3) and Soft (1, rc14) both hide the system effect: Off to remove it, Soft so the
            // app-drawn mask below is the ONLY fade (otherwise the trailing edge would double up).
            .scrollEdgeEffectHidden(mode == 3 || mode == 1, for: .horizontal)
            // rc14: applied unconditionally (cheap — the Bool transform only fires its action on a
            // 0-crossing) so the Soft mask can appear without remounting the ScrollView.
            .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.x > 1 }, action: { _, new in
                scrolled = new
            })
            // Branch is allowed here, unlike the style arguments above, because mode 1 is an About
            // A/B picker value — it is flipped from Settings, never while a row is mid-scroll — so
            // the one-time identity change on a flip is acceptable. Note the SOFT/non-soft split is
            // the only `if` in the chain; the `.mask` itself never changes the ScrollView's frame
            // or layout (it paints enlarged, see `RowSoftEdgeMask`).
            .modifier(RowSoftEdgeMaskModifier(active: mode == 1, leadingActive: scrolled,
                                           restClipAllowance: leadingClipAllowance))
            // Since the sim spike proved the three original legs render byte-identical here, the
            // one thing left for a UI test to verify on this simulator is that the launch-arg
            // override actually reached this row's own `@AppStorage` — same hidden single-Text
            // pattern as `hero_probe_blob`/`settle_probe_blob`. Harmless to repeat across the four
            // rows this modifier attaches to; each just re-states the same live value. DEBUG-only:
            // every other `debug_*` probe in this codebase is gated the same way, and this one has
            // no release-safe switch (unlike the hero/row-settle probes) to justify shipping it to
            // testers. `test70RowEdgeFadeSpike` builds Debug, so the gate costs it nothing.
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                Text("row_edge_fade_probe mode=\(mode) margin=\(Int(RowSoftEdgeMask.margin))")
                    .font(.system(size: 4))
                    .opacity(0.011)
                    .accessibilityIdentifier("row_edge_fade_probe")
            }
            #endif
    }
}

/// rc14: applies `RowSoftEdgeMask` only while `active` (Soft, mode 1).
private struct RowSoftEdgeMaskModifier: ViewModifier {
    let active: Bool
    let leadingActive: Bool
    let restClipAllowance: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask {
                RowSoftEdgeMask(restClipAllowance: restClipAllowance, leadingActive: leadingActive)
                    // beta.18 verdict (BUG-118, R3): softens the rest-cut -> ramp flip when the row
                    // first scrolls; the device pass may remove it.
                    .animation(.easeOut(duration: 0.15), value: leadingActive)
            }
        } else {
            content
        }
    }
}

/// rc14 (BUG-118, Steven rc13 verdict, 2026-09-30): the app-drawn symmetric edge fade behind Soft.
///
/// beta.18 verdict (BUG-118, R3): Steven saw the fade end short of the screen edges. A `.mask`
/// hides everything outside its own bounds, and the old mask spanned only 60 pt past the row frame
/// while the real margin to the bezel is `Theme.Spacing.screen` + the side safe area (~140 pt). The
/// mask now extends `margin` past both sides and the ramps span the whole margin. At rest the
/// leading piece reproduces BUG-92's hard cut at exactly `−restClipAllowance` (clear before it,
/// solid after); with allowance 0 (rows without a clip) it is solid across the whole margin.
/// Scrolled, it is a `margin`-wide `.clear → .black` ramp. Vertical overdraw stays 400 pt so
/// lift/ring/shadow are not clipped.
struct RowSoftEdgeMask: View {
    let restClipAllowance: CGFloat
    let leadingActive: Bool

    nonisolated static var margin: CGFloat { Theme.Spacing.screen + PinnedRowGeometry.sideSafeArea }

    nonisolated enum Kind: Equatable { case clear, solid, rampIn, rampOut }

    nonisolated struct Segment: Equatable {
        let start: CGFloat
        let end: CGFloat
        let kind: Kind
    }

    /// Pure geometry in row-local x: leading piece starts at −margin, trailing ends at width + margin.
    nonisolated static func segments(width: CGFloat, margin: CGFloat, restClipAllowance: CGFloat,
                                     leadingActive: Bool) -> [Segment] {
        var out: [Segment] = []
        if leadingActive {
            out.append(Segment(start: -margin, end: 0, kind: .rampIn))
        } else {
            let allowance = min(max(restClipAllowance, 0), margin)
            if allowance > 0 {
                out.append(Segment(start: -margin, end: -allowance, kind: .clear))
                out.append(Segment(start: -allowance, end: 0, kind: .solid))
            } else {
                out.append(Segment(start: -margin, end: 0, kind: .solid))
            }
        }
        out.append(Segment(start: 0, end: width, kind: .solid))
        out.append(Segment(start: width, end: width + margin, kind: .rampOut))
        return out
    }

    var body: some View {
        let margin = Self.margin
        // Piece widths come from `segments` (width 0 for the middle; it is the flexible Color.black).
        let parts = Self.segments(width: 0, margin: margin, restClipAllowance: restClipAllowance,
                                  leadingActive: leadingActive)
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, seg in
                switch seg.kind {
                case .clear:
                    Color.clear.frame(width: seg.end - seg.start)
                case .rampIn:
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: seg.end - seg.start)
                case .rampOut:
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: seg.end - seg.start)
                case .solid:
                    if seg.end > seg.start {
                        Color.black.frame(width: seg.end - seg.start)
                    } else {
                        Color.black // the middle: width-flexible
                    }
                }
            }
        }
        .padding(.horizontal, -margin)
        .padding(.vertical, -400)
    }
}

extension View {
    /// Attach to a row's horizontal `ScrollView` (the same receiver `.scrollClipDisabled()`
    /// already sits on) — see `RowEdgeEffectStyleModifier`'s header for the full BUG-118 argument.
    ///
    /// `leadingClipAllowance`: the row's rest-state `RowLeadingEdgeClip` allowance (catalog rows),
    /// which Soft's mask reproduces itself; 0 for rows with no leading clip.
    func rowEdgeEffectStyle(leadingClipAllowance: CGFloat = 0) -> some View {
        modifier(RowEdgeEffectStyleModifier(leadingClipAllowance: leadingClipAllowance))
    }
}
