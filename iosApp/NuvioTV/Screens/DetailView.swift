import Combine
import SwiftUI
import SharedCore

/// BUG-41: isolates UX-6's scroll-driven dim value from `DetailView`'s own `@State` so writing it
/// every scroll-geometry frame doesn't invalidate (and re-evaluate) the entire detail page body —
/// see `DetailView.dimModel` and `ScrollDimOverlay` below, its sole observer.
private final class ScrollDimModel: ObservableObject {
    @Published var value: Double = 0
}

/// The UX-6 dim overlay + its DEBUG diagnostic Text, as `ScrollDimModel`'s only observer (BUG-41).
/// Kept as a standalone child view so SwiftUI only re-renders THIS small view when `model.value`
/// changes, instead of the whole `DetailView.body` the way writing a `@State` on DetailView did.
/// Honesty note (2026-08-05 sim measurement): the @State variant did NOT measurably re-eval body
/// per scroll frame on the sim's D-pad walk — this isolation is invalidation hygiene, not a
/// confirmed fix for BUG-41's reported choppiness, which needs a real-swipe device before/after
/// (the `[BUG41]` probe below is there for exactly that).
private struct ScrollDimOverlay: View {
    @ObservedObject var model: ScrollDimModel

    var body: some View {
        ZStack {
            // UX-6: darkens the whole backdrop/poster/trailer stack (trailer keeps playing
            // underneath) as the description scrolls down — the scrim above stays untouched.
            // P-2c: `.animation` interpolates between the (now coarser, 0.05-step) quantized
            // values in Core Animation's render server rather than SwiftUI stepping the opacity
            // directly — see the quantization comment on `DetailView`'s `.onScrollGeometryChange`
            // for the full 0.01→0.05 reasoning this pairs with.
            Color.black.opacity(model.value).ignoresSafeArea().allowsHitTesting(false)
                .animation(.linear(duration: 0.12), value: model.value)
            #if DEBUG
            // UX-6 diagnostic (invisible, harness-readable): the live darkening value, so the
            // UITest can prove whether focus-driven scrolling feeds the overlay at all.
            Text("debug_ux6 dark=\(Int(model.value * 1000))")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_ux6")
            #endif
        }
    }
}

/// Runtime knob for DetailView's scroll-diagnostic probes (the BUG-41 body-eval counter and the
/// UX-6 raw scroll-offset log), following the exact house pattern of `HomeGeometryProbe`
/// (`BrowseComponents.swift:76-78`) and `TrailerProbe` (`TrailerDebugProbes.swift:25-26`):
///
///     defaults write com.nuvio.media.NuvioTV debug.detailScrollProbe -bool YES
///
/// Deliberately NOT `#if DEBUG` — house rule recorded on `TrailerProbe`'s doc comment: testers run
/// release sideloads, there is no automated input path to the physical Apple TV, and the console
/// (`log show`) is the only diagnostic that comes back from a device pass. A probe gated behind
/// `#if DEBUG` never runs on the builds that actually reproduce BUG-41.
enum DetailScrollProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.detailScrollProbe")
}

/// `debug.detailScrollAB` (Int, read once at launch): a four-leg on-device A/B knob that settles
/// BUG-41's attribution question — is the reported scroll choppiness the UX-6 dim overlay, the
/// Liquid Glass chips in the top block, or both — that the simulator has never been able to answer
/// (BUG-41 history: sim never reproduced the choppiness). One build, four device legs:
///
///     defaults write com.nuvio.media.NuvioTV debug.detailScrollAB -int 1
///
///   - 0: shipping behavior (dim + glass), the default.
///   - 1: dim disabled — the `.onScrollGeometryChange` `of:` closure that feeds `dimModel` always
///     returns 0, so the UX-6 overlay never darkens past its first frame.
///   - 2: glass off in the top block — `metaChip` and the parental-guide chips fall back to a
///     plain translucent capsule fill instead of `.glassEffect`. `actionRow`'s
///     `.glass`/`.glassProminent` BUTTON styles are left alone — button styles are a different
///     swap from the chip backgrounds this leg targets.
///   - 3: both 1 and 2.
enum DetailScrollAB {
    nonisolated static let leg = UserDefaults.standard.integer(forKey: "debug.detailScrollAB")
    nonisolated static var dimDisabled: Bool { leg == 1 || leg == 3 }
    nonisolated static var glassDisabled: Bool { leg == 2 || leg == 3 }
}

/// Full detail screen for a single title, fed by the shared `MetaDetailsRepository`.
/// Constructed from a `MetaPreview` (the card the user focused), then enriched in place as the
/// repository resolves full metadata.
struct DetailView: View {
    let preview: MetaPreview

    /// Not `@EnvironmentObject`: DetailView can be reached outside the tab shell entirely (a Top
    /// Shelf deep link presents it inside `DeepLinkTitleView`'s own standalone `NavigationStack`,
    /// with no tab bar at all), where an `@EnvironmentObject` would crash for want of an ancestor
    /// that injected one. The custom environment key falls back to a harmless, unconnected default
    /// instance in that case — `pushImmersive`/`popImmersive` still balance correctly, they just
    /// don't affect anything since there's no tab bar to hide.
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    @StateObject private var model: DetailViewModel
    @State private var showStreams = false
    @State private var seriesPlay: SeriesPlayRoute?
    /// Trakt comment ids the user has expanded (reveals spoilers / full text).
    @State private var expandedComments: Set<Int64> = []

