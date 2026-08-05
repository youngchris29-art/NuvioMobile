import SwiftUI

/// The standard portrait poster lockup used across catalog rows, search results, and "more like
/// this".
///
/// HIG revamp (see docs/design/hig-hybrid-contract.md): focus motion is the SYSTEM's job by
/// default. Use this view as the label of a `Button`/`NavigationLink` with
/// `.buttonStyle(.borderless)` — on tvOS the borderless style gives the lockup the native focus
/// treatment (lift, real Siri-Remote-tracking parallax, specular highlight, shadow).
///
/// BUG-36 (beta.10 regression, tester verdict): the focus treatment now hangs off the WHOLE card —
/// artwork *and* caption — instead of the artwork container alone. Focus used to "zoom only the
/// inside of the artwork" (the lift landed inside BUG-31's `.clipped()` layer, so the tile's own
/// edge never moved) and the focused title could disappear behind the lifted artwork. Both
/// symptoms are structural, and both are fixed by where the treatment is attached, not by tuning
/// numbers — see `CardFocusTreatment`.
///
/// ```swift
/// NavigationLink(value: route) { PosterCard(title: item.name, imageURL: item.poster) }
///     .buttonStyle(.borderless)
///     .posterButtonShape()   // BUG-25: without this the system radius overrides Corners
/// ```
/// BUG-25 (beta.8 regression): the borderless button style rounds its label artwork with a
/// SYSTEM corner radius, silently overriding the card's own `clipShape` — which is driven by
/// the user's Poster Style → Corners setting. `buttonBorderShape` is the supported lever for
/// the lockup's radius, so every card button attaches this modifier to make Corners visible
/// again (Square/Rounded/Round all rendered identically without it).
struct PosterButtonShape: ViewModifier {
    @Environment(\.posterStyle) private var style

    func body(content: Content) -> some View {
        content.buttonBorderShape(.roundedRectangle(radius: style.cornerRadius))
    }
}

extension View {
    /// Follow the user's Poster Style corner radius on a borderless card button — see
    /// [PosterButtonShape].
    func posterButtonShape() -> some View { modifier(PosterButtonShape()) }
}

/// FEAT-14 accent focus ring (final architecture — the third and last one, 2026-08-02): the ring
/// is a `.strokeBorder` drawn INSIDE the artwork's own `RoundedRectangle`, identical to the
/// inline-trailer surface's ring in `InlineTrailerCard` — same shape, same color, same 4pt width,
/// same "paints inside my own clipped bounds" contract. What changed in this final pass is the
/// hover treatment around it: when the ring is on, the card no longer uses the system
/// `.hoverEffect(.highlight)` at all. Instead it applies a manual `.scaleEffect` (see
/// `CardFocusTreatment` below) so the ring and the artwork scale up together as one layer, drawn
/// by SwiftUI in a single pass rather than composited by the system lift.
///
/// Why the swap is necessary (framebuffer-verified on tvOS 26 hardware, 2026-08-02): the system
/// `.hoverEffect(.highlight)` composites the artwork into its own lifted/scaled layer, and
/// SwiftUI shape overlays living in the same subtree do NOT get pulled into that layer — they
/// stay at base geometry. So no matter where the ring overlay sits relative to `.hoverEffect`,
/// the artwork's lifted/scaled copy ends up covering it, and device photos showed red corner arcs
/// of the ring peeking out from under the lifted artwork — a hardware compositor behavior the
/// Simulator does not reproduce. The inline-trailer ring never hit this because that surface
/// doesn't use `.hoverEffect` in the first place; ring mode now borrows that surface's approach
/// (a manual, SwiftUI-owned lift) instead of trying to make the system lift cooperate.
///
/// Graveyard (do not resurrect):
/// - Outside overpaint — a stroke drawn outside the artwork's own clip bounds: got clipped by the
///   row/lockup's layout bounds, cutting off the outer edge of the ring.
/// - Outside flush ring — `.padding(-ringOffset)` plus a transparent `ringMargin` grown around the
///   label to keep the overpaint inside the button's layout bounds so the hardware lockup
///   wouldn't clip it. Survived the clip problem, but device photos under the hover lift's shadow
///   showed the ring reading as a detached glow/halo behind the poster, not a border on it.
/// - Inside `strokeBorder` under the SYSTEM hover lift — geometrically the cleanest of the three
///   (same shape, same clip, "scales with the card as one unit" on paper), except on hardware the
///   system lift doesn't actually pull the overlay into its lifted layer, so the artwork's scaled
///   copy covers the ring at the corners. This is the failure the manual-scale swap above fixes.
private let ringWidth: CGFloat = 4      // thicker for 10-foot visibility

