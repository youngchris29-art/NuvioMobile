import SharedCore
import SwiftUI
import UIKit

// Home Stage & Strip (P1 §1): the Stage layout of Home, mounted by `HomeView` (E5) in place of
// Classic's rows region when Home Layout is Stage.
//
//     StageStripHome                              ZStack(.topLeading), ignores the safe area
//     ├─ layer 0   AmbientWashLayer               the blurred wash of the stage's title (S8)
//     ├─ StageView                                art (full screen, alpha-masked), text block
//     └─ VStack
//        ├─ Color.clear  stageHeight              the stage block's place: nothing focusable
//        └─ StripPager   stripHeight              one row per page, the next heading peeking
//
// Everything else on `HomeView`'s body still applies and is wanted: its `NavigationStack(path:)`,
// the `.navigationDestination`s, the Continue Watching `.fullScreenCover`, `model.acquire()` /
// `release()` and `startUpcoming()`. This view must NOT acquire the model.
//
// None of Classic's pinned machinery is mounted here (P1 §1.2): rows get no pinned environment, so
// their reaches stay 0 and their headings are the plain `Text` above the shelf (with the add-on's
// name after a catalog heading, W2-A §5).
//
// W2-A (§7): this view is the ONLY place the stage's background trailer is armed. Every gate it
// depends on arrives through `onReceive` / `onChange` (the swap output's rest, the focus commit, the
// covers, the scene, the setting, the system autoplay preference, the chrome) and goes through one
// funnel, `syncBackgroundTrailer`. No trailer or swap state is read in `body` (only the setting and
// `scenePhase`, neither of which moves with focus), so the strip never re-renders for a rest, an arm
// or a trailer start.

/// What the strip's rows can ask Home's navigation to do.
struct StageHomeActions {
    /// Continue Watching: open the stream picker (`HomeView.resume`).
    let resume: (ResumeTarget) -> Void
    /// Push onto Home's stack (`HomeView.homePath`).
    let push: (TitleRoute) -> Void
}

/// What covers Home from `HomeView`'s own presentation machinery (the shell is read separately).
nonisolated struct StageCover: Equatable {
    /// Something is pushed over Home (`!homePath.isEmpty`).
    var pushed: Bool
    /// The Continue Watching stream picker is up.
    var resume: Bool
}

/// See the file header.
struct StageStripHome: View {
    @ObservedObject var model: HomeViewModel
    let actions: StageHomeActions
    let cover: StageCover
    /// `HomeView.isScrolledDown`: `rowIndex > 0`, written only when it changes (§6).
    @Binding var isScrolledDown: Bool

    /// Held for its lifetime, never observed: it publishes nothing (#5).
    @StateObject private var stage = StageController()
    /// H9 (P4 R2): the Stage rail route's own state (the captured row, Home's cover), in a reference
    /// box so neither write re-renders the strip.
    @State private var railRouteBox = StageRailRouteBox()
    /// R1: the rail's content shift (36 with the rail Always Visible, from `.railTabRoot`; else 0).
    @Environment(\.railLeadingInset) private var railLeadingInset
    @Environment(\.posterStyle) private var posterStyle
    /// Held, never observed (HomeView's rule): read at Menu-press time, in the page-start write and
    /// in the trailer gate only. The rail (H9) is its only observer.
    @Environment(\.navigationChrome) private var navigationChrome
    /// Held, never observed: the shell cover arrives through `onReceive`.
    @Environment(\.tabBarVisibility) private var tabBarVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// §7: the background trailer plays only while the scene is active (read at the event, and its
    /// changes re-run the trailer funnel).
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("home_upcoming_row_enabled") private var upcomingRowEnabled = true
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false
    @AppStorage("trailer_playback_location") private var trailerPlaybackLocation = "poster"

    /// Classic's row keys, so `pinnedRowUpFallbackTarget(rowKey:)` and the focus memory agree.
    static let continueWatchingKey = "continue-watching"
    static let upcomingKey = "upcoming"

