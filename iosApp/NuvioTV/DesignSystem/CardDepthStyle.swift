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
    }

    /// The inset edge highlight, cut down to `coverage`.
    ///
    /// BUG-31: this used to be nothing but the closed `strokeBorder` below, with coverage ramping only
    /// the gradient's ALPHA down the Y axis. A closed stroke can never be "top only" that way — at
    /// coverage 0 ("Top") the top still painted at full edge opacity, the SIDES still painted at ~1/3
    /// opacity through mid-height, and only the bottom reached zero, so the card read as a gray
    /// hairline around all four edges. The stops are unchanged; the coverage cut is now GEOMETRIC.
    @ViewBuilder
    private func edgeHighlight(edge: Double, coverage: Double) -> some View {
        let stroke = shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(edge), location: 0),
                    .init(color: .white.opacity(edge * (0.33 + 0.67 * coverage)), location: 0.5),
                    .init(color: .white.opacity(edge * coverage), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
        )

        if coverage >= 1 {
            // Full: no mask at all, so the full-perimeter look is pixel-identical to pre-BUG-31.
            stroke
        } else {
            stroke.mask { coverageMask(coverage) }
        }
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
