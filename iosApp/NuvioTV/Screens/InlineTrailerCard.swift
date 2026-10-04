import Combine
import SwiftUI
import UIKit
import SharedCore

/// "Trailers in thumbnails": hold focus on a catalog card for a beat and it blooms into a 16:9
/// landscape tile that plays the title's trailer, muted, in place.
///
/// At rest `InlineTrailerCard` renders the unchanged `PosterCardView`/`LandscapeCard`, so a row of
/// unfocused cards is byte-for-byte what it always was. The expansion is a real **in-row layout
/// morph**: the card's layout width animates from the portrait poster's to a 16:9 tile at the
/// POSTER'S OWN HEIGHT (height never changes — UX-4a), so the `LazyHStack` slides the trailing
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
        /// AVPlayer can open), stamped when we found that out. A statement about the *content*.
        case unavailable(Date)
        /// A resolved trailer whose *playback* just failed, stamped when it did. A statement about
        /// this moment, not about the title (BUG-46/B2).
        case transient(Date)
    }

    /// Extracted YouTube URLs carry a signature that outlives a browsing session by hours; three
    /// hours keeps re-focus free while staying comfortably inside that window.
    private static let resolvedTTL: TimeInterval = 3 * 60 * 60
    /// Negative results expire fast — a momentary addon/network failure shouldn't blacklist a title
    /// for the rest of the session.
    private static let unavailableTTL: TimeInterval = 20 * 60
    /// BUG-46/B2: playback failures used to land in `.unavailable` alongside "this title has no
    /// trailer", so once a leaked-decoder storm made a handful of titles fail, browsing was dead
    /// for 20 minutes and the only cure anyone found was restarting the app. A player failure now
    /// gets its own short TTL: long enough to stop a focus-in/focus-out retry loop, short enough
    /// that the user never has to know the word "restart".
    private static let transientTTL: TimeInterval = 45
    /// A long browsing session touches far more titles than it plays; bound the map and drop the
    /// oldest insertions first (recency of *use* isn't worth tracking for entries this small).
    private static let capacity = 200

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    /// BUG-63: what's cached is a *language-dependent* answer (the trailer list TMDB returned for
    /// the Metadata Language of the moment), but the key is `type:id`. Rather than leak the
    /// language into every key (and every probe line), remember which language the whole map was
    /// built under and drop it wholesale when that changes — a language flip is rare and total.
    private var languageScope: String?

    private init() {}

    private func reconcileLanguageScope() {
        let current = TmdbSettingsRepository.shared.snapshot().language
        guard let scope = languageScope else { languageScope = current; return }
        guard scope != current else { return }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] cache purge reason=language from=%@ to=%@ dropped=%d", scope, current, entries.count)
        }
        entries.removeAll()
        insertionOrder.removeAll()
        languageScope = current
    }

    /// `nonisolated` so view bodies (e.g. `CatalogRowView`'s play/pause gate) can build a key without
    /// hopping actors — it's pure string interpolation and touches no state.
    nonisolated static func key(type: String, id: String) -> String { "\(type):\(id)" }

    /// Non-expired entry for `key`, evicting it if its TTL has passed.
    func entry(for key: String) -> Entry? {
        reconcileLanguageScope()
        guard let entry = entries[key] else { return nil }
        let age: TimeInterval
        let ttl: TimeInterval
        let kind: String
        switch entry {
        case let .resolved(_, stamped):
            age = Date().timeIntervalSince(stamped)
            ttl = Self.resolvedTTL
            kind = "resolved"
        case let .unavailable(stamped):
            age = Date().timeIntervalSince(stamped)
            ttl = Self.unavailableTTL
            kind = "unavailable"
        case let .transient(stamped):
            age = Date().timeIntervalSince(stamped)
            ttl = Self.transientTTL
            kind = "transient"
        }
        guard age < ttl else {
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] cache expire key=%@ kind=%@ age=%.0fs", key, kind, age)
            }
            remove(key)
            return nil
        }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] cache hit key=%@ kind=%@ age=%.0fs", key, kind, age)
        }
        return entry
    }

    /// `causeSite` is Phase 0 instrumentation only (nil for `.resolved` writes): which call site
    /// decided this title has nothing playable, so the `[TrailerPipeline] cache store` line reads
    /// as a diagnosis (e.g. "playbackFailed" vs "no trailer listed") instead of a bare kind flag.
    func store(_ entry: Entry, for key: String, causeSite: String? = nil) {
        reconcileLanguageScope()
        if entries[key] == nil { insertionOrder.append(key) }
        entries[key] = entry
        while insertionOrder.count > Self.capacity, let oldest = insertionOrder.first {
            remove(oldest)
        }
        if TrailerProbe.enabled {
            let kind: String
            switch entry {
            case .resolved: kind = "resolved"
            case .unavailable: kind = "unavailable"
            case .transient: kind = "transient"
            }
            let site = causeSite.map { " causeSite=\($0)" } ?? ""
            NSLog("[TrailerPipeline] cache store key=%@ kind=%@ count=%d%@", key, kind, entries.count, site)
        }
    }

    /// BUG-46/B2+B3: forget everything we know about a title, so the next dwell re-resolves from
    /// scratch. Used when what we cached is provably stale rather than merely old — a `.resolved`
    /// URL whose `TrailerLocalHLS` token has been evicted, or one that just 404'd from that same
    /// loopback server. Deliberately *not* followed by a `.transient` write: a stale playlist is
    /// exactly the case where retrying immediately is the cure.
    func invalidate(key: String) {
        guard entries[key] != nil else { return }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] cache invalidate key=%@", key)
        }
        remove(key)
    }

    /// BUG-46/B2 (storm breaker): drop every entry a *player failure* wrote. Genuine `.unavailable`
    /// results are left alone — a burst of decoder failures says nothing about which titles have
    /// trailers listed, and re-extracting those would be pure waste.
    func clearTransient() {
        let stale = entries.compactMap { key, entry -> String? in
            if case .transient = entry { return key }
            return nil
        }
        guard !stale.isEmpty else { return }
        stale.forEach { remove($0) }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] cache clearTransient purged=%d count=%d", stale.count, entries.count)
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
///
/// P-1c: `beginExtraction()`'s refusal is also, as of this pass, the reason a busy pipeline never
/// makes a card flash. `InlineTrailerCardModel.resolve()` checks this latch before it ever morphs
/// the card to `.expandedStatic` (P-1b), so a card that loses the race for the single extraction
/// slot simply stays in `.dwelling` and quietly collapses — the refusal is decided before there is
/// anything on screen to undo.
///
/// beta.19-rc1 verdict (M3, BUG-126): no longer an `ObservableObject`. The playing key used to be
/// `@Published` and every mounted `CatalogRowView` observed this object, so ONE claim or release
/// re-rendered EVERY row on Home, which is the row-to-row stutter class. The key now goes out
/// through `playingKeySubject`; each row `.onReceive`s it and writes its own `@State` only when the
/// key belongs to one of its own items, so only the affected row re-renders.
@MainActor
final class InlineTrailerCoordinator {
    static let shared = InlineTrailerCoordinator()

    /// Cache key (`"type:id"`) of the title whose trailer currently owns the single player slot, or
    /// `nil` when nothing plays. Sent only when it CHANGES (so subscribers need no dedupe).
    ///
    /// Producers — whoever calls `claimPlayback` / `releasePlayback`:
    /// * an inline catalog card's model (the card's own key);
    /// * Home's hero model (`HomeView.heroTrailerModel`). In Trailer Location: Hero every card is
    ///   `InlineTrailerCard(enabled: false)` and the hero claims with the FOCUSED card's own key,
    ///   which is what lets that card's row arm Play/Pause as the mute toggle;
    /// * the Stage & Strip batch's background trailer, the same way.
    ///
    /// Consumers:
    /// * each `CatalogRowView`, via `.onReceive` (the row, not the card, answers "is the focused
    ///   item the one playing?": tvOS delivers `.onPlayPauseCommand` to the focused view chain,
    ///   which is the row's `Button`/`NavigationLink`, never the card that is its label);
    /// * `HomeView.heroTrailerHolding`'s plain read of `playingKey` on the carousel tick.
    let playingKeySubject = CurrentValueSubject<String?, Never>(nil)

    /// The current value of `playingKeySubject`, for plain reads (`HomeView.heroTrailerHolding`).
    var playingKey: String? { playingKeySubject.value }

    private weak var activePlayer: InlineTrailerCardModel?
    private var extracting = false
    /// Phase 0 instrumentation only: when the latch was last granted, so a refuse can log how
    /// long it's been held — a latch held far past `extractionTimeoutSeconds` (15s) is candidate
    /// #4's smoking gun (a stranded `endExtraction()` that never fired).
    private var extractionStartedAt: Date?
    /// Sanity-check counter, not a real queue depth (only one extraction is ever granted at a
    /// time by design) — a value that ever reads >1 would itself be a bug worth knowing about.
    private var inFlightExtractions = 0
    /// BUG-46/B4: last resort against a latch that never gets released. B4 makes `endExtraction()`
    /// structurally unskippable, so this should never fire — sized above the single-candidate 15s
    /// extraction deadline so it can only ever mean "something we didn't model stalled".
    ///
    /// Finding 5 (BUG-101 follow-up) — CONTRACT: this bounds a single held *attempt*, not a
    /// caller's whole walk across ranked candidates. BUG-101 added sequential candidate retries
    /// that can hold ONE ticket across up to three attempts (≤45s total) — well past this
    /// constant — so every ticket holder that may make more than one attempt MUST call
    /// `touchExtraction(_:)` at the start of each attempt to refresh `extractionStartedAt`.
    /// Skipping that would let this watchdog force-clear a ticket that's still legitimately in
    /// progress, handing a second ticket to another caller and overlapping two extraction
    /// pipelines. Because the refresh only happens once per attempt (not continuously), a SINGLE
    /// attempt that itself hangs past this deadline since its own refresh is still reclaimed —
    /// the contract only forgives the walk taking a while across attempts, never one attempt
    /// stalling.
    private static let latchWatchdogSeconds: TimeInterval = 20
    /// BUG-46/B2 (storm breaker): when the last player failures landed. Process-wide, because the
    /// storm this detects is a shared resource running out, not one card misbehaving.
    ///
    /// Deliberately NOT the Phase 0 `TrailerPipelineCounters` ring: that one is only populated when
    /// `debug.trailerProbe` is on, and the breaker has to work on a tester's release sideload with
    /// every knob off.
    private var playbackFailureStamps: [Date] = []
    private static let stormThreshold = 3
    private static let stormWindowSeconds: TimeInterval = 60

    private init() {}

    /// Hands the single player slot to `owner`, dropping whoever held it back to a plain poster.
    func claimPlayback(_ owner: InlineTrailerCardModel, key: String) {
        if let activePlayer, activePlayer !== owner { activePlayer.relinquishPlayback() }
        activePlayer = owner
        if playingKeySubject.value != key { playingKeySubject.send(key) }
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] claimPlayback key=%@", key)
        }
    }

    func releasePlayback(_ owner: InlineTrailerCardModel) {
        if activePlayer === owner {
            if TrailerProbe.enabled, let playingKey {
                NSLog("[TrailerPipeline] releasePlayback key=%@", playingKey)
            }
            activePlayer = nil
            if playingKeySubject.value != nil { playingKeySubject.send(nil) }
        }
    }

    /// Monotonic id for the current latch holder: `endExtraction` only honors the ticket it
    /// issued, so a stranded extractor whose latch the watchdog force-cleared can't release a
    /// NEWER caller's latch when its deferred `endExtraction` finally fires (Codex round 12).
    private var extractionTicket = 0

    /// A ticket when this caller may extract (pass it to `endExtraction`); nil when refused.
    func beginExtraction() -> Int? {
        if extracting, let startedAt = extractionStartedAt,
           Date().timeIntervalSince(startedAt) > Self.latchWatchdogSeconds {
            // BUG-46/B4: a latch held past every deadline we impose is stranded, and a stranded
            // latch means no card in the app ever extracts again — the worst possible failure for
            // a fail-soft feature. Loud on purpose: this is unreachable by construction now, so if
            // it ever appears in a log there is a real stall class we haven't modelled.
            NSLog("[TrailerPipeline] extraction latch STRANDED held=%.1fs — force-clearing",
                  Date().timeIntervalSince(startedAt))
            extracting = false
            extractionStartedAt = nil
            inFlightExtractions = 0
        }
        guard !extracting else {
            if TrailerProbe.enabled {
                let heldFor = extractionStartedAt.map { Date().timeIntervalSince($0) } ?? -1
                NSLog("[TrailerPipeline] beginExtraction refused held=%.1fs", heldFor)
            }
            return nil
        }
        extracting = true
        extractionTicket += 1
        extractionStartedAt = Date()
        inFlightExtractions += 1
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] beginExtraction granted ticket=%d inFlight=%d", extractionTicket, inFlightExtractions)
        }
        return extractionTicket
    }

    /// Finding 5 (BUG-101 follow-up): refreshes the watchdog clock for the ticket currently held —
    /// see the CONTRACT note on `latchWatchdogSeconds`. Call this at the start of every candidate
    /// attempt a held ticket makes; a stale/superseded ticket (one that lost the latch to a
    /// force-clear, or that isn't the current holder) is silently ignored, same as `endExtraction`.
    func touchExtraction(_ ticket: Int) {
        guard extracting, ticket == extractionTicket else { return }
        extractionStartedAt = Date()
    }

    func endExtraction(_ ticket: Int) {
        guard extracting, ticket == extractionTicket else {
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] endExtraction stale ticket=%d current=%d — ignored", ticket, extractionTicket)
            }
            return
        }
        let heldFor = extractionStartedAt.map { Date().timeIntervalSince($0) } ?? -1
        extracting = false
        extractionStartedAt = nil
        inFlightExtractions = max(0, inFlightExtractions - 1)
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] endExtraction held=%.1fs inFlight=%d", heldFor, inFlightExtractions)
        }
    }

    /// BUG-46/B2 (storm breaker): records a player failure and reports whether the pipeline is in a
    /// storm — three or more failures inside a minute, which is what a shared-resource collapse
    /// (the tvOS decoder cap, media services resetting) looks like from up here. The caller's cure
    /// is to purge what those failures cached, so recovery doesn't have to wait out a TTL.
    func recordPlaybackFailure() -> Bool {
        let now = Date()
        playbackFailureStamps.append(now)
        playbackFailureStamps.removeAll { now.timeIntervalSince($0) > Self.stormWindowSeconds }
        guard playbackFailureStamps.count >= Self.stormThreshold else { return false }
        NSLog("[TrailerPipeline] STORM failures=%d window=%.0fs", playbackFailureStamps.count, Self.stormWindowSeconds)
        playbackFailureStamps.removeAll()
        return true
    }
}

// MARK: - Per-card state machine

