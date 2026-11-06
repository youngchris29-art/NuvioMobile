import SwiftUI
import UIKit
import SharedCore

/// Season selector + horizontal episode thumbnail shelf for series titles. Mirrors the shared
/// `SeriesSeasonSupport` rules: specials (season 0 / missing) normalize to 0 and sort last;
/// episodes order by number, then release, then title. Tapping an episode opens the stream picker
/// with that episode's playback videoId. A fixed-height panel under the shelf shows the focused
/// episode's synopsis, so browsing left/right never reflows the sections below.
///
/// A3 (Apple-style, `appleStyle: true`): compact text season tabs that switch the shelf when focus
/// lands on them (debounced, `SeasonTabBrowse`), a fixed-height text block under every card
/// (`EpisodeCardText`) and no shared panel. Cinematic and Classic pass nothing and are unchanged.
struct EpisodesSection: View {
    let meta: MetaDetails
    /// IMDb ratings keyed "season:episode" (from `DetailViewModel.episodeRatings`); empty = no badges.
    var episodeRatings: [String: Double] = [:]
    /// rc14 (Steven rc13 verdict, 2026-09-30): the Settings → Poster Style "Episode Ratings" choice
    /// (from `DetailViewModel.episodeRatingsVisibility`). `hideEpisodes` drops every badge;
    /// `hideUnwatchedEpisodes` keeps only watched episodes' badges.
    var episodeRatingsVisibility: EpisodeRatingsVisibility = .showAll
    /// Episodes to badge as watched, keyed "season:episode" (from `DetailViewModel.watchedEpisodeKeys`;
    /// `TitleHoldMenuPolicy.episodeKey`, a missing number is -1).
    var watchedEpisodeKeys: Set<String> = []
    /// P5 B22: a post-play More Like This pick from an episode's player; called from the picker
    /// cover's `onDismiss` so the host pushes only after the cover is gone.
    var onPostPlayTitle: ((MetaPreview) -> Void)? = nil
    /// A3: the Apple-style Detail layout (`DetailLayout.appleStyle`). Off = today's section.
    var appleStyle: Bool = false

    @AppStorage(EpisodeSpoilerRules.defaultsKey) private var hideSpoilers = false
    @State private var selectedSeason: Int?
    @State private var episodeForStreams: EpisodeRoute?
    @State private var postPlayPending: MetaPreview?
    @FocusState private var focusedEpisodeId: String?
    /// FEAT-83: the episode a hold-menu action just ran on, until focus is back on the shelf.
    /// Marking the next-up episode moves `nextUpId` while the menu still holds focus
    /// (`focusedEpisodeId == nil`), and the shelf would then scroll to the new next-up under the
    /// returning focus (and `.defaultFocus` would offer it); while this is set, neither happens.
    /// Review r1 P3-2: cleared by the first `focusedEpisodeId` change after it is armed, whatever
    /// the new value, and by a 1 s backstop, so it can never stay armed (the action can run after
    /// focus is already back on the card, or focus may never leave the card while the menu is up).
    @State private var heldEpisodeId: String?
    /// BUG-153 (Batch M): gates the episode row's `zIndex` (`DetailTileFocus.raisedZIndex`).
    @Environment(\.focusAppearance) private var focusAppearance
    /// Review r1 #4: the "N aired unwatched" count, cached per (meta, season, watched keys) so a
    /// Left/Right press (a body evaluation) does not re-read the date and re-parse every episode.
    /// A reference held in `@State`: filling it never invalidates the view.
    @State private var airedCountCache = AiredUnwatchedCountCache()
    /// Grouping, season order and season posters, computed once per `MetaDetails` object. The body
    /// re-runs on every Left/Right (the `focusedEpisodeId` FocusState lives here), and regrouping
    /// re-sorted every episode with Kotlin reads in the comparator on each press.
    @State private var groupingCache = EpisodeGroupingCache()
    /// A3.2: viewed-season browsing (debounce tickets, per-season remembered episode). Only
    /// `selectedSeason` (the viewed season) ever changes from it; see `SeasonTabBrowse`. A reference
    /// in `@State`, like the caches above: recording the focused card on every Left/Right must not
    /// invalidate the section again (BUG-153).
    @State private var seasonBrowse = SeasonTabBrowseBox()
    /// A3.2: the sleeping debounce for the last tab focus; cancelled by the next one.
    @State private var seasonSwitchTask: Task<Void, Never>?
    /// A3.2: which text season tab holds focus (Apple-style only).
    @FocusState private var focusedSeasonTab: Int?
    /// A3.1: formatted air dates for the per-card text block (Apple-style only).
    @State private var airDateCache = EpisodeAirDateCache()

    private func airedUnwatchedCount(season: Int?, episodes: [MetaVideo]) -> Int {
        airedCountCache.count(
            key: AiredUnwatchedCountCache.Key(metaId: meta.id, season: season,
                                              episodeCount: episodes.count, watchedKeys: watchedEpisodeKeys)
        ) { todayIsoDate in
            EpisodeSpoilerRules.airedUnwatchedCount(
                episodes.map {
                    EpisodeSpoilerRules.EpisodeFacts(
                        season: $0.season?.value,
                        episode: $0.episode?.value,
                        released: $0.released
                    )
                },
                watchedKeys: watchedEpisodeKeys,
                todayIsoDate: todayIsoDate
            )
        }
    }

    private func resolvedGrouping() -> EpisodeGroupingCache.Grouping {
        groupingCache.resolve(meta) { meta in
            let grouped = Self.groupedEpisodes(meta.videos)
            return EpisodeGroupingCache.Grouping(
                grouped: grouped,
                seasons: grouped.keys.sorted { Self.seasonSortKey($0) < Self.seasonSortKey($1) },
                posterBySeason: Self.seasonPosters(grouped, meta: meta),
                releasedSeasons: Self.seasonsWithReleasedEpisodes(meta)
            )
        }
    }

    /// Where focus lands when it enters the shelf, and where the shelf scrolls to: the first
    /// unwatched episode of the season (Apple TV app behaviour), else the first episode. Before,
    /// Down from the season row landed on whichever card sat nearest, usually E1.
    private func nextUpEpisodeId(_ episodes: [MetaVideo]) -> String? {
        episodes.first(where: { !isWatched($0) })?.id ?? episodes.first?.id
    }

    /// A3.2: Apple-style enters a season it has seen before on the remembered episode; first entry
    /// (and every other layout) is next-up.
    private func entryEpisodeId(season: Int?, episodes: [MetaVideo]) -> String? {
        let nextUpId = nextUpEpisodeId(episodes)
        guard appleStyle else { return nextUpId }
        return seasonBrowse.state.entryEpisode(season: season, nextUpId: nextUpId,
                                               isListed: { id in episodes.contains { $0.id == id } })
    }

