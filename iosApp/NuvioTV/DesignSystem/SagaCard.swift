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
                        // Padding INSIDE the fixed bounds below, not outside — otherwise this
                        // overlay's own outer frame grows to `width + 2*xs` × `height + 2*xs`
                        // (e.g. 376×219 against a 360×203 card) and centers/displaces relative to
                        // the focus ring/treatment, which are both sized off `width`/`height`.
                        .padding(Theme.Spacing.xs)
                        .frame(width: width, height: height, alignment: .bottomLeading)
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
                        // Same size-neutral ordering as the logo branch above: padding inside the
                        // fixed bounds, not applied to an already width×height-framed view.
                        .padding(Theme.Spacing.xs)
                        .frame(width: width, height: height, alignment: .bottomLeading)
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

/// FEAT-34: per-item (id + type), per-settings-scope cache of a saga-row part's resolved TMDB
/// title-logo URL, including a resolved-but-empty result — so the `collectionRow`'s `LazyHStack`
/// recycling a `SagaCard`'s view identity while scrolling never re-issues the same TMDB lookup.
/// Scoped as a process-wide singleton (mirrors `ArtworkStore`'s own in-memory cache) rather than
/// per-row state, since the same part can appear in more than one title's saga row (e.g. two films
/// in the same franchise both show every other part).
///
/// Every mounted `SagaCard` holds `@ObservedObject private var logoStore = SagaLogoStore.shared`,
/// so ANY `results` mutation (any card's lookup resolving) republishes to every saga card on
/// screen, not just the one that changed — `@Published` on a dictionary has no per-key
/// granularity. Each card's own re-render is cheap (`logoURL(for:)` is a dictionary lookup keyed
/// off its own item + the current scope), so this is a non-issue at saga-row scale.
@MainActor
final class SagaLogoStore: ObservableObject {
    static let shared = SagaLogoStore()

    private init() {}

    /// `.pending(requestId:)` from the moment a lookup starts until its callback lands. The
    /// request id lets a late completion recognize it has been superseded — by a fresh
    /// `lookupIfNeeded` call for the same key, or by the whole cache being dropped in
    /// `evictIfAtCapacity()` — before it can latch a stale `.pending` in place forever (see
    /// `shouldCommit`). `.resolved(nil)` is a completed lookup that found no logo (no
    /// match/network failure) — remembered exactly like a real URL so it is never retried on every
    /// scroll. A lookup skipped because settings gate it off is NEVER written here at all (see
    /// `lookupIfNeeded`), so it is not covered by this case. Internal, not private, so
    /// `SagaCardTests` can exercise `shouldCommit` with `@testable import`.
    enum LookupState: Equatable {
        case pending(requestId: UInt64)
        case resolved(String?)
    }

    @Published private var results: [String: LookupState] = [:]

    /// Monotonically increasing id handed to each lookup attempt so its completion can tell, via
    /// `shouldCommit`, whether it is still the one live attempt for its key rather than a
    /// superseded or evicted one.
    private var nextRequestId: UInt64 = 0

    private func makeRequestId() -> UInt64 {
        nextRequestId += 1
        return nextRequestId
    }

    /// Bumped every time `results` is dropped wholesale by `evictIfAtCapacity()`. Not itself
    /// consulted by `shouldCommit` — a `.pending` entry wiped by a reset already fails the
    /// `requestId` match on its own — but kept as the store's own record of how many times a
    /// reset has happened.
    private var generation: UInt64 = 0

    /// Bounds `results` across a long session — many collections browsed, or repeated settings
    /// changes each adding a fresh generation of keys for the same items, would otherwise grow it
    /// without limit. Past this many entries the whole cache is dropped; a lookup already pending
    /// under a dropped key just gets requested again (`TmdbMetadataService` has no dedup problem
    /// with a redundant in-flight request completing twice — the second write just replaces the
    /// first with the same value).
    private static let maxEntries = 200

    /// Eviction used before a new `.pending` write in `lookupIfNeeded`, the single place that
    /// keeps `results` from growing past `maxEntries`. Codex r3 (Finding P2): only drops
    /// `.resolved` entries — a `.pending` one is a lookup already in flight for a card that is
    /// (or was, moments ago) mounted, and wiping it here would strand it forever, since
    /// `lookupIfNeeded`'s own `results[key] == nil` guard treats a missing entry as "never
    /// looked up" while the mounted card's `.task(id:)` keys only on type|id and so never re-runs
    /// to ask again. Dropping only `.resolved` entries is safe: a card whose logo was already
    /// resolved just re-fetches it once, cheaply, next time it is looked up.
    private func evictIfAtCapacity() {
        guard results.count >= Self.maxEntries else { return }
        results = results.filter { _, state in
            if case .pending = state { return true }
            return false
        }
        generation += 1
    }

