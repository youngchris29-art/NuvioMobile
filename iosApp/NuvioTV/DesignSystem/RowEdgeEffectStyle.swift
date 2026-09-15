import SwiftUI

/// BUG-118 (rc13, Steven's rc12 verdict): "the row edge fade is intermittent". There is no
/// app-drawn fade anywhere on Home's rows today — the leading edge of a catalog row is a hard
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
///   1 = `.soft`      — system soft fade.
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
        case 1: return .soft
        default: return .automatic
        }
    }

    func body(content: Content) -> some View {
        content
            // Both modifiers are applied unconditionally, with the mode folded into their
            // arguments rather than into an `if`/`switch` over the modifier chain itself. A
            // `@ViewBuilder switch` here would put each leg on a different `_ConditionalContent`
            // branch, which SwiftUI treats as a different view identity — flipping this picker
            // would then re-mount the row's `ScrollView` and lose its scroll offset/focus. Passing
            // `style` and the `mode == 3` Bool as plain arguments keeps one identity across every
            // leg.
            .scrollEdgeEffectStyle(style, for: .horizontal)
            .scrollEdgeEffectHidden(mode == 3, for: .horizontal)
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

extension View {
    /// Attach to a row's horizontal `ScrollView` (the same receiver `.scrollClipDisabled()`
    /// already sits on) — see `RowEdgeEffectStyleModifier`'s header for the full BUG-118 argument.
    func rowEdgeEffectStyle() -> some View {
        modifier(RowEdgeEffectStyleModifier())
    }
}
