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
            .modifier(RowSoftEdgeMaskModifier(active: mode == 1, leadingActive: scrolled))
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
                Text("row_edge_fade_probe mode=\(mode)")
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.mask { RowSoftEdgeMask(leadingActive: leadingActive) }
        } else {
            content
        }
    }
}

/// rc14 (BUG-118, Steven rc13 verdict, 2026-09-30): the app-drawn symmetric edge fade behind Soft.
///
/// Built as an `HStack(spacing: 0)` of three pieces — a leading `.clear → .black` ramp, a solid
/// `.black` middle, a trailing `.black → .clear` ramp — enlarged past the row's frame with NEGATIVE
/// padding. Every row `ScrollView` this attaches to uses `.scrollClipDisabled()` so cards bleed past
/// the frame into the screen margin (BUG-103) and their focus lift/ring/shadow overflow vertically;
/// a mask sized to the frame would clip all of that. Negative padding enlarges the mask beyond the
/// proposed size, so it still covers the overflow:
///
///   - horizontally by `bleed` (= `Theme.Spacing.screen`, 60 pt): the trailing fade then sits in the
///     screen margin where the cards actually exit, and — when the leading piece is solid (row at
///     rest) — the leading edge's lift/ring allowance is not clipped either;
///   - vertically by 400 pt, far more than any lift/ring/shadow reaches.
///
/// The leading ramp draws only once the row has scrolled (`leadingActive`); at rest that piece is
/// solid black so the first card is never faded. The ramps are 48 pt each (`fadeWidth`).
private struct RowSoftEdgeMask: View {
    let leadingActive: Bool

    private let fadeWidth: CGFloat = 48
    private let bleed = Theme.Spacing.screen

    var body: some View {
        // Review r1 P2: the leading ramp sits INSIDE the row's frame ([0, 48]) rather than in the
        // margin outside it, because catalog rows already hard-clip their leading edge at
        // `−allowance` (`RowLeadingEdgeClip`, ≈ −30) — a ramp placed out there would be cut mid-way
        // and the edge would still read hard. Inside the frame the exiting card fades over the
        // first 48 pt and is already transparent by the time the clip takes it. At offset 0 the
        // whole leading band (margin + 48) stays solid so card #1's bleed into the margin
        // (BUG-103) is untouched. The trailing ramp stays in the margin, where cards leave through
        // the screen edge with no clip in the way.
        HStack(spacing: 0) {
            if leadingActive {
                Color.clear.frame(width: bleed)
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
            } else {
                Color.black.frame(width: bleed + fadeWidth)
            }
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
        }
        .padding(.horizontal, -bleed)
        .padding(.vertical, -400)
    }
}

extension View {
    /// Attach to a row's horizontal `ScrollView` (the same receiver `.scrollClipDisabled()`
    /// already sits on) — see `RowEdgeEffectStyleModifier`'s header for the full BUG-118 argument.
    func rowEdgeEffectStyle() -> some View {
        modifier(RowEdgeEffectStyleModifier())
    }
}