    /// Pure decision for whether a completed lookup's result should be written into `results`:
    /// true only when `entry` is the exact `.pending` placeholder this request itself installed.
    /// False for a different (newer) request's `.pending`, an already-`.resolved` entry, or a
    /// missing entry — the key was superseded by a newer lookup, or its `.pending` was wiped by a
    /// capacity reset (`evictIfAtCapacity()`, which also bumps `generation`). Internal + testable
    /// on its own, with no store/dictionary access, so `SagaCardTests` can cover every case
    /// directly.
    nonisolated static func shouldCommit(entry: LookupState?, requestId: UInt64) -> Bool {
        entry == .pending(requestId: requestId)
    }

    static func key(for item: MetaPreview) -> String { "\(item.type)|\(item.id)" }

    /// The settings that change what a logo lookup returns or whether it even runs — folded into
    /// the cache key so a Metadata Language change, or the artwork/TMDB gate flipping, can never
    /// serve a stale-language logo or a permanently-latched nil from a session where the gate was
    /// off.
    private static func scopeToken(_ settings: TmdbSettings) -> String {
        "\(settings.language)|\(settings.enabled)|\(settings.hasApiKey)|\(settings.useArtwork)"
    }

    private static func scopedKey(for item: MetaPreview, scope: String) -> String {
        "\(key(for: item))|\(scope)"
    }

    /// The resolved logo URL for `item` under the CURRENT settings snapshot, or nil while
    /// unresolved / if resolution found nothing / if this item has no entry under the current
    /// scope yet (e.g. settings changed since the last lookup — see `lookupIfNeeded`).
    func logoURL(for item: MetaPreview) -> String? {
        let scope = Self.scopeToken(TmdbSettingsRepository.shared.snapshot())
        if case .resolved(let url) = results[Self.scopedKey(for: item, scope: scope)] { return url }
        return nil
    }

    /// Starts (at most once per key, where the key includes the current settings scope) the TMDB
    /// preview-enrichment lookup for `item`'s logo. A second call for the same item under the same
    /// scope, while one is pending or after one has resolved, is a no-op; a call under a NEW scope
    /// (language changed, or the artwork/TMDB gate flipped) always gets its own fresh attempt.
    func lookupIfNeeded(_ item: MetaPreview) {
        let settings = TmdbSettingsRepository.shared.snapshot()
        let scope = Self.scopeToken(settings)
        let key = Self.scopedKey(for: item, scope: scope)
        guard results[key] == nil else { return }

        guard settings.enabled, settings.hasApiKey, settings.useArtwork else {
            // Deliberately NOT cached: writing `.resolved(nil)` here would latch a permanent "no
            // logo" for this scope even though no lookup was ever attempted. Leaving no entry
            // means the very next call under this same scope (gate still off) still short-circuits
            // here cheaply — it's the scope changing, not this branch, that ever triggers a retry.
            return
        }

        evictIfAtCapacity()
        let requestId = makeRequestId()
        results[key] = .pending(requestId: requestId)

        // suspend fun → Swift completion; result may arrive off the main thread (same convention
        // as `HomeView.enrichIfNeeded`), so hop back before touching `@Published` state.
        TmdbMetadataService.shared.fetchPreviewEnrichment(
            type: item.type, id: item.id, settings: settings
        ) { [weak self] enrichment, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Not the live attempt for this key anymore — either a newer `lookupIfNeeded` call
                // for the same key took over (its `.pending(requestId:)` won't match ours), or a
                // capacity reset wiped the entry entirely. Either way, writing now would be wrong:
                // in the superseded case it would clobber the newer attempt's own eventual result;
                // in the wiped case there is nothing to correct — the key simply has no entry until
                // something looks it up again. Drop this completion.
                guard Self.shouldCommit(entry: self.results[key], requestId: requestId) else { return }
                // The live attempt, but for a scope the user has since moved away from. Leaving the
                // `.pending` entry in place here would permanently wedge scope A: `lookupIfNeeded`'s
                // `results[key] == nil` guard above would reject every future lookup for this exact
                // key, so returning to scope A later would never retry and the logo would never
                // appear (Finding 3). Remove the stale entry instead, so scope A starts fresh next
                // time it is looked up; don't write the (now off-scope) result anywhere.
                guard Self.scopeToken(TmdbSettingsRepository.shared.snapshot()) == scope else {
                    self.results.removeValue(forKey: key)
                    return
                }
                let logo: String? = enrichment?.logo
                // Codex r3 (Finding P2): no `evictIfAtCapacity()` call here — this write replaces
                // an existing `.pending` key with `.resolved`, so it can never itself grow
                // `results` past the cap; there was previously a "defensive" eviction call on this
                // path, but `evictIfAtCapacity()` used to drop the whole cache wholesale, which
                // could wipe out the very entry this line just wrote (plus every other in-flight
                // `.pending` lookup) with no mounted card ever re-requesting it — see that
                // function's own doc for why eviction now only touches `.resolved` entries.
                self.results[key] = .resolved((logo?.isEmpty ?? true) ? nil : logo)
            }
        }
    }
}
