import Combine
import SwiftUI
import UIKit
import SharedCore

/// "Trailers in thumbnails": hold focus on a catalog card for a beat and it blooms into a 16:9
/// landscape tile that plays the title's trailer, muted, in place.
///
/// The whole feature is layered *on top of* the existing card — `InlineTrailerCard` renders the
/// unchanged `PosterCardView`/`LandscapeCard` at rest and only adds an overlay once the dwell
/// elapses, so nothing about the row's layout, focus chain, or scroll behaviour changes. The
/// expansion is purely visual (overlay + `scaleEffect`), never a layout change, or every focus
/// move would reflow the row.
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

    static func key(type: String, id: String) -> String { "\(type):\(id)" }

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
final class InlineTrailerCoordinator {
    static let shared = InlineTrailerCoordinator()

    private weak var activePlayer: InlineTrailerCardModel?
    private var extracting = false

    private init() {}

    /// Hands the single player slot to `owner`, dropping whoever held it back to its static tile.
    func claimPlayback(_ owner: InlineTrailerCardModel) {
        if let activePlayer, activePlayer !== owner { activePlayer.relinquishPlayback() }
        activePlayer = owner
    }

    func releasePlayback(_ owner: InlineTrailerCardModel) {
        if activePlayer === owner { activePlayer = nil }
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

/// idle → dwelling (1s of held focus) → expandedStatic (landscape art, immediately) → playing.
///
/// Every step fails soft and *silently*: there is never a spinner or a black tile, because the
/// static landscape art is already on screen from the moment the card expands. If anything doesn't
/// resolve, the card simply stays expanded on that artwork.
@MainActor
final class InlineTrailerCardModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dwelling
        case expandedStatic
        case playing(String)
    }

    @Published private(set) var phase: Phase = .idle

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

    // MARK: Focus

    func focusChanged(_ focused: Bool, item: MetaPreview) {
        if focused {
            startDwell(item)
        } else {
            reset()
        }
    }

    private func startDwell(_ item: MetaPreview) {
        generation &+= 1
        let generationAtStart = generation
        dwellTask?.cancel()
        phase = .dwelling
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
        InlineTrailerCoordinator.shared.releasePlayback(self)
        phase = .idle
    }

    /// Another card took the single player slot — keep the static tile, drop the video.
    func relinquishPlayback() {
        guard playingURL != nil else { return }
        phase = .expandedStatic
    }

    /// The player couldn't start (undecodable/stalled). Negative-cache it and fall back to the
    /// static landscape tile; not retried for this title until the short TTL lapses.
    func playbackFailed() {
        if let activeKey {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: activeKey)
        }
        InlineTrailerCoordinator.shared.releasePlayback(self)
        if case .playing = phase { phase = .expandedStatic }
    }

    // MARK: Expansion + resolution

    private func expand(_ item: MetaPreview) {
        let key = TrailerResolutionCache.key(type: item.type, id: item.id)
        activeKey = key
        phase = .expandedStatic

        switch TrailerResolutionCache.shared.entry(for: key) {
        case let .resolved(url, _):
            startPlayback(url, key: key)
        case .unavailable:
            return
        case nil:
            guard resolvingKey != key else { return }
            resolvingKey = key
            Task { [weak self] in await self?.resolve(item, key: key) }
        }
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
        // cache with it.
        guard let meta else { return }

        let trailers = meta.trailers
        guard !trailers.isEmpty,
              let trailer = HeroTrailerSelectorKt.selectHeroTrailer(trailers: trailers) else {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key)
            return
        }

        // Busy: skip rather than queue, and stay neutral on the cache — being second in line says
        // nothing about whether this title has a trailer.
        guard InlineTrailerCoordinator.shared.beginExtraction() else { return }
        let source = await resolveYouTube(trailer.youtubePlaybackUrl())
        InlineTrailerCoordinator.shared.endExtraction()

        // AVPlayer-friendly progressive/HLS only — adaptive-VP9/AV1-only results stay on the art.
        let progressive: String? = source?.progressiveUrl
        guard let progressive, !progressive.isEmpty else {
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key)
            return
        }
        TrailerResolutionCache.shared.store(.resolved(progressive, Date()), for: key)
        startPlayback(progressive, key: key)
    }

    /// Only attaches when this card is *still* sitting expanded on the title that was resolved —
    /// late results from a card the user has already left write the cache and nothing else.
    private func startPlayback(_ url: String, key: String) {
        guard phase == .expandedStatic, activeKey == key else { return }
        InlineTrailerCoordinator.shared.claimPlayback(self)
        phase = .playing(url)
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

    private var expandingCard: some View {
        baseCard
            // Only the portrait card is crossfaded out — in landscape rows the tile is the same
            // shape and size as the artwork underneath, so there's nothing to morph and fading
            // would just blink the row.
            .opacity(fadesBaseCard && model.isExpanded ? 0 : 1)
            .overlay(alignment: .top) {
                if model.isExpanded { expandedTile }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.isExpanded)
            .onChange(of: isFocused) { _, focused in model.focusChanged(focused, item: item) }
            // A recycled cell can come back already focused (returning from Detail), which produces
            // no `onChange`.
            .onAppear { if isFocused { model.focusChanged(true, item: item) } }
            .onDisappear { model.reset() }
            // Mirrors Detail's hero trailer: the overlay glyph isn't reachable by the focus engine,
            // so play/pause is the toggle — and only while something is actually playing, or the
            // row would swallow the button.
            .onPlayPauseCommand(perform: model.playingURL == nil ? nil : {
                HeroTrailerAudioState.shared.toggleMuted()
            })
    }

    /// The whole card's-worth of expanded content, laid out over the resting card's slot so the
    /// (faded) title keeps its place. Sized/positioned only — never inserted into the layout.
    private var expandedTile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            trailerSurface
                .frame(width: artworkWidth, height: artworkHeight)

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
        // The card's own scale/tilt lives inside PosterCard/LandscapeCard and is untouched; the
        // overlay repeats it so the two move as one object.
        .scaleEffect(isFocused ? 1.12 : 1)
        .posterFocusTilt(isFocused: isFocused, reduceMotion: reduceMotion)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .allowsHitTesting(false)
    }

    /// The 16:9 tile itself: landscape art immediately, trailer fading in over it once resolved.
    private var trailerSurface: some View {
        ZStack {
            CachedAsyncImage(string: Self.landscapeArtworkURL(item))

            if let url = model.playingURL {
                // Removal is deliberately un-animated: focus loss must tear the player down at once
                // (`dismantleUIView`), not linger through a crossfade.
                TrailerHeroPlayer(urlString: url, onFailure: { model.playbackFailed() })
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: Theme.Size.landscapeWidth, height: Theme.Size.landscapeHeight)
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

    /// The faded portrait card takes its title with it, so the overlay carries a replacement in the
    /// same slot. Landscape rows keep their own title (nothing is faded there).
    private var showsOverlayTitle: Bool { fadesBaseCard && posterStyle.showTitle }

    private var artworkWidth: CGFloat {
        posterStyle.landscapeCatalogRows ? Theme.Size.landscapeWidth : posterStyle.width
    }

    private var artworkHeight: CGFloat {
        posterStyle.landscapeCatalogRows ? Theme.Size.landscapeHeight : posterStyle.height
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
