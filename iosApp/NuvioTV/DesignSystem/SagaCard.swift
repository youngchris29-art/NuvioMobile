import Combine
import SwiftUI
import SharedCore

/// FEAT-34 (2026-09-08, Christian's decision): the description page's saga/franchise row (e.g.
/// "Avatar - Saga") the way official Nuvio renders it — 16:9 backdrop cards with the franchise's
/// title-logo art composited bottom-leading over the artwork, film name + year captioned
/// underneath. Tester photo:
/// `docs/research/steven-beta18-photos/2026-09-08-official-nuvio-saga-row-landscape.jpg` (outer
/// repo). Replaces the plain portrait `PosterCard` the row used before, which carried no logo art
/// and put the whole film name in a single caption line under a poster crop.
///
/// `LandscapeCard` (`PosterCard.swift`, the existing 16:9 card used by Upcoming/Continue
/// Watching) has no artwork-overlay slot and this task is scoped to `SagaCard.swift` + the
/// collection row only — no `PosterCard.swift` edits — so composing `LandscapeCard` with a new
/// closure parameter isn't an option here. This view is a sibling that copies `LandscapeCard`'s
/// minimal focus/depth/shape chain (`CardArtworkFocusLift`, `CardFocusTreatment`,
/// `CardCaptionFocusDrop`, `nuvioCardDepth`, the `@Environment(\.posterStyle)` corner radius, and
/// the `accent_focus_ring` / `no_zoom_on_focus` `@AppStorage` reads — same keys, same behavior)
/// rather than reusing `LandscapeCard` itself, and adds its own artwork-overlay logo/text and an
/// always-shown two-line caption in place of `LandscapeCard`'s badges/progress bar.
///
/// Sized and shaped identically to `LandscapeCard`: `Theme.Size.landscapeWidth` ×
/// `Theme.Size.landscapeHeight` (360×203, 16:9), `style.cornerRadius` from Poster Style.
struct SagaCard: View {
    let item: MetaPreview

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    /// FEAT-14: opt-in accent focus ring — see `LandscapeCard`'s copy of this property for the
    /// full rationale. Same UserDefaults key, so a saga card and every other card in the row
    /// family stay in lockstep with the setting.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// BUG-36: opt-in "No Zoom on Focus" — see `LandscapeCard`'s copy of this property.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    /// Where the async-resolved TMDB logo lookups live — a process-wide singleton keyed by item
    /// id/type, so scrolling this row off-screen and back never re-fetches a part's logo.
    @ObservedObject private var logoStore = SagaLogoStore.shared
    @State private var logoImage: UIImage?

    private let width: CGFloat = Theme.Size.landscapeWidth
    private let height: CGFloat = Theme.Size.landscapeHeight