    /// Tester ask: auto full-screen the hero trailer a few seconds after opening a title.
    @AppStorage("detail_trailer_autoplay") private var trailerAutoplayEnabled: Bool = true
    /// Tester ask: keep the poster visible on the right, backdrop-style, behind the description.
    @AppStorage("detail_poster_backdrop") private var posterBackdropEnabled: Bool = true
    /// UX-4b (tester ask): the muted trailer looping behind the description previously had no
    /// switch at all — only auto-play did. Off = detail pages stay on the still artwork; the
    /// explicit "Watch Trailer" button and auto-play (if enabled) still work.
    @AppStorage("detail_trailer_background") private var backgroundTrailerEnabled: Bool = true
    /// FEAT-8: how long the muted background trailer plays before fading back to the still
    /// backdrop. 0 = play forever (previous, still-default behavior). Mirrors
    /// AppearanceSettingsPane's "Trailer Duration" chip row (same @AppStorage key).
    @AppStorage("detail_trailer_duration") private var trailerDurationSeconds: Int = 0
    /// FEAT-9: render the five detail action buttons (Play, Watch Trailer, Mark Watched, Add to
    /// Library) as icon-only pills. Mirrors AppearanceSettingsPane's "Icon-Only Detail Buttons"
    /// toggle (same @AppStorage key).
    @AppStorage("detail_action_icons_only") private var actionIconsOnly = false
    /// FEAT-11: whether a full-screen trailer should start with sound instead of muted. Mirrors
    /// PlaybackSettingsPane's "Trailer Sound by Default" toggle (same @AppStorage key) — read here
    /// only to restore the shared `HeroTrailerAudioState` back to this default once a full-screen
    /// trailer is dismissed (see the `.fullScreenCover(item: $model.trailerPlayback` below).
    @AppStorage("trailer_audio_default_on") private var trailerAudioDefaultOn = false

    /// FEAT-8: true once `trailerDurationSeconds` has elapsed for the current background trailer —
    /// fades the background player back out to the still backdrop without ever touching
    /// `model.trailerVideoURL` (that still gates the "Watch Trailer" button). Reset per detail visit.
    @State private var backgroundTrailerStopped = false
    @State private var trailerDurationTask: Task<Void, Never>?

    /// UX-6: 0...0.85 darkening applied over the whole backdrop/poster/trailer stack as the user
    /// scrolls the description down, computed once inside `.onScrollGeometryChange`'s `of:` so it
    /// stops firing once fully saturated. BUG-41: lives in `ScrollDimModel` (a tiny
    /// `ObservableObject`), not a plain `@State` on `DetailView` — see that type's doc comment for
    /// why the indirection matters for scroll smoothness.
    @StateObject private var dimModel = ScrollDimModel()

    /// One-shot per detail visit — never re-fires after the auto-played trailer is dismissed.
    @State private var didAutoPlayTrailer = false
    /// Set the moment the user swipes/moves focus at all (see `onMoveCommand` below); cancels the
    /// pending auto-play so it never yanks focus away from someone who's already exploring the page.
    @State private var userInteracted = false
    @State private var autoPlayTrailerTask: Task<Void, Never>?
    /// True only while the CURRENT `trailerPlayback` presentation was kicked off by the auto-play
    /// timer (not the explicit "Watch Trailer" button or a "Trailers & Extras" row item) — gates the
    /// "Press Back to exit" hint so it only shows for the surprise entry, not a deliberate tap.
    @State private var trailerPlaybackIsAutoPlay = false
    @State private var trailerHintVisible = false
    /// Which cast card holds focus — feeds `cardFocusButtonStyle(stillFocused:)`'s generic
    /// still ring in no-zoom mode (CastCard has no border treatment of its own; Codex
    /// 2026-08-29 rounds 3-4).
    @FocusState private var focusedCastIndex: Int?

    init(preview: MetaPreview) {
        self.preview = preview
        _model = StateObject(wrappedValue: DetailViewModel(preview: preview))
    }

    /// BUG-41 measurement probe: counts `DetailView.body` evaluations so the main session can
    /// compare before/after this fix. Logs every 10th eval (not every single one) to stay cheap
    /// while still grep-able: `log show --predicate 'eventMessage contains "BUG41"'`. Gated by
    /// `DetailScrollProbe.enabled` rather than `#if DEBUG` — see that enum's doc comment: testers
    /// run release sideloads, so a compile-time gate would stop measuring on exactly the builds
    /// that reproduce the reported choppiness.
    static var bodyEvalCount = 0
    static func logBodyEval() {
        guard DetailScrollProbe.enabled else { return }
        bodyEvalCount += 1
        if bodyEvalCount % 10 == 0 {
            NSLog("[BUG41] detailBodyEval=%d", bodyEvalCount)
        }
    }