    var body: some View {
        let grouping = resolvedGrouping()
        let grouped = grouping.grouped
        let seasons = grouping.seasons
        let current = selectedSeason ?? seasons.first
        let episodes = current.flatMap { grouped[$0] } ?? []
        let nextUpId = nextUpEpisodeId(episodes)
        let entryId = entryEpisodeId(season: current, episodes: episodes)
        let showsSeasonTabs = appleStyle && seasons.count > 1

        return VStack(alignment: .leading, spacing: 20) {
            if showsSeasonTabs {
                seasonTabRow(seasons: seasons, current: current,
                             releasedSeasons: grouping.releasedSeasons,
                             airedLabel: hideSpoilers ? EpisodeSpoilerRules.airedUnwatchedLabel(
                                count: airedUnwatchedCount(season: current, episodes: episodes),
                                settingOn: hideSpoilers) : nil)
            } else if seasons.count > 1 {
                // FEAT-24 (u/mrStevenx3, p4afwfo): season POSTERS instead of "Season 1 / Season 2"
                // text, "comme le fait l'application mobile Nuvio". The data was already here —
                // `MetaVideo.seasonPoster` is filled by the TMDB season fetch (`useSeasonPosters`,
                // default ON) — tvOS just never drew it. Mobile's rule (DetailSeriesContent.kt):
                // posters when any season has one, text chips otherwise; the poster's fallback is
                // the show poster. No new setting this cycle (mobile's Posters/Text toggle stays
                // out until someone asks), so no new strings either.
                let posterBySeason = grouping.posterBySeason
                if posterBySeason.values.contains(where: { $0 != nil }) {
                    // BUG-153 (Batch M): its own view, so the season row's FocusState re-runs only
                    // the row on Left/Right, not the whole section (and the episode shelf with it).
                    SeasonPosterRow(
                        seasons: seasons,
                        posterBySeason: posterBySeason,
                        fallbackImage: meta.poster ?? meta.background,
                        current: current,
                        meta: meta,
                        watchedEpisodeKeys: watchedEpisodeKeys,
                        releasedSeasons: grouping.releasedSeasons,
                        onSelect: { selectedSeason = $0 }
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(seasons, id: \.self) { season in
                                Button {
                                    selectedSeason = season
                                } label: {
                                    Text(Self.seasonLabel(season))
                                        .padding(.horizontal, 20).padding(.vertical, 8)
                                }
                                .buttonStyle(.chip(selected: season == current))
                                // FEAT-83: the same season menu as the posters (titles without
                                // season art get these chips instead). Attached unconditionally;
                                // a season with nothing released has no content, so no menu
                                // (review r1 P3-9, `releasedSeasons`).
                                .contextMenu {
                                    if grouping.releasedSeasons.contains(season) {
                                        SeasonHoldMenuItems(meta: meta, season: season,
                                                            watchedEpisodeKeys: watchedEpisodeKeys)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusSection()
                }
            }

            // UX-15 (u/mrStevenx3, beta.13 review): with multiple seasons the heading used to sit
            // ABOVE the season selector, reading "Episodes → seasons → episodes" — inverted
            // hierarchy. It now labels the shelf it belongs to, directly under the selector. Was
            // also a raw `Text("Episodes")` — the one unlocalized string on this screen (his
            // French locale showed "Episodes", not "Épisodes").
            // A3.2: with tabs, the tab row is the shelf's heading (and carries the aired count).
            if !showsSeasonTabs {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(String(localized: "Episodes")).font(Theme.Font.screenTitle)
                    if hideSpoilers, let label = EpisodeSpoilerRules.airedUnwatchedLabel(
                        count: airedUnwatchedCount(season: current, episodes: episodes),
                        settingOn: hideSpoilers
                    ) {
                        Text(label)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .accessibilityIdentifier("episodes_aired_unwatched")
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                        ForEach(episodes, id: \.id) { episode in
                            Button {
                                episodeForStreams = EpisodeRoute(meta: meta, episode: episode)
                            } label: {
                                EpisodeThumbCard(
                                    episode: episode,
                                    fallbackImage: meta.background ?? meta.poster,
                                    // A3.1: Apple-style draws the rating in the text block instead.
                                    rating: appleStyle ? nil : rating(for: episode),
                                    isWatched: isWatched(episode),
                                    hidesSpoiler: EpisodeSpoilerRules.hidesSpoilers(
                                        settingOn: hideSpoilers, isWatched: isWatched(episode)),
                                    textBlock: appleStyle ? cardText(for: episode) : nil
                                )
                            }
                            // BUG-177 (Steven rc7): EpisodeThumbCard owns its ring-mode lift now
                            // (`DetailTileFocusLift`), so the default `.card` style applies.
                            .cardFocusButtonStyle()
                            .posterButtonShape() // BUG-32: honor the Corners setting
                            .focused($focusedEpisodeId, equals: episode.id)
                            // FEAT-83 (GitHub #9 item 3): hold for the watched actions. Attached
                            // unconditionally (an empty menu is never possible here: the episode
                            // item always exists), after `.focused` and before `.id`, the Continue
                            // Watching row's order. A plain press still opens the source list.
                            .contextMenu {
                                EpisodeHoldMenuItems(meta: meta, episode: episode,
                                                     watchedEpisodeKeys: watchedEpisodeKeys,
                                                     willAct: { armHeldEpisode(episode.id) })
                            }
                            .id(episode.id)
                            .modifier(EpisodeCardIdentifier(identifier: appleStyle
                                ? EpisodeCardText.cardIdentifier(season: episode.season?.value,
                                                                 episode: episode.episode?.value,
                                                                 fallbackId: episode.id)
                                : nil))
                            // BUG-177: the lifted card draws over its right neighbour.
                            // BUG-153 (Batch M): only when SwiftUI draws the lift.
                            .zIndex(DetailTileFocus.raisedZIndex(
                                isFocused: focusedEpisodeId == episode.id,
                                accentFocusRing: focusAppearance.accentFocusRing,
                                noZoomOnFocus: focusAppearance.noZoomOnFocus))
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
                // beta.19-rc1 verdict (F, FEAT-54): the episode cards fade at the screen edges like
                // the other Detail rows (Christian 2026-10-03: the Episodes rows get it too). The
                // fade only reads the horizontal scroll offset, so the `scrollTo` snap below is
                // unaffected.
                .rowEdgeEffectStyle()
                .onChange(of: current) { _, _ in
                    // A new season can be shorter than the old scroll offset; snap to its next-up
                    // episode (the first one when all are watched) without animating through the
                    // intermediate layout. A3.2: Apple-style returns to a revisited season's
                    // remembered episode instead (`entryId` is `nextUpId` everywhere else).
                    guard let target = entryId else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(target, anchor: .leading) }
                }
                .onAppear {
                    guard let target = entryId, target != episodes.first?.id else { return }
                    // One runloop later: a scrollTo during the first appear can no-op before the
                    // row has a content size.
                    DispatchQueue.main.async {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { proxy.scrollTo(target, anchor: .leading) }
                    }
                }
                .onChange(of: nextUpId) { _, target in
                    // Watched state often lands after the first render (review r1 P2). Only move
                    // a shelf the user isn't on — nor one whose card just ran a hold-menu action
                    // and is about to take focus back (FEAT-83, `heldEpisodeId`).
                    // A3.2: Apple-style keeps a revisited season on its remembered episode.
                    let goal: String? = appleStyle ? entryId : target
                    guard focusedEpisodeId == nil, heldEpisodeId == nil, let goal else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(goal, anchor: .leading) }
                }
            }
            // `.userInitiated`: the default priority only applies to programmatic focus and first
            // load, never to the user's Down from the season row (review r1 P1). Up from Cast now
            // also lands on next-up rather than the last-visited card, as in the Apple TV app.
            // FEAT-83: while a hold-menu action is settling, the acted-on card is the default, so
            // focus coming back from the menu is never redirected to a next-up that just moved.
            .defaultFocus($focusedEpisodeId, heldEpisodeId ?? entryId, priority: .userInitiated)
            .focusSection()
            // A3.2: Menu on an episode card goes to the viewed season's tab first; Menu on the tabs
            // (no handler there) leaves Detail as before. nil everywhere else: no handler.
            .onExitCommand(perform: showsSeasonTabs ? { focusedSeasonTab = current } : nil)
            .onChange(of: focusedEpisodeId) { _, newValue in
                // FEAT-83: focus moved after the action (back to the held card, on along the
                // shelf, or anywhere else): the hold is over. Any change, not only a return to
                // the shelf (review r1 P3-2).
                if heldEpisodeId != nil { heldEpisodeId = nil }
                guard appleStyle, let newValue else { return }
                // A3.2: focus reached the shelf while a tab switch was still pending (Down within
                // the debounce; this can run before the tab row sees focus leave): commit it now,
                // and send focus on to that season's entry instead of the old season's card.
                commitPendingSeasonOnLeave()
                if redirectShelfFocus(from: newValue) { return }
                // A3.2: per-season remembered episode (Apple-style only). `selectedSeason` is read
                // live: a commit above may have moved it past this render's `current`.
                if let season = selectedSeason ?? current {
                    seasonBrowse.state.remember(episodeId: newValue, season: season)
                }
            }

            // A3.1: Apple-style puts the text under each card and drops the shared panel.
            if !appleStyle {
                focusedOverviewPanel(episodes: episodes)
            }
        }
        .fullScreenCover(item: $episodeForStreams, onDismiss: {
            guard let pick = postPlayPending else { return }
            postPlayPending = nil
            onPostPlayTitle?(pick)
        }) { route in
            // P3.3: the episode's saved entry for the resume pill. Review r1: a finished entry
            // offers nothing (the players start a completed episode from 0).
            let entry = WatchProgressRepository.shared.progressForVideo(
                videoId: Self.episodeVideoId(metaId: route.meta.id, episode: route.episode),
                parentMetaId: route.meta.id,
                seasonNumber: route.episode.season, episodeNumber: route.episode.episode)
                .flatMap { $0.isCompleted ? nil : $0 }
            StreamPickerView(
                type: route.meta.type,
                videoId: Self.episodeVideoId(metaId: route.meta.id, episode: route.episode),
                title: Self.episodeTitle(route.episode),
                parentMetaId: route.meta.id,
                season: route.episode.season?.value,
                episode: route.episode.episode?.value,
                episodes: route.meta.videos,
                poster: route.meta.poster,
                background: route.meta.background,
                episodeStill: route.episodeStill,
                synopsis: route.synopsis,
                meta: PlaybackMeta(details: route.meta),
                logoUrl: route.meta.logo,
                resumePositionMs: entry.map { $0.lastPositionMs }.flatMap { $0 > 0 ? $0 : nil },
                resumeFraction: entry.map { Double($0.progressFraction) },
                onOpenTitle: onPostPlayTitle == nil ? nil : { postPlayPending = $0 }
            )
        }
    }

    // MARK: - A3 Apple-style

    /// A3.2 (C1): compact text tabs, one per season (Specials last). Focus landing on a tab switches
    /// the shelf after `SeasonTabBrowse.debounce`; Select switches at once. Only the viewed season
    /// (`selectedSeason`) changes: the hero and Play read `DetailViewModel`, never this section.
    @ViewBuilder
    private func seasonTabRow(seasons: [Int], current: Int?, releasedSeasons: Set<Int>,
                              airedLabel: String?) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(EpisodeSeasonTabs.tabs(for: seasons), id: \.season) { tab in
                        Button {
                            selectSeasonTab(tab.season)
                        } label: {
                            Text(tab.label)
                                .font(Theme.Font.metaStrong)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.chip(selected: tab.season == current))
                        .focused($focusedSeasonTab, equals: tab.season)
                        // FEAT-83: the same season hold menu as the chips and posters.
                        .contextMenu {
                            if releasedSeasons.contains(tab.season) {
                                SeasonHoldMenuItems(meta: meta, season: tab.season,
                                                    watchedEpisodeKeys: watchedEpisodeKeys)
                            }
                        }
                        .accessibilityIdentifier(tab.accessibilityIdentifier)
                        .accessibilityAddTraits(tab.season == current ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            .focusSection()
            // Focus entering the row (Down from the hero, Up from the shelf) lands on the viewed
            // season's tab, as in the Apple TV app, not on the tab nearest the previous focus.
            .defaultFocus($focusedSeasonTab, current, priority: .userInitiated)
            .onChange(of: focusedSeasonTab) { old, season in
                let viewed = selectedSeason ?? seasons.first
                // Backstop for the default above: an entry that still lands on another tab is moved
                // to the viewed one before its debounce can switch the shelf.
                if let target = SeasonTabBrowse.entryTab(from: old, to: season, viewed: viewed) {
                    seasonSwitchTask?.cancel()
                    seasonSwitchTask = nil
                    _ = seasonBrowse.state.focus(on: target, viewed: viewed)
                    focusedSeasonTab = target
                    return
                }
                seasonTabFocusChanged(season, viewed: viewed)
            }

            if let airedLabel {
                Text(airedLabel)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("episodes_aired_unwatched")
            }
        }
    }

    /// A3.2: focus moved onto a tab (debounced switch) or off the row. Leaving with a switch that
    /// has not settled yet commits it at once (`commitPendingSeasonOnLeave`), so Down within the
    /// debounce enters the season the viewer tabbed to, on its entry episode. Only the viewed
    /// season changes: the hero and Play never read it.
    private func seasonTabFocusChanged(_ season: Int?, viewed: Int?) {
        seasonSwitchTask?.cancel()
        seasonSwitchTask = nil
        guard let season else {
            commitPendingSeasonOnLeave()
            // Focus may already sit on the old season's card (the shelf saw it first).
            if let focused = focusedEpisodeId { _ = redirectShelfFocus(from: focused) }
            return
        }
        guard let ticket = seasonBrowse.state.focus(on: season, viewed: viewed) else { return }
        seasonSwitchTask = Task { @MainActor in
            try? await Task.sleep(for: SeasonTabBrowse.debounce)
            guard !Task.isCancelled else { return }
            if let settled = seasonBrowse.state.settle(ticket: ticket) { selectedSeason = settled }
        }
    }

    /// A3.2: focus left the tab row: show the pending season now (if any) and arm its entry
    /// episode for the next shelf focus. Idempotent: the tab row and the shelf both call it, in
    /// whichever order SwiftUI delivers the two focus changes.
    private func commitPendingSeasonOnLeave() {
        guard seasonBrowse.state.pending != nil else { return }
        seasonSwitchTask?.cancel()
        seasonSwitchTask = nil
        let grouped = resolvedGrouping().grouped
        // Read the entry from a copy: `entryEpisodeId` reads `seasonBrowse.state`, which `leave`
        // is mutating (an overlapping access on the box's stored property).
        let browse = seasonBrowse.state
        let committed = seasonBrowse.state.leave(entry: { season in
            let episodes = grouped[season] ?? []
            return browse.entryEpisode(season: season, nextUpId: nextUpEpisodeId(episodes),
                                       isListed: { id in episodes.contains { $0.id == id } })
        })
        if let committed, selectedSeason != committed { selectedSeason = committed }
    }

    /// A3.2: after a leave commit, move shelf focus from `episodeId` (a card of the season the
    /// viewer tabbed away from) to the committed season's entry. One runloop later, so the
    /// rebuilt shelf has the target card. Returns whether it redirected.
    private func redirectShelfFocus(from episodeId: String) -> Bool {
        guard let target = seasonBrowse.state.shelfFocus(on: episodeId) else { return false }
        DispatchQueue.main.async { focusedEpisodeId = target }
        return true
    }

    /// A3.2: Select on a tab switches at once (no debounce wait).
    private func selectSeasonTab(_ season: Int) {
        seasonSwitchTask?.cancel()
        seasonSwitchTask = nil
        _ = seasonBrowse.state.flush()
        if selectedSeason != season { selectedSeason = season }
    }

    /// A3.1: the text block's content for one card (spoiler rule shared with the still's blur).
    private func cardText(for episode: MetaVideo) -> EpisodeCardText.Content {
        let overview: String? = episode.overview
        let released: String? = episode.released
        return EpisodeCardText.make(
            episodeNumber: episode.episode?.value,
            title: episode.title,
            overview: overview,
            airDate: airDateCache.airDate(released),
            runtimeMinutes: episode.runtime?.value,
            rating: rating(for: episode),
            hidesSpoiler: EpisodeSpoilerRules.hidesSpoilers(settingOn: hideSpoilers, isWatched: isWatched(episode))
        )
    }

    /// Fixed-height synopsis for the focused episode (falls back to the season's first episode so
    /// the panel is never blank). Fixed frame keeps the cast row below from reflowing as focus
    /// moves along the shelf.
    @ViewBuilder
    private func focusedOverviewPanel(episodes: [MetaVideo]) -> some View {
        let episode = episodes.first { $0.id == focusedEpisodeId } ?? episodes.first
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let episode {
                if let caption = Self.episodeCaption(episode) {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                let overview: String? = episode.overview
                if EpisodeSpoilerRules.hidesSpoilers(settingOn: hideSpoilers, isWatched: isWatched(episode)) {
                    Text(String(localized: "Synopsis hidden until watched"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("episode_synopsis_hidden")
                } else if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: 1100, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.15), value: focusedEpisodeId)
    }

    /// "S1E4 · Apr 12, 2024 · 52 min"-style caption line; nil when nothing is known.
    private static func episodeCaption(_ episode: MetaVideo) -> String? {
        var parts: [String] = []
        if let s = episode.season?.value, let e = episode.episode?.value {
            parts.append("S\(s)E\(e)")
        }
        let released: String? = episode.released
        if let released, released.count >= 10 {
            parts.append(String(released.prefix(10)))
        }
        if let runtime = episode.runtime?.value, runtime > 0 {
            parts.append("\(runtime) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Grouping / sorting (mirrors shared SeriesSeasonSupport.kt)

    /// True if this title should show an episode list at all.
    static func isSeriesLike(_ meta: MetaDetails) -> Bool {
        meta.type == "series" || meta.videos.contains { $0.season != nil || $0.episode != nil }
    }

    nonisolated static func normalizeSeasonNumber(_ season: KotlinInt?) -> Int {
        guard let s = season?.value, s > 0 else { return 0 }
        return s
    }

    nonisolated static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    nonisolated private static func groupedEpisodes(_ videos: [MetaVideo]) -> [Int: [MetaVideo]] {
        let withNumbers = videos.filter { $0.season != nil || $0.episode != nil }
        var groups: [Int: [MetaVideo]] = [:]
        for video in withNumbers {
            groups[normalizeSeasonNumber(video.season), default: []].append(video)
        }
        for (key, value) in groups {
            groups[key] = value.sorted(by: episodeOrder)
        }
        return groups
    }

    nonisolated private static func episodeOrder(_ a: MetaVideo, _ b: MetaVideo) -> Bool {
        let ea = a.episode?.value ?? Int.max
        let eb = b.episode?.value ?? Int.max
        if ea != eb { return ea < eb }
        let ra: String = a.released ?? ""
        let rb: String = b.released ?? ""
        if ra != rb { return ra < rb }
        return a.title < b.title
    }

    fileprivate static func seasonLabel(_ season: Int) -> String {
        EpisodeSeasonTabs.label(season)
    }

    /// FEAT-24: first non-blank `seasonPoster` among each season's episodes (mobile's rule), then —
    /// upstream 22096a1e parity — the addon's own `app_extras.seasonPosters` art for that season
    /// number. Same precedence as mobile's `resolveSeasonPoster`: per-episode (TMDB enrichment or a
    /// per-video addon field) first, addon season map second, and the caller's show poster/backdrop
    /// last. The map is keyed by season NUMBER with specials at 0, matching `groupedEpisodes` keys.
    nonisolated private static func seasonPosters(_ grouped: [Int: [MetaVideo]], meta: MetaDetails) -> [Int: String?] {
        var result: [Int: String?] = [:]
        for (season, episodes) in grouped {
            let poster = episodes.lazy
                .compactMap { $0.seasonPoster?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            // `Map<Int, String>` crosses the SharedCore boundary as `[KotlinInt: String]`.
            let trimmedAddon: String? = meta.seasonPosters[KotlinInt(int: Int32(season))]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let addonPoster: String? = (trimmedAddon?.isEmpty == false) ? trimmedAddon : nil
            // Explicit `String?` so `??` doesn't infer against the dictionary's `String??` value type.
            let resolved: String? = poster ?? addonPoster
            result[season] = resolved
        }
        return result
    }

    private static func episodeVideoId(metaId: String, episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return "\(metaId):\(s):\(e)"
        }
        return episode.id
    }

    private static func episodeTitle(_ episode: MetaVideo) -> String {
        if let s = episode.season?.value, let e = episode.episode?.value {
            return String(localized: "S\(s)E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }

    private func rating(for episode: MetaVideo) -> Double? {
        // rc14 (Steven rc13 verdict, 2026-09-30): honour the episode-ratings visibility setting.
        guard episodeRatingsVisibility.showRating(isWatched: isWatched(episode)) else { return nil }
        guard let s = episode.season?.value, let e = episode.episode?.value else { return episode.rating?.doubleValue }
        return episodeRatings["\(s):\(e)"] ?? episode.rating?.doubleValue
    }

    private func isWatched(_ episode: MetaVideo) -> Bool {
        // Review r1 P3-8: the shared key form, so an episode with only one number reads watched.
        guard let key = EpisodeHoldMenuItems.key(episode) else { return false }
        return watchedEpisodeKeys.contains(key)
    }

    /// FEAT-83: arms `heldEpisodeId` before a hold-menu action, with a 1 s backstop (review r1
    /// P3-2) in case no focus change follows to clear it. The backstop leaves a newer arm alone.
    private func armHeldEpisode(_ id: String) {
        heldEpisodeId = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if heldEpisodeId == id { heldEpisodeId = nil }
        }
    }

    /// FEAT-83 (review r1 P3-9): the seasons, normalized like `groupedEpisodes`, that hold at least
    /// one RELEASED episode in the shared list the season menu marks (`releasedPlayableEpisodes`,
    /// which `releasedEpisodesForSeason` filters). A season outside it gets no menu content, so a
    /// hold shows no menu at all, the device-verified behaviour of an empty `.contextMenu` (the
    /// Detail Play button's hold with Auto-Play off is inert, Orivio pass 2026-10-01). Read once per
    /// `MetaDetails` (`EpisodeGroupingCache`) with today's date: one shared sort per Detail visit.
    nonisolated private static func seasonsWithReleasedEpisodes(_ meta: MetaDetails) -> Set<Int> {
        let released = meta.releasedPlayableEpisodes(todayIsoDate: CurrentDateProvider.shared.todayIsoDate())
        return Set(released.map { normalizeSeasonNumber($0.season) })
    }
}

/// `KotlinInt` is an `NSNumber` subclass, whose `.intValue` Swift accessor is `Int32`. This converts
/// to a plain Swift `Int` to avoid Int/Int32 mismatches throughout.
extension KotlinInt {
    nonisolated var value: Int { Int(truncating: self) }
}

/// Identifiable wrapper so an episode can drive `.fullScreenCover(item:)`.
private struct EpisodeRoute: Identifiable {
    let meta: MetaDetails
    let episode: MetaVideo
    var id: String { episode.id }

    /// Episode still for the player's Info header — blank addon values count as missing.
    var episodeStill: String? {
        let t: String? = episode.thumbnail
        return (t ?? "").isEmpty ? nil : t
    }
    /// Episode overview, else the series synopsis (never an empty header for a blank overview).
    var synopsis: String? {
        let o: String? = episode.overview
        if let o, !o.isEmpty { return o }
        let d: String? = meta.description_
        return d
    }
}

/// FEAT-83 (GitHub #9 item 3): an episode card's hold menu — Mark Episode Watched / Unwatched,
/// then Mark Previous Episodes Watched / Unwatched (mobile's episode action sheet). The policy is
/// `TitleHoldMenuPolicy.episodeActions`.
///
/// Everything is resolved in THIS body, which tvOS evaluates when it presents the menu — never in
/// the shelf's body, which re-runs on every Left/Right (BUG-153): the previous-episodes list is a
/// shared sort over every episode. Review r1 P3-10, confirmed from device consoles: the same
/// shape's `[HoldMenu] menu built` line (`TitleHoldMenuItems`, a `.contextMenu` content body)
/// logs only around a hold, as the menu presents (just before focus moves into
/// `_UIContextMenuCell`) and once more while it is open, and never while rows of those cards
/// render and scroll (`docs/research/rc5-promises-device-2026-10-17/console-a.log`: 2 builds in a
/// 525-line Home walk; `bug170-device-2026-10-18/console-mpv.log`: 1). The shared toggles are
/// called with the state each LABEL was
/// built from (`DetailTileAction.labelState`), never a re-read of the live state; the watched keys
/// refresh by themselves through `DetailViewModel`'s watched and progress watchers.
private struct EpisodeHoldMenuItems: View {
    let meta: MetaDetails
    let episode: MetaVideo
    let watchedEpisodeKeys: Set<String>
    /// Runs before an action, so the shelf records the card before the watched state moves.
    let willAct: () -> Void

    var body: some View {
        let today = CurrentDateProvider.shared.todayIsoDate()
        let previous = meta.previousReleasedEpisodesBefore(target: episode, todayIsoDate: today)
        let isWatched = TitleHoldMenuPolicy.areAllWatched(keys: [Self.key(episode)],
                                                          watchedKeys: watchedEpisodeKeys)
        let arePreviousWatched = TitleHoldMenuPolicy.areAllWatched(keys: previous.map(Self.key),
                                                                   watchedKeys: watchedEpisodeKeys)
        ForEach(TitleHoldMenuPolicy.episodeActions(isEpisodeWatched: isWatched,
                                                   previousCount: previous.count,
                                                   arePreviousWatched: arePreviousWatched),
                id: \.self) { action in
            Button {
                willAct()
                switch action {
                case .episode:
                    WatchingActions.shared.toggleEpisodeWatched(
                        meta: meta, episode: episode, isCurrentlyWatched: action.labelState)
                case .previousEpisodes:
                    // `episodes` is a Kotlin `Collection<MetaVideo>` (bridged as `Any`): pass the
                    // `[MetaVideo]` array the shared extension returned, as is.
                    WatchingActions.shared.togglePreviousEpisodesWatched(
                        meta: meta, episodes: previous, areCurrentlyWatched: action.labelState)
                case .season:
                    break // never in an episode menu (`episodeActions`)
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

    nonisolated static func key(_ episode: MetaVideo) -> String? {
        TitleHoldMenuPolicy.episodeKey(season: episode.season?.value, episode: episode.episode?.value)
    }
}

/// FEAT-83: a season poster's or season chip's hold menu — Mark Season Watched / Unwatched over
/// the season's RELEASED episodes (`TitleHoldMenuPolicy.seasonActions`). Same presentation-time
/// rule as `EpisodeHoldMenuItems`. The callers include it only for a season in
/// `releasedSeasons`, so a season with nothing released has no menu (review r1 P3-9). That set is
/// cached per `MetaDetails`: a season whose first episode airs during the visit gets no menu until
/// `meta` is republished (never a dead item, at worst a missing one).
private struct SeasonHoldMenuItems: View {
    let meta: MetaDetails
    /// `EpisodesSection`'s season number (specials normalized to 0, as the shared side does).
    let season: Int
    let watchedEpisodeKeys: Set<String>

    var body: some View {
        let today = CurrentDateProvider.shared.todayIsoDate()
        let released = meta.releasedEpisodesForSeason(seasonNumber: KotlinInt(int: Int32(season)),
                                                      todayIsoDate: today)
        let isWatched = TitleHoldMenuPolicy.seasonIsWatched(releasedKeys: released.map(EpisodeHoldMenuItems.key),
                                                            watchedKeys: watchedEpisodeKeys)
        ForEach(TitleHoldMenuPolicy.seasonActions(seasonLabel: EpisodesSection.seasonLabel(season),
                                                  releasedCount: released.count,
                                                  isSeasonWatched: isWatched),
                id: \.self) { action in
            Button {
                WatchingActions.shared.toggleSeasonWatched(
                    meta: meta, episodes: released, areCurrentlyWatched: action.labelState)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

/// FEAT-24's season poster row, pulled out of `EpisodesSection.body` (BUG-153, Batch M) so its
/// `FocusState` invalidates only this row. Same buttons, styles and identifiers as before.
private struct SeasonPosterRow: View {
    let seasons: [Int]
    let posterBySeason: [Int: String?]
    /// The show poster (else background) — a season without its own poster falls back to it.
    let fallbackImage: String?
    let current: Int?
    /// FEAT-83: for the hold menu only (`SeasonHoldMenuItems` reads them when the menu opens).
    let meta: MetaDetails
    let watchedEpisodeKeys: Set<String>
    /// FEAT-83 (review r1 P3-9): seasons with a released episode; the others get no menu.
    let releasedSeasons: Set<Int>
    let onSelect: (Int) -> Void

    /// BUG-177: which season poster holds focus — only to raise it over its neighbours (`zIndex`).
    @FocusState private var focusedSeason: Int?
    @Environment(\.focusAppearance) private var focusAppearance

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Theme.Spacing.rowGap) {
                ForEach(seasons, id: \.self) { season in
                    Button {
                        onSelect(season)
                    } label: {
                        SeasonPosterCard(
                            label: EpisodesSection.seasonLabel(season),
                            imageURL: posterBySeason[season] ?? nil ?? fallbackImage,
                            isSelected: season == current
                        )
                    }
                    // BUG-177 (Steven rc7): SeasonPosterCard owns its ring-mode lift now
                    // (`DetailTileFocusLift`), so ring mode takes the native lift away
                    // (`.card`, the default); ring off is the same `.borderless` as before.
                    .cardFocusButtonStyle()
                    // BUG-32: follow the user's Corners setting (system radius
                    // otherwise overrides it — the BUG-25 class).
                    .posterButtonShape()
                    .focused($focusedSeason, equals: season)
                    // FEAT-83 (GitHub #9 item 3): hold for Mark Season Watched / Unwatched;
                    // attached unconditionally, with no content (so no menu) for a season with
                    // nothing released (review r1 P3-9).
                    .contextMenu {
                        if releasedSeasons.contains(season) {
                            SeasonHoldMenuItems(meta: meta, season: season,
                                                watchedEpisodeKeys: watchedEpisodeKeys)
                        }
                    }
                    // BUG-177: the lifted poster draws over its right neighbour.
                    // BUG-153 (Batch M): only when SwiftUI draws the lift.
                    .zIndex(DetailTileFocus.raisedZIndex(
                        isFocused: focusedSeason == season,
                        accentFocusRing: focusAppearance.accentFocusRing,
                        noZoomOnFocus: focusAppearance.noZoomOnFocus))
                    .accessibilityIdentifier("season_poster_\(season)")
                }
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .scrollClipDisabled()
        // beta.19-rc1 verdict (F, FEAT-54): the season-poster row wears the Appearance
        // "Row Edge Fade" like every other row. The text season-chip row below has no
        // `scrollClipDisabled`, so it is left alone.
        .rowEdgeEffectStyle()
        .focusSection()
    }
}

/// One 16:9 episode thumbnail in the horizontal shelf: still + watched/rating badges over a bottom
/// scrim, title below. Platter-free — used inside a `cardFocusButtonStyle()` Button; draws the same
/// focus ring/scale/shadow language as `LandscapeCard` itself (`DetailTileFocusLift`, BUG-177).
private struct EpisodeThumbCard: View {
    let episode: MetaVideo
    let fallbackImage: String?
    /// IMDb rating for this episode (badge hidden when nil).
    var rating: Double? = nil
    /// Shows the green watched checkmark on the thumbnail (mirrors mobile's watched badge).
    var isWatched: Bool = false
    /// "Hide Episode Spoilers": blur the still until the episode is watched.
    var hidesSpoiler: Bool = false
    /// A3.1: Apple-style text block (number, title, two-line overview, date, rating) in place of
    /// the one-line heading; nil = the heading (Cinematic, Classic).
    var textBlock: EpisodeCardText.Content? = nil

    @Environment(\.isFocused) private var isFocused
    // BUG-32: shared corner token, not the hardcoded Theme.Radius.card.
    @Environment(\.posterStyle) private var posterStyle
    /// BUG-177: ring/zoom/poster-colour settings from the root (`ProvidesFocusAppearance`).
    @Environment(\.focusAppearance) private var focusAppearance
    @Environment(\.cardDepthStyle) private var depthStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// BUG-177: the rail colour sampled when the still lands ("Depth Takes Poster Color").
    @State private var depthRailTint: Color?

    private var samplesDepthColor: Bool {
        DetailTileFocus.samplesRailColor(depthTakesPosterColor: focusAppearance.depthTakesPosterColor,
                                         depthEnabled: depthStyle.isEnabled(for: .episodeCards),
                                         artworkURL: thumbnailURL)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .bottom) {
                // Decoded at the card's focused size (×1.2 covers the lift), not the 1920 px default.
                CachedAsyncImage(string: thumbnailURL,
                                 decodeSize: .points(width: Theme.Size.episodeWidth * 1.2,
                                                     height: Theme.Size.episodeHeight * 1.2))
                    .onImageLoaded { _ in
                        DetailTileRailTint.imageLoaded(samples: samplesDepthColor, source: thumbnailURL) { color in
                            if depthRailTint != color { depthRailTint = color }
                        }
                    }
                    .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
                    .blur(radius: hidesSpoiler ? EpisodeSpoilerRules.stillBlurRadius : 0, opaque: true)
                    // BUG-31: episode stills are not all 16:9 (and the poster fallback never is), so
                    // the `.fill` image overflows this fixed frame and the hover lift copies the
                    // overflow as a ghost-doubled subject. Clip inside the frame first.
                    .clipped()

                // Soft scrim so the rating badge reads over bright stills.
                // BUG-177: under the depth layer now (inside the clip, before `nuvioCardDepth`).
                if rating != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 70)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight)
            .clipShape(shape)
            .nuvioCardDepth(shape, surface: .episodeCards,
                            railTint: DetailTileRailTint.resolved(samples: samplesDepthColor,
                                                                  source: thumbnailURL,
                                                                  sampled: depthRailTint))
            .overlay(alignment: .topTrailing) {
                if isWatched { WatchedCheckBadge().padding(10) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating { ratingBadge(rating).padding(10) }
            }
            // Port 2f0185ce: unreleased / flagged-unavailable episode. Top corner like the watched
            // check (moves to the leading corner when that check is showing).
            .overlay(alignment: isWatched ? .topLeading : .topTrailing) {
                if EpisodeAvailability.isUnavailable(episode) { UnavailableEpisodeBadge().padding(10) }
            }
            // Whole-card system lift — see PosterCard: still, scrim, and badges move as one.
            // BUG-31/BUG-25: highlight geometry pinned to the card's own corner radius; goes
            // still under "No Zoom on Focus" (which this tile used to ignore).
            // BUG-177 (Steven rc7): draws the accent ring and owns its lift in ring mode.
            .detailTileFocusLift(cornerRadius: posterStyle.cornerRadius,
                                 size: CGSize(width: Theme.Size.episodeWidth, height: Theme.Size.episodeHeight),
                                 tintSource: thumbnailURL)

            Group {
                if let textBlock {
                    EpisodeCardTextBlock(content: textBlock, isFocused: isFocused)
                } else {
                    Text(heading)
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(width: Theme.Size.episodeWidth, alignment: .leading)
                }
            }
            // UX-15 class: keep the artwork↔title gap constant under the system lift (the
            // Apple-style text block drops with it as one piece).
            .modifier(CardCaptionFocusDrop(
                mode: CardFocusMode.resolve(accentFocusRing: focusAppearance.accentFocusRing,
                                            noZoomOnFocus: focusAppearance.noZoomOnFocus),
                isFocused: isFocused,
                artworkHeight: Theme.Size.episodeHeight
            ))
        }
        // BUG-177: Reduce Motion gate — see `TrailerThumbCard`. BUG-153 (Batch M): also nil in
        // ring mode under the `debug.detailTileRingNoAnim` knob.
        .animation(DetailTileFocus.tileFocusAnimation(reduceMotion: reduceMotion,
                                                      accentFocusRing: focusAppearance.accentFocusRing),
                   value: isFocused)
    }

    /// Heatmap-colored IMDb rating chip (green ≥ 8.5, lime ≥ 7, orange ≥ 5.5, red below).
    private func ratingBadge(_ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
            Text(String(format: "%.1f", value))
        }
        .font(Theme.Font.meta)
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ratingColor(value), in: Capsule())
    }

    private func ratingColor(_ value: Double) -> Color {
        switch value {
        case 8.5...: return Color(red: 0.22, green: 0.78, blue: 0.36)
        case 7.0..<8.5: return Color(red: 0.68, green: 0.85, blue: 0.25)
        case 5.5..<7.0: return .orange
        default: return Color(red: 0.9, green: 0.3, blue: 0.25)
        }
    }

    private var thumbnailURL: String {
        let thumb: String? = episode.thumbnail
        if let thumb, !thumb.isEmpty { return thumb }
        return fallbackImage ?? ""
    }

    private var heading: String {
        if let e = episode.episode?.value {
            return String(localized: "E\(e) \u{00B7} \(episode.title)")
        }
        return episode.title
    }
}

/// A3.1 (C2): the Apple-style text under one episode card. Every row has a fixed slot and the block
/// a fixed height (`EpisodeCardTextLayout`), so cards in the shelf line up whatever data each has.
/// The overview and the placeholder share one two-line slot; the still's blur is driven by the same
/// `hidesSpoiler` value (`EpisodeThumbCard.hidesSpoiler`), so text and still hide together.
private struct EpisodeCardTextBlock: View {
    let content: EpisodeCardText.Content
    let isFocused: Bool

    var body: some View {
        // Every row is drawn in a caption2-sized token (`caption`, `cardTitle`), so one measured
        // line height (Larger Text and the Open Sans face included) sizes all of them.
        let line = Theme.Font.uiFont(for: .caption2).lineHeight
        let lineSlot = line.rounded(.up)
        VStack(alignment: .leading, spacing: EpisodeCardTextLayout.rowSpacing) {
            Text(content.numberLabel ?? "")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: lineSlot, maxHeight: lineSlot, alignment: .leading)
                .accessibilityIdentifier("episode_text_number")

            Text(content.title)
                .font(Theme.Font.cardTitle.weight(.semibold))
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: lineSlot, maxHeight: lineSlot, alignment: .leading)
                .accessibilityIdentifier("episode_text_title")

            let overviewSlot = EpisodeCardTextLayout.overviewHeight(overviewLine: line)
            Group {
                if content.overviewHidden {
                    Text(String(localized: "Synopsis hidden until watched"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(EpisodeCardTextLayout.overviewLineLimit)
                        .accessibilityIdentifier("episode_synopsis_hidden")
                } else if let overview = content.overview {
                    Text(overview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(EpisodeCardTextLayout.overviewLineLimit)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("episode_text_overview")
                }
            }
            .frame(maxWidth: .infinity, minHeight: overviewSlot, maxHeight: overviewSlot, alignment: .topLeading)

            HStack(spacing: Theme.Spacing.xs) {
                if let metaLine = content.metaLine {
                    Text(metaLine)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let ratingText = content.ratingText {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Theme.Palette.star)
                        Text(ratingText)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("episode_text_rating")
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: lineSlot, maxHeight: lineSlot, alignment: .leading)
            .accessibilityIdentifier("episode_text_meta")
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(width: Theme.Size.episodeWidth,
               height: EpisodeCardTextLayout.blockHeight(numberLine: lineSlot, titleLine: lineSlot,
                                                         overviewLine: line, metaLine: lineSlot),
               alignment: .topLeading)
    }
}

/// A3: the Apple-style card's `episode_card_<s>_<e>` identifier; nil adds none, so the other
/// layouts' accessibility tree is unchanged.
private struct EpisodeCardIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// "UNAVAILABLE" pill on an episode card (upstream `EpisodeAvailabilityBadge`: brown 80% fill,
/// white semibold caption). Drawn inside the lifted card, so focus and press are unchanged.
struct UnavailableEpisodeBadge: View {
    var body: some View {
        Text("Unavailable")
            .textCase(.uppercase)
            .font(Theme.Font.meta.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(red: 0x5D / 255, green: 0x40 / 255, blue: 0x37 / 255).opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .accessibilityIdentifier("episode_unavailable_badge")
    }
}

/// Green circular checkmark marking a watched episode (tvOS take on mobile's watched badge).
struct WatchedCheckBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(Theme.Font.meta)
            .foregroundStyle(.white)
            .padding(7)
            .background(Color(red: 0.22, green: 0.78, blue: 0.36).opacity(0.95), in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// FEAT-24: one season in the poster selector — 2:3 artwork with the season label under it, the
/// selected season outlined in the accent (the same "selected vs focused" split the text chips
/// draw with colour). Same idioms as `TrailerThumbCard`: `cardFocusButtonStyle()` button,
/// `detailTileFocusLift` (the accent ring in ring mode, still under No Zoom on Focus, BUG-177),
/// `Theme.Font.cardTitle` caption.
// beta.19-rc1 verdict (review r1, I1): internal (was private) only so `SeasonPosterDecodeSizeTests`
// can pin `decodeSize`; nothing outside this file constructs it.
struct SeasonPosterCard: View {
    let label: String
    let imageURL: String?
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused
    // BUG-32: read the shared corner token instead of hardcoding Theme.Radius.card, so the
    // Poster Style → Corners setting reaches this card (both states, focused and not).
    @Environment(\.posterStyle) private var posterStyle
    /// BUG-177: ring/zoom/poster-colour settings from the root (`ProvidesFocusAppearance`).
    @Environment(\.focusAppearance) private var focusAppearance
    @Environment(\.cardDepthStyle) private var depthStyle
    /// BUG-177: the rail colour sampled when the poster lands ("Depth Takes Poster Color").
    @State private var depthRailTint: Color?

    private var samplesDepthColor: Bool {
        DetailTileFocus.samplesRailColor(depthTakesPosterColor: focusAppearance.depthTakesPosterColor,
                                         depthEnabled: depthStyle.isEnabled(for: .posters),
                                         artworkURL: imageURL)
    }

    // FEAT-26: 180×270 — the same miniPoster size as More Like This, so the season row no longer
    // reads as the smallest tile on the detail screen (it shipped at 120×180).
    private static let width: CGFloat = Theme.Size.miniPosterWidth
    private static let height: CGFloat = Theme.Size.miniPosterHeight

    /// beta.19-rc1 verdict (review r1, I1): the decode size the card's artwork is drawn at. This batch
    /// moved the Kotlin season poster to TMDB w780 (780x1170); left on the unsized `.legacy` decode
    /// (a 1920 px cap) each one became a ~3.6 MB bitmap for a 180x270 pt card. Sized to the drawn
    /// frame (points x displayScale, 540 px long side at scale 2, bucketed to 640) it is the same
    /// request `PosterCard.decodeRequest` builds for a poster of this size. No `upgrade:` here: the
    /// shared parser already hands over the larger rendition.
    static let decodeSize: ArtworkDecodeSize = .points(width: width, height: height)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                if let imageURL, !imageURL.isEmpty {
                    CachedAsyncImage(string: imageURL, decodeSize: Self.decodeSize)
                        .onImageLoaded { _ in
                            DetailTileRailTint.imageLoaded(samples: samplesDepthColor, source: imageURL) { color in
                                if depthRailTint != color { depthRailTint = color }
                            }
                        }
                } else {
                    Theme.Palette.surface
                    // FEAT-26: at 180×270 the caption2 label got lost in the empty surface — meta
                    // (caption semibold) with md padding gives the placeholder some presence.
                    Text(label)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(Theme.Spacing.md)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: posterStyle.cornerRadius))
            // BUG-177 (Steven rc7): the selection stroke now sits UNDER the depth layer (it used
            // to be stroked over the rail and hide it on every card). The selected season keeps its
            // 4 pt accent outline; the rail draws its thin highlight over the outline's top edge.
            .overlay {
                RoundedRectangle(cornerRadius: posterStyle.cornerRadius)
                    .strokeBorder(isSelected ? Theme.Palette.accent : Color.white.opacity(0.10), lineWidth: isSelected ? 4 : 1)
            }
            // FEAT-26: these cards were the only detail tiles without the card-depth treatment —
            // same surface as the poster rows, attached to the artwork like EpisodeThumbCard.
            .nuvioCardDepth(RoundedRectangle(cornerRadius: posterStyle.cornerRadius), surface: .posters,
                            railTint: DetailTileRailTint.resolved(samples: samplesDepthColor,
                                                                  source: imageURL,
                                                                  sampled: depthRailTint))
            // BUG-177: draws the accent ring and owns its lift in ring mode (`DetailTileFocusLift`).
            .detailTileFocusLift(cornerRadius: posterStyle.cornerRadius,
                                 size: CGSize(width: Self.width, height: Self.height),
                                 tintSource: imageURL)

            Text(label)
                .font(Theme.Font.cardTitle)
                .foregroundStyle(isFocused || isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
                // UX-15 (beta.13 review, frame-verified at t=77.5): the system lift grows the
                // artwork's bottom edge over this caption. Same fix as PosterCard's BUG-54
                // treatment — the focused caption drops by the lift's bottom expansion.
                .modifier(CardCaptionFocusDrop(
                    mode: CardFocusMode.resolve(accentFocusRing: focusAppearance.accentFocusRing,
                                                noZoomOnFocus: focusAppearance.noZoomOnFocus),
                    isFocused: isFocused,
                    artworkHeight: Self.height
                ))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Review r1 #4: see `EpisodesSection.airedCountCache`. Today's date is read once per Detail visit
/// (the section's lifetime), the count once per key.
/// See `EpisodesSection.groupingCache`. Holds the `MetaDetails` it was built from (a strong
/// reference, so identity can't be confused with a freed object's reused address); a new object
/// (enrichment, a reload) rebuilds. Filling it never invalidates the view.
final class EpisodeGroupingCache {
    struct Grouping {
        let grouped: [Int: [MetaVideo]]
        let seasons: [Int]
        let posterBySeason: [Int: String?]
        /// FEAT-83 (review r1 P3-9): see `EpisodesSection.seasonsWithReleasedEpisodes`.
        let releasedSeasons: Set<Int>
    }

    private var source: MetaDetails?
    private var cached: Grouping?

    func resolve(_ meta: MetaDetails, build: (MetaDetails) -> Grouping) -> Grouping {
        if let cached, source === meta { return cached }
        let next = build(meta)
        source = meta
        cached = next
        return next
    }
}

final class AiredUnwatchedCountCache {
    struct Key: Equatable {
        /// Review r2 #4: the meta's stable id, not `ObjectIdentifier(meta)` — the cache does not
        /// retain the meta, so a freed object's address could be reused by a different title.
        let metaId: String
        let season: Int?
        let episodeCount: Int
        let watchedKeys: Set<String>
    }

    private var key: Key?
    private var cached = 0
    private lazy var todayIsoDate: String = CurrentDateProvider.shared.todayIsoDate()

    func count(key: Key, compute: (String) -> Int) -> Int {
        if let existing = self.key, existing == key { return cached }
        cached = compute(todayIsoDate)
        self.key = key
        return cached
    }
}