/// FEAT-14: approximates the magnitude of the system `.hoverEffect(.highlight)` lift, used by
/// `CardFocusTreatment`'s manual scale so ring mode's focused size roughly matches the size a
/// focused card would have under the default (non-ring) hover treatment.
private let cardRingLiftScale: CGFloat = 1.06

/// BUG-36: the ARTWORK's rounded rect, expressed in the WHOLE CARD's coordinate space.
///
/// The focus treatment moved from the artwork container up to the card lockup (artwork + caption)
/// so the whole card travels as one object. Everything that treatment draws still has to be shaped
/// like the *artwork*, though — a hover platter, highlight border or shadow that swallowed the
/// caption slot too would read as a grey slab behind the title. Every card in this file lays its
/// artwork out at the top of a leading-aligned `VStack` whose width the caption matches, so the
/// artwork is always `rect` cut down to `artworkHeight`.
///
/// `InsettableShape` so the still-mode highlight can use `strokeBorder` — same "paints strictly
/// inside my own bounds" contract as the accent ring (see the FEAT-14 note above; an outside
/// stroke gets clipped by the row's layout bounds).
struct CardArtworkShape: Shape, InsettableShape {
    var artworkHeight: CGFloat
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let height = min(artworkHeight, rect.height)
        let artwork = CGRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: max(rect.width - inset * 2, 0),
            height: max(height - inset * 2, 0)
        )
        return RoundedRectangle(cornerRadius: max(cornerRadius - inset, 0)).path(in: artwork)
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Which focus treatment a card wears. Resolved from two independent Appearance settings so the
/// three-way branch lives in exactly one place instead of being re-derived at every card.
///
/// - `.systemLift` — default (ring OFF, zoom ON): the native tvOS lockup treatment,
///   `.contentShape(.hoverEffect, …)` + `.hoverEffect(.highlight)`.
/// - `.manualScale` — ring ON, zoom ON: no `.hoverEffect` at all, a SwiftUI `.scaleEffect` stands
///   in for it (FEAT-14 — the system lift leaves shape overlays like the ring behind at base
///   geometry, so ring mode has to own the lift).
/// - `.still` — BUG-36's "No Zoom on Focus" (`no_zoom_on_focus`), either ring state: no scale of
///   any kind, focus is drawn as a highlight border plus a shadow.
enum CardFocusMode {
    case systemLift
    case manualScale
    /// `ringed` = the accent focus ring is already drawing on the artwork, so still mode must not
    /// paint its own neutral highlight border on top of it.
    case still(ringed: Bool)

    static func resolve(accentFocusRing: Bool, noZoomOnFocus: Bool) -> CardFocusMode {
        if noZoomOnFocus { return .still(ringed: accentFocusRing) }
        return accentFocusRing ? .manualScale : .systemLift
    }

    /// Every treatment SwiftUI draws itself needs an explicit `zIndex` to sit above its row
    /// neighbours — only the system lift raises the focused card implicitly (it composites into
    /// its own layer). See the `zIndex` call sites below.
    var raisesFocusedCard: Bool {
        if case .systemLift = self { return false }
        return true
    }
}