    var body: some View {
        // BUG-41 measurement probe, gated at runtime by `DetailScrollProbe.enabled` (see above).
        let _ = Self.logBodyEval()
        ZStack(alignment: .topLeading) {
            backdropImage
            if showPosterBackdrop {
                posterBackdropLayer
                    .transition(.opacity)
            }
            // Tear the trailer's libmpv instance down while the stream player (also libmpv) is open,
            // so two GPU/Vulkan contexts never render at once; it resumes when the player dismisses.
            // Also pause it while a full-screen trailer plays (no doubled decode/audio).
            if backgroundTrailerEnabled, let trailer = model.trailerVideoURL, !showStreams, model.trailerPlayback == nil, !backgroundTrailerStopped {
                // UX-9: the zoom that hides the letterbox bars baked into our YouTube encodes is
                // measured per stream and applied to the player layer itself now
                // (`TrailerLetterboxProbe`, floor `TrailerHeroPlayer.parityZoom`) — no
                // `.scaleEffect` here any more. Full-screen and already ignoring the safe area, so
                // the overscale just pushes the bars past the screen edges — the screen bounds
                // themselves do the clipping. The failure report is ignored: Detail has one hero
                // trailer and no negative cache to scope (that's the inline card's problem).
                TrailerHeroPlayer(urlString: trailer, onFailure: { _ in model.trailerFailed() }, zoomKey: model.trailerZoomKey)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            scrimOverlay(posterBackdropVisible: showPosterBackdrop)
            // UX-6/BUG-41: the dim overlay + its debug Text live in `ScrollDimOverlay`, the sole
            // observer of `dimModel` — see that type's doc comment for why.
            ScrollDimOverlay(model: dimModel)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg + Theme.Spacing.sm) {
                    topBlock
                    // Grouped to stay under ViewBuilder's 10-subview ceiling.
                    Group {
                        companyLogosRow
                        parentalGuideSection
                    }
                    if let meta = model.meta, EpisodesSection.isSeriesLike(meta) {
                        EpisodesSection(
                            meta: meta,
                            episodeRatings: model.episodeRatings,
                            watchedEpisodeKeys: model.watchedEpisodeKeys
                        )
                        // A discrete focus region: vertical D-pad moves must land here instead of
                        // geometrically skipping from the info/network chips down to the cast row.
                        .focusSection()
                    }
                    Group {
                        castRow
                        collectionRow
                        trailersRow
                        moreLikeThisRow
                        commentsSection
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // UX-6: final darkening value computed here (not in `action:`) so saturated scrolling
            // stops firing state updates once fully dark.
            .onScrollGeometryChange(for: Double.self, of: { geo in
                // P-2b (BUG-41 attribution knob): leg 1/3 disables the dim outright by pinning
                // this closure's result to a constant, so `action:` fires once with 0 and never
                // again — see `DetailScrollAB`'s doc comment.
                guard !DetailScrollAB.dimDisabled else { return 0 }
                // 0 → 0.85 over the first ~400pt of scroll. Device pass (2026-08-01): the
                // original 0.35 ceiling was invisible over a bright playing trailer on a real
                // TV — the reporter's ask (and upstream's cinematic mode) is a near-black dim
                // once the description scrolls up. Sim-verified via debug_ux6 (test17).
                let raw = min(max((geo.contentOffset.y - geo.contentInsets.top) / 400.0, 0), 1) * 0.85
                // BUG-41: quantized to the nearest 0.05 (was 0.01) — `onScrollGeometryChange`
                // only calls `action:` when the mapped value actually *changes*, so coarsening the
                // step cuts the write rate from ~85 possible values over the 400pt ramp down to
                // ~17, roughly 5x fewer SwiftUI invalidations. P-2c (device revival, 2026-08-23):
                // 0.01 alone was fine-grained enough to read as smooth without help, but 0.05 alone
                // visibly steps — paired with `ScrollDimOverlay`'s
                // `.animation(.linear(duration: 0.12), value:)` below, which interpolates between
                // steps in Core Animation's render server instead of SwiftUI stepping the opacity
                // directly, 0.05 reads as smooth again while writing far less.
                return (raw * 20).rounded() / 20
            }, action: { _, newValue in
                dimModel.value = newValue
            })
            // UX-6 device-verify probe: raw offset/inset so `log show` proves whether tvOS
            // focus-scrolling moves this ScrollView's contentOffset at all. Gated by
            // `DetailScrollProbe.enabled` (not `#if DEBUG` — see that enum's doc comment). The
            // `of:` closure collapses to a constant when disabled so `action:` only fires once
            // (on the first geometry read) instead of on every scroll frame.
            .onScrollGeometryChange(for: String.self, of: { geo in
                guard DetailScrollProbe.enabled else { return "" }
                return "y=\(Int(geo.contentOffset.y)) inset=\(Int(geo.contentInsets.top))"
            }, action: { _, v in
                guard DetailScrollProbe.enabled else { return }
                NSLog("[UX6] %@", v)
            })
        }
        // FEAT-8: combined into one Bool so the fade also triggers when the trailer-duration timer
        // stops the background player (a `withAnimation(.easeInOut(duration: 1.5))` at the call site
        // overrides this ambient 0.8s for that specific change — see `stopBackgroundTrailer()`).
        .animation(.easeInOut(duration: 0.8), value: model.trailerVideoURL != nil && !backgroundTrailerStopped)
        // UX-12 removed the on-screen speaker indicator (FEAT-11's default-audio setting makes it
        // redundant); the Siri Remote's play/pause button remains the mute/unmute control.
        .onPlayPauseCommand {
            if isTrailerActive {
                HeroTrailerAudioState.shared.toggleMuted()
            }
        }
        // Any D-pad swipe means the user is actively navigating the page rather than just reading
        // the description — treat it as "started interacting" and cancel the pending auto-play.
        // This only adds an observer alongside the focus engine's own directional handling (like
        // `onPlayPauseCommand` above), so ordinary focus movement between buttons/rows is unaffected.
        .onMoveCommand { _ in userInteracted = true }
        .onAppear {
            model.start()
            // FEAT-8: one-shot per screen visit — a prior visit's expiry must not carry over.
            backgroundTrailerStopped = false
            cancelTrailerDurationTask()
        }
        .onDisappear {
            model.stop()
            cancelAutoPlayTrailer()
            cancelTrailerDurationTask()
        }
        .onChange(of: model.trailerVideoURL) { _, newValue in
            if newValue != nil {
                scheduleAutoPlayTrailerIfNeeded()
                scheduleTrailerDurationTimerIfNeeded()
            }
        }
        .onChange(of: showStreams) { _, isShowing in
            if isShowing { cancelAutoPlayTrailer() }
        }
        .onChange(of: seriesPlay?.id) { _, routeId in
            if routeId != nil { cancelAutoPlayTrailer() }
        }
        .onChange(of: userInteracted) { _, interacted in
            if interacted { cancelAutoPlayTrailer() }
        }
        .fullScreenCover(isPresented: $showStreams) {
            StreamPickerView(type: preview.type, videoId: streamVideoId, title: title,
                             poster: posterUrl, synopsis: overview, meta: playbackMeta)
        }
        .fullScreenCover(item: $seriesPlay) { route in
            StreamPickerView(
                type: route.meta.type,
                videoId: route.action.videoId,
                title: route.pickerTitle,
                parentMetaId: route.meta.id,
                season: route.action.seasonNumber?.value,
                episode: route.action.episodeNumber?.value,
                episodes: route.meta.videos,
                poster: route.meta.poster,
                episodeStill: route.episodeStill,
                synopsis: route.synopsis,
                meta: playbackMeta
            )
        }
        .fullScreenCover(item: $model.trailerPlayback, onDismiss: {
            // FEAT-11: returning from ANY full-screen trailer (the hero "Watch Trailer" button
            // above, or a "Trailers & Extras" row item) to the muted background loop — restore the
            // shared audio preference back to the user's configured default (it seeds `isMuted`
            // from this same shared state on re-attach; see
            // `TrailerHeroPlayerView.Coordinator.attach`) so the sound the user just heard doesn't
            // unconditionally carry over into the background player once it reappears.
            HeroTrailerAudioState.shared.setMuted(value: !trailerAudioDefaultOn)
            trailerPlaybackIsAutoPlay = false
        }) { item in
            // UX-9: the player scales itself past fill (parityZoom) to crop baked-in letterbox
            // bars; end-of-playback dismisses back to Detail rather than resting on a black
            // frame, since the controls-free surface has no replay affordance.
            FullScreenTrailerPlayer(urlString: item.url, onPlaybackEnded: {
                model.trailerPlayback = nil
            }, zoomKey: model.trailerZoomKey)
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    if trailerPlaybackIsAutoPlay {
                        autoPlayHintOverlay
                    }
                }
        }
        // Detail is an "immersive" screen: the floating tab bar hides for as long as one is on
        // screen, at any nesting depth (Detail → More Like This → Detail pushes are common, hence
        // a depth counter on the shared TabBarVisibility rather than a plain flag here).
        .onAppear { tabBarVisibility.pushImmersive() }
        .onDisappear { tabBarVisibility.popImmersive() }
    }

    // MARK: - Derived values (prefer enriched meta, fall back to the preview card)

    private var isSeries: Bool {
        if let meta = model.meta { return EpisodesSection.isSeriesLike(meta) }
        return preview.type == "series"
    }
    private var title: String { model.meta?.name ?? preview.name }
    // Kotlin `description` collides with NSObject.description, so KMP exposes it as `description_`.
    private var overview: String? { model.meta?.description_ ?? preview.description_ }
    private var genres: [String] { model.meta?.genres ?? preview.genres }
    private var backgroundUrl: String? { model.meta?.background ?? preview.banner ?? preview.poster }
    private var logoUrl: String? { model.meta?.logo ?? preview.logo }
    /// Poster art for the right-hand backdrop layer — independent of `backgroundUrl`'s
    /// banner/backdrop preference (tester ask: mirror mobile's "poster stays on the right" layout).
    private var posterUrl: String? { model.meta?.poster ?? preview.poster }

    /// BUG-74: the id a STREAM request must use — the resolved meta's canonical id whenever we
    /// have it, never the catalog preview's. This is the one derived value where the two genuinely
    /// disagree, and it is why it took three weeks and a DM to find.
    ///
    /// Every TMDB-backed surface (collection folders, search, More Like This) hands this screen a
    /// `preview.id` of the form `tmdb:<n>`. `MetaDetailsRepository.resolveMetaLookupId` remaps that
    /// to `tt…` for the META fetch *only*: the addon's canonical id comes back on `meta.id` while
    /// `preview.id` stays `tmdb:` — the divergence `DetailViewModel` already documents where it
    /// explains why the stale-publish guard must not match on `meta.id`. Stream addons declare
    /// `idPrefixes: ["tt"]`, so shipping a `tmdb:` id into `StreamsRepository` filters out every
    /// one of them (`NoCompatibleAddons`) and the user gets no streams at all — on a detail page
    /// that rendered perfectly, which is exactly what hid this.
    ///
    /// The preview fallback still earns its place: Play can be pressed before the meta resolves.
    /// That window is covered by `StreamsRepository`'s own tmdb→imdb retry, not here — this
    /// property must stay a pure read so it can't stall the cover's presentation.
    private var streamVideoId: String { model.meta?.id ?? preview.id }

    /// Same gate the muted background hero player (and its mute button/play-pause toggle) use.
    /// FEAT-8: also false once the trailer-duration timer has stopped the background player, so the
    /// mute button hides and the poster-backdrop layer (below) reclaims the area it faded into.
    private var isTrailerActive: Bool {
        backgroundTrailerEnabled && model.trailerVideoURL != nil && !showStreams
            && model.trailerPlayback == nil && !backgroundTrailerStopped
    }

    /// The poster-backdrop layer only earns its keep when it would show something the plain
    /// backdrop doesn't already — skip when they're the same URL (`backgroundUrl` already falls
    /// back to poster art itself) — and only while the hero trailer isn't occupying that same area.
    private var showPosterBackdrop: Bool {
        posterBackdropEnabled && posterUrl != nil && posterUrl != backgroundUrl && !isTrailerActive
    }

    // MARK: - Sections

    private var backdropImage: some View {
        GeometryReader { geo in
            CachedAsyncImage(string: backgroundUrl)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        // Purely decorative full-bleed background — the title/overview text drawn over it
        // already carries the same information for VoiceOver.
        .accessibilityHidden(true)
    }

    /// The poster pinned to the right 40% of the screen, behind the description (tester ask, mirrors
    /// mobile's Detail layout). Its own leading edge fades to transparent so it blends into the plain
    /// backdrop underneath instead of showing a hard seam.
    private var posterBackdropLayer: some View {
        GeometryReader { geo in
            CachedAsyncImage(string: posterUrl)
                .frame(width: geo.size.width * 0.4, height: geo.size.height, alignment: .trailing)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.3),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .ignoresSafeArea()
        // Same reasoning as backdropImage — decorative right-edge poster art, not a control.
        .accessibilityHidden(true)
    }

    /// Gradient scrims for text legibility, drawn over the backdrop (and the trailer, when present).
    /// `posterBackdropVisible` softens the trailing (right-edge) stop so the poster-backdrop layer
    /// behind it (pinned to the right 40%) reads through instead of going nearly opaque black; the
    /// leading 0.95 stop (left-text readability invariant) and the bottom vertical gradient are
    /// unchanged either way.
    private func scrimOverlay(posterBackdropVisible: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.95),
                    .black.opacity(0.4),
                    .black.opacity(posterBackdropVisible ? 0.45 : 0.85)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// BUG-44: header/metaLine/actionRow/genres/overview/info as ONE focus region — the same
    /// pattern as `PersonDetailView`'s BUG-34 fix (read that file's `topBlock` first for the full
    /// story). Previously each of these lived loose in the page's outer `VStack`, with only the
    /// lower rows (episodes, cast, collection, trailers, more-like-this, comments) individually
    /// `.focusSection()`'d — so from some scroll positions the focus engine found no upward
    /// candidate at all in the current column, and the tester had to detour the cursor all the way
    /// left to escape. Grouping the whole top-of-page run into one section means vertical D-pad Up
    /// from anywhere below (a horizontal row, or scrolled past the non-focusable overview `Text`)
    /// always finds a landing target in here. Unlike `PersonDetailView`'s inert `topBlock`, this one
    /// is already interactive (`actionRow`'s buttons), so no extra `.focusable()` /
    /// `.prefersDefaultFocus` scaffolding is needed — but that also means the section is never
    /// empty: `actionRow` always renders at least "Mark Watched" and "Add to Library", so it anchors
    /// the section's focusability even when Play, Watch Trailer, genres, overview and infoSection
    /// are all absent (`.focusSection()` requires *something* focusable inside it).
    private var topBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg + Theme.Spacing.sm) {
            header
            metaLine
            actionRow
            if !genres.isEmpty {
                Text(genres.joined(separator: " \u{2022} "))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.Font.body)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            infoSection
        }
        .focusSection()
    }

