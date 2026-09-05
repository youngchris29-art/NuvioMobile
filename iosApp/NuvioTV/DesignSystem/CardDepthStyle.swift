import Combine
import SwiftUI
import SharedCore

/// Which on-screen card family a depth treatment applies to. Mirrors the shared
/// `NuvioCardDepthSurface` enum, but kept as a Swift enum so call sites and the resolver can `switch`
/// cleanly instead of bridging a Kotlin enum across the ObjC boundary.
enum CardDepthSurface {
    case posters
    case continueWatching
    case episodeCards
    case cast
    case trailers
}

/// Resolved card-depth styling for the tvOS UI, derived from the shared `CardDepthStyleRepository`
/// (which stores the preference profile-scoped and syncs it across devices). The look is an inset
/// edge highlight plus a top sheen — a direct port of the Compose `cardDepthVisual`. Disabled by
/// default; the master toggle and each surface can be switched independently.
struct CardDepthStyle: Equatable {
    /// BUG-57: top-stop opacity for the partial-coverage (Top/Half) rail — the configured edge
    /// strength (0…1) lifted ×1.5, capped so Bold doesn't blow out. Pure so it is unit-testable;
    /// Full never calls it (its closed 1 pt stroke is unchanged).
    static func partialCoverageRailBoost(edge: Double) -> Double {
        min(max(edge, 0) * 1.5, 0.9)
    }

    /// Tester (u/mrStevenx3-class report, beta.15): "Card Depth appears thick even when I select
    /// Subtle." Root cause: the partial-coverage rail's `lineWidth` used to be keyed on COVERAGE
    /// (Top/Half vs Full), not on the user's STRENGTH choice — every partial-coverage rail drew at
    /// 2pt regardless of Subtle/Balanced/Bold. Since Subtle+Top is the *default* combination, that
    /// made the out-of-the-box look thicker and brighter than even Bold+Full's 1pt closed stroke —
    /// exactly backwards from what "Subtle" should mean.
    ///
    /// Width now follows edge STRENGTH instead: at/below the Subtle preset band the rail stays a 1pt
    /// hairline; above it, 2pt as before. Full coverage is untouched — it never calls this, and stays
    /// a pixel-identical 1pt closed stroke at every strength.
    ///
    /// The `28` threshold mirrors `AppearanceSettingsPane`'s Subtle/Balanced/Bold preset mapping
    /// (28/42/56 out of 0…100). That mapping is UI-layer and not shared with this design-system file,
    /// so the value is duplicated here rather than importing the pane — keep the two in sync by hand
    /// if the presets ever move.
    ///
    /// BUG-57 interplay: dropping to 1pt does NOT drop the opacity boost from
    /// `partialCoverageRailBoost` above. BUG-57's finding was that a bare 1pt rail at partial coverage
    /// reads as nothing from a couch — a 1pt rail needs the boost *more* than a 2pt one does, not
    /// less, so the boost stays applied at both widths. Only the width follows strength; the boost
    /// keeps doing its job of making a thin rail visible.
    static func partialCoverageRailWidth(edgeStrength: Int) -> CGFloat {
        edgeStrength <= 28 ? 1 : 2
    }
    var enabled = false
    /// 0…100. Opacity of the inset edge highlight at the top of the card. Default mirrors the shared
    /// `DefaultCardDepthEdgeStrength` (28).
    var edgeStrength = 28
    /// 0…100. Opacity of the top sheen. Default mirrors the shared `DefaultCardDepthSheenStrength` (10).
    var sheenStrength = 10
    /// 0…100. How far the edge highlight carries toward the bottom edge. Default mirrors the shared
    /// `DefaultCardDepthEdgeCoverage` (0 — highlight fades out before the bottom).
    var edgeCoverage = 0
    var postersEnabled = true
    var continueWatchingEnabled = true
    var episodeCardsEnabled = true
    var castEnabled = true
    var trailersEnabled = true

    static let `default` = CardDepthStyle()

    init() {}

    init(from state: CardDepthStyleUiState) {
        enabled = state.enabled
        edgeStrength = Int(state.edgeStrength)
        sheenStrength = Int(state.sheenStrength)
        edgeCoverage = Int(state.edgeCoverage)
        postersEnabled = state.postersEnabled
        continueWatchingEnabled = state.continueWatchingEnabled
        episodeCardsEnabled = state.episodeCardsEnabled
        castEnabled = state.castEnabled
        trailersEnabled = state.trailersEnabled
    }

    /// Whether the depth treatment should render for `surface` — the master toggle AND the per-surface
    /// flag both have to be on.
    func isEnabled(for surface: CardDepthSurface) -> Bool {
        guard enabled else { return false }
        switch surface {
        case .posters: return postersEnabled
        case .continueWatching: return continueWatchingEnabled
        case .episodeCards: return episodeCardsEnabled
        case .cast: return castEnabled
        case .trailers: return trailersEnabled
        }
    }
}

