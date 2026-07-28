import Combine
import SwiftUI
import UIKit
import SharedCore

/// "Trailers in thumbnails": hold focus on a catalog card for a beat and it blooms into a 16:9
/// landscape tile that plays the title's trailer, muted, in place.
///
/// At rest `InlineTrailerCard` renders the unchanged `PosterCardView`/`LandscapeCard`, so a row of
/// unfocused cards is byte-for-byte what it always was. The expansion is a real **in-row layout
/// morph**: the card's layout width animates from the portrait poster's to `LandscapeCard`'s exact
/// geometry (`Theme.Size.landscapeWidth × landscapeHeight`), so the `LazyHStack` slides the trailing
/// posters aside and the wide tile never overlaps a neighbour. It morphs back when the trailer ends,
/// when nothing resolves, or when focus leaves.
///
/// Three collaborators live here:
/// * `TrailerResolutionCache` — process-wide memo of "does this title have a playable trailer".
/// * `InlineTrailerCoordinator` — makes sure only one card owns an `AVPlayer`, and only one
///   YouTube extraction runs at a time.
/// * `InlineTrailerCardModel` — the per-card dwell → expand → resolve → play state machine.

// MARK: - Resolution cache

/// Remembers what resolving a title's trailer produced, so re-focusing a card (or scrolling back to
/// a row) never repeats the extraction. Keyed `"type:id"` — the same identity `TitleRoute` hashes on.
@MainActor
final class TrailerResolutionCache {
    static let shared = TrailerResolutionCache()

    enum Entry {
        /// A directly-playable progressive/HLS URL for this title, stamped when it was resolved.
        case resolved(String, Date)
        /// This title has no usable inline trailer (none listed, or extraction produced nothing
        /// AVPlayer can open), stamped when we found that out.
        case unavailable(Date)
    }

    /// Extracted YouTube URLs carry a signature that outlives a browsing session by hours; three
    /// hours keeps re-focus free while staying comfortably inside that window.
    private static let resolvedTTL: TimeInterval = 3 * 60 * 60
    /// Negative results expire fast — a momentary addon/network failure shouldn't blacklist a title
    /// for the rest of the session.
    private static let unavailableTTL: TimeInterval = 20 * 60
    /// A long browsing session touches far more titles than it plays; bound the map and drop the
    /// oldest insertions first (recency of *use* isn't worth tracking for entries this small).
    private static let capacity = 200

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    private init() {}

    /// `nonisolated` so view bodies (e.g. `CatalogRowView`'s play/pause gate) can build a key without
    /// hopping actors — it's pure string interpolation and touches no state.
    nonisolated static func key(type: String, id: String) -> String { "\(type):\(id)" }

    /// Non-expired entry for `key`, evicting it if its TTL has passed.
    func entry(for key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        let age: TimeInterval
        let ttl: TimeInterval
        switch entry {
        case let .resolved(_, stamped):
            age = Date().timeIntervalSince(stamped)
            ttl = Self.resolvedTTL
        case let .unavailable(stamped):
            age = Date().timeIntervalSince(stamped)
            ttl = Self.unavailableTTL
        }
        guard age < ttl else {
            remove(key)
            return nil
        }
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        if entries[key] == nil { insertionOrder.append(key) }
        entries[key] = entry
        while insertionOrder.count > Self.capacity, let oldest = insertionOrder.first {
            remove(oldest)
        }
    }

    private func remove(_ key: String) {
        entries[key] = nil
        insertionOrder.removeAll { $0 == key }
    }
}

// MARK: - Cross-card coordination

/// Global traffic control for inline trailers. Two jobs, both about never letting a fast D-pad hand
/// stack up work: at most one card owns an `AVPlayer`, and at most one YouTube extraction is in
/// flight (a second card that dwells while one is running simply skips — it is *not* queued, or the
/// user would get trailers for cards they left long ago).
@MainActor
final class InlineTrailerCoordinator: ObservableObject {
    static let shared = InlineTrailerCoordinator()

    /// Cache key (`"type:id"`) of the card currently playing a trailer, or `nil` when nothing is.
    ///
    /// Published because the *row* — not the card — has to answer "is this focused item the one
    /// playing?": tvOS delivers `.onPlayPauseCommand` to the focused view chain, which is the
    /// `Button`/`NavigationLink` in `CatalogRowView`, never the card that is its label.
    @Published private(set) var playingKey: String?

    private weak var activePlayer: InlineTrailerCardModel?
    private var extracting = false

    private init() {}

