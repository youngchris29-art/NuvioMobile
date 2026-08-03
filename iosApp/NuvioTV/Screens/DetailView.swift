import SwiftUI
import SharedCore

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

    /// UX-6: 0...0.35 darkening applied over the whole backdrop/poster/trailer stack as the user
    /// scrolls the description down, computed once inside `.onScrollGeometryChange`'s `of:` so it
    /// stops firing once fully saturated.
    @State private var scrollDarkening: Double = 0

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

    init(preview: MetaPreview) {
        self.preview = preview
        _model = StateObject(wrappedValue: DetailViewModel(preview: preview))
    }

    var body: some View {
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
                // UX-9: same parity zoom as the inline card (see `TrailerHeroPlayer.parityZoom`) to
                // hide the letterbox bars baked into our YouTube encodes. Full-screen and already
                // ignoring the safe area, so the 1.08 overscale just pushes the bars past the
                // screen edges — the screen bounds themselves do the clipping.
                TrailerHeroPlayer(urlString: trailer, onFailure: { model.trailerFailed() })
                    .scaleEffect(TrailerHeroPlayer.parityZoom)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            scrimOverlay(posterBackdropVisible: showPosterBackdrop)
            // UX-6: darkens the whole backdrop/poster/trailer stack (trailer keeps playing
            // underneath) as the description scrolls down — the scrim above stays untouched.
            Color.black.opacity(scrollDarkening).ignoresSafeArea().allowsHitTesting(false)
            #if DEBUG
            // UX-6 diagnostic (invisible, harness-readable): the live darkening value, so the
            // UITest can prove whether focus-driven scrolling feeds the overlay at all.
            Text("debug_ux6 dark=\(Int(scrollDarkening * 1000))")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_ux6")
            #endif
            ScrollView(.vertical) {
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
                    // Grouped to stay under ViewBuilder's 10-subview ceiling.
                    Group {
                        infoSection
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
                // 0 → 0.85 over the first ~400pt of scroll. Device pass (2026-08-01): the
                // original 0.35 ceiling was invisible over a bright playing trailer on a real
                // TV — the reporter's ask (and upstream's cinematic mode) is a near-black dim
                // once the description scrolls up. Sim-verified via debug_ux6 (test17).
                min(max((geo.contentOffset.y - geo.contentInsets.top) / 400.0, 0), 1) * 0.85
            }, action: { _, newValue in
                scrollDarkening = newValue
            })
            #if DEBUG
            // UX-6 device-verify probe: raw offset/inset so `log show` proves whether tvOS
            // focus-scrolling moves this ScrollView's contentOffset at all.
            .onScrollGeometryChange(for: String.self, of: { geo in
                "y=\(Int(geo.contentOffset.y)) inset=\(Int(geo.contentInsets.top))"
            }, action: { _, v in
                NSLog("[UX6] %@", v)
            })
            #endif
        }
        .overlay(alignment: .topTrailing) {
            // Topmost so it stays reachable over both the scrim (hit-testing disabled there) and
            // the ScrollView's full-bleed frame; shown only while the hero trailer is actually
            // playing (same gating as the player itself, just re-checked without `trailer` unwrapped
            // since we don't need the URL here).
            if isTrailerActive {
                HeroTrailerMuteButton()
                    .padding(Theme.Spacing.screen)
                    .transition(.opacity)
            }
        }
        // FEAT-8: combined into one Bool so the fade also triggers when the trailer-duration timer
        // stops the background player (a `withAnimation(.easeInOut(duration: 1.5))` at the call site
        // overrides this ambient 0.8s for that specific change — see `stopBackgroundTrailer()`).
        .animation(.easeInOut(duration: 0.8), value: model.trailerVideoURL != nil && !backgroundTrailerStopped)
        // The speaker overlay sits above the ScrollView, where the tvOS focus engine routes Up
        // presses to the tab bar instead — so the reachable control is the Siri Remote's
        // play/pause button, and the overlay acts as the state indicator.
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
            StreamPickerView(type: preview.type, videoId: preview.id, title: title)
        }
        .fullScreenCover(item: $seriesPlay) { route in
            StreamPickerView(
                type: route.meta.type,
                videoId: route.action.videoId,
                title: route.pickerTitle,
                parentMetaId: route.meta.id,
                season: route.action.seasonNumber?.value,
                episode: route.action.episodeNumber?.value,
                episodes: route.meta.videos
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
            FullScreenTrailerPlayer(urlString: item.url)
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

    /// A small Liquid Glass capsule around one metadata item (year / runtime / rating).
    private func metaChip(stroked: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs - 2)
            .glassEffect(.regular, in: .capsule)
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
        .focusSection()
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
                        ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                            // Cast members carry a TMDB id only when TMDB enrichment is on; make those
                            // tappable to a person page, leave the rest as plain (non-focusable) cards.
                            if let personId = person.tmdbId?.value {
                                NavigationLink(value: PersonRoute(id: personId, name: person.name)) {
                                    CastCard(person: person)
                                }
                                .buttonStyle(.borderless)
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
                            .buttonStyle(.borderless)
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
                            .buttonStyle(.borderless)
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
                        .glassEffect(.regular, in: .capsule)
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
                            .buttonStyle(.borderless)
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
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let rating = comment.rating?.value {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Theme.Palette.star)
                            Text("\(rating)/10")
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if let date = commentDate(comment) {
                        Text(date)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if comment.review {
                        Text("Review")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if hidesForSpoiler {
                    Label("Contains spoilers \u{2014} press to reveal", systemImage: "eye.slash")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text(comment.comment)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
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