/// BUG-36 / FEAT-14: the card's focus treatment, attached to the WHOLE card lockup (the `VStack`
/// of artwork + caption) by both `PosterCard` and `LandscapeCard` so the branch isn't duplicated
/// at each call site.
///
/// **Where this is attached is the fix.** Pre-BUG-36 it hung off the artwork container, one level
/// below the caption — and BUG-31 had just added a `.clipped()` inside that container. The lift
/// then landed on the clipped image rather than on the tile: artwork zoomed *inside* a frozen
/// edge, and the growing artwork could cover the title underneath it (tester verdict). Moving the
/// treatment to the lockup makes the artwork, its `.clipped()` edge and the caption one object:
/// in every mode the caption travels with the artwork instead of being an unmoving thing the
/// artwork can grow over, so **the focused title can no longer be hidden in any mode**.
///
/// The clip stays where BUG-31 put it — directly on the image's own frame — because that is all it
/// was ever for: cropping the artwork's (and the UX-9 trailer overscale's) own overflow inside the
/// tile. It is now strictly interior to whatever scales, so it crops instead of capturing the lift.
///
/// What scales, per mode:
/// - `.systemLift` — the whole lockup. `.contentShape(.hoverEffect, CardArtworkShape)` keeps the
///   platter/specular geometry pinned to the ARTWORK's rounded rect (BUG-31/BUG-25: never let it
///   fall back to a system rect that extends past the artwork) while the effect itself is attached
///   to the card, so the caption rides along with the lift instead of standing still under it.
/// - `.manualScale` — the whole lockup, via `.scaleEffect`. Same magnitude as before, one level
///   up. Reduce Motion is honored explicitly here (the system lift respects it automatically, a
///   manual `.scaleEffect` does not) by skipping the animation and snapping straight to the
///   focused/unfocused scale — the ring still has to reach its scaled geometry to stay aligned
///   with the artwork, so scale itself is kept, not skipped.
/// - `.still` — nothing scales, ever. Focus reads as a border plus a drop shadow on the artwork
///   shape: the accent ring when the user has it on, otherwise a neutral white border of the same
///   weight, so ring-on and ring-off still modes are the same geometry in two colors and a
///   ring-off user is never left with an unmarked focused card. Reduce Motion skips the fade.
struct CardFocusTreatment: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: CardFocusMode
    let isFocused: Bool
    /// Height of the card's artwork — the caption is whatever sits below it. Drives
    /// `CardArtworkShape`, so pass the same value the artwork's `.frame(height:)` uses.
    let artworkHeight: CGFloat
    let cornerRadius: CGFloat

    private var artworkShape: CardArtworkShape {
        CardArtworkShape(artworkHeight: artworkHeight, cornerRadius: cornerRadius)
    }

    func body(content: Content) -> some View {
        switch mode {
        case .systemLift:
            content
                .contentShape(.hoverEffect, artworkShape)
                .hoverEffect(.highlight)
        case .manualScale:
            content
                .scaleEffect(isFocused ? cardRingLiftScale : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        case let .still(ringed):
            content
                // Behind the (opaque) artwork, so only the spill reads. Same weight as the inline
                // trailer surface's shadow, which is the other card face that never scales.
                .background {
                    if isFocused {
                        artworkShape
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
                    }
                }
                .overlay {
                    if isFocused && !ringed {
                        artworkShape.strokeBorder(stillHighlight, lineWidth: ringWidth)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        }
    }

    /// Still mode's ring-less focus border. Deliberately NOT the accent color — the accent ring is
    /// its own opt-in setting, and a user who left it off shouldn't get one by turning zoom off.
    /// Near-white at partial opacity reads as the system's own highlight edge at 10 feet without
    /// impersonating the ring.
    private var stillHighlight: Color { Color.white.opacity(0.85) }
}

/// FEAT-14: the ring's draw color, factored out of the two call sites below so they can't drift
/// apart — and so `InlineTrailerCard`'s inline-trailer surface can draw the identical color.
/// Device finding (2026-08-02): when a focused poster dwell-morphs into the inline trailer, the
/// landscape surface had no ring of its own, so the accent ring visibly vanished the instant the
/// morph fired. Pure extraction of the pre-existing `hex → focusRingHex → Color` derivation —
/// same fallback to `accentFocus` on a bad/empty hex — so this refactor changes no on-screen
/// behavior at either PosterCard call site.
extension Theme.Palette {
    static var focusRingColor: Color {
        Color(hexString: focusRingHex(accentFocusHex: accentFocusHex)) ?? accentFocus
    }
}

struct PosterCard: View {
    let title: String
    let imageURL: String?
    /// Explicit sizes override the environment style (used by the small "more like this" / credit
    /// rails); leave nil to follow the user's Poster Style setting.
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var showTitle: Bool? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF. Read independently (same UserDefaults key
    /// as `AppearanceSettingsPane`'s toggle) rather than threaded through props, so every card
    /// picks up the setting without a prop-drilling pass through every call site. When OFF the
    /// `if` below emits no overlay at all — no extra view/layer exists in the tree, keeping the
    /// OFF render byte-identical to pre-FEAT-14.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "No Zoom on Focus", default OFF. Same independent-read pattern (and the same
    /// UserDefaults key) as `AppearanceSettingsPane`'s toggle, so every card site inherits it
    /// without a prop-drilling pass. OFF resolves to the same two treatments as before.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    private var resolvedWidth: CGFloat { width ?? style.width }
    private var resolvedHeight: CGFloat { height ?? style.height }
    private var titleVisible: Bool { showTitle ?? style.showTitle }
    private var focusMode: CardFocusMode {
        .resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match LandscapeCard and expandedTile
            CachedAsyncImage(string: imageURL)
                .frame(width: resolvedWidth, height: resolvedHeight)
                // BUG-31: CachedAsyncImage is `.fill` with no clip of its own, and this frame is
                // always exactly 2:3 — so off-ratio artwork overflows it and the hover lift copies
                // the overflow too, drawing a ghost-doubled subject. Clip inside the frame first.
                // BUG-36: this clip must stay HERE, on the image's own frame, and nothing but the
                // artwork's overflow may depend on it — while the focus treatment hung off this
                // same container the lift landed inside the clip and zoomed the picture within a
                // frozen tile edge. The treatment now sits on the whole card (below), leaving the
                // clip purely as a crop.
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                // BUG-36: the card-depth overlay stays anchored to the ARTWORK's frame — its edge
                // coverage mask measures 0…1 down *this* box (see `CardDepthStyle.coverageMask`),
                // so hoisting it to the lockup would stretch "Top" across the caption slot too.
                .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
                // FEAT-14 (final): the ring is drawn on the artwork, inside its own clip bounds —
                // same inside-strokeBorder treatment as the trailer surface's ring in
                // `InlineTrailerCard`. See the file-level comment above for why this replaced the
                // earlier outside-flush-ring geometry. It rides whatever the whole-card focus
                // treatment below does, because it is part of that card.
                .overlay {
                    if accentFocusRing && isFocused {
                        RoundedRectangle(cornerRadius: style.cornerRadius)
                            .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                    }
                }

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: resolvedWidth, alignment: .leading)
            }
        }
        // BUG-36: the focus treatment belongs to the WHOLE card — artwork, ring and caption lift
        // (or, in still mode, stay put) as one object. `artworkHeight` keeps everything the
        // treatment draws shaped like the artwork rather than the lockup. See
        // `CardFocusTreatment` for what scales in each mode.
        .modifier(CardFocusTreatment(
            mode: focusMode,
            isFocused: isFocused,
            artworkHeight: resolvedHeight,
            cornerRadius: style.cornerRadius
        ))
        // FEAT-14/BUG-36: a treatment SwiftUI draws itself (ring mode's manual scale, still mode's
        // shadow) isn't lifted into a separate compositor layer the way the system hover effect is,
        // so without an explicit zIndex a focused card can render underneath its unfocused row
        // neighbors instead of above them. The system lift raises the focused card above its
        // siblings implicitly; this is the explicit equivalent, and it stays scoped to the modes
        // that need it so the default (system-lift) path's stacking is completely untouched.
        .zIndex(focusMode.raisesFocusedCard && isFocused ? 1 : 0)
    }
}