    var body: some View {
        let geo = geometry
        let keys = rowKeys
        ZStack(alignment: .topLeading) {
            // Layer 0 (S8): the ambient wash. It observes the swap driver's wash feed itself, so
            // this view never re-renders on a swap (#5); switched off, it draws nothing and the
            // page background shows through.
            AmbientWashLayer(feed: stage.swap.washFeed)
            StageView(controller: stage, geometry: geo)
            VStack(spacing: 0) {
                // The stage block's place. Nothing focusable lives here, so Up from row 0 goes to
                // the tab bar (in Rail mode Up has no target there and never reveals, §6).
                Color.clear
                    .frame(height: geo.stageHeight)
                    .allowsHitTesting(false)
                strip(keys: keys, geometry: geo)
                    .frame(height: geo.stripHeight)
            }
            #if DEBUG
            StripDebugLabel(debug: stage.swap.debug)
            StageTrailerDebugLabel(debug: stage.swap.debug)
            #endif
        }
        // Kept exactly as the spike had it: the strip's page arithmetic is in full-screen points.
        .ignoresSafeArea()
        // The stage frame changes only with a settings change (Poster Size, Hide Titles, No Zoom,
        // font), animated like Classic's plan animation; never with a swap or a page.
        .animation(.easeInOut(duration: 0.28), value: geo)
        .onAppear {
            stage.start()
            stage.swap.setReduceMotion(reduceMotion)
            stage.bgTrailer.prefersReducedMotion = reduceMotion
            // §7: where Trailers on Focus plays in Stage, stated once on mount and once per actual
            // flip (`.onChange` below), never per render.
            Self.logTrailerLocation(background: backgroundTrailerMode)
        }
        .onDisappear {
            // Home Layout switched to Classic (or the shell went away): the player slot goes back.
            stage.stopBackgroundTrailer(reason: "disappear")
        }
        .onChange(of: reduceMotion) { _, motion in
            stage.swap.setReduceMotion(motion)
            stage.bgTrailer.prefersReducedMotion = motion
        }
        // §5: Home's Continue Watching row, as the stage copy's lookup (the folder page installs
        // none). `@Published` emits on willSet: use the payload. An unchanged republish is a no-op.
        .onReceive(model.$continueWatching) { entries in
            stage.setContinueWatching(entries)
        }
        // §7 arm/teardown. The swap output's `restingKey` going non-nil is the rest the trailer arms
        // on; any focus activity or page start clears it, which tears the trailer down. Payload, not
        // the property (willSet).
        .onReceive(stage.swap.$output) { output in
            stageOutputChanged(output)
        }
        // §7: the focus commit the arming rule checks the rest against (a See All tile or an
        // art-less folder leaves the stage on the previous title).
        .onReceive(stage.focusModel.$focusedItem) { item in
            syncBackgroundTrailer(reason: "focus", focused: .some(item))
        }
        // §7: the chrome taking focus stops the trailer (the rail, H9; R2's teardown).
        .onReceive(navigationChrome.$isFocusedChrome) { focused in
            syncBackgroundTrailer(reason: "chrome", chromeFocused: focused)
        }
        // §7: tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews, read live by the funnel; its
        // change notification re-runs it (HomeView's `systemVideoAutoplayEnabled` rule, without the
        // `@State` mirror: nothing here reads it in `body`).
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
            syncBackgroundTrailer(reason: "autoplay")
        }
        .onChange(of: scenePhase) { _, phase in
            syncBackgroundTrailer(reason: "scene", scene: phase)
        }
        .onChange(of: backgroundTrailerMode) { _, mode in
            Self.logTrailerLocation(background: mode)
            syncBackgroundTrailer(reason: "mode")
        }
        // §4.3 seed: once the rows gate opens, the first strip row's first item (the card tvOS
        // focuses at launch), so the first commit is a silent gap-fill: no double paint.
        .onChange(of: seedSignature, initial: true) { _, _ in
            stage.seed(seedItem)
        }
        .onChange(of: keys) { _, newKeys in
            stage.memory.prune(keeping: Set(newKeys))
        }
        .onChange(of: geo, initial: true) { _, newGeometry in
            StageStripProbe.shared.logGeometry(newGeometry)
        }
        // HomeView's `syncHeroFocusCover` rule: a push or the stream picker restores row focus when it
        // lifts; the shell alone (a tab switch, a cross-stack cover) does not.
        .onChange(of: cover, initial: true) { _, _ in
            syncCover(shell: nil)
        }
        .onReceive(tabBarVisibility.$homeSurfaceCovered) { covered in
            // `@Published` emits on willSet: use the payload, not the property.
            syncCover(shell: covered)
        }
        // H9 (P4 §2.5, R2): Stage's rail return route, registered while the Stage layout is mounted.
        // Rail mode only; nothing is registered in Tabs mode.
        .railReturnRoute { stageRailRoute }
    }

    // MARK: Geometry

    private var geometry: StripGeometry {
        StripGeometry.make(.live(style: posterStyle, noZoom: noZoomOnFocus, leadingInset: railLeadingInset))
    }

    // MARK: Rows

    /// Classic's row order and keys: Continue Watching (non-empty), Upcoming (on and non-empty), then
    /// `model.rows` as `section.key` / the bare `collection.id`. Deduplicated defensively: a repeated
    /// key would break the strip's `ForEach`.
    private var rowKeys: [String] {
        var keys: [String] = []
        var seen = Set<String>()
        if !model.continueWatching.isEmpty, seen.insert(Self.continueWatchingKey).inserted {
            keys.append(Self.continueWatchingKey)
        }
        if upcomingRowEnabled, !model.upcoming.isEmpty, seen.insert(Self.upcomingKey).inserted {
            keys.append(Self.upcomingKey)
        }
        for row in model.rows {
            let key: String
            switch row {
            case .catalog(let section): key = section.key
            case .collection(let collection): key = collection.id
            }
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    private func homeRow(for key: String) -> HomeRow? {
        model.rows.first { row in
            switch row {
            case .catalog(let section): return section.key == key
            case .collection(let collection): return collection.id == key
            }
        }
    }

    @ViewBuilder
    private func strip(keys: [String], geometry geo: StripGeometry) -> some View {
        if keys.isEmpty {
            StageStripPlaceholder(model: model)
                .padding(.leading, geo.contentLeading)
                .padding(.top, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Review r1 (B P3-6): Menu with the add-on error's Retry focused opens the rail in
                // Rail mode, as at the strip's row 0 (and Classic's top). nil in Tabs mode.
                .onExitCommand(perform: atTopExit)
        } else {
            StripPager(rowKeys: keys,
                       geometry: geo,
                       controller: stage,
                       linksTabBar: true,
                       reportsTab: "Home",
                       menuPagesToTop: true,
                       atTopExit: atTopExit,
                       onRowChange: { index, _ in
                           let down = index > 0
                           if isScrolledDown != down { isScrolledDown = down }
                           // §7: a strip row owns focus again (also when focus comes back from the
                           // tab bar, the rail or a pushed page); the trailer re-arms at the rest.
                           stage.stripFocusGained()
                       },
                       // H9 (#8, R4): Hide While Browsing moves with the strip's page — its curve
                       // and duration, no resting settle. This write owns the rail; the strip's
                       // `reportsScrollToTabBar` mirror (kept for TabBarStateProbe) writes the same
                       // value at its later crossing, a no-op under write-on-change.
                       onPageStart: { index, seconds in
                           guard NavigationChrome.isRail() else { return }
                           navigationChrome.setScrolledDown(tab: 0, index > 0, motion: .page(seconds: seconds))
                       },
                       onStripFocusLost: { stage.stripFocusLost() }) { key in
                rowView(key)
            }
            // #23: a synced Poster Size too tall for the stage's 420 pt floor is laid out at the
            // largest height that fits, a re-layout of every row (they all read `\.posterStyle`).
            .environment(\.posterStyle, geo.fits ? posterStyle : posterStyle.withHeight(geo.layoutPosterHeight))
            // D1: settings only (Trailers on Focus + Background), never per focus (the BUG-19 rule).
            .environment(\.trailerPlaysInHero, backgroundTrailerMode)
            // §5 (Stage only): catalog headings carry their add-on's name ("Popular · Cinemeta").
            .environment(\.rowHeadingShowsAddon, true)
        }
    }

    @ViewBuilder
    private func rowView(_ key: String) -> some View {
        if key == Self.continueWatchingKey {
            continueWatchingRow
        } else if key == Self.upcomingKey {
            upcomingRow
        } else if let row = homeRow(for: key) {
            switch row {
            case .catalog(let section):
                catalogRow(section)
            case .collection(let collection):
                collectionRow(collection)
            }
        }
    }

    private var continueWatchingRow: some View {
        ContinueWatchingRow(
            entries: model.continueWatching,
            onSelect: { actions.resume(ResumeTarget(entry: $0)) },
            onRemove: { WatchProgressRepository.shared.clearProgress(videoId: $0.videoId, parentMetaId: $0.parentMetaId) },
            onGoToDetails: { actions.push(TitleRoute(preview: HomeRowPreviews.entry($0))) },
            onPlayManually: { actions.resume(ResumeTarget(entry: $0, forceManual: true)) },
            onStartOver: { actions.resume(ResumeTarget(entry: $0, startFromBeginning: true)) },
            onMarkWatched: { entry in
                // Classic's pair: the episode joins watched history and its half-played progress
                // row stops showing in the shelf.
                WatchedRepository.shared.markWatched(
                    item: WatchingActionsKt.watchedItemFromProgress(
                        entry: entry,
                        markedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                )
                WatchProgressRepository.shared.clearProgress(videoId: entry.videoId, parentMetaId: entry.parentMetaId)
            },
            shuffleParentIds: model.shuffleParentIds,
            posterPattern: model.continueWatchingPosterPattern,
            onItemFocusChange: { entry in
                stage.report(entry.map { StageCopy.preview(from: $0) },
                             source: Self.continueWatchingKey,
                             prefetch: { model.continueWatching.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
            }
        )
    }

    private var upcomingRow: some View {
        UpcomingRow(items: model.upcoming, onItemFocusChange: { item in
            stage.report(item?.toMetaPreview(),
                         source: Self.upcomingKey,
                         prefetch: { model.upcoming.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0.toMetaPreview()) } })
        })
    }

    private func catalogRow(_ section: HomeCatalogSection) -> some View {
        CatalogRowView(
            section: section,
            previewLimit: CatalogRowView.homePreviewLimit,
            onItemFocusChange: { item in
                stage.report(item,
                             source: section.key,
                             logoCandidates: {
                                 section.items.prefix(CatalogRowView.homePreviewLimit)
                                     .filter { TitleLogoStore.isLookupCandidate($0.logo) }
                             },
                             prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
            }
        )
        // BUG-35: localize this row's leading items when it scrolls into view.
        .onAppear { model.rowAppeared(sectionKey: section.key) }
    }

    private func collectionRow(_ collection: NuvioCollection) -> some View {
        CollectionRowView(collection: collection, onFolderFocusChange: { folder in
            // A folder with neither a backdrop nor a logo reports nil, and the stage keeps its title.
            stage.report(folder.flatMap { HomeRowPreviews.folder(collection: collection, folder: $0) },
                         source: collection.id,
                         prefetch: { HomeRowPreviews.collectionArtURLs(collection) })
        })
        // Wave H: warm every folder's hero art when the ROW appears, not on first focus.
        .onAppear { stage.rowAppeared(collection: collection) }
    }

    // MARK: Seed (§4.3)

    /// The first strip row's first item once the rows gate is open; when that item has no stage
    /// preview (a collection folder with neither a backdrop nor a logo), the next row's, so a
    /// collection-first Home still opens on a title.
    private var seedItem: MetaPreview? {
        guard model.rowsGateOpen else { return nil }
        for key in rowKeys {
            if let item = firstPreview(ofRow: key) { return item }
        }
        return nil
    }

    private var seedSignature: String {
        guard let item = seedItem else { return "-" }
        return "\(item.type):\(item.id)"
    }

    private func firstPreview(ofRow key: String) -> MetaPreview? {
        if key == Self.continueWatchingKey {
            return model.continueWatching.first.map { StageCopy.preview(from: $0) }
        }
        if key == Self.upcomingKey {
            return model.upcoming.first?.toMetaPreview()
        }
        guard let row = homeRow(for: key) else { return nil }
        switch row {
        case .catalog(let section):
            return section.items.first
        case .collection(let collection):
            return collection.folders.first.flatMap { HomeRowPreviews.folder(collection: collection, folder: $0) }
        }
    }

    // MARK: Chrome

    /// Menu at row 0 (§6, P4 R3): in Rail mode, open the rail (HomeView's `railMenuRevealHandler`
    /// rule); in Tabs mode nil, so the system default applies (focus to the tab bar, then exit). From
    /// any later row Menu still pages to row 0 first (the strip's own handler). Inside a rail Menu
    /// opened, Menu is the system default (R4). Up at row 0 has no target in Rail mode and never
    /// reveals (BUG-98).
    private var atTopExit: (() -> Void)? {
        guard NavigationChrome.isRail() else { return nil }
        let chrome = navigationChrome
        return {
            // Read at press time, not as a body dependency.
            guard !chrome.isFocusedChrome else { return }
            chrome.requestReveal(.menu)
        }
    }

    /// H9 (P4 §2.5, R2): where a rail exit puts focus back on Stage Home. `capture` records the row
    /// that owns the strip (`currentRowKey`, kept after focus leaves the strip); `restore` asks the
    /// pager for that row's remembered card through P1's rungs (`requestFocus(rowKey:itemId:)`
    /// moves the mounted window to the row before asking it for focus). A Left entry comes from card
    /// 0, which the memory then holds. Declines while a push or the Continue Watching picker covers
    /// Home. A tab switch back to Home with nothing captured this session falls to the live row.
    private var stageRailRoute: RailReturnRoute {
        let controller = stage
        let box = railRouteBox
        return RailReturnRoute(
            name: "home",
            capture: { box.savedRow = controller.currentRowKey },
            restore: {
                guard !box.covered, let row = box.savedRow ?? controller.currentRowKey else { return false }
                controller.requestFocus(rowKey: row, itemId: controller.memory.itemId(for: row))
                return true
            },
            vetoesLeftArm: { false }
        )
    }

    /// D1: the rows skip the in-row morph when the trailer plays in the stage (W2-A).
    private var backgroundTrailerMode: Bool {
        inlineTrailersEnabled && trailerPlaybackLocation == "hero"
    }

    private func syncCover(shell: Bool?) {
        let restoresFocus = cover.pushed || cover.resume
        // H9: the Stage rail route declines while Home is covered by a push or the stream picker.
        railRouteBox.covered = restoresFocus
        stage.setCovered(restoresFocus || (shell ?? tabBarVisibility.homeSurfaceCovered),
                         restoresFocus: restoresFocus)
        // §7: any cover stops the background trailer; lifting one lets the next rest arm it again.
        syncBackgroundTrailer(reason: "cover", shellCovered: shell)
    }

    // MARK: Background trailer (W2-A, §7)

    /// `[TrailerPipeline] trailerLocation stage=bg|row`: `bg` = the stage's background trailer
    /// (Trailer Location "hero"), `row` = the in-row morph (or nothing, with Trailers on Focus off).
    /// Classic's own `trailerLocation heroMode=` line is HomeView's.
    private static func logTrailerLocation(background: Bool) {
        NSLog("[TrailerPipeline] trailerLocation stage=%@", background ? "bg" : "row")
    }

    /// The swap output changed (a payload from willSet). `restingKey` going non-nil is the rest the
    /// trailer arms on; any focus activity or page start clears it, which tears the trailer down.
    private func stageOutputChanged(_ output: StageSwapOutput) {
        let reason = output.restingKey == nil ? "activity" : "rest"
        syncBackgroundTrailer(reason: reason, output: output)
    }

    /// The background trailer's one funnel: builds the gate from what this view knows and hands it,
    /// with the swap output and the committed focus, to `StageController.syncBackgroundTrailer`,
    /// which arms or tears down on change only. A caller fed by a `@Published` publisher passes the
    /// value it was handed (the publisher fires in willSet, so the property still holds the old
    /// value); everything else is read live, here, at the event, never through `body`.
    ///
    /// Arm: the trailer setting, the system autoplay preference, an active scene, nothing covering
    /// Home, a strip row owning focus, the chrome not holding it, and the stage at rest on the
    /// focused, non-folder title (`StageTrailerGate`). Trailer Start Delay then runs as the dwell
    /// (M4): Automatic starts it 1 s after the strip's rest, a fixed N counts from this arm.
    private func syncBackgroundTrailer(reason: String,
                                       output: StageSwapOutput? = nil,
                                       focused: MetaPreview?? = nil,
                                       shellCovered: Bool? = nil,
                                       chromeFocused: Bool? = nil,
                                       scene: ScenePhase? = nil) {
        let gate = StageTrailerGate(
            modeOn: backgroundTrailerMode,
            autoplayAllowed: UIAccessibility.isVideoAutoplayEnabled,
            sceneActive: (scene ?? scenePhase) == .active,
            covered: cover.pushed || cover.resume || (shellCovered ?? tabBarVisibility.homeSurfaceCovered),
            stripOwnsFocus: stage.stripOwnsFocus,
            chromeHoldsFocus: chromeFocused ?? navigationChrome.isFocusedChrome
        )
        stage.syncBackgroundTrailer(gate,
                                    output: output ?? stage.swap.output,
                                    focused: focused ?? stage.focusModel.focusedItem,
                                    reason: reason)
    }
}

/// H9 (P4 R2): the Stage rail route's state. A reference box (never observed), so the captured row
/// and the cover flag never re-render the strip.
@MainActor
final class StageRailRouteBox {
    /// The strip row that owned focus when the rail armed (nil until the first capture).
    var savedRow: String?
    /// A push or the Continue Watching picker covers Home (`StageCover`).
    var covered = false
}

/// Before any strip row exists: a copy of `HomeView`'s private `placeholder` (loading, error, the
/// add-on error with its focusable Retry chip — the BUG-47 anchor — and setting up).
struct StageStripPlaceholder: View {
    @ObservedObject var model: HomeViewModel

    var body: some View {
        if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Loading catalogs\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.errorMessage {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.addonManifestError {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Couldn't load your add-ons.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.accent)
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                Button {
                    AddonRepository.shared.refreshAll()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else {
            Text("Setting up your catalogs\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        }
    }
}