    private var focusMode: CardFocusMode {
        .resolve(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    /// `LandscapeCard`/`PosterCard`'s `ringInset(...)` is `private` to `PosterCard.swift`, which
    /// this task does not touch — same one-line rule duplicated here rather than imported.
    private var inset: CGFloat { (accentFocusRing || noZoomOnFocus) ? ringWidth : 0 }

    /// The item's own `logo` (when the shared layer already resolved one) else whatever this
    /// card's own TMDB lookup found (nil until resolved, and nil forever if the lookup found
    /// nothing) — see `SagaLogoStore`.
    private var resolvedLogoURL: String? {
        let own: String? = item.logo
        if let own, !own.isEmpty { return own }
        return logoStore.logoURL(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(string: SagaCardArt.artworkURL(for: item), contentMode: .fill)
                    .frame(width: width - 2 * inset, height: height - 2 * inset)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: max(0, style.cornerRadius - inset)),
                                    surface: .posters)
                    .frame(width: width, height: height)

                if let resolvedLogoURL, let logoImage {
                    // Bottom-leading logo composite — the `CollectionsUI.swift` folder-tile
                    // pattern (title-logo art replacing plain text once it loads).
                    Image(uiImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: width * 0.82, maxHeight: height * 0.36)
                        .frame(width: width, height: height, alignment: .bottomLeading)
                        .padding(Theme.Spacing.xs)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityLabel(item.name)
                } else {
                    // No logo bitmap yet (still loading, no logo art exists, or TMDB enrichment
                    // is off) — text fallback in the same bottom-leading slot with the same
                    // padding, same treatment `InlineTrailerCard` uses for its own no-logo state.
                    Text(item.name)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                        .frame(maxWidth: width * 0.82, alignment: .leading)
                        .frame(width: width, height: height, alignment: .bottomLeading)
                        .padding(Theme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            // FEAT-14 (final) — see `LandscapeCard`'s copy of this overlay for the full
            // rationale: the ring is drawn on the artwork/overlay group and rides whatever the
            // whole-card focus treatment does.
            .overlay {
                if accentFocusRing && isFocused {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(Theme.Palette.focusRingColor, lineWidth: ringWidth)
                }
            }
            .modifier(CardArtworkFocusLift(
                mode: focusMode,
                isFocused: isFocused,
                artworkHeight: height,
                cornerRadius: style.cornerRadius
            ))

            // Always shown regardless of Hide Labels — this row is informational like Cast,
            // whose names always show (see the rc2 comment on `DetailView.collectionRow`).
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                let release: String? = item.releaseInfo
                if let release, !release.isEmpty {
                    Text(release)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(width: width, alignment: .leading)
            // BUG-54: caption follows the lift — see `LandscapeCard`'s copy of this modifier.
            .modifier(CardCaptionFocusDrop(
                mode: focusMode, isFocused: isFocused, artworkHeight: height
            ))
        }
        .modifier(CardFocusTreatment(
            mode: focusMode,
            isFocused: isFocused,
            artworkHeight: height,
            cornerRadius: style.cornerRadius
        ))
        .zIndex(focusMode.raisesFocusedCard && isFocused ? 1 : 0)
        // Kick off the TMDB logo lookup at most once per item id/type — `SagaLogoStore` itself
        // guards re-entrancy and remembers "looked, found nothing" so re-appearing (LazyHStack
        // recycling this card's identity as the row scrolls) never re-issues the request.
        .task(id: SagaLogoStore.key(for: item)) {
            if SagaCardArt.needsLogoLookup(item) {
                logoStore.lookupIfNeeded(item)
            }
        }
        // Mirrors `CollectionsUI.swift`'s own title-logo load: a synchronous `ArtworkStore.cached`
        // check first (a warm logo never flashes in), then the async fetch. Re-runs whenever the
        // resolved URL string changes — nil while unresolved, the shared field if the item
        // already had one, or `SagaLogoStore`'s async result once it lands.
        .task(id: resolvedLogoURL) {
            guard let resolvedLogoURL, let url = URL(string: resolvedLogoURL) else {
                logoImage = nil
                return
            }
            if let cached = ArtworkStore.cached(url) {
                logoImage = cached
                return
            }
            logoImage = nil
            if let fetched = try? await ArtworkStore.fetch(url) {
                // `ArtworkStore.fetch` deliberately completes shared work even after this task is
                // cancelled, so a superseded request can resume here after its replacement —
                // never install a stale part's logo (same guard `CollectionsUI` uses).
                guard !Task.isCancelled, self.resolvedLogoURL == resolvedLogoURL else { return }
                withAnimation(.easeIn(duration: 0.25)) { logoImage = fetched }
            }
        }
    }
}

/// Pure helpers behind `SagaCard`, factored out so `SagaCardTests` can exercise them without a
/// view host.
enum SagaCardArt {
    /// The shared collection fetch (`TmdbMetadataService.fetchCollection`) sets `banner` to the
    /// TMDB backdrop at w1280 and `poster` to the same backdrop at w780 — banner is the larger
    /// asset, so it's preferred; poster is the fallback for any caller that only populated that
    /// field. Nil when neither is present.
    static func artworkURL(for item: MetaPreview) -> String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        if let poster, !poster.isEmpty { return poster }
        return nil
    }

    /// True when the item arrived with no `logo` of its own — `fetchCollection` always sets
    /// `logo = nil` for collection parts today, so this is worth a dedicated TMDB lookup.
    static func needsLogoLookup(_ item: MetaPreview) -> Bool {
        let logo: String? = item.logo
        return logo?.isEmpty ?? true
    }
}

/// FEAT-34: per-item (id + type) cache of a saga-row part's resolved TMDB title-logo URL,
/// including a resolved-but-empty result — so the `collectionRow`'s `LazyHStack` recycling a
/// `SagaCard`'s view identity while scrolling never re-issues the same TMDB lookup. Scoped as a
/// process-wide singleton (mirrors `ArtworkStore`'s own in-memory cache) rather than per-row state,
/// since the same part can appear in more than one title's saga row (e.g. two films in the same
/// franchise both show every other part).
@MainActor
final class SagaLogoStore: ObservableObject {
    static let shared = SagaLogoStore()

    private init() {}

    /// `.pending` from the moment a lookup starts until its callback lands; `.resolved(nil)` is a
    /// completed lookup that found no logo (TMDB disabled/no key/no match/network failure) or a
    /// part this store has decided never to look up — remembered exactly like a real URL so it is
    /// never retried on every scroll.
    private enum LookupState {
        case pending
        case resolved(String?)
    }

    @Published private var results: [String: LookupState] = [:]

    static func key(for item: MetaPreview) -> String { "\(item.type)|\(item.id)" }

    /// The resolved logo URL for `item`, or nil while unresolved / if resolution found nothing.
    func logoURL(for item: MetaPreview) -> String? {
        if case .resolved(let url) = results[Self.key(for: item)] { return url }
        return nil
    }

    /// Starts (at most once per key) the TMDB preview-enrichment lookup for `item`'s logo. A
    /// second call for the same key while one is pending, or after one has resolved, is a no-op.
    func lookupIfNeeded(_ item: MetaPreview) {
        let key = Self.key(for: item)
        guard results[key] == nil else { return }
        results[key] = .pending

        let settings = TmdbSettingsRepository.shared.snapshot()
        guard settings.enabled, settings.hasApiKey, settings.useArtwork else {
            results[key] = .resolved(nil)
            return
        }
        // suspend fun → Swift completion; result may arrive off the main thread (same convention
        // as `HomeView.enrichIfNeeded`), so hop back before touching `@Published` state.
        TmdbMetadataService.shared.fetchPreviewEnrichment(
            type: item.type, id: item.id, settings: settings
        ) { [weak self] enrichment, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let logo: String? = enrichment?.logo
                self.results[key] = .resolved((logo?.isEmpty ?? true) ? nil : logo)
            }
        }
    }
}