/// Landscape (16:9) lockup used for the Continue Watching row: artwork with a progress bar and a
/// title that brightens on focus. Same system focus language as `PosterCard` — use with
/// `.buttonStyle(.borderless)`.
struct LandscapeCard: View {
    let title: String
    let imageURL: String?
    /// 0...1 watched fraction; pass nil to hide the progress bar.
    var progress: Double? = nil
    var width: CGFloat = Theme.Size.landscapeWidth
    var height: CGFloat = Theme.Size.landscapeHeight
    var showTitle: Bool? = nil
    /// Card-depth surface this landscape card belongs to — Continue Watching by default; catalog rows
    /// rendered in landscape mode pass `.posters` so the depth toggles map to the right setting.
    var depthSurface: CardDepthSurface = .continueWatching

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring, default OFF — see `PosterCard`'s copy of this property
    /// for the full rationale (same UserDefaults key, same byte-identical-when-OFF guarantee).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "No Zoom on Focus", default OFF — see `PosterCard`'s copy of this property
    /// for the full rationale (same UserDefaults key, same independent read).
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    private var titleVisible: Bool { showTitle ?? style.showTitle }
    private var focusMode: CardFocusMode {
        .resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match PosterCard and expandedTile
            ZStack(alignment: .bottom) {
                CachedAsyncImage(string: imageURL)
                    .frame(width: width, height: height)
                    // BUG-31: same fill-overflow → hover-lift ghosting as PosterCard; artwork whose
                    // ratio isn't 16:9 spills out of this fixed frame unless clipped here.
                    // BUG-36: and like PosterCard, this clip stays on the image's own frame so it
                    // crops the artwork instead of capturing the card's focus treatment.
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                    // BUG-36: depth (and its coverage mask) stays anchored to the artwork frame.
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: depthSurface)

                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle()
                                .fill(Theme.Palette.progress)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .frame(width: width, height: height)
            // FEAT-14 (final) — see PosterCard's copy of this overlay for the full rationale. The
            // ring is drawn on the artwork/progress-bar group, using the same inside-strokeBorder
            // treatment as the trailer surface's ring in `InlineTrailerCard`, and rides whatever
            // the whole-card focus treatment does.
            .overlay {
                if accentFocusRing && isFocused {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                }
            }

            if titleVisible {
                Text(title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: width, alignment: .leading)
            }
        }
        // BUG-36: whole-card focus treatment — artwork, progress bar, ring and caption move (or
        // hold still) as one object. See `PosterCard`'s copy for the full rationale.
        .modifier(CardFocusTreatment(
            mode: focusMode,
            isFocused: isFocused,
            artworkHeight: height,
            cornerRadius: style.cornerRadius
        ))
        // FEAT-14/BUG-36: see `PosterCard`'s copy of this zIndex for the full rationale — the
        // SwiftUI-drawn treatments need an explicit zIndex to draw above row neighbors the way the
        // system lift does implicitly; the default path's stacking is untouched.
        .zIndex(focusMode.raisesFocusedCard && isFocused ? 1 : 0)
    }
}