private struct CardDepthStyleKey: EnvironmentKey {
    static let defaultValue = CardDepthStyle.default
}

extension EnvironmentValues {
    var cardDepthStyle: CardDepthStyle {
        get { self[CardDepthStyleKey.self] }
        set { self[CardDepthStyleKey.self] = newValue }
    }
}

/// Observes the shared `CardDepthStyleRepository` and republishes a resolved `CardDepthStyle` for the
/// environment. Owned at the app root and injected via `.environment(\.cardDepthStyle,)`; profile-scoped
/// (the repo reloads on profile switch through the lifecycle coordinator). Mirrors `PosterStyleModel`.
@MainActor
final class CardDepthStyleModel: ObservableObject {
    @Published private(set) var style = CardDepthStyle.default

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        CardDepthStyleRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(CardDepthStyleRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? CardDepthStyleUiState else { return }
            self.style = CardDepthStyle(from: state)
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}

extension View {
    /// Applies the shared card-depth treatment (inset edge highlight + top sheen) for `surface`,
    /// reading the resolved style from the environment. A no-op when the user has the effect — or this
    /// surface — turned off, so callers can attach it unconditionally right after the card's `clipShape`.
    ///
    /// **Attach it to the ARTWORK, never to the card lockup.** Both gradients here — the sheen's top
    /// 22% and the edge highlight's coverage mask — measure 0…1 down *this view's* own height, so the
    /// box this modifier lands on defines what "Top" means. On the artwork frame that is the artwork's
    /// top edge (correct); hoisted onto a caption-bearing lockup it would silently stretch the same
    /// band across artwork + title. BUG-36 moved the cards' focus treatment up to the lockup and
    /// deliberately left this modifier down on the artwork for exactly that reason — the coverage
    /// geometry below is unchanged and stays anchored where it always was.
    ///
    /// BUG-91 sharpens "the artwork" into **the INSET artwork frame, with the inset radius**.
    /// `PosterCard`/`LandscapeCard` reserve a `ringWidth` band around the picture whenever either
    /// focus ring can draw (`ringInset`), and they used to attach this modifier after re-framing
    /// back up to the card's outer size - so the rail traced the OUTER rect and stood 4pt off the
    /// picture on every edge of every card, at rest, which is what the beta.17 report calls "an
    /// empty band between the artwork and the card frame". Both cards now attach it to the smaller,
    /// clipped artwork box and pass `max(0, cornerRadius - inset)` - the same radius the artwork's
    /// own `clipShape` uses, so the rail is concentric with the picture's corner rather than with
    /// the ring's. Nothing about the geometry below changes: every fraction is relative to whatever
    /// box this lands on, so a 4pt-shorter box moves the bands by the same 4pt the picture moved.
    /// With no band reserved (ring off, zoom on) the two attachment points are the same rect and
    /// the render is unchanged.
    func nuvioCardDepth<S: InsettableShape>(_ shape: S, surface: CardDepthSurface) -> some View {
        modifier(CardDepthModifier(shape: shape, surface: surface))
    }
}

private struct CardDepthModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let surface: CardDepthSurface
    @Environment(\.cardDepthStyle) private var style

    func body(content: Content) -> some View {
        if style.isEnabled(for: surface) {
            content.overlay { CardDepthOverlay(shape: shape, style: style) }
        } else {
            content
        }
    }
}

/// Port of Compose `Modifier.cardDepthVisual`: a 1pt inset edge whose white highlight fades top→bottom
/// (governed by edge strength + coverage), plus a sheen gradient over the top 22% of the card. Both
/// are clipped to the card's own `shape` so rounded corners and circles stay clean.
private struct CardDepthOverlay<S: InsettableShape>: View {
    let shape: S
    let style: CardDepthStyle