    @ViewBuilder
    private var header: some View {
        if let logoUrl, !logoUrl.isEmpty {
            AsyncImage(url: URL(string: logoUrl)) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            .frame(maxWidth: 600, maxHeight: 180, alignment: .leading)
        } else {
            Text(title).font(Theme.Font.hero).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    /// Title facts handed to the player for its Info tab chips (same sources as `metaLine`).
    private var playbackMeta: PlaybackMeta {
        PlaybackMeta(
            year: { let s: String? = model.meta?.releaseInfo ?? preview.releaseInfo; return (s ?? "").isEmpty ? nil : s }(),
            runtime: { let s: String? = model.meta?.runtime; return (s ?? "").isEmpty ? nil : s }(),
            imdbRating: { let s: String? = model.meta?.imdbRating ?? preview.imdbRating; return (s ?? "").isEmpty ? nil : s }(),
            ageRating: { let s: String? = model.meta?.ageRating; return (s ?? "").isEmpty ? nil : s }(),
            genres: genres
        )
    }

    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.md + 2) {
            if let year = model.meta?.releaseInfo ?? preview.releaseInfo, !year.isEmpty {
                metaChip { Text(year) }
            }
            if let runtime = model.meta?.runtime, !runtime.isEmpty {
                metaChip { Text(runtime) }
            }
            if let rating = model.meta?.imdbRating ?? preview.imdbRating, !rating.isEmpty {
                metaChip {
                    HStack(spacing: Theme.Spacing.xs - 2) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.Palette.star)
                        Text(rating)
                    }
                }
            }
            if let age = model.meta?.ageRating, !age.isEmpty {
                // Outlined rating chip (e.g. "TV-MA"), mirroring mobile's bordered pill.
                metaChip(stroked: true) { Text(age) }
            }
            if model.isLoading { ProgressView() }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// P-2b (BUG-41 attribution knob): wraps padded chip content in either the shipping Liquid
    /// Glass capsule or, on `DetailScrollAB` leg 2/3, a plain translucent capsule fill — the
    /// single swap point shared by `metaChip` and the parental-guide chips below so the two don't
    /// duplicate the conditional. `actionRow`'s `.glass`/`.glassProminent` BUTTON styles are a
    /// separate swap and are untouched by this leg.
    @ViewBuilder
    private func detailChipBackground(@ViewBuilder _ content: () -> some View) -> some View {
        if DetailScrollAB.glassDisabled {
            content().background(Color.white.opacity(0.12), in: .capsule)
        } else {
            content().glassEffect(.regular, in: .capsule)
        }
    }