/// idle → dwelling (held focus until the rows rest, `TrailerStartGate`) → expandedStatic (landscape
/// art, immediately) → playing, and back to idle the moment the reason to be expanded goes away.
///
/// Every step fails soft and *silently*: there is never a spinner or a black tile, because the
/// static landscape art is already on screen from the moment the card expands. Anything that ends
/// the preview — no trailer, extraction failure, playback failure, or the trailer simply finishing —
/// collapses the card back to its poster rather than parking it on static artwork.
///
/// The phase used to drive *layout* directly (portrait poster ⇄ landscape tile in the row) through
/// one 0.35 s `setPhase` transaction. beta.19-rc1 verdict (R2, BUG-133): for a catalog card
/// (`hostsTile`) the visual is now `morphStage`, a separate staged choreography (in-place dissolve
/// at the poster's width, THEN the width grows; shrink, THEN dissolve; abort = one frame), and
/// `phase` keeps the pipeline meaning only (dwell / resolved / playing). The hero model
/// (`hostsTile == false`) keeps today's phase-only behaviour exactly.
@MainActor
final class InlineTrailerCardModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case dwelling
        case expandedStatic
        case playing(String)
    }

    /// beta.19-rc1 verdict (R2, BUG-133): the catalog tile's visual stage.
    /// `.none` poster only · `.reveal` tile drawn at the POSTER's width (dissolving in or out) ·
    /// `.wide` tile at 16:9, neighbours pushed aside.
    nonisolated enum MorphStage: Equatable, Sendable {
        case none
        case reveal
        case wide
    }

    @Published private(set) var phase: Phase = .idle
    /// R2: see `MorphStage`. Always `.none` on the hero model.
    @Published private(set) var morphStage: MorphStage = .none
    /// R2: the decoded tile art, set BEFORE `.reveal` (so the first revealed frame is the picture,
    /// never a shimmer — Steven's 0:53.5 empty frame) and cleared in the completion of the final
    /// collapse transaction, token-guarded so a re-expansion during the collapse keeps it.
    @Published private(set) var tileArt: InlineTileArt?

    /// Mirrors `accessibilityReduceMotion` from the hosting card. When set, the morph is an instant
    /// swap instead of an animated one.
    var prefersReducedMotion = false

    /// beta.19-rc1 verdict (M3, BUG-133): which rest signal the dwell gate reads. The catalog card
    /// assigns it from `EnvironmentValues.rowRestSource` before every dwell; `HomeView` assigns the
    /// hero model's (W2-E).
    var restSource: RowRestSource = .motionClock
    /// R2: true for a catalog card (set in the card's `.onAppear`, BEFORE any `focusChanged(true…)`),
    /// which owns a tile and runs the staged morph. False on the hero model: no art, no stages.
    var hostsTile = false
    /// R2: the tile art's candidates (banner, then poster) and the tile's resting size, set by the
    /// catalog card in `.onAppear`. nil on the hero model.
    var tileArtSource: InlineTileArtSource?

    nonisolated static let morphDuration: TimeInterval = 0.35
    /// The morph curve. Slow enough to read as one object changing shape, short enough that a fast
    /// D-pad hand never feels held up by it. R2: the WIDTH stage only (`.reveal ⇄ .wide`), and the
    /// hero model's phase changes.
    static let morphAnimation: Animation = .easeInOut(duration: morphDuration)
    /// R2: the in-place dissolve (poster ⇄ tile at the poster's width). 0 would be a cut; tune on
    /// device.
    nonisolated static let revealDuration: TimeInterval = 0.12
    /// R2: a focus loss this soon after the `.wide` edge aborts (one frame) instead of animating
    /// the collapse. Device-tune item (critique #26): read the `[CatalogGridProbe]` lines around
    /// `style=instant` and lower this if the row shows a second correcting motion after an abort.
    nonisolated static let abortWindowIntoWide: TimeInterval = 0.2
    /// R2: how long `beginMorph` waits for the tile art. NOT a request timeout — the fetch keeps
    /// running to warm the cache (critique #6).
    nonisolated static let artAwaitDeadline: TimeInterval = 1.0

    #if DEBUG
    /// R2 DEBUG knobs (critique #7), read once. They make the abort legs non-vacuous on the
    /// simulator: `reset()` this many ms after the `.reveal` / `.wide` edge, and an override for
    /// `abortWindowIntoWide` so an "instant" abort can land late enough to observe the pushed
    /// layout first.
    private static let abortAfterRevealMs = UserDefaults.standard.integer(forKey: "debug.trailerMorphAbortAfterRevealMs")
    private static let abortAfterWideMs = UserDefaults.standard.integer(forKey: "debug.trailerMorphAbortAfterWideMs")
    private static let abortWindowOverrideMs = UserDefaults.standard.integer(forKey: "debug.trailerAbortWindowMs")
    #endif

    /// `abortWindowIntoWide`, or the DEBUG `-debug.trailerAbortWindowMs` override.
    static var effectiveAbortWindow: TimeInterval {
        #if DEBUG
        if abortWindowOverrideMs > 0 { return TimeInterval(abortWindowOverrideMs) / 1000 }
        #endif
        return abortWindowIntoWide
    }

    /// Expanded covers both "showing static landscape art" and "playing" — the tile is the same one.
    /// Pipeline meaning only on a catalog card since R2; the visual is `tileVisible`/`layoutExpanded`.
    var isExpanded: Bool {
        switch phase {
        case .idle, .dwelling: return false
        case .expandedStatic, .playing: return true
        }
    }

    /// R2: the card's LAYOUT width is the 16:9 tile's (drives `onExpansionChange` and the row scroll).
    var layoutExpanded: Bool { morphStage == .wide }
    /// R2: the tile is drawn (dissolving in, wide, or dissolving out).
    var tileVisible: Bool { morphStage != .none }

    var playingURL: String? {
        if case let .playing(url) = phase { return url }
        return nil
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // R2 stage bookkeeping.
    /// When `morphStage` last changed (systemUptime); nil at rest.
    private var stageChangedAt: TimeInterval?
    /// Identifies the current stage sequence. Bumped by `beginMorph` (a new expansion), an abort,
    /// and the start of an animated collapse, so a stale scheduled step can never act. Deliberately
    /// NOT `generation`: `collapse()` bumps `generation`, and a deferred collapse must let the
    /// expansion it interrupted finish first (§2.2 "Deferred collapse").
    private var morphToken = 0
    /// An animated collapse (shrink → dissolve) is running; a focus loss lets it finish instead of
    /// snapping the width back mid-shrink.
    private var collapseInFlight = false
    /// The pending `.reveal → .wide` step, or the pending shrink → dissolve step.
    private var stageTask: Task<Void, Never>?
    /// A collapse waiting for the expansion in flight to finish (§2.2).
    private var deferTask: Task<Void, Never>?
    private var stageAge: TimeInterval {
        stageChangedAt.map { Self.now - $0 } ?? .greatestFiniteMagnitude
    }

    // R2 tile-art prefetch (critique #6).
    private var artTask: Task<InlineTileArt?, Never>?
    private var artToken = 0
    private var artDone = false
    private var artResult: InlineTileArt?

    #if DEBUG
    /// M3 gate telemetry for `debug_trailerTile` (seconds since focus; absolute uptime for
    /// `gateFocusAt`). Plain stored values: the morph that follows publishes `morphStage`, which
    /// re-renders the probe with them.
    private(set) var gateFocusAt: TimeInterval?
    private(set) var gateRestAt: TimeInterval?
    private(set) var gateStartAt: TimeInterval?
    private(set) var gateVia: String?
    private(set) var gateDelay: TrailerStartDelay?
    #endif

    /// Probe spelling of this model's host.
    private var hostTag: String { hostsTile ? "card" : "hero" }

    /// Meta comes from the shared repo's cache in the common case; this bounds the cold path so a
    /// slow addon can't leave a card resolving for the whole time the user sits on it.
    private static let metaTimeoutSeconds: TimeInterval = 5
    /// Extraction is several chained requests to YouTube; well past this it isn't an inline preview
    /// any more.
    private static let extractionTimeoutSeconds: TimeInterval = 15

    private var dwellTask: Task<Void, Never>?
    /// Bumped on every focus change/teardown. Guards the dwell → expand hop against a stale timer.
    private var generation = 0
    /// beta.19-rc1 verdict (review r2, P3-4): re-arms this focus visit has spent after a cache hit
    /// found the listener not ready (`InlineTrailerCacheHitPlan.rearmsAfterListenerWait`), and the
    /// one pending. Both reset by `reset()`, so the budget is per focus visit, never per dwell (a
    /// re-arm IS a dwell, so a per-dwell budget would loop).
    private var listenerRearmsUsed = 0
    private var listenerRearmTask: Task<Void, Never>?
    /// The title this card is currently expanded on; a resolution may only attach to its own key.
    private var activeKey: String?
    /// Key of the resolution currently in flight for this card, so a re-focus mid-resolve doesn't
    /// start a second pipeline (the in-flight one attaches itself when it lands).
    ///
    /// Finding 6 (BUG-101 follow-up, r2) — CONTRACT: this represents ownership of the WHOLE
    /// candidate walk for `key`, not just the `resolve()` async function that first set it.
    /// `resolve()`'s own extraction can hand the walk off to `retryNextCandidate` (a repack
    /// failure) in a SEPARATE `Task`, and `playbackFailed` can start a walk of its own well after
    /// `resolve()` has already returned — both are still the same logical resolution and must
    /// keep holding this key, or `reset()`'s "keep `candidateTrailers` while a resolution for this
    /// key is in flight" check (which compares `candidateTrailersKey` to this property) goes blind
    /// the moment focus leaves and returns, and a refocus's `startResolution` sees `resolvingKey`
    /// as free and starts a second, concurrent pipeline against the same key. Concretely:
    /// * `resolve()` sets this (via `startResolution`) before its `Task` starts, and clears it
    ///   itself on every return that is a TRUE end of the walk — but NOT on the return that hands
    ///   off to `retryNextCandidate`, and only when that hand-off is ACCEPTED (see the
    ///   `retryOwnsResolution` flag there).
    /// * `retryNextCandidate` returns `true` when it accepts a hand-off — claiming this
    ///   (idempotently, if `resolve()` already holds it; freshly, if `playbackFailed` is the
    ///   caller) — and is thereafter the sole owner: it clears this on every branch that truly
    ///   ends the walk, but never before its own recursive hand-off to itself for the next
    ///   candidate. It returns `false`, WITHOUT ever touching this property, when its own
    ///   early-return guard rejects the hand-off outright (e.g. `activeKey` already went nil
    ///   because focus left mid-`await`) — a rejected hand-off must still release `resolvingKey`,
    ///   which the caller does by only setting `retryOwnsResolution`/treating the walk as "in
    ///   flight" when the return value is `true`; a caller that ignored the return value would
    ///   leave this key latched with no resolver running, stranding a later refocus in
    ///   `.dwelling` forever.
    /// * Either owner clears this ONLY when it still equals `key` — a walk that bails because
    ///   focus moved to a different title must never clobber that other title's own in-flight
    ///   `resolvingKey`.
    private var resolvingKey: String?
    /// Title whose trailer already played through on *this* dwell. Blocks an immediate re-expansion
    /// while focus stays put; cleared by `reset()`, so leaving and coming back plays it again.
    private var didFinishForKey: String?

    /// BUG-101: the ranked candidate list `resolve()` last extracted from, and the index that
    /// actually produced the current/most recent playable source — kept around so `playbackFailed`
    /// can retry the NEXT candidate instead of just collapsing. `candidateTrailersKey` ties both to
    /// the key they were populated for, since the cache-hit branch of `expand()` starts playback
    /// without ever calling `resolve()` and must not let a retry fire against a stale, unrelated list.
    private var candidateTrailers: [MetaTrailer] = []
    private var candidateIndex = 0
    private var candidateTrailersKey: String?
    /// One playback-failure retry per title per dwell — otherwise a title whose every remaining
    /// candidate fails to actually decode would retry without end.
    private var retriedAfterPlaybackFailureKey: String?

    // MARK: Focus

    func focusChanged(_ focused: Bool, item: MetaPreview) {
        // BUG-55: everything below `beginExtraction` already logs, but a dwell that never armed was
        // invisible — the probe has to start at the very first event the card receives.
        if focused {
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] focus key=%@", TrailerResolutionCache.key(type: item.type, id: item.id))
            }
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

    /// beta.19-rc1 verdict (M3, BUG-133): the dwell is a REST GATE, not a 1 s wall clock from focus.
    /// The old timer was blind to row motion, and the engine's row slide after a Down press takes
    /// ~1.15 s to settle, so the morph started while the row was still sliding (Steven's video).
    /// The loop polls `restSource` every `TrailerStartGate.poll` and asks the pure planner
    /// (`TrailerStartGate.step`) whether to start: Automatic = rest + 1 s, a fixed N = max(focus + N,
    /// rest), and with no rest at all the 3 s ceiling (`via=ceiling`). `restBegan` resets whenever
    /// motion returns (a corrector nudge, a relayout). The generation/cancel discipline is
    /// unchanged: any focus change or teardown bumps `generation` and the loop bails.
    private func startDwell(_ item: MetaPreview) {
        generation &+= 1
        let generationAtStart = generation
        dwellTask?.cancel()
        // Normally a no-op transition from `.idle`; routed through `setPhase` so the rare arrival on
        // an already-expanded card (a re-render that re-runs `onAppear`) still collapses smoothly.
        // R2: on a catalog card the visual collapse is the stage's, by the same abort rule as a
        // focus loss.
        collapseStage(trigger: "redwell")
        setPhase(.dwelling)
        let key = TrailerResolutionCache.key(type: item.type, id: item.id)
        dwellTask = Task { [weak self] in
            // M4/FEAT-52: read once per dwell.
            let delay = TrailerStartDelay.current()
            let focusAt = InlineTrailerCardModel.now
            var restBegan: TimeInterval?
            while true {
                guard !Task.isCancelled, let model = self, model.generation == generationAtStart else { return }
                let now = InlineTrailerCardModel.now
                if model.restSource.isAtRest() {
                    restBegan = restBegan ?? now
                } else {
                    restBegan = nil
                }
                let restAge = restBegan.map { now - $0 }
                // R2 (critique #6): the tile-art prefetch never starts at focus, so a horizontal
                // scrub across a row fires no banner fetch per card it passes. beta.19-rc1 verdict
                // (review r1, A-3): "the first at-rest reading" WAS focus whenever the rows were
                // already still (a held Right across cards already in view), so the rest branch now
                // also needs `artPrefetchMinDwell` on this card; `artPrefetchAfter` is unchanged.
                if model.hostsTile, model.artTask == nil,
                   TrailerStartGate.shouldStartArtPrefetch(focusAge: now - focusAt, restAge: restAge) {
                    model.startArtPrefetch()
                }
                switch TrailerStartGate.step(delay: delay, focusAge: now - focusAt, restAge: restAge) {
                case .start(let via):
                    model.noteGateStart(key: key, delay: delay, focusAt: focusAt,
                                        restAt: restBegan.map { $0 - focusAt }, startAt: now - focusAt, via: via)
                    await model.expand(item)
                    return
                case .wait(let seconds):
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
    }

    /// M3 gate telemetry: the `[TrailerPipeline] gate` probe line, the `debug_trailerTile` fields
    /// and the DEBUG `event=gate` line. `restAt`/`startAt` are seconds since focus.
    private func noteGateStart(key: String, delay: TrailerStartDelay, focusAt: TimeInterval,
                               restAt: TimeInterval?, startAt: TimeInterval, via: String) {
        if TrailerProbe.enabled {
            // Kept for log continuity: device-log readers grep the pre-gate spelling.
            NSLog("[TrailerPipeline] dwell fired key=%@", key)
            NSLog("[TrailerPipeline] gate key=%@ delay=%@ focusToRest=%.2f restToStart=%.2f via=%@ host=%@ src=%@",
                  key, delay.rawValue, restAt ?? -1, restAt.map { startAt - $0 } ?? -1, via,
                  hostTag, restSource.probeTag)
        }
        #if DEBUG
        gateFocusAt = focusAt
        gateRestAt = restAt
        gateStartAt = startAt
        gateVia = via
        gateDelay = delay
        let rest = restAt.map { String(format: "%.2f", $0) } ?? "-"
        InlineTrailerDebugLog.shared.note(
            "event=gate host=\(hostTag) key=\(key) delay=\(delay.rawValue) rest=\(rest) start=\(String(format: "%.2f", startAt)) via=\(via)"
        )
        #endif
    }

    /// Focus lost, or the card scrolled out of the row: back to the plain poster immediately. Any
    /// in-flight resolution keeps running to completion (it still populates the cache, so coming
    /// back is instant); if focus returns to the SAME title before it finishes, `startResolution`
    /// re-arms `activeKey` (it bails on `resolvingKey == key` rather than starting a second
    /// pipeline) and the original result attaches when it lands — see `startPlayback`'s "original
    /// result attaches" comment.
    ///
    /// Finding 4 (BUG-101 follow-up): that late attach used to strand `playbackFailed`'s retry —
    /// this unconditionally wiped `candidateTrailers`/`candidateTrailersKey` the moment focus
    /// left, so by the time the reattached resolution's result played and then failed, there was
    /// no candidate list left to retry from. Keep them across `reset()` for as long as the
    /// resolution they were populated for (`candidateTrailersKey`) is still the one in flight
    /// (`resolvingKey`); drop them here only once that resolution is no longer in flight —
    /// finished, abandoned, or superseded by a different key's `startResolution` (which
    /// overwrites `resolvingKey` and leaves this stale list orphaned but harmless, since
    /// `candidateTrailersKey` no longer matches `activeKey` for anything that reads it).
    ///
    /// beta.19-rc1 verdict (R2, BUG-133): on a catalog card the visual collapse follows the abort
    /// rule (`InlineTrailerMorphPlan.collapseStyle`): focus lost during `.reveal`, or within
    /// `abortWindowIntoWide` of the `.wide` edge, snaps everything to the poster in ONE frame (no
    /// half-pushed neighbour sliding back, no ghost logo fading across the gap — Steven's 2:10.6
    /// GIGN frame); later, the tile shrinks and then dissolves. `abortStages` forces the one-frame
    /// path whatever the stage (the card's `.onDisappear`: a recycled cell must not come back
    /// mid-collapse, and `tileArt` clears at once).
    func reset(abortStages: Bool = false) {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        // Review r2 (P3-4): a new focus visit gets its own listener re-arm.
        listenerRearmTask?.cancel()
        listenerRearmTask = nil
        listenerRearmsUsed = 0
        activeKey = nil
        didFinishForKey = nil
        if candidateTrailersKey == nil || candidateTrailersKey != resolvingKey {
            candidateTrailers = []
            candidateIndex = 0
            candidateTrailersKey = nil
            retriedAfterPlaybackFailureKey = nil
        }
        InlineTrailerCoordinator.shared.releasePlayback(self)
        dropArtPrefetch()
        if abortStages {
            abortStage(trigger: "disappear")
        } else {
            collapseStage(trigger: "reset")
        }
        setPhase(.idle)
    }

    /// Another card took the single player slot. Defensive only — the card that loses focus resets
    /// itself first — so collapse rather than park a now-landscape tile in a row nobody is looking at.
    func relinquishPlayback() {
        guard playingURL != nil else { return }
        activeKey = nil
        setPhase(.idle)
        collapseStage(trigger: "relinquish")
    }

    /// The player couldn't start (undecodable/stalled/404). Remember it *as a playback failure* and
    /// collapse.
    ///
    /// BUG-46/B2: what gets remembered is the whole point. This used to write `.unavailable` — the
    /// same verdict as "this title lists no trailer" — so a run of failures blacklisted real titles
    /// for 20 minutes and the app looked permanently broken until it was restarted. Now:
    /// * a 404 from our own loopback repack server means the playlists we cached are gone, not that
    ///   the title is bad — forget the entry entirely so the next dwell re-repacks (B3 makes that
    ///   rare; this is the backstop for a googlevideo URL expiring inside a playlist);
    /// * anything else gets `.transient`, which suppresses a tight refocus retry for 45s and then
    ///   lets the title prove itself again;
    /// * three failures inside a minute is a shared-resource storm, so the negative entries those
    ///   failures wrote are purged outright rather than left to expire one by one.
    func playbackFailed(_ report: TrailerFailureReport) {
        // beta.19-rc1 verdict (B2, BUG-131): a connection-class failure (a start-watchdog timeout, or
        // an NSURLErrorDomain item error such as -1004) of a LOOPBACK repack URL with no HTTP status
        // is what a dead listener looks like — the app was suspended and the socket reclaimed with no
        // callback. Ask the server to ping itself now (alive → nothing; dead → rebuild), BEFORE the
        // BUG-101 retry below starts its own `playbackOutcome` (its `Task` runs after this method
        // returns), so the retry finds the rebuilt listener or the 2 s attempt deadline. A 404 from the
        // listener itself, or any HTTP status, is the evicted-token path and not this one.
        if report.httpStatus == nil,
           let failedURL = report.urlString,
           TrailerLocalHLS.port(inPlaybackURL: failedURL) != nil,
           report.cause.isConnectionClass {
            TrailerLocalHLS.shared.verifyListener(reason: "playback")
        }
        var retrying = false
        if let activeKey {
            let isLoopback404 = report.httpStatus == 404
                && report.urlString.flatMap(TrailerLocalHLS.token(inPlaybackURL:)) != nil
            if isLoopback404 {
                TrailerResolutionCache.shared.invalidate(key: activeKey)
            } else {
                TrailerResolutionCache.shared.store(
                    .transient(Date()),
                    for: activeKey,
                    causeSite: "playbackFailed:\(report.cause.tag)"
                )
            }
            // BUG-101: a playback failure says THIS stream didn't pan out, not that the title has
            // nothing to show — walk to the next ranked candidate once before giving up, mirroring
            // the extraction-miss fallback in `resolve()`. Excludes the loopback-404 case (our own
            // repack cache going stale, not the candidate being bad — `expand()`'s stale-token check
            // already re-resolves the SAME candidate from scratch on the next focus) and requires
            // `candidateTrailersKey == activeKey`, since the cache-hit branch of `expand()` can start
            // playback without ever populating `candidateTrailers` for this key.
            if !isLoopback404,
               candidateTrailersKey == activeKey,
               retriedAfterPlaybackFailureKey != activeKey,
               candidateIndex + 1 < candidateTrailers.count,
               candidateIndex + 1 < 3 {
                retriedAfterPlaybackFailureKey = activeKey
                // The failed player still owns the single playback slot; hand it back before
                // dropping the phase to `.expandedStatic` so `startPlayback` (which only promotes
                // from `.expandedStatic`/`.dwelling`) can re-promote once the retry lands.
                InlineTrailerCoordinator.shared.releasePlayback(self)
                setPhase(.expandedStatic)
                // Finding 6 (BUG-101 follow-up, r2): `resolve()` already returned by the time
                // playback can fail, so `resolvingKey` is normally free here — `retryNextCandidate`
                // claims it fresh for this retry (see the CONTRACT on `resolvingKey`) so a
                // focus-out/focus-back-in mid-retry re-arms `activeKey` instead of racing a second
                // `startResolution` pipeline against the one already walking. Codex r3 (Finding
                // P2): read its return value into `retrying` rather than assuming the hand-off
                // succeeded — its own early-return guard can reject it (e.g. focus already moved
                // off `activeKey`), and treating that as "retrying" would fall through to
                // `collapse()` being skipped below while nothing is actually resolving.
                retrying = retryNextCandidate(key: activeKey, startIndex: candidateIndex + 1)
            }
        }
        if InlineTrailerCoordinator.shared.recordPlaybackFailure() {
            TrailerResolutionCache.shared.clearTransient()
        }
        if !retrying {
            collapse()
        }
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
    ///
    /// R2 (deferred collapse, BUG-133): the player goes at once, but on a catalog card whose
    /// expansion is still in flight (`.reveal`, or `.wide` younger than `morphDuration`) the
    /// visual collapse waits for the expansion to finish, then shrinks and dissolves — never a
    /// reversal mid-growth (Steven's 4:34.7 Verity frame). A focus loss in between wins and aborts.
    private func collapse() {
        generation &+= 1
        dwellTask?.cancel()
        dwellTask = nil
        activeKey = nil
        InlineTrailerCoordinator.shared.releasePlayback(self)
        setPhase(.idle)
        deferOrCollapseStage(trigger: "collapse")
    }

    // MARK: R2 staged morph

    /// One morph entry point (R2). Every path that used to `setPhase(.expandedStatic)` to morph — the
    /// cache-hit branch of `expand`, `resolve()` after `beginExtraction`, and `startPlayback`'s
    /// refocus `.dwelling` branch — goes through here. Returns false when focus left (or the title
    /// changed) during the art wait; the caller then does nothing visual.
    ///
    /// On a catalog card, in order: wait at most `artAwaitDeadline` for the tile art (the fetch keeps
    /// running past it); re-check the key; set `phase = .expandedStatic` with no animation of its
    /// own; set `tileArt`; run stage 1 (`.none → .reveal`, the in-place dissolve at the poster's
    /// width) and schedule stage 2 (`.reveal → .wide`, the width) `revealDuration` later. No art
    /// at all → the poster already in memory → failing that, the tile draws a flat surface, never a
    /// shimmer. The hero model keeps today's single animated phase change.
    private func beginMorph(key: String) async -> Bool {
        guard activeKey == key else { return false }
        guard hostsTile else {
            setPhase(.expandedStatic)
            return true
        }
        let generationAtStart = generation
        if artTask == nil { startArtPrefetch() }
        let waitStart = Self.now
        // `artTask != nil`: no art source at all (nothing to wait for) skips the wait.
        while artTask != nil, !artDone, Self.now - waitStart < Self.artAwaitDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled || generation != generationAtStart || activeKey != key { return false }
        }
        guard generation == generationAtStart, activeKey == key else { return false }
        let waitedMs = Int(((Self.now - waitStart) * 1000).rounded())
        var art = artResult
        var artFrom = art == nil ? "none" : "fetch"
        if art == nil, let held = InlineTileArtLoader.inMemory(primary: tileArtSource?.primary,
                                                                fallback: tileArtSource?.fallback) {
            art = held
            artFrom = "memory"
        }

        // A new sequence: supersedes any scheduled step, including a collapse still in flight
        // (re-focus during a collapse — its completion must not clear the art set below).
        morphToken &+= 1
        let token = morphToken
        stageTask?.cancel()
        stageTask = nil
        deferTask?.cancel()
        deferTask = nil
        collapseInFlight = false
        if case .playing = phase {} else { phase = .expandedStatic }
        if let art { tileArt = art }

        if prefersReducedMotion {
            // Reduce Motion: every stage change is instant.
            stageChangedAt = Self.now
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { morphStage = .wide }
            noteStage("wide", key: key, extra: "style=instant art=\(artFrom) artWaitMs=\(waitedMs)")
            return true
        }
        switch morphStage {
        case .none, .reveal:
            stageChangedAt = Self.now
            withAnimation(.easeOut(duration: Self.revealDuration)) { morphStage = .reveal }
            noteStage("reveal", key: key, extra: "art=\(artFrom) artWaitMs=\(waitedMs)")
            scheduleWide(token: token, key: key)
            scheduleAbortKnob(after: .reveal, token: token)
        case .wide:
            // A deferred collapse had not started shrinking yet: the tile is already wide.
            break
        }
        return true
    }

    /// Stage 2: `.reveal → .wide` `revealDuration` after stage 1, in `morphAnimation`. Guarded by
    /// `morphToken` only — NOT by `activeKey`/`generation` — because a deferred collapse
    /// (`collapse()` during `.reveal`) wants the expansion to finish before it shrinks.
    private func scheduleWide(token: Int, key: String) {
        stageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(InlineTrailerCardModel.revealDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.morphToken == token, self.morphStage == .reveal else { return }
            self.stageChangedAt = InlineTrailerCardModel.now
            withAnimation(InlineTrailerCardModel.morphAnimation) { self.morphStage = .wide }
            self.noteStage("wide", key: key, extra: "")
            self.scheduleAbortKnob(after: .wide, token: token)
        }
    }

    /// The focus-loss collapse (reset, re-dwell, relinquish): abort in one frame or animate, by
    /// `InlineTrailerMorphPlan.collapseStyle`. A collapse already animating is left to finish: it is
    /// heading to `.none` anyway, and snapping its width back mid-shrink would hand the focus engine
    /// a second correcting motion (the critique #26 class).
    private func collapseStage(trigger: String) {
        guard hostsTile, !collapseInFlight else { return }
        switch InlineTrailerMorphPlan.collapseStyle(stage: morphStage, stageAge: stageAge,
                                                     abortWindow: Self.effectiveAbortWindow) {
        case .none:
            if tileArt != nil { tileArt = nil }
        case .abort:
            abortStage(trigger: trigger)
        case .animated:
            startAnimatedCollapse(trigger: trigger)
        }
    }

    /// The pipeline collapse (`collapse()`): defer while an expansion is in flight, else animate.
    private func deferOrCollapseStage(trigger: String) {
        guard hostsTile, !collapseInFlight else { return }
        if let delay = InlineTrailerMorphPlan.deferredCollapseDelay(stage: morphStage, stageAge: stageAge) {
            let token = morphToken
            deferTask?.cancel()
            deferTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.morphToken == token, !self.collapseInFlight else { return }
                self.startAnimatedCollapse(trigger: trigger + "-deferred")
            }
            noteStage("defer", key: nil, extra: "ms=\(Int((delay * 1000).rounded())) trigger=\(trigger)")
        } else if morphStage != .none {
            startAnimatedCollapse(trigger: trigger)
        } else if tileArt != nil {
            tileArt = nil
        }
    }

    /// Abort: everything to `.none` in ONE frame — width, tile, art, player, in-tile logo — inside a
    /// transaction that also disables the implicit animations below it (the playing-URL fade, the
    /// in-tile title's `.transition(.opacity)`), so nothing ghosts across the gap.
    private func abortStage(trigger: String) {
        guard hostsTile else { return }
        let from = morphStage
        morphToken &+= 1
        stageTask?.cancel()
        stageTask = nil
        deferTask?.cancel()
        deferTask = nil
        collapseInFlight = false
        stageChangedAt = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            morphStage = .none
            tileArt = nil
            phase = .idle
        }
        guard from != .none else { return }
        let stage = from == .wide ? "wide" : "reveal"
        noteStage("abort", key: nil, extra: "style=instant stage=\(stage) trigger=\(trigger)")
        if CatalogGridProbe.enabled {
            CatalogGridProbe.log("morph abort style=instant stage=\(stage) trigger=\(trigger)")
        }
    }

    /// Collapse 1 (`.wide → .reveal`: the width shrinks under an opaque tile, the video already
    /// gone), then collapse 2 (`.reveal → .none`: the in-place dissolve back to the poster). The
    /// poster is drawn under an opaque tile in every collapse frame (Steven's 0:54.8 empty slot),
    /// and a lifted poster never peeks out from under a tile narrower than itself.
    private func startAnimatedCollapse(trigger: String) {
        guard hostsTile else { return }
        guard morphStage != .none else {
            if tileArt != nil { tileArt = nil }
            return
        }
        morphToken &+= 1
        let token = morphToken
        stageTask?.cancel()
        stageTask = nil
        deferTask?.cancel()
        deferTask = nil
        if prefersReducedMotion {
            stageChangedAt = nil
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                morphStage = .none
                tileArt = nil
            }
            noteStage("dissolve", key: nil, extra: "style=instant trigger=\(trigger)")
            return
        }
        collapseInFlight = true
        if morphStage == .wide {
            stageChangedAt = Self.now
            withAnimation(Self.morphAnimation) { morphStage = .reveal }
            noteStage("shrink", key: nil, extra: "style=animated trigger=\(trigger)")
            stageTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(InlineTrailerCardModel.morphDuration * 1_000_000_000))
                guard !Task.isCancelled, let self, self.morphToken == token else { return }
                self.dissolveStage(token: token, trigger: trigger)
            }
        } else {
            dissolveStage(token: token, trigger: trigger)
        }
    }

    private func dissolveStage(token: Int, trigger: String) {
        stageChangedAt = Self.now
        noteStage("dissolve", key: nil, extra: "style=animated trigger=\(trigger)")
        withAnimation(.easeOut(duration: Self.revealDuration), completionCriteria: .logicallyComplete) {
            morphStage = .none
        } completion: { [weak self] in
            self?.finishCollapse(token: token)
        }
        // Belt and braces: if the completion is never delivered (no view left depending on the
        // stage), the art is still released and the in-flight latch still drops.
        stageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((InlineTrailerCardModel.revealDuration + 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishCollapse(token: token)
        }
    }

    private func finishCollapse(token: Int) {
        guard morphToken == token else { return }
        collapseInFlight = false
        guard morphStage == .none else { return }
        stageChangedAt = nil
        if tileArt != nil { tileArt = nil }
    }

    /// DEBUG abort knobs (critique #7): `reset()` n ms after the `.reveal` / `.wide` edge.
    private func scheduleAbortKnob(after stage: MorphStage, token: Int) {
        #if DEBUG
        let ms = stage == .reveal ? Self.abortAfterRevealMs : Self.abortAfterWideMs
        guard ms > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard let self, self.morphToken == token, self.morphStage == stage else { return }
            NSLog("[TrailerPipeline] morph knob=abortAfter%@ ms=%d", stage == .reveal ? "Reveal" : "Wide", ms)
            self.reset()
        }
        #endif
    }

    /// `[TrailerPipeline] morph stage=…` (when the probe is on) and the DEBUG `event=…` line. The
    /// stage's own fields follow the event name directly (`event=abort style=instant stage=reveal …`)
    /// so a UI leg can match that prefix literally; `host=`/`key=` go last.
    private func noteStage(_ stage: String, key: String?, extra: String) {
        let keyText = key ?? activeKey ?? "-"
        if TrailerProbe.enabled {
            NSLog("[TrailerPipeline] morph stage=%@ key=%@ host=%@ %@", stage, keyText, hostTag, extra)
        }
        #if DEBUG
        let fields = extra.isEmpty ? "" : " " + extra
        InlineTrailerDebugLog.shared.note("event=\(stage)\(fields) host=\(hostTag) key=\(keyText)")
        #endif
    }

    // MARK: R2 tile art

    /// Starts the tile-art load (banner, then poster) with `.normal` admission and NO request
    /// timeout, so a coalesced in-flight fetch shared with the hero or Detail is never failed early
    /// (critique #6). The result lands in `artResult`; `beginMorph` waits on `artDone`.
    private func startArtPrefetch() {
        guard hostsTile, artTask == nil, let source = tileArtSource else { return }
        artToken &+= 1
        let token = artToken
        artDone = false
        artResult = nil
        artTask = Task { [weak self] in
            let art = await InlineTileArtLoader.load(source)
            if let self, self.artToken == token {
                self.artResult = art
                self.artDone = true
            }
            return art
        }
    }

    /// Focus left: forget this dwell's art and cancel the load. beta.19-rc1 verdict (review r1,
    /// A-3): the loader stops at its next step (`InlineTileArtLoader.load` checks cancellation after
    /// each fetch), so a card left mid-load starts no poster-fallback fetch and no letterbox scan. A
    /// download already in flight is `ArtworkStore`'s shared work, which a waiter's cancellation
    /// does not stop (a coalesced fetch the hero or Detail also waits on must never fail early,
    /// critique #6); it lands in the memory cache for the next dwell.
    private func dropArtPrefetch() {
        artTask?.cancel()
        artTask = nil
        artToken &+= 1
        artDone = false
        artResult = nil
    }

    // MARK: Expansion + resolution

    private func expand(_ item: MetaPreview) async {
        let key = TrailerResolutionCache.key(type: item.type, id: item.id)
        // Every skip below must leave `.idle`, not the `.dwelling` the timer fired from: a parked
        // `.dwelling` renders identically to idle on the card, but `phase != .idle` is also the
        // hero carousel's "attempt in progress" hold (FEAT-25) — leaving it set would hold the
        // page forever on a title with nothing to play.
        guard didFinishForKey != key else {
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand skip=alreadyFinished key=%@", key) }
            setPhase(.idle)
            return
        }

        switch TrailerResolutionCache.shared.entry(for: key) {
        case let .resolved(cachedURL, _):
            var url = cachedURL
            activeKey = key
            // BUG-46/B3: a local repack URL is only as good as the token behind it. Checking here
            // costs a dictionary lookup and turns "AVPlayer 404s, the card dies" into "re-resolve,
            // exactly like a cache miss" — no round trip, no failure, no negative cache entry.
            //
            // beta.19-rc1 verdict (B2, BUG-131): the token alone is not enough. The URL also names
            // the loopback PORT it was minted against, and the listener behind it can have died or
            // moved while the app was suspended (Steven's 4:34.7 Verity: a cache-hit morph, then an
            // AVPlayer failure 0.4 s later against a dead port, then a 45 s `.transient`).
            // `readyPort()` starts or re-verifies the listener (bounded by its 2 s attempt deadline);
            // `servableURL` then returns the URL unchanged when its port is the ready one, REBASES it
            // onto the ready port when only the port moved and the token is still stored (no YouTube
            // re-extraction), and nil when the token is gone or no listener could be bound — which is
            // "re-resolve, exactly like a cache miss". A non-loopback URL passes through untouched.
            //
            // beta.19-rc1 verdict (review r1, A-5): "the listener did not come up within the wait"
            // is NOT "the token is gone". It used to invalidate the still-valid `.resolved` entry
            // and re-extract from YouTube (the BUG-46 cost critique #4 meant to avoid) whenever
            // `readyPort()` came back nil on its 2 s attempt deadline (H2, or a rebuild still
            // waiting on the old socket). Now, per `InlineTrailerCacheHitPlan`: the token is checked
            // FIRST (gone → re-resolve at once, without starting the listener for nothing); a nil
            // port is retried once (the server is already on its next candidate, so the second wait
            // answers with that attempt); and a listener still not ready after that keeps the
            // cached resolution untouched and goes back to idle — the next dwell retries against a
            // listener that is up by then. Review r2 (P3-4): that next dwell no longer waits for the
            // user to leave and come back: the card re-arms once while focus stays
            // (`rearmAfterListenerWait`).
            if let token = TrailerLocalHLS.token(inPlaybackURL: url) {
                let generationAtStart = generation
                var tokenStored = TrailerLocalHLS.shared.hasToken(token)
                var ready: UInt16?
                var waits = 0
                while tokenStored, ready == nil, waits < InlineTrailerCacheHitPlan.listenerWaits {
                    if waits > 0, TrailerProbe.enabled {
                        NSLog("[TrailerPipeline] expand branch=resolvedListenerRetry key=%@ wait=%d", key, waits + 1)
                    }
                    ready = await TrailerLocalHLS.shared.readyPort()
                    waits += 1
                    // Focus can leave during the await: `reset()` bumped `generation` and cleared `activeKey`.
                    guard generation == generationAtStart, activeKey == key else { return }
                    // An eviction during the wait makes the token's answer final.
                    tokenStored = TrailerLocalHLS.shared.hasToken(token)
                }
                let servable: String?
                switch InlineTrailerCacheHitPlan.action(tokenStored: tokenStored, readyPort: ready) {
                case .reresolve:
                    servable = nil
                case .waitForListener:
                    if TrailerProbe.enabled {
                        NSLog("[TrailerPipeline] expand skip=listenerNotReady key=%@ waits=%d (cache kept)", key, waits)
                    }
                    // beta.19-rc1 verdict (review r2, P3-4): an idle card holds no key, like every
                    // other skip branch (`.unavailable`, `alreadyFinished` never set one), and the
                    // focus visit gets one more try once the listener is up instead of none until
                    // the user leaves and comes back (`rearmAfterListenerWait`).
                    activeKey = nil
                    setPhase(.idle)
                    rearmAfterListenerWait(item, key: key)
                    return
                case .serve(let port):
                    // Re-checks the token under the server's lock: nil here means it was evicted
                    // between the check above and now, which is a real stale token.
                    servable = TrailerLocalHLS.shared.servableURL(url, readyPort: port)
                }
                guard let servable else {
                    if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand branch=resolvedStale key=%@", key) }
                    TrailerResolutionCache.shared.invalidate(key: key)
                    startResolution(item, key: key)
                    return
                }
                if servable != url {
                    // Rebased onto the live port: remember it, so the next dwell skips this hop.
                    if TrailerProbe.enabled {
                        NSLog("[TrailerPipeline] expand branch=resolvedRebased key=%@ port=%d", key,
                              Int(TrailerLocalHLS.port(inPlaybackURL: servable) ?? 0))
                    }
                    TrailerResolutionCache.shared.store(.resolved(servable, Date()), for: key)
                    url = servable
                }
            }
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand branch=resolved key=%@", key) }
            // R2: the morph goes through `beginMorph` (art first, then the staged reveal). False =
            // focus left during the art wait; `reset()` already put the card back.
            guard await beginMorph(key: key) else { return }
            startPlayback(url, key: key)
        case .unavailable:
            // Already known to have nothing to play: never morph at all, so a row full of
            // trailer-less titles never twitches under a browsing thumb. Expires in 20 minutes.
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand skip=unavailable key=%@", key) }
            setPhase(.idle)
            return
        case .transient:
            // Nothing that played, moments ago — suppresses a tight refocus retry. Expires in 45s.
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand skip=transient key=%@", key) }
            setPhase(.idle)
            return
        case nil:
            // P-1a: `MetaDetailsRepository.peek()` is usually cold here — `DetailViewModel.stop()`
            // clears its cache the instant a Detail visit ends, so a genuinely fresh card still
            // falls through to `startResolution`'s async `resolve()` below, which (as of P-1b) no
            // longer morphs until `resolve()` itself confirms a trailer exists — the cold-meta case
            // is covered by that hold, not by this peek. This synchronous check only helps the WARM
            // cases — a TTL-expiry re-flash on a title whose meta is still cached, or re-dwelling a
            // title just visited in Detail — both can be resolved-or-refused right here, with zero
            // async hop at all.
            if let meta = MetaDetailsRepository.shared.peek(type: item.type, id: item.id) {
                let language = TmdbSettingsRepository.shared.snapshot().language
                let hasTrailer = !meta.trailers.isEmpty
                    && HeroTrailerSelectorKt.selectHeroTrailer(trailers: meta.trailers, preferredLanguage: language) != nil
                if TrailerProbe.forceNoTrailer || !hasTrailer {
                    TrailerResolutionCache.shared.store(.unavailable(Date()), for: key, causeSite: "noTrailerListedPeek")
                    if TrailerProbe.enabled {
                        NSLog("[TrailerPipeline] expand skip=peekNoTrailer key=%@ listed=%d", key, meta.trailers.count)
                    }
                    setPhase(.idle)
                    return
                }
            }
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand branch=miss key=%@", key) }
            startResolution(item, key: key)
        }
    }

    /// beta.19-rc1 verdict (review r2, P3-4): one more try of the cache-hit path while focus stays.
    ///
    /// A cache hit whose listener was still not ready after both `readyPort()` waits (up to ~4 s,
    /// e.g. a rebuild after resume outlasting two attempt deadlines) used to go idle with the dwell
    /// loop already returned, so the trailer never started while the user waited on the card; the
    /// "next dwell" only came after leaving and coming back. Now the card waits for the listener
    /// (`readyPort()` answers the moment it is up, else at its own 2 s attempt deadline), plus
    /// `InlineTrailerCacheHitPlan.rearmDelay` when it answered with no port, and then re-dwells:
    /// `startDwell` re-runs the rest gate (the morph never starts in motion) and the cache-hit path
    /// with the `.resolved` entry still in place, so no YouTube re-extraction. Bounded: one re-arm per
    /// focus visit (`rearmsAfterListenerWait`, budget reset only by `reset()`); a second
    /// `.waitForListener` in the same visit stays idle. Dropped when focus leaves (`reset()` cancels
    /// it and bumps `generation`) or when anything else moved the card off `.idle` meanwhile.
    private func rearmAfterListenerWait(_ item: MetaPreview, key: String) {
        guard InlineTrailerCacheHitPlan.rearmsAfterListenerWait(rearmsUsed: listenerRearmsUsed) else {
            if TrailerProbe.enabled { NSLog("[TrailerPipeline] expand rearm=none key=%@ (used)", key) }
            return
        }
        listenerRearmsUsed += 1
        let generationAtStart = generation
        listenerRearmTask?.cancel()
        listenerRearmTask = Task { [weak self] in
            let port = await TrailerLocalHLS.shared.readyPort()
            let delay = InlineTrailerCacheHitPlan.rearmDelay(readyPort: port)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.generation == generationAtStart,
                  self.phase == .idle, self.activeKey == nil else { return }
            self.listenerRearmTask = nil
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] expand rearm=listener key=%@ ready=%d", key, port == nil ? 0 : 1)
            }
            self.startDwell(item)
        }
    }

    /// Arms the resolve pipeline for `key` — it does NOT expand the card any more (P-1b: that used
    /// to happen here, immediately, and then snap back ~1s later on any title with nothing to
    /// play). The card stays exactly where the dwell timer left it, `.dwelling`, which still holds
    /// the FEAT-25 hero "attempt in progress" gate (see the comment in `expand()` above) — only
    /// `resolve()` promotes it to `.expandedStatic`, and only once it has proof there's something
    /// to show: a selectable trailer AND a held extraction ticket (P-1c). Shared by the cache-miss
    /// path and B3's stale-token path, which are the same thing from here on.
    private func startResolution(_ item: MetaPreview, key: String) {
        activeKey = key
        guard resolvingKey != key else { return }
        resolvingKey = key
        Task { [weak self] in await self?.resolve(item, key: key) }
    }

    /// Collapses the card — usually a silent no-op, not "resolution concluded there's nothing to
    /// play": since P-1b, most callers (no meta, language changed pre-fetch, no trailer listed,
    /// refused extraction slot) fire while the card is still `.dwelling`, before it has ever
    /// morphed, so `collapse()` just resets bookkeeping and re-asserts `.idle` on a card that was
    /// already reading as idle. The two callers that DO undo a real `.expandedStatic` morph are the
    /// ones after `resolve()`'s extraction guard: a language change mid-extraction, and extraction
    /// producing nothing playable (`notPlayable`, rare — ≤1× per title per 20 min).
    private func abandonExpansion(key: String) {
        guard activeKey == key else { return }
        collapse()
    }

    /// cache miss → meta (peek, else fetch) → best trailer → extraction → playable URL. Mirrors
    /// `DetailViewModel.resolveTrailerIfNeeded`, just with Swift-side deadlines and the cache.
    private func resolve(_ item: MetaPreview, key: String) async {
        // Finding 6 (BUG-101 follow-up, r2): see the CONTRACT on `resolvingKey`. This function
        // owns `resolvingKey` for `key` from the moment `startResolution` set it — EXCEPT when it
        // hands the walk off to `retryNextCandidate` (a repack failure on its own extraction,
        // below), which runs in a separate `Task` that outlives this `defer`. `retryOwnsResolution`
        // is flipped to `true` right before that hand-off so this defer steps aside instead of
        // clearing a key `retryNextCandidate` is still walking.
        var retryOwnsResolution = false
        defer { if !retryOwnsResolution, resolvingKey == key { resolvingKey = nil } }

        let type = item.type
        let id = item.id
        // BUG-63: everything below is an answer for THIS Metadata Language. If the setting flips
        // while we're awaiting meta or extraction, the result belongs to the old language — the
        // cache has already been purged for the new one, so don't repopulate it (and don't play).
        let languageAtStart = TmdbSettingsRepository.shared.snapshot().language
        func languageStillCurrent() -> Bool {
            let now = TmdbSettingsRepository.shared.snapshot().language
            if now != languageAtStart, TrailerProbe.enabled {
                NSLog("[TrailerPipeline] resolve dropped reason=languageChanged key=%@ from=%@ to=%@", key, languageAtStart, now)
            }
            return now == languageAtStart
        }
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

        guard languageStillCurrent() else { abandonExpansion(key: key); return }
        // P-1d: debug.trailerForceNoTrailer forces this to read as empty, so a cold-meta fetch
        // (peek() missed above, in `expand()`) behaves deterministically too — every title takes
        // the noTrailerListed branch below instead of only the ones peek() happened to catch warm.
        let trailers = TrailerProbe.forceNoTrailer ? [] : meta.trailers
        // BUG-63: prefer the Metadata Language among the (now language-inclusive) list. BUG-101:
        // the FULL ranking, not just the head — a dead/blocked top candidate (e.g. a TMDB-listed
        // trailer whose YouTube id no longer resolves) falls through to the next one during
        // extraction below instead of collapsing the card outright.
        let rankedTrailers = HeroTrailerSelectorKt.rankHeroTrailers(
            trailers: trailers,
            preferredLanguage: TmdbSettingsRepository.shared.snapshot().language
        )
        guard !rankedTrailers.isEmpty else {
            // BUG-63: say how many the meta listed and under which language, so a device log can
            // tell "TMDB has none" from "wrong language" (the two look identical from the tile).
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] noTrailerListed key=%@ listed=%d language=%@",
                      key, trailers.count, languageAtStart)
            }
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key, causeSite: "noTrailerListed")
            abandonExpansion(key: key)
            return
        }

        // Codex wave-1 r1 (P1): the `await fetchMeta` above is the first suspension since the
        // `activeKey == key` guard at the top of `resolve()` — focus can leave the card during it,
        // in which case `reset()` already cleared `activeKey` and restored `.idle`. Without this
        // re-check the continuation would still take the single extraction slot and morph the now
        // UNFOCUSED card to `.expandedStatic`, which nothing ever collapses (`startPlayback`
        // rejects on the nil `activeKey`, leaving the stale landscape tile in the row).
        guard activeKey == key else { return }

        // Busy: skip rather than queue, and stay neutral on the cache — being second in line says
        // nothing about whether this title has a trailer.
        //
        // P-1c: this guard runs before `resolve()` has touched phase at all — the card is still
        // sitting in whatever phase it was in when `resolve()` started (`.dwelling`, dwell-driven;
        // never `.expandedStatic` here). P-1b moves the morph to immediately AFTER this guard
        // succeeds, so a refusal means the card never became visible as a landscape tile in the
        // first place: `abandonExpansion` below is a plain `.idle` no-op, not a collapse-after-flash.
        guard let extractionTicket = InlineTrailerCoordinator.shared.beginExtraction() else {
            abandonExpansion(key: key)
            return
        }
        // P-1b: THIS is where the card actually becomes visible as a landscape tile — only now,
        // with a selectable trailer confirmed (the guard above) and the single extraction slot
        // actually held. Everything before this point in `resolve()` ran against `.dwelling`
        // (armed by `startResolution`, never touched by it); a title with nothing to play, or a
        // refused slot, never puts anything on screen to undo.
        //
        // beta.19-rc1 verdict (R2): the morph now goes through `beginMorph`, which awaits the tile
        // art (≤ `artAwaitDeadline`) before it reveals anything. It runs INSIDE the ticket's
        // scoped `defer` below, so every return across that await still releases the latch (the
        // BUG-46/B4 invariant).
        // BUG-101: remembered so a later `playbackFailed` can retry the NEXT candidate — tagged
        // with `key` so a stale list from a previous title/resolve can never be mistaken for this
        // one's (see `candidateTrailersKey`'s doc comment).
        candidateTrailers = rankedTrailers
        candidateIndex = 0
        candidateTrailersKey = key
        retriedAfterPlaybackFailureKey = nil
        var source: TrailerPlaybackSource?
        // BUG-46/B4: the latch is released by a `defer` in its OWN scope, so no future early return
        // between here and the end of the extraction can strand it (a stranded latch means nothing
        // in the app ever extracts again). Deliberately a scoped `do` rather than a function-wide
        // `defer`: the `TrailerLocalHLS` repack fetches below are not extraction, and holding the
        // single extraction slot through them would serialize the pipeline for no reason. BUG-101:
        // `extractPlayableSource` walks `rankedTrailers` (capped at 3) inside this same held ticket
        // — still one logical extraction episode, just sequential across candidates instead of one.
        do {
            defer { InlineTrailerCoordinator.shared.endExtraction(extractionTicket) }
            // R2: false with `activeKey` gone = focus left during the art wait: `reset()` already
            // put the card back, so end the walk here (the function's own `defer` releases
            // `resolvingKey`, exactly like the `guard activeKey == key` above). False with
            // `activeKey` still on this key = a refocus re-armed it mid-wait: keep extracting —
            // `startPlayback`'s `.dwelling` branch morphs when the result lands.
            _ = await beginMorph(key: key)
            guard activeKey == key else { return }
            if let result = await extractPlayableSource(candidates: rankedTrailers, startIndex: 0, key: key, ticket: extractionTicket) {
                source = result.source
                candidateIndex = result.index
            }
        }

        // AVPlayer-friendly URL only — a local byte-range HLS repackage of the demuxed 1080p pair
        // when the extractor surfaced one (SABR fallback), else the progressive/HLS URL.
        // Adaptive-VP9/AV1-only results collapse the card.
        //
        // beta.19-rc1 verdict (B2, BUG-131): `playbackOutcome` (12 s race, see `TrailerLocalHLS`) tells
        // "nothing playable" from "no answer in time". A timeout is a TRANSIENT — play the progressive
        // URL when there is one (without caching it), else a 45 s `.transient` — and never the 20-minute
        // `.unavailable` that a title with no trailer earns. (Before this, a listener that never
        // reported back parked this function forever with `resolvingKey` latched.)
        let outcome: TrailerPlaybackURLOutcome?
        if let source {
            outcome = await TrailerLocalHLS.shared.playbackOutcome(for: source)
        } else {
            outcome = nil
        }
        guard languageStillCurrent() else { abandonExpansion(key: key); return }
        if let outcome {
            switch InlineTrailerResolveOutcome.action(for: outcome) {
            case .storeResolvedAndPlay:
                if let playable = InlineTrailerResolveOutcome.playbackURL(for: outcome) {
                    TrailerResolutionCache.shared.store(.resolved(playable, Date()), for: key)
                    startPlayback(playable, key: key)
                }
                return
            case .playUncached:
                if let progressive = InlineTrailerResolveOutcome.playbackURL(for: outcome) {
                    if TrailerProbe.enabled { NSLog("[TrailerPipeline] resolve outcome=timedOut fallback=progressive key=%@", key) }
                    startPlayback(progressive, key: key)
                }
                return
            case .storeTransient:
                if TrailerProbe.enabled { NSLog("[TrailerPipeline] resolve outcome=timedOut fallback=none key=%@", key) }
                TrailerResolutionCache.shared.store(.transient(Date()), for: key, causeSite: "playbackURLTimeout")
                abandonExpansion(key: key)
                return
            case .tryNextCandidate:
                break   // falls through to the BUG-101 Finding 3 hand-off below
            }
        }
        guard source != nil else {
            // No candidate's YouTube extraction produced anything at all — the budget is already
            // exhausted (`extractPlayableSource` walked every candidate up to the cap).
            TrailerResolutionCache.shared.store(.unavailable(Date()), for: key, causeSite: "notPlayable")
            abandonExpansion(key: key)
            return
        }
        // Finding 3 (BUG-101 follow-up): extraction succeeded but the local repack of THIS
        // candidate yielded nothing playable (conversion failure, no progressive fallback) — a
        // dead end for this candidate, not for the title. Walk to the next ranked one within the
        // same three-candidate budget rather than give up; `retryNextCandidate` reacquires the
        // extraction ticket and applies the same generation/activeKey guards as the
        // extraction-miss and playback-failure paths.
        //
        // Finding 6 (BUG-101 follow-up, r2): this is the hand-off from the CONTRACT on
        // `resolvingKey` — `retryNextCandidate` runs the rest of the walk in its own `Task`, so
        // tell this function's `defer` to leave `resolvingKey` alone rather than clear it out from
        // under the retry the instant this `async` function returns. Codex r3 (Finding P2):
        // `retryNextCandidate` can reject the hand-off outright via its own early-return guard
        // (e.g. `activeKey` already went nil because focus left during the `playbackURL(for:)`
        // repack above) without ever claiming `resolvingKey` — only flip `retryOwnsResolution`
        // when the hand-off was actually accepted, so a rejection falls through to this
        // function's own `defer` and releases the key instead of leaving it latched with no
        // resolver running (which would strand a later refocus in `.dwelling` forever).
        retryOwnsResolution = retryNextCandidate(key: key, startIndex: candidateIndex + 1)
    }

    /// BUG-101: tries `candidates[startIndex..<min(candidates.count, 3)]` in ranked order, stopping
    /// at the first one whose YouTube extraction actually produces a source. Shared by the
    /// cache-miss path in `resolve()` (`startIndex: 0`) and the `playbackFailed` retry (`startIndex`
    /// past whatever already played). Bails early if focus has moved off `key` mid-loop, so a card
    /// nobody is looking at any more doesn't keep making YouTube extraction calls on its way out.
    ///
    /// `ticket` is the extraction ticket the caller is holding for this whole walk — Finding 5
    /// (BUG-101 follow-up): touched at the start of every candidate attempt so
    /// `InlineTrailerCoordinator`'s stranded-ticket watchdog measures time-since-last-progress,
    /// not time-since-the-walk-began (three sequential 15s attempts can outlast the 20s watchdog
    /// on their own). See the CONTRACT note on `latchWatchdogSeconds`.
    private func extractPlayableSource(
        candidates: [MetaTrailer],
        startIndex: Int,
        key: String,
        ticket: Int
    ) async -> (source: TrailerPlaybackSource, index: Int)? {
        let maxIndex = min(candidates.count, 3)
        var index = startIndex
        while index < maxIndex {
            guard activeKey == key else { return nil }
            InlineTrailerCoordinator.shared.touchExtraction(ticket)
            let candidate = candidates[index]
            var youtubeUrl = candidate.youtubePlaybackUrl()
            // Phase 0 (0.5): honor the same `debug.trailerSmokeVideoId` knob
            // `DetailViewModel.resolveTrailerIfNeeded` uses, so every inline dwell resolves the SAME
            // known videoId — deterministic `[TrailerRepack]`/`[TrailerZoom]` logs for the soak. The
            // substitution happens AFTER `key` was derived, so cache behavior stays per-title (many
            // distinct keys, one known stream) rather than collapsing every card onto one entry.
            // BUG-59 (beta.13): honored ONLY while `debug.trailerProbe` is also on — see the
            // comment at the smoke-id call site in `DetailViewModel.resolveTrailerIfNeeded`.
            if TrailerProbe.enabled, let forced = TrailerProbe.smokeVideoId {
                youtubeUrl = "https://www.youtube.com/watch?v=\(forced)"
            }
            if TrailerProbe.enabled {
                NSLog("[TrailerPipeline] resolve candidate=%d/%d key=%@", index + 1, maxIndex, key)
            }
            if let source = await resolveYouTube(youtubeUrl) {
                return (source, index)
            }
            index += 1
        }
        return nil
    }

    /// BUG-101 retry path for `playbackFailed` and (Finding 3) for `resolve()`'s own
    /// extraction-succeeded/repack-failed dead end: the prior attempt already released its
    /// extraction ticket, so this reacquires one for the follow-up walk starting at `startIndex`.
    /// Leaves the card at `.expandedStatic` (never collapses it directly) unless the retry itself
    /// comes up empty, in which case `abandonExpansion` takes over exactly as it would from
    /// `resolve()`.
    ///
    /// Finding 6 (BUG-101 follow-up, r2): this is the OTHER owner named in the CONTRACT on
    /// `resolvingKey` — claims it up front (a no-op re-assignment when `resolve()` is the caller
    /// and already holds it; a fresh claim when `playbackFailed` is the caller, since by then
    /// `resolve()` has long since returned and released it) and stays the sole owner for the rest
    /// of this walk, including every further recursive hop to itself for the next candidate. A
    /// caller-supplied `key` this function no longer owns (because focus moved to a different
    /// title, which will have claimed `resolvingKey` for ITS OWN key by now) must never be
    /// clobbered — `releaseResolutionOwnership()` only clears when `resolvingKey` still reads
    /// `key`, exactly like `resolve()`'s own defer.
    ///
    /// Codex r3 (Finding P2): returns whether the hand-off was ACCEPTED. The early-return guard
    /// below can reject it outright — without ever claiming `resolvingKey` or starting the
    /// `Task` — when `activeKey` has already moved off `key` (focus left during an `await` in the
    /// caller). Every caller must use this return value rather than assume acceptance: neither
    /// this function nor anything it started will release `resolvingKey` on a rejected hand-off,
    /// so the caller is the only one left who can — see the CONTRACT on `resolvingKey`.
    @discardableResult
    private func retryNextCandidate(key: String, startIndex: Int) -> Bool {
        guard activeKey == key else { return false }
        resolvingKey = key
        Task { [weak self] in
            guard let self else { return }
            guard let extractionTicket = InlineTrailerCoordinator.shared.beginExtraction() else {
                self.releaseResolutionOwnership(for: key)
                self.abandonExpansion(key: key)
                return
            }
            var result: (source: TrailerPlaybackSource, index: Int)?
            do {
                defer { InlineTrailerCoordinator.shared.endExtraction(extractionTicket) }
                result = await self.extractPlayableSource(candidates: self.candidateTrailers, startIndex: startIndex, key: key, ticket: extractionTicket)
            }
            guard self.activeKey == key else {
                self.releaseResolutionOwnership(for: key)
                return
            }
            guard let result else {
                self.releaseResolutionOwnership(for: key)
                self.abandonExpansion(key: key)
                return
            }
            self.candidateIndex = result.index
            // beta.19-rc1 verdict (B2, BUG-131): the same outcome mapping as `resolve()` — a timeout
            // is a transient, never "this candidate is dead", so it does NOT recurse to the next one.
            let outcome = await TrailerLocalHLS.shared.playbackOutcome(for: result.source)
            guard self.activeKey == key else {
                self.releaseResolutionOwnership(for: key)
                return
            }
            switch InlineTrailerResolveOutcome.action(for: outcome) {
            case .storeResolvedAndPlay:
                self.releaseResolutionOwnership(for: key)
                if let playable = InlineTrailerResolveOutcome.playbackURL(for: outcome) {
                    TrailerResolutionCache.shared.store(.resolved(playable, Date()), for: key)
                    self.startPlayback(playable, key: key)
                }
                return
            case .playUncached:
                self.releaseResolutionOwnership(for: key)
                if let progressive = InlineTrailerResolveOutcome.playbackURL(for: outcome) {
                    self.startPlayback(progressive, key: key)
                }
                return
            case .storeTransient:
                self.releaseResolutionOwnership(for: key)
                TrailerResolutionCache.shared.store(.transient(Date()), for: key, causeSite: "playbackURLTimeout")
                self.abandonExpansion(key: key)
                return
            case .tryNextCandidate:
                break   // Finding 3: keep walking, below
            }
            // Finding 3 (BUG-101 follow-up): same dead end as `resolve()`'s initial walk — this
            // candidate's extraction succeeded but its repack didn't. Keep walking within the same
            // three-candidate budget instead of stopping here; `extractPlayableSource`'s own
            // `maxIndex` cap is what actually terminates this recursion once every candidate has
            // been tried. Finding 6: deliberately no `releaseResolutionOwnership` on this path —
            // the recursive call re-claims `resolvingKey` (a no-op, already held) and stays the
            // owner; releasing here and reclaiming a beat later would open the exact window this
            // fix closes.
            self.retryNextCandidate(key: key, startIndex: result.index + 1)
        }
        return true
    }

    /// Finding 6 (BUG-101 follow-up, r2): the shared release half of the `resolvingKey` ownership
    /// contract — see the CONTRACT comment on that property. Guards on `resolvingKey == key` so a
    /// walk that bails after focus moved to a different title can never clobber that other
    /// title's own in-flight `resolvingKey`.
    private func releaseResolutionOwnership(for key: String) {
        if resolvingKey == key { resolvingKey = nil }
    }

    /// Only attaches when this card is *still* sitting on the title that was resolved —
    /// late results from a card the user has already left write the cache and nothing else.
    ///
    /// Codex final-branch review (P2): `.dwelling` is accepted alongside `.expandedStatic` for the
    /// refocus race — focus can leave AFTER the resolver morphed (reset() → `.idle`) and return
    /// BEFORE it finished; the new dwell's `startResolution` re-arms `activeKey` but bails on
    /// `resolvingKey == key`, leaving the card `.dwelling` while the ORIGINAL resolver carries the
    /// result. Rejecting that here stranded the card in `.dwelling` (no trailer, and the FEAT-25
    /// hero hold latched until focus left). Re-promoting through the morph phase keeps the
    /// morph-then-play visual order.
    private func startPlayback(_ url: String, key: String) {
        guard activeKey == key else { return }
        switch phase {
        case .expandedStatic:
            claimAndPlay(url, key: key)
        case .dwelling:
            // The refocus's own dwell timer is still pending — cancel it, or it re-enters
            // `expand()` on a `.playing` card once its gate opens and replays the morph.
            generation &+= 1
            dwellTask?.cancel()
            dwellTask = nil
            guard hostsTile else {
                setPhase(.expandedStatic)
                claimAndPlay(url, key: key)
                return
            }
            // R2: a catalog card morphs through `beginMorph` (art, then the staged reveal) and only
            // then claims and plays — same `activeKey` guard, and `beginMorph` captures the
            // generation bumped just above, so a focus change during its art wait wins.
            Task { [weak self] in
                guard let self, await self.beginMorph(key: key) else { return }
                guard self.activeKey == key, self.phase == .expandedStatic else { return }
                self.claimAndPlay(url, key: key)
            }
        default:
            return
        }
    }

    private func claimAndPlay(_ url: String, key: String) {
        InlineTrailerCoordinator.shared.claimPlayback(self, key: key)
        setPhase(.playing(url))
        #if DEBUG
        InlineTrailerDebugLog.shared.note("event=play host=\(hostTag) key=\(key)")
        #endif
    }

    // MARK: Kotlin bridges (with Swift-side deadlines)

    private func fetchMeta(type: String, id: String) async -> MetaDetails? {
        await withCheckedContinuation { continuation in
            let latch = ResumeLatch<MetaDetails>(continuation)
            MetaDetailsRepository.shared.fetch(type: type, id: id, cacheResult: true) { details, _ in
                // Suspend completions can land off-main; hop before touching the latch.
                DispatchQueue.main.async { latch.settle(details) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.metaTimeoutSeconds) {
                latch.settle(nil)
            }
        }
    }

    /// BUG-46/B4: the Kotlin extractor gets *our* deadline, not its own 30s one. Before this, walking
    /// away at 15s left an orphan extraction running for another 15s — still holding sockets, still
    /// scheduled, and overlapping whatever the next dwell started. The Swift latch still wins the
    /// race (Kotlin completions aren't cancellable from here); the point is that the work stops too.
    private func resolveYouTube(_ youtubeUrl: String) async -> TrailerPlaybackSource? {
        await withCheckedContinuation { continuation in
            let latch = ResumeLatch<TrailerPlaybackSource>(continuation)
            HeroTrailerResolver.shared.resolveYouTube(
                youtubeUrl: youtubeUrl,
                timeoutMillis: Int64(Self.extractionTimeoutSeconds * 1000)
            ) { source, _ in
                DispatchQueue.main.async { latch.settle(source) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.extractionTimeoutSeconds) {
                latch.settle(nil)
            }
        }
    }

    deinit {
        dwellTask?.cancel()
        listenerRearmTask?.cancel()
    }
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

// MARK: - R2 morph plan (pure)

/// beta.19-rc1 verdict (R2, BUG-133): the two collapse decisions, pure so
/// `InlineTrailerMorphPlanTests` can pin them as a table.
nonisolated enum InlineTrailerMorphPlan {
    nonisolated enum CollapseStyle: Equatable, Sendable {
        /// Nothing on screen.
        case none
        /// Everything to the poster in one frame (no animation, implicit ones disabled).
        case abort
        /// Shrink (if wide), then dissolve.
        case animated
    }

    /// The focus-loss collapse (`reset()`): abort during `.reveal`, or within `abortWindow` of the
    /// `.wide` edge — the width has barely moved, and animating it back is what slid card #2 back
    /// across the gap with a ghost logo (Steven's 2:10.6 GIGN frame); later, animate.
    static func collapseStyle(stage: InlineTrailerCardModel.MorphStage, stageAge: TimeInterval,
                              abortWindow: TimeInterval = InlineTrailerCardModel.abortWindowIntoWide) -> CollapseStyle {
        switch stage {
        case .none: return .none
        case .reveal: return .abort
        case .wide: return stageAge < abortWindow ? .abort : .animated
        }
    }

    /// The pipeline collapse (`collapse()`: playback failed or finished, nothing to play): how long
    /// to wait for the expansion still in flight to finish before collapsing, or nil to collapse
    /// now. `.reveal` waits out the rest of the dissolve plus the whole width stage; a `.wide`
    /// younger than `morphDuration` waits out the width animation.
    static func deferredCollapseDelay(stage: InlineTrailerCardModel.MorphStage, stageAge: TimeInterval) -> TimeInterval? {
        switch stage {
        case .none:
            return nil
        case .reveal:
            return max(0, InlineTrailerCardModel.revealDuration - stageAge) + InlineTrailerCardModel.morphDuration
        case .wide:
            let remaining = InlineTrailerCardModel.morphDuration - stageAge
            return remaining > 0 ? remaining : nil
        }
    }
}

// MARK: - R1 tile tint (pure)

/// beta.19-rc1 verdict (R1, BUG-132; Steven's 72 Heures / Elize frames: a pink or gold ring turned
/// white the moment the trailer tile replaced the poster card). Which colour the tile's focus ring
/// wears — pure, so `InlineTrailerTileTintTests` can pin the table without a hosting view.
nonisolated enum InlineTrailerTileTint {
    nonisolated enum RingSource: String, Equatable, Sendable {
        /// The poster's own colour (`ArtworkColorStore`) — "Focus Ring Takes Poster Color" on, a ring
        /// can draw, and the art has a colour.
        case poster
        /// The accent ring's colour (`Theme.Palette.focusRingColor`): the setting is off, or the art is
        /// grey (no colour), with the accent ring on.
        case accent
        /// No Zoom's neutral still ring (`stillHighlight`) with the accent ring off.
        case still
        /// No ring: not focused, or zoom on with the accent ring off.
        case none
    }

    /// - Parameters:
    ///   - settingOn: `focus_ring_poster_color`.
    ///   - accentRing: `accent_focus_ring`.
    ///   - noZoom: `no_zoom_on_focus`.
    ///   - focused: the card holds focus (the tile draws a ring only then).
    ///   - hasPosterColor: the store has a colour for the poster's art (nil for grey art).
    ///
    /// The accent ring takes precedence over No Zoom's still ring, as in `PosterCard` (the still
    /// ring is suppressed when the accent ring is on).
    static func ringSource(settingOn: Bool, accentRing: Bool, noZoom: Bool, focused: Bool,
                           hasPosterColor: Bool) -> RingSource {
        guard focused else { return .none }
        let wearsPosterColor = settingOn && hasPosterColor
        if accentRing { return wearsPosterColor ? .poster : .accent }
        if noZoom { return wearsPosterColor ? .poster : .still }
        return .none
    }
}

// MARK: - B2 playback-URL outcome (pure)

/// beta.19-rc1 verdict (B2, BUG-131): what the card does with a `TrailerPlaybackURLOutcome`. The old
/// `String?` could not tell "this source has nothing playable" (try the next ranked candidate) from
/// "the repack took too long" (a transient: play the progressive URL when there is one, never mark
/// the title unavailable). An empty URL counts as absent, exactly as the old `!playable.isEmpty`
/// checks did.
nonisolated enum InlineTrailerResolveOutcome {
    nonisolated enum Action: Equatable, Sendable {
        /// `.playable`: store `.resolved(url)` and play it.
        case storeResolvedAndPlay
        /// `.timedOut` with a progressive URL: play it WITHOUT storing it (the repack may still land
        /// and a later dwell should get the better URL), no negative entry.
        case playUncached
        /// `.timedOut` with no progressive URL: store `.transient` (45 s) and collapse. Never
        /// `.unavailable` — the title is not trailer-less, the answer was just slow.
        case storeTransient
        /// `.nothingPlayable`: the existing BUG-101 Finding 3 hand-off to the next ranked candidate.
        case tryNextCandidate
    }

    static func action(for outcome: TrailerPlaybackURLOutcome) -> Action {
        switch outcome {
        case .playable(let url):
            return url.isEmpty ? .tryNextCandidate : .storeResolvedAndPlay
        case .timedOut(let progressive):
            return (progressive?.isEmpty ?? true) ? .storeTransient : .playUncached
        case .nothingPlayable:
            return .tryNextCandidate
        }
    }

    /// The URL to hand `startPlayback` for `.storeResolvedAndPlay` / `.playUncached`; nil otherwise.
    static func playbackURL(for outcome: TrailerPlaybackURLOutcome) -> String? {
        switch action(for: outcome) {
        case .storeResolvedAndPlay:
            if case .playable(let url) = outcome { return url }
            return nil
        case .playUncached:
            if case .timedOut(let progressive) = outcome { return progressive }
            return nil
        case .storeTransient, .tryNextCandidate:
            return nil
        }
    }
}

// MARK: - B2 cache-hit listener plan (pure)

/// beta.19-rc1 verdict (review r1, A-5): what `expand()`'s cache-hit branch does with a cached
/// LOOPBACK playback URL, given whether its token is still stored and the listener's ready port
/// after the bounded waits. Only a missing token invalidates the `.resolved` entry; a listener that
/// is merely slow is transient and keeps it, so a slow start never costs a YouTube re-extraction.
nonisolated enum InlineTrailerCacheHitPlan {
    nonisolated enum Action: Equatable, Sendable {
        /// Token gone: invalidate the entry and re-resolve, exactly like a cache miss.
        case reresolve
        /// Token stored, no listener within the waits: keep the entry, go idle; the next dwell
        /// retries.
        case waitForListener
        /// Token stored and a ready port: serve (unchanged, or rebased onto `port`).
        case serve(port: UInt16)
    }

    /// `readyPort()` calls per dwell: the first, plus one retry. Each is bounded by the listener's own
    /// 2 s attempt deadline. After a deadline the server moves straight on to its next candidate
    /// port, so the retry joins that attempt (or a rebuild still waiting on the old socket); only
    /// when every port was exhausted does it start a fresh cycle.
    static let listenerWaits = 2

    static func action(tokenStored: Bool, readyPort: UInt16?) -> Action {
        guard tokenStored else { return .reresolve }
        guard let readyPort else { return .waitForListener }
        return .serve(port: readyPort)
    }

    // beta.19-rc1 verdict (review r2, P3-4): what `.waitForListener` does next while focus stays
    // (`InlineTrailerCardModel.rearmAfterListenerWait`).

    /// Re-arms per focus visit after `.waitForListener`. One: the re-arm is itself a dwell, so the
    /// budget is spent per visit (reset only when focus leaves), never per dwell, or it would loop.
    static let listenerRearms = 1
    /// How long the re-arm waits, after the listener answered with NO port (an attempt cycle that
    /// exhausted its candidates), before it re-dwells anyway against a fresh cycle.
    static let listenerRearmDelay: TimeInterval = 1

    /// Whether a `.waitForListener` re-arms the card: only while this focus visit has re-arms left.
    static func rearmsAfterListenerWait(rearmsUsed: Int) -> Bool {
        rearmsUsed < listenerRearms
    }

    /// The pause between the listener's answer and the re-dwell: none once it reported a ready port
    /// (the cache hit will serve), `listenerRearmDelay` when it reported none.
    static func rearmDelay(readyPort: UInt16?) -> TimeInterval {
        readyPort == nil ? listenerRearmDelay : 0
    }
}

// MARK: - R2 tile art

/// The decoded art the tile reveals: the image, its measured baked-bar zoom (`ArtworkLetterbox`,
/// the same crop `CachedAsyncImage(cropsBakedLetterboxBars:)` applied), and the URL it came from.
nonisolated struct InlineTileArt: Sendable {
    let image: UIImage
    let barZoom: CGFloat
    let url: String
}

/// beta.19-rc1 verdict (R2, BUG-133 / I1, BUG-134): what the tile-art loader needs from the card —
/// the candidates (banner, then poster) and the tile's resting size in POINTS, so the banner can be
/// decoded at the size the tile is drawn at (points × display scale, rounded up to a bucket) instead
/// of the old fixed 1920 px cap.
nonisolated struct InlineTileArtSource: Equatable, Sendable {
    /// `InlineTrailerCard.landscapeArtworkURL(item)`: the banner, or the poster when there is none.
    var primary: String?
    /// The item's poster. A candidate equal to this string is loaded as a POSTER (see
    /// `InlineTileArtLoader.Role`), wherever it sits in the list.
    var fallback: String?
    /// The 16:9 tile's drawn size in points: the landscape card in landscape rows, else the poster's
    /// height × 16/9 wide by the poster's height tall. The focus-ring band is not subtracted: the
    /// bucket rounding absorbs it.
    var tileSize: CGSize
}

/// beta.19-rc1 verdict (R2): loads the tile art BEFORE the reveal, so the first revealed frame is
/// the picture (never a shimmer) and the bar crop is already applied (never animated in).
///
/// I1 (critique #3): written against spec B's decode API. The BANNER is looked up and fetched with
/// the tile's pixel decode (`ArtworkDecodeRequest(.points(tile), fill, screenScale)`): a bucket-aware
/// hit when a decode that big already exists, else a `.normal`-admission fetch with no request
/// timeout (a coalesced fetch shared with the hero or Detail is never failed early). The POSTER
/// fallback looks in memory first with `ArtworkStore.cachedLargest` (any bucket of any rendition, so
/// the decode the row's card already made is found even though the card drew the `w780` / metahub
/// `large` variant of this URL) and only fetches when nothing at all is cached.
enum InlineTileArtLoader {
    /// Candidate URLs in order: the primary first, blank and duplicate entries dropped.
    nonisolated static func candidates(primary: String?, fallback: String?) -> [String] {
        var out: [String] = []
        for entry in [primary, fallback] {
            guard let value = entry, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !out.contains(value) else { continue }
            out.append(value)
        }
        return out
    }

    /// How one candidate is decoded and looked up.
    nonisolated enum Role: Equatable, Sendable {
        /// A 16:9 backdrop / banner: decoded to cover the tile.
        case banner
        /// The portrait poster: decoded to cover the tile, so its LONG side is 1.5 × the tile width.
        case poster
    }

    nonisolated struct Step: Equatable, Sendable {
        let url: String
        let role: Role
    }

    /// `candidates(primary:fallback:)` with each entry's role. A candidate equal to `fallback` (the
    /// poster) is a `.poster` even when it is also the primary (an item with no banner), so
    /// `candidates`' de-duplication cannot turn a poster into a banner.
    nonisolated static func steps(primary: String?, fallback: String?) -> [Step] {
        candidates(primary: primary, fallback: fallback).map { url in
            Step(url: url, role: url == fallback ? .poster : .banner)
        }
    }

    /// The decode a candidate of `role` needs to cover a `tile` of the given size (points) at `scale`.
    /// A poster covering a 16:9 tile is drawn `tile.width` wide and 1.5 × that tall, so asking for
    /// `.points(width, width × 1.5)` makes the unknown-source estimate (`max(W, H)`) the poster's long
    /// side; once a decode has recorded the source size, `ArtworkDecodeMath` refines it per aspect.
    nonisolated static func request(for role: Role, tile: CGSize, scale: CGFloat) -> ArtworkDecodeRequest {
        let height = role == .poster ? tile.width * 1.5 : tile.height
        return ArtworkDecodeRequest(size: .points(width: tile.width, height: height), fill: true, scale: scale)
            .normalized
    }

    /// beta.19-rc1 verdict (review r1, A-3): returns nil as soon as the calling task is cancelled
    /// (the card's `dropArtPrefetch` on focus loss), checked before each candidate and after each
    /// fetch: no fallback fetch and no letterbox scan for a card the user has left. A fetch already
    /// awaited runs to completion either way (shared `ArtworkStore` work) and warms the cache.
    static func load(_ source: InlineTileArtSource) async -> InlineTileArt? {
        let scale = ArtworkDecodeMath.screenScale
        for step in steps(primary: source.primary, fallback: source.fallback) {
            if Task.isCancelled { return nil }
            guard let url = URL(string: step.url) else { continue }
            let request = request(for: step.role, tile: source.tileSize, scale: scale)
            let image: UIImage
            switch step.role {
            case .banner:
                if let hit = ArtworkStore.cached(url, decode: request) {
                    image = hit
                } else if let fetched = try? await ArtworkStore.fetch(url, decode: request, admission: .normal, timeout: nil) {
                    image = fetched
                } else {
                    continue
                }
            case .poster:
                if let hit = ArtworkStore.cachedLargest(url) {
                    image = hit
                } else if let fetched = try? await ArtworkStore.fetch(url, decode: request, admission: .normal, timeout: nil) {
                    image = fetched
                } else {
                    continue
                }
            }
            // Same key and call shape as `CachedAsyncImage`'s crop task, so the memo is shared.
            let key = url.absoluteString
            let zoom: CGFloat
            if let memo = ArtworkLetterbox.cachedZoom(forKey: key) {
                zoom = memo
            } else {
                // Review r1, A-3: the card was left during the fetch; skip the scan.
                if Task.isCancelled { return nil }
                zoom = await Task.detached(priority: .utility) {
                    ArtworkLetterbox.zoom(for: image, cacheKey: key)
                }.value
            }
            return InlineTileArt(image: image, barZoom: zoom, url: key)
        }
        return nil
    }

    /// `beginMorph`'s last resort when no art arrived inside the deadline: whichever candidate is
    /// already decoded in memory at ANY size (`ArtworkStore.cached` is the family-wide largest, so the
    /// poster the row's card drew is found whichever rendition it drew), with its memoized zoom or none.
    static func inMemory(primary: String?, fallback: String?) -> InlineTileArt? {
        for candidate in candidates(primary: primary, fallback: fallback) {
            guard let url = URL(string: candidate), let image = ArtworkStore.cached(url) else { continue }
            let key = url.absoluteString
            return InlineTileArt(image: image, barZoom: ArtworkLetterbox.cachedZoom(forKey: key) ?? 1, url: key)
        }
        return nil
    }
}

// MARK: - BUG-92 tile geometry

/// Pure, unit-testable geometry for the inline trailer tile's concentric focus band (BUG-92,
/// u/mrStevenx3 beta.17: "inline trailer on the GIGN card sits offset — dark band between the
/// [ring] and the video"). Reference (official Nuvio's focused card): a continuous border, a thin
/// inner gap, the video clipped concentric INSIDE that gap with a matching inner corner radius.
///
/// `band` is `trailerSurface`'s `ringWidth` reserved margin when either focus ring is active, 0
/// otherwise — the same contract `PosterCard.swift`'s `ringInset` uses for the poster artwork.
/// No `View`/environment dependency at all, so this is exercised directly by
/// `InlineTrailerTileGeometryTests` without standing up a hosting view.
enum InlineTrailerTileGeometry {
    /// - Parameters:
    ///   - outer: the tile's own layout size (`artworkWidth`/`artworkHeight` in `trailerSurface`).
    ///   - band: the margin to reserve on every edge (0, or `ringWidth`, from the tile's caller).
    ///   - cornerRadius: the OUTER corner radius the ring itself draws at (`posterStyle.cornerRadius`).
    /// - Returns: `rect` — the inset rect within `outer`'s own coordinate space, i.e.
    ///   `(band, band, outer.width - 2*band, outer.height - 2*band)` after `band` is clamped so it
    ///   can never exceed half of either edge (a degenerate tiny tile can't invert to a negative
    ///   size); `radius` — `max(0, cornerRadius - band)`, the matching inner corner radius, floored
    ///   at 0 so an already-tight radius never goes negative.
    static func inner(outer: CGSize, band: CGFloat, cornerRadius: CGFloat) -> (rect: CGRect, radius: CGFloat) {
        let b = min(band, outer.width / 2, outer.height / 2)
        let rect = CGRect(x: b, y: b, width: outer.width - 2 * b, height: outer.height - 2 * b)
        let radius = max(0, cornerRadius - b)
        return (rect, radius)
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
    /// BUG-29: fires whenever the card's LAYOUT width changes edge, so the enclosing row can scroll
    /// itself to keep the morphing tile on screen. Focus never moves during the morph (it's the same
    /// button, just wider), so tvOS's automatic focus-driven scroll never fires on its own — the row
    /// has to ask for it explicitly. beta.19-rc1 verdict (R2): fires on the `.wide` edge
    /// (`model.layoutExpanded`), i.e. when the width actually starts growing, not when the
    /// in-place dissolve begins.
    var onExpansionChange: ((Bool) -> Void)? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// beta.19-rc1 verdict (M3): the host's rest signal, handed to the model before every dwell.
    @Environment(\.rowRestSource) private var rowRestSource
    @StateObject private var model = InlineTrailerCardModel()
    /// FEAT-14 (device finding, 2026-08-02): the accent focus ring lives on `PosterCard`, but the
    /// dwell-morph replaces that card's rendered surface with this landscape trailer tile — so
    /// with the ring on, it visibly disappeared the instant a trailer started playing. Read
    /// independently, same key/pattern as `PosterCard`'s copy of this property.
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// Read for the neutral still ring below (Codex 2026-08-29 round 6) — same key/pattern as
    /// `PosterCard`'s copy.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// beta.19-rc1 verdict (R1, BUG-132): the morph replaced the poster card with this tile, and the
    /// tile read neither FEAT-46 key, so a pink or gold ring turned white (and the depth rail
    /// disappeared) the moment the trailer started — Steven's 72 Heures / Elize frames. Same keys,
    /// same independent-read pattern, same `ArtworkColorStore` as `PosterCard` (Appearance owns the
    /// toggles).
    @AppStorage("focus_ring_poster_color") private var ringTakesPosterColor = false
    @AppStorage("depth_rail_poster_color") private var depthTakesPosterColor = false
    @Environment(\.cardDepthStyle) private var depthStyle
    /// R1: the last colour `ArtworkColorStore` answered for this card's art. Written at most once per
    /// tile reveal (`sampleTileColors`, on the `tileVisible` true edge), never per frame; it is the
    /// re-render trigger for a colour sampled after the tile appeared and the fallback if the store
    /// has since evicted the entry. The store peek in `posterTint` covers the normal case (the base
    /// `PosterCard` already sampled on focus gain).
    @State private var posterRingTint: Color?
    @State private var depthRailTint: Color?
    #if DEBUG
    /// BUG-92 (beta.18 follow-up): the tile's own frame origin in `.global` space, fed to
    /// `debug_trailerTile`'s `x=` field — see that overlay's doc comment for why `.global` and not
    /// a named coordinate space.
    @State private var debugTileGlobalOriginX: CGFloat = 0
    #endif

    /// Landscape rows prefer the wide banner; a poster fallback is cropped to 16:9 by the tile's
    /// aspect-fill, which reads better than an empty slot.
    static func landscapeArtworkURL(_ item: MetaPreview) -> String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
    }

    /// The expanded tile's width for a portrait row: a 16:9 tile at the poster's own height
    /// (UX-4a). Shared with `CatalogRowView`'s morph-scroll math (M3).
    static func expandedWidth(_ style: PosterStyle) -> CGFloat {
        style.height * (16.0 / 9.0)
    }

    // MARK: R1 poster colour (ring + depth rail)

    /// The art the BASE card shows, in the base card's own order, so the tile asks the store about
    /// exactly the picture the poster rail / ring colour was sampled from
    /// (`BrowseComponents.PosterCardView`: `[poster, rawPosterUrl]`; landscape rows'
    /// `LandscapeCard`: the landscape art alone).
    private var tintSources: [String?] {
        let poster: String? = item.poster
        if posterStyle.landscapeCatalogRows { return [Self.landscapeArtworkURL(item)] }
        let raw: String? = item.rawPosterUrl
        return [poster, raw]
    }

    /// `PosterCard.samplesPosterColor`: the setting is on AND a ring can draw (the accent ring, or No
    /// Zoom's still ring). With neither, the focused card only lifts and there is nothing to colour.
    private var samplesPosterColor: Bool {
        ringTakesPosterColor && (accentFocusRing || noZoomOnFocus)
    }

    /// `PosterCard.posterTint`: nil unless sampling AND focused. Store peek first (a read, never a
    /// write), so the colour the poster card sampled on focus gain is on the tile's ring from its
    /// first frame; `posterRingTint` covers a colour that lands after the tile did.
    private var posterTint: Color? {
        guard samplesPosterColor, isFocused else { return nil }
        return ArtworkColorStore.shared.cachedColor(for: tintSources) ?? posterRingTint
    }

    /// `PosterCard.samplesDepthColor`.
    private var samplesDepthColor: Bool {
        depthTakesPosterColor && depthStyle.isEnabled(for: .posters)
    }

    /// `PosterCard.depthRailTintResolved`: store peek first, then the local state.
    private var depthRailTintResolved: Color? {
        guard samplesDepthColor else { return nil }
        return ArtworkColorStore.shared.cachedColor(for: tintSources, use: .rail) ?? depthRailTint
    }

    /// Which colour the tile's ring wears right now (pure table in `InlineTrailerTileTint`).
    private var tileRingSource: InlineTrailerTileTint.RingSource {
        InlineTrailerTileTint.ringSource(
            settingOn: ringTakesPosterColor,
            accentRing: accentFocusRing,
            noZoom: noZoomOnFocus,
            focused: isFocused,
            hasPosterColor: posterTint != nil
        )
    }

    /// The ring's stroke colour for `tileRingSource`; nil = no ring.
    private var tileRingColor: Color? {
        switch tileRingSource {
        case .poster: return posterTint
        case .accent: return Theme.Palette.focusRingColor
        case .still: return stillHighlight
        case .none: return nil
        }
    }

    /// R1: on the `tileVisible` true edge, when the store peek in `posterTint` / `depthRailTintResolved`
    /// missed (the base card never sampled this art, or the entry was evicted), ask the store ONCE and
    /// keep the answer. Mirrors `PosterCard`'s focus-gain sample, which is where this normally lands
    /// first — so in practice both peeks hit and nothing below runs.
    private func sampleTileColors() {
        let sources = tintSources
        if samplesPosterColor, ArtworkColorStore.shared.cachedColor(for: sources) == nil {
            ArtworkColorStore.shared.color(for: sources) { color in
                guard posterRingTint != color else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { posterRingTint = color }
            }
        }
        if samplesDepthColor, ArtworkColorStore.shared.cachedColor(for: sources, use: .rail) == nil {
            ArtworkColorStore.shared.color(for: sources, use: .rail) { color in
                if depthRailTint != color { depthRailTint = color }
            }
        }
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
    /// width to a 16:9 tile at the poster's height when the card expands — so the enclosing `LazyHStack`
    /// pushes the trailing posters aside and the wide tile sits **in** the row rather than over it.
    /// (That's why `CatalogRowView` no longer needs a `zIndex` lift: nothing overhangs any more.)
    ///
    /// The resting poster and the landscape tile are stacked and crossfaded, top-leading aligned so
    /// the tile grows out of the poster's top-left corner instead of drifting. The tile is *always*
    /// in the hierarchy (at opacity 0 when idle) purely so its frame has a "from" value to animate
    /// out of — an inserted view would pop in at full landscape size and overlap its neighbour for
    /// the length of the transition. Its artwork/player are still gated on the phase, so an idle
    /// card loads nothing.
    ///
    /// beta.19-rc1 verdict (R2, BUG-133): the single 0.35 s cross-fade-while-growing is gone (it put
    /// a translucent tile wider than the poster over a half-visible poster: Steven's doubled
    /// "72 HEURES" at 1:31.2). Every visual edge is now an explicit `morphStage` transaction in the
    /// model — dissolve at the poster's width, then grow; shrink, then dissolve; abort in one frame
    /// — so the blanket `.animation(value:)` here was removed.
    private var expandingCard: some View {
        ZStack(alignment: .topLeading) {
            baseCard
                // Only the portrait card is crossfaded out — in landscape rows the tile is the same
                // shape and size as the artwork underneath, so there's nothing to morph and fading
                // would just blink the row.
                .opacity(fadesBaseCard && model.tileVisible ? 0 : 1)

            expandedTile
        }
        .frame(width: artworkWidth, alignment: .leading)
        // BUG-125 (device probe 2026-10-01): tvOS hit-tests a `.contextMenu` even though focus does
        // not. Once the card has morphed, `baseCard` sits at opacity 0 and `expandedTile` is
        // `.allowsHitTesting(false)`, so a long Select press on the playing card found nothing to
        // hit and never became a long press (the menu body was never evaluated; the same hold on
        // a plain poster was). The explicit content shape keeps the whole label hit-testable in
        // both states without touching layout, focus or the tile's own non-interactivity.
        .contentShape(Rectangle())
        .onChange(of: isFocused) { _, focused in
            if focused { configureModel() }
            model.focusChanged(focused, item: item)
        }
        // A recycled cell can come back already focused (returning from Detail), which produces
        // no `onChange`.
        .onAppear {
            configureModel()
            if isFocused { model.focusChanged(true, item: item) }
        }
        .onChange(of: reduceMotion) { _, motion in model.prefersReducedMotion = motion }
        // R2: a recycled cell must not come back mid-morph; the tile and its art go in one frame.
        .onDisappear { model.reset(abortStages: true) }
        // BUG-29: notify the row on every expand/collapse edge, not just expand — a card that
        // collapses mid-scroll-request should still let the row know its width is back to normal.
        // R2: the WIDTH edge (`.wide`), which is when the row has something to scroll for.
        .onChange(of: model.layoutExpanded) { _, wide in onExpansionChange?(wide) }
        // beta.19-rc1 verdict (R1, BUG-132): see `sampleTileColors`.
        .onChange(of: model.tileVisible) { _, visible in
            if visible { sampleTileColors() }
        }
    }

    /// Everything the model needs from this host BEFORE a `focusChanged(true…)` (critique #25):
    /// it owns a tile, where the tile art comes from (banner, then poster), and which rest signal
    /// gates the dwell (M3; re-read before every dwell, since the host can change it).
    private func configureModel() {
        model.prefersReducedMotion = reduceMotion
        model.hostsTile = true
        let poster: String? = item.poster
        // I1 (critique #3): the tile's resting size, so the loader decodes the banner at the size the
        // tile is drawn at. Same numbers as `artworkWidth` / `artworkHeight` at `.wide`.
        let tile = posterStyle.landscapeCatalogRows
            ? CGSize(width: Theme.Size.landscapeWidth, height: Theme.Size.landscapeHeight)
            : CGSize(width: Self.expandedWidth(posterStyle), height: posterStyle.height)
        model.tileArtSource = InlineTileArtSource(primary: Self.landscapeArtworkURL(item), fallback: poster, tileSize: tile)
        model.restSource = rowRestSource
    }

    /// The expanded card: landscape tile plus the title in the same slot the poster's title occupies,
    /// both following the animated artwork width.
    private var expandedTile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) { // UX-5: artwork↔title gap increased to match PosterCard and LandscapeCard
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
        // R2: opacity follows the STAGE (dissolve in at `.reveal`, out on the way back to `.none`),
        // animated by the model's stage transactions.
        .opacity(model.tileVisible ? 1 : 0)
        // No focus scale of its own: the system `.borderless` lift moves the whole button label
        // (base card + this tile) as one object (HIG revamp).
        .allowsHitTesting(false)
    }

    /// The tile itself: landscape art as soon as the card expands, trailer fading in over it once
    /// resolved. The frame is the animated one, so this *is* the morphing artwork region.
    ///
    /// BUG-92 (u/mrStevenx3, beta.17): this used to shrink the fully-clipped surface with a
    /// per-axis `.scaleEffect` AFTER the outer clip — that distorted the video's aspect ratio and
    /// de-concentred its corners from the ring stroked at the surface's TRUE (unscaled) bounds,
    /// because `.scaleEffect` shrinks the rendered pixels without changing the reported layout
    /// frame the ring/title overlays measured against. Reference (official Nuvio's focused card):
    /// a continuous border, a thin inner gap, the video clipped concentric INSIDE that gap with a
    /// matching inner corner radius. Now: `InlineTrailerTileGeometry.inner(...)` computes an
    /// actual inset rect + radius (settings-driven, not focus-time — same reasoning `ringInset`
    /// documents for `PosterCard`: an always-reserved band costs a few points of artwork nobody
    /// notices at 10 feet, while a focus-time inset would shrink the picture at the moment it
    /// should feel marked), the art/player are framed and clipped AT that inset size, the in-tile
    /// title overlay moves inside the inset with it (so its scrim + logo are concentric with the
    /// video too), and only then does the whole thing get centered back inside the tile's outer
    /// frame — which is exactly where the ring below still draws.
    private var trailerSurface: some View {
        let ringBandActive = accentFocusRing || noZoomOnFocus
        let band: CGFloat = ringBandActive ? ringWidth : 0
        let geometry = InlineTrailerTileGeometry.inner(
            outer: CGSize(width: artworkWidth, height: artworkHeight),
            band: band,
            cornerRadius: posterStyle.cornerRadius
        )
        return ZStack {
            // BUG-59 (reveal-gate wave): with the video side bar-proof (measured zoom + the
            // probe's reveal gate), this art — on screen from the morph until the video is
            // revealed — is the only surface left that can put a black bar on the tile: TMDB
            // backdrops are sometimes trailer stills with the bars baked in. Scanned once per
            // URL, symmetric-bars-only (genuinely dark art is never cropped), clipped by this
            // view's own `.clipShape` below exactly like the video zoom is.
            //
            // beta.19-rc1 verdict (R2, BUG-133): the art is DECODED before the reveal
            // (`InlineTileArtLoader`, bar zoom measured up front), so the first revealed frame is
            // the picture. The old `CachedAsyncImage` was inserted with the morph, ran its load in
            // `.onAppear` and drew a shimmer on the first frame even for a cached image, then
            // animated the bar-crop zoom in over 0.25 s (Steven's 0:53.5 empty dark frame). The art
            // stays in the tree until the model clears `tileArt` at the end of the final collapse,
            // so the poster is never uncovered by an empty slot mid-collapse (0:54.8).
            if let art = model.tileArt {
                // beta.19-rc1 verdict (R1, BUG-132): the tile had no `nuvioCardDepth`, so the sheen
                // (and, once focus left, the rail) the poster wore vanished at the morph. Hung on the
                // ART only — framed and clipped to the inset rect first, exactly like `PosterCard`'s
                // artwork, so the overlay traces the picture and not the fill-overflowed image view —
                // with the inset radius `geometry.radius` the surface's own clip uses. The video
                // covers it while playing. BUG-110: a focused card draws no rail (the modifier reads
                // `\.isFocused`), so the rail shows during the collapse dissolve, like the poster it
                // turns back into. `depthRailTintResolved` is nil unless "Depth Takes Poster Color".
                Image(uiImage: art.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(art.barZoom)
                    .frame(width: geometry.rect.width, height: geometry.rect.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: geometry.radius))
                    .nuvioCardDepth(RoundedRectangle(cornerRadius: geometry.radius),
                                    surface: .posters, railTint: depthRailTintResolved)
            } else if model.tileVisible {
                // No art arrived inside `artAwaitDeadline` and the poster was not in memory either:
                // a flat surface, never a shimmer.
                Theme.Palette.surface
            }

            // R2: the playing-URL fade is scoped to the PLAYER alone. On the surface as a whole it
            // also re-timed the tile's width on a collapse (the URL clears in the same update the
            // shrink starts), so the art resized on a 0.25 s ease-out against the row's 0.35 s.
            ZStack {
                if let url = model.playingURL {
                    // Removal is deliberately un-animated: focus loss must tear the player down at
                    // once (`dismantleUIView`), not linger through a crossfade.
                    // `loops: false` — the preview plays once and then the card collapses itself,
                    // rather than looping under a resting thumb forever.
                    TrailerHeroPlayer(
                        urlString: url,
                        // BUG-46/B2: the report says *why*, which is what decides whether this title
                        // is remembered as broken (it usually isn't) — see `playbackFailed`.
                        onFailure: { report in model.playbackFailed(report) },
                        // BUG-59: the measured zoom is remembered per TITLE, not per playback URL.
                        zoomKey: TrailerResolutionCache.key(type: item.type, id: item.id),
                        loops: false,
                        onPlaybackEnded: { model.playbackFinished() },
                        // BUG-92 (beta.18): the hosted view's own CALayer now gets the tile's INNER
                        // corner radius (`TrailerPlayerUIView` in TrailerHeroPlayerView.swift), so
                        // the video is clipped by its own layer regardless of the SwiftUI
                        // `.clipShape` mask below. That mask alone left a rectangular sliver of
                        // leaked video at the tile's rounded corners on the first card of a row
                        // (nothing else clips it there — see `RowLeadingEdgeClip`'s header).
                        // `geometry.radius` is the exact inner radius this tile's own
                        // `.clipShape(RoundedRectangle(cornerRadius: geometry.radius))` uses a few
                        // lines down, so the two can never disagree.
                        cornerRadius: geometry.radius
                    )
                    // UX-9: no `.scaleEffect` here any more — the zoom over the baked-in letterbox
                    // bars is measured per stream and applied to the player layer
                    // (`TrailerLetterboxProbe`, floor `TrailerHeroPlayer.parityZoom`), so a bar-free
                    // source renders exactly as it did before. Still only the video surface, never
                    // the static artwork underneath: that is already sized to the tile, with no bars
                    // of its own to hide. Layout is untouched either way — both the old modifier and
                    // the layer transform are render-only, which is what keeps UX-4a's morph and
                    // BUG-29's scroll intact.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.playingURL)
        }
        // BUG-92: framed and clipped at the INSET size — a real resize, not a post-render scale —
        // so the video's aspect ratio and the ring's reserved band agree with each other. Corner
        // radius is the matching inner radius (`geometry.radius`), never the outer one, so the
        // video's rounded corners land concentric with the ring drawn on the outer frame below.
        .frame(width: geometry.rect.width, height: geometry.rect.height)
        .clipShape(RoundedRectangle(cornerRadius: geometry.radius))
        // FEAT-18 (u/mrStevenx3, asked twice): "the title (logo) disappears while the trailer is
        // playing, whereas in Nuvio it remains visible." With Hide Labels on there is NO caption
        // under the tile, so a playing trailer carried no title at all (reporter's frame,
        // p2qudtq t22). Draw the title ON the tile — logo art with a text fallback, over its own
        // bottom scrim — the way Nuvio's TV app does. Only when the caption slot is hidden: users
        // whose caption survives playback would otherwise get the title twice. Anchored to the
        // BOTTOM of the tile so it can never meet the pinned row title band that slides down
        // onto the artwork top in Nuvio-style Home (BUG-53/BUG-61 geometry stays untouched).
        // BUG-92: moved inside the inset frame (sized/clipped to `geometry.rect`, not the outer
        // tile) so the scrim + logo are concentric with the video instead of drawn at the outer,
        // unreserved bounds.
        .overlay(alignment: .bottomLeading) {
            if showsInTileTitle {
                InlineTrailerTitleOverlay(item: item, tileWidth: geometry.rect.width, tileHeight: geometry.rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: geometry.radius))
                    .transition(.opacity)
            }
        }
        // BUG-92: re-center the inset content inside the tile's own layout size. SwiftUI's
        // default `.frame(width:height:)` centering does the rest of the geometry's job here —
        // `band` is reserved equally on every edge, so centering a `geometry.rect`-sized view
        // inside an `artworkWidth`×`artworkHeight` frame lands it exactly at `(band, band)`,
        // matching `geometry.rect.origin` without this view needing to know its own position.
        .frame(width: artworkWidth, height: artworkHeight)
        // FEAT-14: the dwell-morph swaps the focused `PosterCard` out for this landscape tile, and
        // that card's own ring dies with it — so with the setting on, the ring visibly vanished
        // the moment a trailer started (device finding, 2026-08-02). This tile needs its own ring.
        // Deliberately a **`.strokeBorder`** drawn INSIDE the surface bounds — the opposite of
        // PosterCard's outside-flush ring — for two reasons: (1) the morph's width/height geometry
        // was hardened by BUG-29's trailing-anchor row-scroll work, and growing this frame the way
        // PosterCard grows its label (via `ringMargin` padding) would change the layout size the
        // row measures, risking that fix; (2) an inside stroke paints strictly within the shape
        // this view already clips to, so unlike an outside ring it can never be clipped by a
        // parent's bounds — no `ringMargin`-style padding dance is needed here. Gated on
        // `isFocused` too, not just the morph phase: the tile stays in the view tree at opacity 0
        // while idle/dwelling (see `expandedTile`'s doc), and this mirrors PosterCard's own
        // `accentFocusRing && isFocused` guard rather than assuming the morph phase alone proves
        // focus.
        //
        // BUG-92: drawn at the OUTER frame (unchanged from before this fix), which is now exactly
        // the reserved `band` outside the inset content above — so the ring lands in the vacated
        // margin around the video instead of over it, concentric with the inset's rounded corner.
        //
        // beta.19-rc1 verdict (R1, BUG-132): the colour comes from `tileRingSource` (the pure table in
        // `InlineTrailerTileTint`): the poster's own colour when "focus ring takes the poster's
        // colour" is on and the art has one (accent ring or No Zoom's still ring, exactly
        // `PosterCard`'s rule), else what each branch drew before — the accent colour, or the
        // neutral still ring (Codex 2026-08-29 round 6: with No Zoom on and the ring off, the faded
        // base card left this surface with NO focus indication, so it draws the same neutral ring
        // `TileFocusLift` does). The accent branch's 4 pt and the still branch's `ringWidth` are the
        // same number.
        .overlay {
            if let ringColor = tileRingColor {
                RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
                    .strokeBorder(ringColor, lineWidth: ringWidth)
            }
        }
        #if DEBUG
        // BUG-92 diagnostic (invisible, harness-readable, `debug_ux6`'s pattern): the tile's live
        // outer/inner geometry, so a UITest — or a device pass reading the AX tree — can prove the
        // inset/ring/video actually agree instead of trusting a screenshot alone. Only while the
        // tile is up; band/rOut/rIn included so a default-config run (band=0) reads as identity
        // without cross-referencing the settings separately.
        //
        // BUG-92 (beta.18 follow-up, first-card leading-edge bleed): `x=` appended — append-only,
        // like every other probe string in this file — the tile's frame origin in the row's
        // coordinate space. `BrowseComponents.swift`'s row `ScrollView`/`LazyHStack` defines no
        // NAMED coordinate space, so this reads `.global`: the same space a `RowLeadingEdgeTests`
        // screenshot's pixel columns are already in, which is exactly what that UI test compares a
        // fixed screen column against. Measured via a `.background` `GeometryReader`
        // (`TileFocusLift`'s `measuredSize` pattern in PosterCard.swift) rather than read inline,
        // so this diagnostic never influences the tile's own layout.
        //
        // beta.19-rc1 verdict (M3/R2): shown while the tile is VISIBLE (`tileVisible`), with five
        // fields appended: ` stage=<reveal|wide> gate=<auto|1|2|3> gateRest=<s|-> gateStart=<s>
        // via=<rest|ceiling>` — the gate's seconds-since-focus (test85: `gateStart − gateRest ≥
        // 0.95` under Automatic; test88: `gate=2`, `gateStart ≥ 2.0`) — then R1's ` ring=`.
        .overlay(alignment: .topLeading) {
            if model.tileVisible {
                Text("debug_trailerTile outer=\(Self.debugFmt(artworkWidth))x\(Self.debugFmt(artworkHeight)) inner=\(Self.debugFmt(geometry.rect.width))x\(Self.debugFmt(geometry.rect.height)) band=\(Self.debugFmt(band)) rOut=\(Self.debugFmt(posterStyle.cornerRadius)) rIn=\(Self.debugFmt(geometry.radius)) x=\(Self.debugFmt(debugTileGlobalOriginX))\(debugGateFields)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_trailerTile")
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { debugTileGlobalOriginX = proxy.frame(in: .global).minX }
                                .onChange(of: proxy.frame(in: .global).minX) { _, newValue in
                                    debugTileGlobalOriginX = newValue
                                }
                        }
                    }
            }
        }
        #endif
        // BUG-92: the ring is the focus indicator in ring-band configurations (accent ring, or
        // no-zoom's neutral still ring) — the reference card has no halo behind it, so drop the
        // shadow whenever the band is reserved. Kept, unconditionally as before, in the
        // ring-off/zoom-on default so the shipped default look is byte-identical.
        .shadow(color: .black.opacity(ringBandActive ? 0 : 0.6), radius: ringBandActive ? 0 : 22, y: ringBandActive ? 0 : 10)
    }

    #if DEBUG
    /// M3/R2 `debug_trailerTile` tail (append-only; leading space included).
    private var debugGateFields: String {
        let stage = model.morphStage == .wide ? "wide" : "reveal"
        let gate = model.gateDelay?.rawValue ?? "-"
        let rest = model.gateRestAt.map { String(format: "%.2f", $0) } ?? "-"
        let start = model.gateStartAt.map { String(format: "%.2f", $0) } ?? "-"
        let via = model.gateVia ?? "-"
        // R1: `ring=<poster|accent|still|none>` — test87 reads `poster` with the poster-colour
        // setting on (and skips on `accent`: grey art legitimately keeps the accent colour).
        return " stage=\(stage) gate=\(gate) gateRest=\(rest) gateStart=\(start) via=\(via) ring=\(tileRingSource.rawValue)"
    }
    #endif

    /// One-decimal formatting for `debug_trailerTile` — matches `debug_ux6`'s "small, greppable,
    /// harness-readable" contract without dragging a `NumberFormatter` into a hot render path.
    private static func debugFmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private var fadesBaseCard: Bool { !posterStyle.landscapeCatalogRows }

    /// The faded portrait card takes its title with it, so the tile carries a replacement in the
    /// same slot. Landscape rows keep their own title (nothing is faded there).
    private var showsOverlayTitle: Bool { fadesBaseCard && posterStyle.showTitle }

    /// FEAT-18: the in-tile title/logo — only while the tile is up AND no caption is drawn under
    /// it (Hide Labels on, in either row shape). The tile's visibility rather than `playingURL`: the
    /// still landscape art that precedes the video is part of the same "trailer focus view", and
    /// gating on playback would make the title blink in a beat after the morph.
    /// beta.19-rc1 verdict (R2): `model.tileVisible`, so the logo rides the stage — dissolving with
    /// the tile, and gone in the same frame on an abort (no ghost logo across the gap, 2:10.6).
    private var showsInTileTitle: Bool { model.tileVisible && !posterStyle.showTitle }

    /// UX-4a (Christian's spec, 2026-07-30): the poster KEEPS ITS HEIGHT and only grows
    /// WIDER when the trailer starts — a 16:9 tile at the poster's full height. The old
    /// morph shrank the card to a short 360×203 landscape tile, which read as "too small"
    /// next to its portrait neighbours (tester photo); matching upstream Nuvio's behavior,
    /// the height never changes so the row never breathes vertically, and the width follows
    /// whatever Poster Size the user runs.
    /// beta.19-rc1 verdict (R2): wide only at `.wide` — the `.reveal` stage dissolves at the
    /// poster's own width, so the tile never grows while translucent.
    private var artworkWidth: CGFloat {
        if posterStyle.landscapeCatalogRows { return Theme.Size.landscapeWidth }
        return model.layoutExpanded ? Self.expandedWidth(posterStyle) : posterStyle.width
    }

    /// Landscape rows are already the target geometry — no morph there, the trailer just
    /// fades in. Portrait rows: constant height in BOTH states (see artworkWidth).
    private var artworkHeight: CGFloat {
        if posterStyle.landscapeCatalogRows { return Theme.Size.landscapeHeight }
        return posterStyle.height
    }
}

// MARK: - FEAT-18: in-tile title / logo

/// The title drawn over the bottom-left of a playing (or about-to-play) inline trailer tile:
/// the item's logo art when it exists (same resolver + cache as the Home hero — `heroLogoURL`,
/// `ArtworkStore`), the name as text otherwise, both over a bottom-up scrim so a bright frame
/// can't wash them out (the UX-6 legibility lesson). Sized relative to the tile, never the hero:
/// the logo may take at most ~55 % of the width and ~30 % of the height. `.allowsHitTesting`
/// is irrelevant here (the whole tile is inside a button label), and nothing in this view
/// changes the tile's layout size — it is a pure overlay on an already-measured frame (BUG-29's
/// row-scroll math depends on that).
struct InlineTrailerTitleOverlay: View {
    let item: MetaPreview
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    private let url: URL?
    @State private var image: UIImage?

    init(item: MetaPreview, tileWidth: CGFloat, tileHeight: CGFloat) {
        self.item = item
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.url = heroLogoURL(for: item)
        _image = State(initialValue: ArtworkStore.cached(url))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Scrim: transparent through the top half, dark enough at the foot for white text
            // or a light logo on any frame. Cheap gradient, no material — materials over a
            // moving video would sample the player every frame.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.72), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: tileWidth * 0.55,
                            maxHeight: tileHeight * 0.30,
                            alignment: .bottomLeading
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                } else {
                    Text(item.name)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                        .frame(maxWidth: tileWidth * 0.8, alignment: .leading)
                }
            }
            .padding(.leading, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
        }
        .frame(width: tileWidth, height: tileHeight, alignment: .bottomLeading)
        .accessibilityHidden(true) // the button label already carries the item name
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ArtworkStore.cached(url) {
                image = hit
                return
            }
            image = nil
            if let fetched = try? await ArtworkStore.fetch(url) {
                withAnimation(.easeIn(duration: 0.25)) { image = fetched }
            }
        }
    }
}

// MARK: - Mute indicator