    /// Hands the single player slot to `owner`, dropping whoever held it back to a plain poster.
    func claimPlayback(_ owner: InlineTrailerCardModel, key: String) {
        if let activePlayer, activePlayer !== owner { activePlayer.relinquishPlayback() }
        activePlayer = owner
        playingKey = key
    }

    func releasePlayback(_ owner: InlineTrailerCardModel) {
        if activePlayer === owner {
            activePlayer = nil
            playingKey = nil
        }
    }

    /// `true` when this caller may extract; balance every `true` with `endExtraction()`.
    func beginExtraction() -> Bool {
        guard !extracting else { return false }
        extracting = true
        return true
    }

    func endExtraction() { extracting = false }
}

// MARK: - Per-card state machine

/// idle → dwelling (1s of held focus) → expandedStatic (landscape art, immediately) → playing, and
/// back to idle the moment the reason to be expanded goes away.
///
/// Every step fails soft and *silently*: there is never a spinner or a black tile, because the
/// static landscape art is already on screen from the moment the card expands. Anything that ends
/// the preview — no trailer, extraction failure, playback failure, or the trailer simply finishing —
/// collapses the card back to its poster rather than parking it on static artwork.
///
/// The phase drives *layout* now (portrait poster ⇄ landscape tile in the row), so every transition
/// goes through `setPhase`, which wraps the mutation in a `withAnimation` transaction. That single
/// transaction is what lets the enclosing `LazyHStack` slide the trailing neighbours aside in step
/// with the card instead of snapping them.
@MainActor
final class InlineTrailerCardModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dwelling
        case expandedStatic
        case playing(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Mirrors `accessibilityReduceMotion` from the hosting card. When set, the morph is an instant
    /// swap instead of an animated one.
    var prefersReducedMotion = false

    /// The morph curve. Slow enough to read as one object changing shape, short enough that a fast
    /// D-pad hand never feels held up by it.
    static let morphAnimation: Animation = .easeInOut(duration: 0.35)

    /// Expanded covers both "showing static landscape art" and "playing" — the tile is the same one.
    var isExpanded: Bool {
        switch phase {
        case .idle, .dwelling: return false
        case .expandedStatic, .playing: return true
        }
    }

    var playingURL: String? {
        if case let .playing(url) = phase { return url }
        return nil
    }

    /// How long focus must rest on a card before it expands. Long enough that scrubbing across a row
    /// with the D-pad expands nothing and issues zero requests.
    private static let dwellSeconds: TimeInterval = 1.0
    /// Meta comes from the shared repo's cache in the common case; this bounds the cold path so a
    /// slow addon can't leave a card resolving for the whole time the user sits on it.
    private static let metaTimeoutSeconds: TimeInterval = 5
    /// Extraction is several chained requests to YouTube; well past this it isn't an inline preview
    /// any more.
    private static let extractionTimeoutSeconds: TimeInterval = 15

    private var dwellTask: Task<Void, Never>?
    /// Bumped on every focus change/teardown. Guards the dwell → expand hop against a stale timer.
    private var generation = 0
    /// The title this card is currently expanded on; a resolution may only attach to its own key.
    private var activeKey: String?
    /// Key of the resolution currently in flight for this card, so a re-focus mid-resolve doesn't
    /// start a second pipeline (the in-flight one attaches itself when it lands).
    private var resolvingKey: String?
    /// Title whose trailer already played through on *this* dwell. Blocks an immediate re-expansion
    /// while focus stays put; cleared by `reset()`, so leaving and coming back plays it again.
    private var didFinishForKey: String?

    // MARK: Focus

    func focusChanged(_ focused: Bool, item: MetaPreview) {
        if focused {
            startDwell(item)
        } else {
            reset()
        }
    }

    /// Single funnel for phase changes so the layout morph always animates in one transaction (see
    /// the type comment). Reduce Motion swaps it for an instant change.
    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        if prefersReducedMotion {
            phase = next
        } else {
            withAnimation(Self.morphAnimation) { phase = next }
        }
    }

    private func startDwell(_ item: MetaPreview) {
        generation &+= 1
        let generationAtStart = generation
        dwellTask?.cancel()
        // Normally a no-op transition from `.idle`; routed through `setPhase` so the rare arrival on
        // an already-expanded card (a re-render that re-runs `onAppear`) still collapses smoothly.
        setPhase(.dwelling)
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == generationAtStart else { return }
            self.expand(item)
        }
    }

    /// Focus lost, or the card scrolled out of the row: back to the plain poster immediately. Any
    /// in-flight resolution keeps running to completion (it still populates the cache, so coming
    /// back is instant) but can no longer attach anything — `activeKey` is gone.
    func reset() {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        activeKey = nil
        didFinishForKey = nil
        InlineTrailerCoordinator.shared.releasePlayback(self)
        setPhase(.idle)
    }

    /// Another card took the single player slot. Defensive only — the card that loses focus resets
    /// itself first — so collapse rather than park a now-landscape tile in a row nobody is looking at.
    func relinquishPlayback() {
        guard playingURL != nil else { return }
        activeKey = nil
        setPhase(.idle)
    }

    /// The player couldn't start (undecodable/stalled). Negative-cache it and collapse; not retried
    /// for this title until the short TTL lapses.
    func playbackFailed() {
        if let activeKey {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: activeKey)
        }
        collapse()
    }

    /// The trailer played through. Collapse, and remember the title so sitting on the card doesn't
    /// immediately bloom it again — only leaving and coming back does (`reset()` clears the flag).
    func playbackFinished() {
        guard case .playing = phase else { return }
        didFinishForKey = activeKey
        collapse()
    }

    /// Drops everything this card owns and animates back to the resting poster, *without* arming a
    /// new dwell — focus hasn't moved, so re-blooming here would be a loop, not a feature.
    private func collapse() {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        activeKey = nil
        InlineTrailerCoordinator.shared.releasePlayback(self)
        setPhase(.idle)
    }

    // MARK: Expansion + resolution

    private func expand(_ item: MetaPreview) {
        let key = TrailerResolutionCache.key(type: item.type, id: item.id)
        guard didFinishForKey != key else { return }

        switch TrailerResolutionCache.shared.entry(for: key) {
        case let .resolved(url, _):
            activeKey = key
            setPhase(.expandedStatic)
            startPlayback(url, key: key)
        case .unavailable:
            // Already known to have nothing to play: never morph at all, so a row full of
            // trailer-less titles never twitches under a browsing thumb.
            return
        case nil:
            activeKey = key
            setPhase(.expandedStatic)
            guard resolvingKey != key else { return }
            resolvingKey = key
            Task { [weak self] in await self?.resolve(item, key: key) }
        }
    }

    /// Resolution concluded that there is nothing to play: collapse instead of sitting on static
    /// landscape art (device feedback — an expanded card that never plays reads as a stuck card).
    private func abandonExpansion(key: String) {
        guard activeKey == key else { return }
        collapse()
    }

    /// cache miss → meta (peek, else fetch) → best trailer → extraction → playable URL. Mirrors
    /// `DetailViewModel.resolveTrailerIfNeeded`, just with Swift-side deadlines and the cache.
    private func resolve(_ item: MetaPreview, key: String) async {
        defer { if resolvingKey == key { resolvingKey = nil } }

        let type = item.type
        let id = item.id
        // Detail's `stop()` clears the shared repo, so `peek` can miss right after backing out of a
        // title — harmless, `fetch` refills from its own cache.
        var meta = MetaDetailsRepository.shared.peek(type: type, id: id)
        if meta == nil {
            meta = await fetchMeta(type: type, id: id)
        }
        // No meta at all is a transport failure, not "this title has no trailer" — don't poison the
        // cache with it. The card still collapses: nothing is coming.
        guard let meta else {
            abandonExpansion(key: key)
            return
        }

        let trailers = meta.trailers
        guard !trailers.isEmpty,
              let trailer = HeroTrailerSelectorKt.selectHeroTrailer(trailers: trailers) else {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key)
            abandonExpansion(key: key)
            return
        }

        // Busy: skip rather than queue, and stay neutral on the cache — being second in line says
        // nothing about whether this title has a trailer.
        guard InlineTrailerCoordinator.shared.beginExtraction() else {
            abandonExpansion(key: key)
            return
        }
        let source = await resolveYouTube(trailer.youtubePlaybackUrl())
        InlineTrailerCoordinator.shared.endExtraction()

        // AVPlayer-friendly progressive/HLS only — adaptive-VP9/AV1-only results collapse the card.
        let progressive: String? = source?.progressiveUrl
        guard let progressive, !progressive.isEmpty else {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key)
            abandonExpansion(key: key)
            return
        }
        TrailerResolutionCache.shared.store(.resolved(progressive, Date()), for: key)
        startPlayback(progressive, key: key)
    }

    /// Only attaches when this card is *still* sitting expanded on the title that was resolved —
    /// late results from a card the user has already left write the cache and nothing else.
    private func startPlayback(_ url: String, key: String) {
        guard phase == .expandedStatic, activeKey == key else { return }
        InlineTrailerCoordinator.shared.claimPlayback(self, key: key)
        setPhase(.playing(url))
    }

    // MARK: Kotlin bridges (with Swift-side deadlines)

    private func fetchMeta(type: String, id: String) async -> MetaDetails? {
        await withCheckedContinuation { continuation in
            let latch = ResumeLatch<MetaDetails>(continuation)
            MetaDetailsRepository.shared.fetch(type: type, id: id) { details, _ in
                // Suspend completions can land off-main; hop before touching the latch.
                DispatchQueue.main.async { latch.settle(details) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.metaTimeoutSeconds) {
                latch.settle(nil)
            }
        }
    }

    private func resolveYouTube(_ youtubeUrl: String) async -> TrailerPlaybackSource? {
        await withCheckedContinuation { continuation in
            let latch = ResumeLatch<TrailerPlaybackSource>(continuation)
            HeroTrailerResolver.shared.resolveYouTube(youtubeUrl: youtubeUrl) { source, _ in
                DispatchQueue.main.async { latch.settle(source) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.extractionTimeoutSeconds) {
                latch.settle(nil)
            }
        }
    }

    deinit { dwellTask?.cancel() }
}

/// One-shot resume for "Kotlin completion handler vs. Swift deadline, first one wins".
///
/// A `TaskGroup` race can't express this: the group awaits *all* of its children when the scope
/// exits, so a hung Kotlin call would still block past the deadline. Kotlin's generated completions
/// aren't cancellable from Swift either — the loser is simply dropped here.
private final class ResumeLatch<T> {
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    /// Main-queue only (every call site hops first).
    func settle(_ value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

// MARK: - The card

/// A catalog-row tile that grows a muted trailer preview after a focus dwell.
///
/// At rest — and always, when `enabled` is false — this is exactly the card the row rendered before
/// the feature existed, with no extra modifiers attached.
struct InlineTrailerCard: View {
    let item: MetaPreview
    /// Master gate: the user's setting plus tvOS's "Reduce Autoplay". False ⇒ plain card, no state
    /// machine, no overlay, no modifiers.
    var enabled: Bool = true

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = InlineTrailerCardModel()

    /// Landscape rows prefer the wide banner; a poster fallback is cropped to 16:9 by the tile's
    /// aspect-fill, which reads better than an empty slot.
    static func landscapeArtworkURL(_ item: MetaPreview) -> String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
    }

    var body: some View {
        if enabled {
            expandingCard
        } else {
            baseCard
        }
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog
    /// rows. Kept identical to what `CatalogRowView` rendered directly before inline trailers.
    @ViewBuilder
    private var baseCard: some View {
        if posterStyle.landscapeCatalogRows {
            LandscapeCard(
                title: item.name,
                imageURL: Self.landscapeArtworkURL(item),
                depthSurface: .posters
            )
        } else {
            PosterCardView(item: item)
        }
    }

    /// The morph. The card's *layout* width is `artworkWidth`, which swings from the portrait poster
    /// width to `Theme.Size.landscapeWidth` when the card expands — so the enclosing `LazyHStack`
    /// pushes the trailing posters aside and the wide tile sits **in** the row rather than over it.
    /// (That's why `CatalogRowView` no longer needs a `zIndex` lift: nothing overhangs any more.)
    ///
    /// The resting poster and the landscape tile are stacked and crossfaded, top-leading aligned so
    /// the tile grows out of the poster's top-left corner instead of drifting. The tile is *always*
    /// in the hierarchy (at opacity 0 when idle) purely so its frame has a "from" value to animate
    /// out of — an inserted view would pop in at full landscape size and overlap its neighbour for
    /// the length of the transition. Its artwork/player are still gated on the phase, so an idle
    /// card loads nothing.
    private var expandingCard: some View {
        ZStack(alignment: .topLeading) {
            baseCard
                // Only the portrait card is crossfaded out — in landscape rows the tile is the same
                // shape and size as the artwork underneath, so there's nothing to morph and fading
                // would just blink the row.
                .opacity(fadesBaseCard && model.isExpanded ? 0 : 1)

            expandedTile
        }
        .frame(width: artworkWidth, alignment: .leading)
        .animation(reduceMotion ? nil : InlineTrailerCardModel.morphAnimation, value: model.isExpanded)
        .onChange(of: isFocused) { _, focused in model.focusChanged(focused, item: item) }
        // A recycled cell can come back already focused (returning from Detail), which produces
        // no `onChange`.
        .onAppear {
            model.prefersReducedMotion = reduceMotion
            if isFocused { model.focusChanged(true, item: item) }
        }
        .onChange(of: reduceMotion) { _, motion in model.prefersReducedMotion = motion }
        .onDisappear { model.reset() }
    }

    /// The expanded card: landscape tile plus the title in the same slot the poster's title occupies,
    /// both following the animated artwork width.
    private var expandedTile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            trailerSurface

            if showsOverlayTitle {
                Text(item.name)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: artworkWidth, alignment: .leading)
            }
        }
        .opacity(model.isExpanded ? 1 : 0)
        // The card's own scale/tilt lives inside PosterCard/LandscapeCard and is untouched; the
        // tile repeats it so the two move as one object.
        .scaleEffect(isFocused ? 1.12 : 1)
        .posterFocusTilt(isFocused: isFocused, reduceMotion: reduceMotion)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .allowsHitTesting(false)
    }

    /// The tile itself: landscape art as soon as the card expands, trailer fading in over it once
    /// resolved. The frame is the animated one, so this *is* the morphing artwork region.
    private var trailerSurface: some View {
        ZStack {
            if model.isExpanded {
                CachedAsyncImage(string: Self.landscapeArtworkURL(item))
            }

            if let url = model.playingURL {
                // Removal is deliberately un-animated: focus loss must tear the player down at once
                // (`dismantleUIView`), not linger through a crossfade.
                // `loops: false` — the preview plays once and then the card collapses itself, rather
                // than looping under a resting thumb forever.
                TrailerHeroPlayer(
                    urlString: url,
                    onFailure: { model.playbackFailed() },
                    loops: false,
                    onPlaybackEnded: { model.playbackFinished() }
                )
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: artworkWidth, height: artworkHeight)
        .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
                .strokeBorder(Theme.Palette.accentFocus, lineWidth: 4)
        )
        .overlay(alignment: .bottomTrailing) {
            if model.playingURL != nil {
                InlineTrailerMuteGlyph().padding(Theme.Spacing.sm)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.playingURL)
    }

    private var fadesBaseCard: Bool { !posterStyle.landscapeCatalogRows }

    /// The faded portrait card takes its title with it, so the tile carries a replacement in the
    /// same slot. Landscape rows keep their own title (nothing is faded there).
    private var showsOverlayTitle: Bool { fadesBaseCard && posterStyle.showTitle }

    /// Landscape rows are already the target geometry — no morph there, the trailer just fades in.
    private var artworkWidth: CGFloat {
        if posterStyle.landscapeCatalogRows { return Theme.Size.landscapeWidth }
        return model.isExpanded ? Theme.Size.landscapeWidth : posterStyle.width
    }

    private var artworkHeight: CGFloat {
        if posterStyle.landscapeCatalogRows { return Theme.Size.landscapeHeight }
        return model.isExpanded ? Theme.Size.landscapeHeight : posterStyle.height
    }
}

// MARK: - Mute indicator

/// Card-sized echo of `HeroTrailerMuteButton`: same glyph pair, same shared `HeroTrailerAudioState`,
/// same "press play/pause" story — just scaled for a tile instead of a full-screen hero. Not
/// focusable (the focus engine owns the card itself).
private struct InlineTrailerMuteGlyph: View {
    @StateObject private var audio = InlineTrailerAudioObserver()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "playpause.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
            Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .accessibilityLabel(audio.isMuted
            ? String(localized: "Trailer muted — press play/pause to unmute")
            : String(localized: "Trailer sound on — press play/pause to mute"))
    }
}

/// Bridges `HeroTrailerAudioState.muted` (Kotlin `StateFlow<Boolean>`) to SwiftUI for the glyph
/// above — same shape as Detail's private observer, which isn't visible from here.
@MainActor
private final class InlineTrailerAudioObserver: ObservableObject {
    @Published private(set) var isMuted: Bool

    private var watcher: FlowWatcher?

    init() {
        let flow = HeroTrailerAudioState.shared.muted
        self.isMuted = (flow.value_ as? KotlinBoolean)?.boolValue ?? true
        self.watcher = FlowWatcherKt.watch(flow) { [weak self] emitted in
            guard let self, let boxed = emitted as? KotlinBoolean else { return }
            self.isMuted = boxed.boolValue
        }
    }

    deinit { watcher?.cancel() }
}