    /// A small Liquid Glass capsule around one metadata item (year / runtime / rating).
    private func metaChip(stroked: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        detailChipBackground {
            content()
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs - 2)
        }
        .overlay {
            if stroked {
                Capsule().stroke(Theme.Palette.textSecondary, lineWidth: 1)
            }
        }
    }

    /// Play + library/watched controls as one Liquid Glass cluster. The container lets the
    /// individual glass shapes blend/morph as focus moves between them (mobile-reference look:
    /// prominent Play pill next to compact glass buttons).
    private var actionRow: some View {
        GlassEffectContainer(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                if !isSeries {
                    Button {
                        showStreams = true
                    } label: {
                        // BUG-14: `.glassProminent`'s unfocused fill is the raw accent tint (not
                        // lifted/inverted the way focus is), so on the White theme that fill is
                        // near-white and an unmanaged label defaults to unreadable white-on-white.
                        // `prominentAccentLabel()` (already proven for `.borderedProminent` sites,
                        // BUG-4) covers both states: accent-contrasting text unfocused, dark text
                        // on the near-white focus lift.
                        actionButtonPadding(
                            actionLabel("Play", systemImage: "play.fill")
                                .font(Theme.Font.meta)
                                .prominentAccentLabel(),
                            horizontal: Theme.Spacing.lg
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Palette.accent)
                } else if let action = model.seriesAction, let meta = model.meta {
                    Button {
                        seriesPlay = SeriesPlayRoute(meta: meta, action: action)
                    } label: {
                        // BUG-14: see the non-series Play button above.
                        actionButtonPadding(
                            actionLabel(action.label, systemImage: "play.fill")
                                .font(Theme.Font.meta)
                                .prominentAccentLabel(),
                            horizontal: Theme.Spacing.lg
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Palette.accent)
                }

                if model.trailerVideoURL != nil {
                    // Explicit, focusable "watch it full screen" entry point (tester request — the
                    // background hero loop below is muted and deliberately NON-focusable, since a
                    // floating control over the hero area would be unreachable once the focus engine
                    // routes Up-navigation to the tab bar; see `TrailerHeroPlayerView.swift`). Living
                    // in the ordinary action-row focus flow instead, this just hands the already-
                    // resolved hero trailer URL to the same `trailerPlayback` full-screen-cover
                    // machinery the "Trailers & Extras" row uses below, which also takes care of
                    // pausing/tearing down the background player for free (both are gated on
                    // `trailerPlayback == nil`).
                    Button {
                        if let trailer = model.trailerVideoURL {
                            model.trailerPlayback = TrailerPlaybackItem(id: "hero-trailer", url: trailer, title: title)
                        }
                    } label: {
                        actionButtonPadding(
                            actionLabel("Watch Trailer", systemImage: "play.rectangle.fill")
                                .font(Theme.Font.meta),
                            horizontal: Theme.Spacing.md
                        )
                    }
                    .buttonStyle(.glass)
                }

                Button {
                    model.toggleWatched()
                } label: {
                    actionButtonPadding(
                        actionLabel(
                            model.isWatched ? "Watched" : "Mark Watched",
                            systemImage: model.isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                        .font(Theme.Font.meta),
                        horizontal: Theme.Spacing.md
                    )
                }
                .buttonStyle(.glass)
                .tint(model.isWatched ? Theme.Palette.accent : nil)

                Button {
                    model.toggleLibrary()
                } label: {
                    actionButtonPadding(
                        actionLabel(
                            model.isSaved ? "In Library" : "Add to Library",
                            systemImage: model.isSaved ? "checkmark" : "plus"
                        )
                        .font(Theme.Font.meta),
                        horizontal: Theme.Spacing.md
                    )
                }
                .buttonStyle(.glass)
                .tint(model.isSaved ? Theme.Palette.accent : nil)
            }
        }
        // BUG-44: no longer its own `.focusSection()` — folded into `topBlock`'s single top-of-page
        // section (header/metaLine/actionRow/genres/overview/info) so the section boundary can't
        // fragment vertical navigation between this row and the content around it.
    }

    /// FEAT-9: the underlying `Label` for one action-row button — icon + text normally, icon-only
    /// (with the title preserved for VoiceOver) when `actionIconsOnly` is on.
    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        let label = Label(title, systemImage: systemImage)
        if actionIconsOnly {
            label.labelStyle(.iconOnly).accessibilityLabel(Text(title))
        } else {
            label
        }
    }

    /// FEAT-9: shared padding for action-row buttons — the normal asymmetric horizontal/vertical
    /// padding, or symmetric padding (pills go square-ish around the bare icon) when icons-only.
    @ViewBuilder
    private func actionButtonPadding<Content: View>(_ content: Content, horizontal: CGFloat) -> some View {
        if actionIconsOnly {
            content.padding(Theme.Spacing.md)
        } else {
            content
                .padding(.horizontal, horizontal)
                .padding(.vertical, Theme.Spacing.xxs + 2)
        }
    }

    @ViewBuilder
    private var castRow: some View {
        let cast = model.meta?.cast ?? []
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Cast")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(Array(cast.enumerated()), id: \.offset) { index, person in
                            // Cast members carry a TMDB id only when TMDB enrichment is on; make those
                            // tappable to a person page, leave the rest as plain (non-focusable) cards.
                            if let personId = person.tmdbId?.value {
                                NavigationLink(value: PersonRoute(id: personId, name: person.name)) {
                                    // stillFocused: CastCard draws its own no-zoom still ring on
                                    // the avatar circle (Codex 2026-08-29 rounds 3-5) — focus
                                    // truth from the row's FocusState, not a second binding.
                                    CastCard(person: person, stillFocused: focusedCastIndex == index)
                                }
                                // Card-like navigation element: joins the no-zoom sweep so the
                                // setting stills every card on the page, not most (Codex 2026-08-29).
                                .cardFocusButtonStyle()
                                .focused($focusedCastIndex, equals: index)
                            } else {
                                CastCard(person: person)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private var moreLikeThisRow: some View {
        let items = model.meta?.moreLikeThis ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("More Like This")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Info section (director / writers / studios / networks / country / etc.)

    /// A block of label/value rows for the metadata that isn't already on the meta line. Only the
    /// fields that are populated are shown — director/writer/country come from the addon; studios,
    /// networks, awards, language, status and external ratings fill in when TMDB enrichment is on.
    @ViewBuilder
    private var infoSection: some View {
        let rows = infoRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Details")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Text(row.label)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 180, alignment: .leading)
                        Text(row.value)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                }
            }
        }
    }

    private var infoRows: [InfoRow] {
        guard let meta = model.meta else { return [] }
        var rows: [InfoRow] = []
        func add(_ label: String, _ value: String) {
            if !value.isEmpty { rows.append(InfoRow(label: label, value: value)) }
        }
        add(String(localized: "Director"), meta.director.joined(separator: ", "))
        add(String(localized: "Writers"), meta.writer.joined(separator: ", "))
        add(String(localized: "Studios"), meta.productionCompanies.map { $0.name }.joined(separator: ", "))
        add(String(localized: "Network"), meta.networks.map { $0.name }.joined(separator: ", "))
        // Bare Kotlin `String?` reads can bridge as non-optional in this framework — widen before use.
        let country: String? = meta.country;   add(String(localized: "Country"), country ?? "")
        let language: String? = meta.language;  add(String(localized: "Language"), language ?? "")
        let status: String? = meta.status;      add(String(localized: "Status"), status ?? "")
        let awards: String? = meta.awards;      add(String(localized: "Awards"), awards ?? "")
        let ratings = meta.externalRatings
        if !ratings.isEmpty {
            add(String(localized: "Ratings"), ratings.map { "\($0.source) \(formatRating($0.value))" }.joined(separator: "   "))
        }
        return rows
    }

    private func formatRating(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    // MARK: - Collection row ("Part of the X Collection")

    /// The title's collection (e.g. sequels/prequels) as a poster row. TMDB-backed via
    /// `collectionItems` — stays hidden until TMDB enrichment is on.
    @ViewBuilder
    private var collectionRow: some View {
        let items = model.meta?.collectionItems ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(collectionTitle)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    private var collectionTitle: String {
        let name: String? = model.meta?.collectionName
        if let name, !name.isEmpty { return name }
        return String(localized: "Collection")
    }

    // MARK: - Company logos (studios & networks with TMDB logo art)

    /// Logo strip for the production companies/networks that carry TMDB logo art (the info rows
    /// above already list all of them by name). White chips keep the mostly-dark logos readable.
    /// Chips with a TMDB id push the studio/network browse page (`EntityRoute`).
    @ViewBuilder
    private var companyLogosRow: some View {
        let companies = companyLogos
        if !companies.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Array(companies.enumerated()), id: \.offset) { _, entry in
                    if let tmdbId = entry.company.tmdbId?.value {
                        NavigationLink(value: EntityRoute(
                            id: tmdbId,
                            name: entry.company.name,
                            isNetwork: entry.isNetwork,
                            sourceType: model.meta?.type ?? preview.type
                        )) {
                            companyChip(entry.company)
                        }
                        // Deliberately NOT cardFocusButtonStyle() (Codex 2026-08-29 P1): unlike
                        // CastCard, the chip has no isFocused-dependent treatment of its own, so
                        // disabling the system effect in no-zoom mode would leave remote focus on
                        // this link with NO visible indication at all. The system lift on a small
                        // chip is a wiggle, not a zoom; a still-mode chip treatment can join a
                        // future pass if a no-zoom user reports it.
                        .buttonStyle(.borderless)
                    } else {
                        companyChip(entry.company)
                    }
                }
            }
            .focusSection()
        }
    }

    private func companyChip(_ company: MetaCompany) -> some View {
        CompanyChip(company: company)
    }

    private var companyLogos: [(company: MetaCompany, isNetwork: Bool)] {
        guard let meta = model.meta else { return [] }
        var seen = Set<String>()
        let tagged = meta.productionCompanies.map { (company: $0, isNetwork: false) }
            + meta.networks.map { (company: $0, isNetwork: true) }
        return tagged.filter { entry in
            let logo: String? = entry.company.logo
            guard let logo, !logo.isEmpty, !seen.contains(entry.company.name) else { return false }
            seen.insert(entry.company.name)
            return true
        }
        .prefix(6).map { $0 }
    }

    // MARK: - Parental guide (IMDb parents-guide severities)

    @ViewBuilder
    private var parentalGuideSection: some View {
        let warnings = model.parentalWarnings
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Parental Guide")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        detailChipBackground {
                            HStack(spacing: Theme.Spacing.xs) {
                                Circle()
                                    .fill(severityColor(warning.severity))
                                    .frame(width: 12, height: 12)
                                Text(warning.label)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text(warning.severity)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .font(Theme.Font.caption)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                }
            }
        }
    }

    /// Severity strings come back as the labels we supplied (`parentalGuideLabels`).
    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "Severe": return .red
        case "Moderate": return .orange
        default: return .yellow
        }
    }

    // MARK: - Trailers & extras

    @ViewBuilder
    private var trailersRow: some View {
        let trailers = model.meta?.trailers ?? []
        if !trailers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Trailers & Extras")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                        ForEach(Array(trailers.prefix(10).enumerated()), id: \.element.id) { _, trailer in
                            Button {
                                model.playTrailer(trailer)
                            } label: {
                                TrailerThumbCard(trailer: trailer, isResolving: model.resolvingTrailerId == trailer.id)
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape() // BUG-32: honor the Corners setting
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
                #if DEBUG
                // UX-10 diagnostic (invisible, harness-readable): rendered trailer count vs. how
                // many resolved a YouTube thumbnail, so a UITest can prove the shelf switched from
                // text rows to thumbnail cards without depending on pixel comparison.
                let rendered = Array(trailers.prefix(10))
                Text("debug_trailers n=\(rendered.count) thumbs=\(rendered.filter { $0.thumbnailURLString != nil }.count)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_trailers")
                #endif
            }
            .focusSection()
        }
    }

    // MARK: - Trakt community comments

    @ViewBuilder
    private var commentsSection: some View {
        let comments = model.comments
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Comments")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(Array(comments.prefix(8).enumerated()), id: \.element.id) { _, comment in
                        commentCard(comment)
                    }
                }
                Text("From Trakt")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .focusSection()
        }
    }

    /// One comment as a focusable card. Pressing reveals spoilers / expands long text.
    private func commentCard(_ comment: TraktCommentReview) -> some View {
        let expanded = expandedComments.contains(comment.id)
        let hidesForSpoiler = (comment.spoiler || comment.hasSpoilerContent) && !expanded
        return Button {
            if expanded {
                expandedComments.remove(comment.id)
            } else {
                expandedComments.insert(comment.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.md) {
                    Text(comment.authorDisplayName)
                        .font(Theme.Font.meta)
                        .rowTextColor()
                    if let rating = comment.rating?.value {
                        HStack(spacing: 2) {
                            // BUG-50: the star's fixed gold (Theme.Palette.star) isn't a
                            // semantic color the row's colorScheme flip can fix, and reads as
                            // washed-out on the near-white focused platter. `rowAccentTint`
                            // preserves the gold at rest (active: false, inactiveColor: star)
                            // while forcing the platter-safe color on focus, same shape as
                            // BUG-22's row-icon fix.
                            Image(systemName: "star.fill")
                                .rowAccentTint(false, inactiveColor: Theme.Palette.star)
                            Text("\(rating)/10")
                        }
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                    }
                    if let date = commentDate(comment) {
                        Text(date)
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                    if comment.review {
                        Text("Review")
                            .font(Theme.Font.caption)
                            .rowAccentTint()
                    }
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                }
                if hidesForSpoiler {
                    Label("Contains spoilers \u{2014} press to reveal", systemImage: "eye.slash")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                } else {
                    Text(comment.comment)
                        .font(Theme.Font.body)
                        .rowTextColor()
                        .lineLimit(expanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
    }

    private func commentDate(_ comment: TraktCommentReview) -> String? {
        let raw: String? = comment.createdAt
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }

    // MARK: - Auto-play hero trailer

    /// (Re)starts the ~4s countdown once `model.trailerVideoURL` resolves. Every cancellation
    /// condition is re-checked once the timer actually fires, since a lot can change in 4 seconds.
    private func scheduleAutoPlayTrailerIfNeeded() {
        guard trailerAutoplayEnabled, !didAutoPlayTrailer, !userInteracted,
              !showStreams, seriesPlay == nil, model.trailerPlayback == nil else { return }
        autoPlayTrailerTask?.cancel()
        autoPlayTrailerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { fireAutoPlayTrailer() }
        }
    }

    private func fireAutoPlayTrailer() {
        guard trailerAutoplayEnabled, !didAutoPlayTrailer, !userInteracted,
              !showStreams, seriesPlay == nil, model.trailerPlayback == nil,
              let trailer = model.trailerVideoURL else { return }
        didAutoPlayTrailer = true
        trailerPlaybackIsAutoPlay = true
        // The exact same assignment the "Watch Trailer" button makes (see the action row above) —
        // reuses its whole `fullScreenCover` path (background-player teardown, the
        // mute-reset-on-dismiss dance) for free. Neither this nor the button touches
        // `HeroTrailerAudioState`: `FullScreenTrailerPlayer` is a brand-new `AVPlayer` instance that
        // is never muted, so both entries already play with sound without any extra unmuting.
        model.trailerPlayback = TrailerPlaybackItem(id: "hero-trailer", url: trailer, title: title)
    }

    private func cancelAutoPlayTrailer() {
        autoPlayTrailerTask?.cancel()
        autoPlayTrailerTask = nil
    }

    // MARK: - FEAT-8: background-trailer duration

    /// One-shot per detail visit — starts the configured countdown once the background trailer
    /// becomes active (mirrors `scheduleAutoPlayTrailerIfNeeded`'s shape). `trailerDurationSeconds
    /// == 0` means "play forever" (the original behavior), so nothing is scheduled.
    private func scheduleTrailerDurationTimerIfNeeded() {
        guard trailerDurationSeconds > 0, !backgroundTrailerStopped else { return }
        trailerDurationTask?.cancel()
        let seconds = trailerDurationSeconds
        trailerDurationTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { stopBackgroundTrailer() }
        }
    }

    /// Fades the background trailer back to the still backdrop. Deliberately slower than the
    /// ordinary 0.8s crossfade — the slow 1.5s fade back to the still artwork IS the "smoother
    /// return to backdrop" this feature asks for. Never touches `model.trailerVideoURL`: that still
    /// gates the "Watch Trailer" button, so the trailer stays one tap away after it stops.
    private func stopBackgroundTrailer() {
        withAnimation(.easeInOut(duration: 1.5)) {
            backgroundTrailerStopped = true
        }
    }

    private func cancelTrailerDurationTask() {
        trailerDurationTask?.cancel()
        trailerDurationTask = nil
    }

    /// "Press Back to exit the trailer" — shown only for the auto-play entry (not the explicit
    /// "Watch Trailer" button or a "Trailers & Extras" item), fading out on its own after ~4s.
    private var autoPlayHintOverlay: some View {
        Text("Press Back to exit the trailer")
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, Theme.Spacing.xl)
            .opacity(trailerHintVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.6), value: trailerHintVisible)
            .onAppear {
                trailerHintVisible = true
                // 6s (was 4): reported as "doesn't stay on the screen" when the display-mode
                // switch ate the start of the window (BUG-18). The switch is gone now, but the
                // longer dwell keeps the hint readable even on TVs that blank briefly at
                // playback start for other reasons.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    trailerHintVisible = false
                }
            }
    }

}