    var body: some View {
        let edge = unit(style.edgeStrength)
        let sheen = unit(style.sheenStrength)
        let coverage = unit(style.edgeCoverage)

        ZStack {
            if sheen > 0 {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(sheen), location: 0),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            }
            if edge > 0 {
                edgeHighlight(edge: edge, coverage: coverage)
            }
        }
        .allowsHitTesting(false)
        // BUG-91 gate (test50): this ZStack fills whatever box `nuvioCardDepth` was attached to, so
        // its frame IS the rail's rect. Publishing it lets the harness assert "the rail hugs the
        // picture" against real geometry instead of hunting a 1-2pt hairline in a screenshot.
        // DEBUG-only, identifier-only - see `DebugAXIdentifier` (PosterCard.swift).
        .modifier(DebugAXIdentifier("card_depth_rail"))
    }

    /// The inset edge highlight, cut down to `coverage`.
    ///
    /// BUG-31: this used to be nothing but the closed `strokeBorder` below, with coverage ramping only
    /// the gradient's ALPHA down the Y axis. A closed stroke can never be "top only" that way — at
    /// coverage 0 ("Top") the top still painted at full edge opacity, the SIDES still painted at ~1/3
    /// opacity through mid-height, and only the bottom reached zero, so the card read as a gray
    /// hairline around all four edges. The stops are unchanged; the coverage cut is now GEOMETRIC.
    ///
    /// BUG-57 (u/mrStevenx3, the same reporter, on beta.11's arc): "Top is still not correct … Full
    /// works well." Sim A/B at 1:1 (2026-08-16, Bold edge): what Top left on screen was a 1 pt
    /// hairline at ≤56 % white over the top edge and corner shoulders — from a couch that reads as
    /// NOTHING, while Full's closed hairline still reads as an outline because a closed shape
    /// registers where a short arc does not. The partial modes therefore draw a heavier rail at low
    /// strength: up to 2 pt, with the top stop lifted (×1.5, capped) so a "lit from above" edge is
    /// actually visible at the same setting; the geometric mask is unchanged (still no side rails,
    /// no bottom). Full is untouched — same 1 pt closed stroke, pixel-identical to before.
    ///
    /// Tester follow-up ("Card Depth appears thick even when I select Subtle"): the line width used
    /// to be fixed at 2 pt for every partial-coverage rail, keyed only on coverage — so the default
    /// Subtle+Top combination drew thicker than Bold+Full. See
    /// `CardDepthStyle.partialCoverageRailWidth(edgeStrength:)` — width now follows the user's
    /// strength choice (1 pt at/below the Subtle preset, 2 pt above), while the opacity boost below
    /// still applies at both widths per BUG-57.
    @ViewBuilder
    private func edgeHighlight(edge: Double, coverage: Double) -> some View {
        if coverage >= 1 {
            // Full: no mask at all, so the full-perimeter look is pixel-identical to pre-BUG-31.
            edgeStroke(top: edge, mid: edge, bottom: edge, lineWidth: 1)
        } else {
            let lift = CardDepthStyle.partialCoverageRailBoost(edge: edge)
            edgeStroke(
                top: lift,
                mid: edge * (0.33 + 0.67 * coverage),
                bottom: edge * coverage,
                lineWidth: CardDepthStyle.partialCoverageRailWidth(edgeStrength: style.edgeStrength)
            )
            .mask { coverageMask(coverage) }
        }
    }

    private func edgeStroke(top: Double, mid: Double, bottom: Double, lineWidth: CGFloat) -> some View {
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(top), location: 0),
                    .init(color: .white.opacity(mid), location: 0.5),
                    .init(color: .white.opacity(bottom), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: lineWidth
        )
    }

    /// Vertical mask that makes the edge honor `coverage` geometrically: opaque through a short top
    /// band, fading to clear, and erased outright below — so at Top the highlight arcs over the upper
    /// corners and dies on their shoulders (no side rails, no bottom).
    ///
    ///     fadeEnd(c)   = 0.28 + 0.44·c + 0.28·c²      → 0.28 @ Top, 0.57 @ Half, 1.00 @ Full
    ///     fadeStart(c) = fadeEnd(c) · (0.35 + 0.65·c) → 0.10 @ Top, 0.39 @ Half, 1.00 @ Full
    ///
    /// Both are continuous and monotonic in `c` — the setting is 0…100 and the chips are only presets,
    /// so every intermediate value gets a sensible band. Both converge on 1.0 as c → 1, i.e. the mask
    /// degenerates to "opaque everywhere"; `edgeHighlight` takes that limit exactly by dropping the
    /// mask at Full rather than emitting coincident stops at location 1.
    ///
    /// The fractions are relative to the masked view's own height, and this overlay is sized to the
    /// card's artwork frame (see `nuvioCardDepth`), so the band is measured against the artwork —
    /// which is also why a uniform focus scale on the card can't disturb it: a scale multiplies both
    /// the stroke and its mask by the same factor, leaving every fraction where it was.
    private func coverageMask(_ coverage: Double) -> some View {
        let fadeEnd = min(0.28 + 0.44 * coverage + 0.28 * coverage * coverage, 1)
        let fadeStart = min(fadeEnd * (0.35 + 0.65 * coverage), fadeEnd)
        return LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: fadeStart),
                .init(color: .clear, location: fadeEnd),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Shared strengths are stored 0…100; the Compose port works in 0…1.
    private func unit(_ value: Int) -> Double {
        min(max(Double(value), 0), 100) / 100
    }
}