/// One label/value pair in the Detail info block. `id` is the label (unique within the block).
private struct InfoRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Circular cast avatar + name/role. Platter-free: used inside a `.poster`-styled NavigationLink
/// when tappable, so it supplies its own focus visuals (ring + scale + shadow); rendered bare for
/// non-tappable cast, where `isFocused` simply never fires.
private struct CastCard: View {
    let person: MetaPerson
    /// Caller-supplied focus truth for the no-zoom still ring (Codex 2026-08-29 rounds 3-5):
    /// with the system focus effect disabled this card's only treatment was caption opacity, and
    /// the generic outer-bounds ring wrapped the whole lockup — the ring belongs on the avatar
    /// circle, whose geometry only this view knows.
    var stillFocused: Bool = false

    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            AsyncImage(url: URL(string: person.photo ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.Palette.surface
                        Image(systemName: "person.fill")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .frame(width: Theme.Size.castAvatar, height: Theme.Size.castAvatar)
            .clipShape(Circle())
            .nuvioCardDepth(Circle(), surface: .cast)
            .overlay {
                if noZoomOnFocus && stillFocused {
                    Circle().strokeBorder(stillHighlight, lineWidth: ringWidth)
                }
            }
            Text(person.name)
                .font(Theme.Font.caption)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textPrimary.opacity(0.9))
                .lineLimit(1)
                .frame(width: Theme.Size.castAvatar + 10)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: Theme.Size.castAvatar + 10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Studio/network logo chip. Keeps the intentional white capsule (logo legibility); focus reads as
/// scale + the brand focus ring, platter-free like every other tile.
private struct CompanyChip: View {
    let company: MetaCompany

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        AsyncImage(url: URL(string: company.logo ?? "")) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(company.name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.black)
            }
        }
        .frame(height: 36)
        .frame(minWidth: 60, maxWidth: 180)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Color.white.opacity(0.92), in: Capsule())
    }
}

/// Identifiable wrapper so the series primary action can drive `.fullScreenCover(item:)`.
private struct SeriesPlayRoute: Identifiable {
    let meta: MetaDetails
    let action: SeriesPrimaryAction
    var id: String { action.videoId }

    /// The resolved episode (by season/episode number) — the Info header shows ITS still +
    /// overview, not the series poster/synopsis, matching the EpisodesSection launch path.
    private var episode: MetaVideo? {
        guard let s = action.seasonNumber?.value, let e = action.episodeNumber?.value else { return nil }
        return meta.videos.first { $0.season?.value == s && $0.episode?.value == e }
    }
    /// Episode still (action's, else the resolved episode's); blank addon values count as missing.
    var episodeStill: String? {
        let still: String? = action.episodeThumbnail
        if let still, !still.isEmpty { return still }
        let epStill: String? = episode?.thumbnail
        return (epStill ?? "").isEmpty ? nil : epStill
    }
    var synopsis: String? {
        let overview: String? = episode?.overview
        if let overview, !overview.isEmpty { return overview }
        let d: String? = meta.description_
        return d
    }

    /// "S1E1 · Pilot"-style picker title (falls back to the action label).
    var pickerTitle: String {
        if let s = action.seasonNumber?.value, let e = action.episodeNumber?.value {
            let name: String? = action.episodeTitle
            if let name, !name.isEmpty { return "S\(s)E\(e) \u{00B7} \(name)" }
            return "S\(s)E\(e)"
        }
        return action.label
    }
}
