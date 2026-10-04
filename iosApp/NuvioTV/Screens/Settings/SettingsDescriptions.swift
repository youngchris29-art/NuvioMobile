import SwiftUI

// MARK: - Settings description catalog (FEAT-50, detail-settings-revamp W1-B)
//
// The ONE place the Settings explainer copy lives: every focusable Settings row that carries a
// description names a `SettingsDescriptionID`, and the explainer column on the left of each pane
// shows `SettingsDescriptions.text(for:)` for the focused row (pane summary otherwise). Keeping it
// in one file is what lets the copy be reviewed and translated in one pass (W3-A / W3-B).
//
// Rules for authors:
// - Ids are passed as a LITERAL `.caseName` at the call site (to a `descriptionID` parameter,
//   or as the first argument of the `settingsDescription` modifier), never computed.
//   `SettingsDescriptionsTests` scans the Settings sources for those literals to prove every id
//   here is used, so don't quote a literal call in a comment in this folder either.
// - Raw values are stable dotted strings (`home.showHero`); the case name is the raw value
//   camel-cased with the dots dropped.
// - Copy is written as `LocalizedStringResource("English text")` so the compiler emits it to
//   `.stringsdata` and the populate script picks it up (the catalog key IS the English text).
//
// Copy follows the house copy rule: short, plain, says what the row does and its default.

enum SettingsDescriptionID: String, CaseIterable {

    // MARK: Account & Profiles
    case accountSignInOut = "account.signInOut"
    case accountConnectServer = "account.connectServer"
    case accountUseOfficialServer = "account.useOfficialServer"
    case accountRemoteSetup = "account.remoteSetup"

    // MARK: Services
    case servicesTrakt = "services.trakt"
    case servicesActivationCancel = "services.activationCancel"
    case servicesSimkl = "services.simkl"
    case servicesSimklSyncNow = "services.simklSyncNow"
    case servicesSimklSyncInfo = "services.simklSyncInfo"
    case servicesSimklAnimeId = "services.simklAnimeId"
    case servicesMdblist = "services.mdblist"
    case servicesMoreLikeThisSource = "services.moreLikeThisSource"
    case servicesDebridProvider = "services.debridProvider"
    case servicesDebridDismiss = "services.debridDismiss"
    case servicesDebridKey = "services.debridKey"
    case servicesDebridResolve = "services.debridResolve"
    case servicesDebridPrepare = "services.debridPrepare"
    case servicesDebridResolver = "services.debridResolver"

    // MARK: Appearance
    case appearanceTheme = "appearance.theme"
    case appearanceAccentFocusRing = "appearance.accentFocusRing"
    case appearanceRingPosterColor = "appearance.ringPosterColor"
    case appearanceDepthPosterColor = "appearance.depthPosterColor"
    case appearanceNoZoomOnFocus = "appearance.noZoomOnFocus"
    case appearanceOledBlack = "appearance.oledBlack"
    // beta.19-rc1 verdict (F, FEAT-54): the row edge fade, promoted from the Developer A/B.
    case appearanceRowEdgeFade = "appearance.rowEdgeFade"
    case appearanceSettingsStyle = "appearance.settingsStyle"
    case appearanceNavigation = "appearance.navigation"
    case appearanceTypeface = "appearance.typeface"
    case appearancePosterSize = "appearance.posterSize"
    case appearancePosterCorners = "appearance.posterCorners"
    case appearanceHideTitles = "appearance.hideTitles"
    case appearanceLandscapeRows = "appearance.landscapeRows"
    case appearancePosterReset = "appearance.posterReset"
    case appearanceHideHeroArtwork = "appearance.hideHeroArtwork"
    case appearanceCustomPosters = "appearance.customPosters"
    case appearanceCardDepth = "appearance.cardDepth"
    case appearanceCardDepthEdge = "appearance.cardDepthEdge"
    case appearanceCardDepthSheen = "appearance.cardDepthSheen"
    case appearanceCardDepthCoverage = "appearance.cardDepthCoverage"
    case appearanceCardDepthSurface = "appearance.cardDepthSurface"
    case appearanceCardDepthReset = "appearance.cardDepthReset"
    case appearanceBadgesFileSize = "appearance.badgesFileSize"
    case appearanceBadgesAddonLogo = "appearance.badgesAddonLogo"
    case appearanceBadgesAboveTitle = "appearance.badgesAboveTitle"
    case appearanceBadgePack = "appearance.badgePack"
    case appearanceBadgeImport = "appearance.badgeImport"

    // MARK: Home Screen (ids wired in HomeScreenSettingsPane by W1-B)
    case homeUpcoming = "home.upcoming"
    case homeRefreshAddons = "home.refreshAddons"
    case homeShowHero = "home.showHero"
    case homeNuvioStyleHero = "home.nuvioStyleHero"
    case homeHeroSources = "home.heroSources"
    case homeHeroSource = "home.heroSource"
    case homeTrailersOnFocus = "home.trailersOnFocus"
    case homeTrailerLocation = "home.trailerLocation"
    case homeHeroTrailerAutoplay = "home.heroTrailerAutoplay"
    // beta.19-rc1 verdict (M4, FEAT-52): the row lives in HomeScreenSettingsPane (spec A, W2-D).
    case homeTrailerStartDelay = "home.trailerStartDelay"
    case homeCatalogType = "home.catalogType"
    case homeCatalogs = "home.catalogs"
    case homeCatalog = "home.catalog"

    // MARK: Detail Page (names follow DetailSettingsKeys; the pane itself is W2-B)
    case detailLayout = "detail.layout"
    case detailIconOnlyButtons = "detail.iconOnlyButtons"
    case detailPosterBackdrop = "detail.posterBackdrop"
    case detailTrailerAutoplay = "detail.trailerAutoplay"
    case detailTrailerBackground = "detail.trailerBackground"
    case detailTrailerDuration = "detail.trailerDuration"
    case detailTrailerSound = "detail.trailerSound"
    case detailEpisodeRatings = "detail.episodeRatings"
    case detailHideEpisodeSpoilers = "detail.hideEpisodeSpoilers"
    case detailSectionStudioLogos = "detail.sectionStudioLogos"
    case detailSectionParentalGuide = "detail.sectionParentalGuide"
    case detailSectionRatings = "detail.sectionRatings"
    case detailSectionCast = "detail.sectionCast"
    case detailSectionCollection = "detail.sectionCollection"
    case detailSectionTrailers = "detail.sectionTrailers"
    case detailSectionMoreLikeThis = "detail.sectionMoreLikeThis"
    case detailSectionComments = "detail.sectionComments"
    case detailSectionAbout = "detail.sectionAbout"

    // MARK: Player
    case playerDefaultPlayer = "player.defaultPlayer"
    case playerSkipIntro = "player.skipIntro"
    case playerAutoSkipIntro = "player.autoSkipIntro"
    case playerAutoSkipRecap = "player.autoSkipRecap"
    case playerAutoSkipOutro = "player.autoSkipOutro"
    case playerAutoSkipCredits = "player.autoSkipCredits"
    case playerEpisodeShuffle = "player.episodeShuffle"
    case playerPauseInfoCard = "player.pauseInfoCard"
    case playerMatchFrameRate = "player.matchFrameRate"
    case playerEnhancedRenderer = "player.enhancedRenderer"
    case playerNativeDolbyVision = "player.nativeDolbyVision"
    case playerP7FelMpv = "player.p7FelMpv"
    case playerStreamingBuffer = "player.streamingBuffer"
    case playerNetworkReadahead = "player.networkReadahead"
    case playerPreloadNextEpisode = "player.preloadNextEpisode"

    // MARK: Sources
    case sourcesAutoPlayBest = "sources.autoPlayBest"
    case sourcesAutoPlayCachedOnly = "sources.autoPlayCachedOnly"
    case sourcesSort = "sources.sort"
    case sourcesMinResolution = "sources.minResolution"
    case sourcesDvFilter = "sources.dvFilter"
    case sourcesHdrFilter = "sources.hdrFilter"
    case sourcesCachedOnlyFilter = "sources.cachedOnlyFilter"
    case sourcesTmdbEnrichment = "sources.tmdbEnrichment"
    case sourcesTmdbKey = "sources.tmdbKey"
    case sourcesTmdbReleaseDates = "sources.tmdbReleaseDates"
    case sourcesTmdbLanguage = "sources.tmdbLanguage"
    case sourcesMdblistRatings = "sources.mdblistRatings"
    case sourcesMdblistKey = "sources.mdblistKey"
    case sourcesLibrarySource = "sources.librarySource"
    case sourcesWatchProgressSource = "sources.watchProgressSource"
    case sourcesRecentSearches = "sources.recentSearches"
    case sourcesHideDiscover = "sources.hideDiscover"
    case sourcesSearchCatalog = "sources.searchCatalog"
    case sourcesPluginsEnabled = "sources.pluginsEnabled"
    case sourcesPluginRepoAdd = "sources.pluginRepoAdd"
    case sourcesPluginRepo = "sources.pluginRepo"
    case sourcesPluginScraper = "sources.pluginScraper"
    case sourcesPluginsRefresh = "sources.pluginsRefresh"

    // MARK: Subtitles & Audio
    case subtitlesTextColor = "subtitles.textColor"
    case subtitlesSize = "subtitles.size"
    case subtitlesBackground = "subtitles.background"
    case subtitlesBold = "subtitles.bold"
    case subtitlesOutline = "subtitles.outline"
    case subtitlesStripSdh = "subtitles.stripSdh"
    case subtitlesAudioLanguage = "subtitles.audioLanguage"
    case subtitlesSubtitleLanguage = "subtitles.subtitleLanguage"

    // MARK: About
    case aboutVersion = "about.version"
    case aboutBuild = "about.build"
    case aboutCommit = "about.commit"
    case aboutTvos = "about.tvos"
    case aboutDevice = "about.device"
    case aboutSource = "about.source"
    case aboutFonts = "about.fonts"

    // MARK: Developer
    case devHeroPaint = "dev.heroPaint"
    case devTabBarDiag = "dev.tabBarDiag"
    case devHardTopEdge = "dev.hardTopEdge"
    case devStreamDiag = "dev.streamDiag"
    case devTrailerDiag = "dev.trailerDiag"
    case devTrailerCacheReset = "dev.trailerCacheReset"
    case devDetailScrollAB = "dev.detailScrollAB"
    case devDetailScrollProbe = "dev.detailScrollProbe"
    case devTrailerMaxFps = "dev.trailerMaxFps"
    case devTrailerBuffer = "dev.trailerBuffer"
    case devTrailerLetterbox = "dev.trailerLetterbox"
    case devCollectionProbe = "dev.collectionProbe"
    case devCollectionProbeClear = "dev.collectionProbeClear"
    case devCollectionAB = "dev.collectionAB"
    case devRowSettle = "dev.rowSettle"
    case devTabBarGeometry = "dev.tabBarGeometry"
    case devNoZoomReach = "dev.noZoomReach"
    case devShortRowFloor = "dev.shortRowFloor"
    case devTabBarScrollLink = "dev.tabBarScrollLink"
    case devTabBarRestFix = "dev.tabBarRestFix"
}

enum SettingsDescriptions {
    /// Exhaustive switch: the compiler guarantees every id has copy.
    static func text(for id: SettingsDescriptionID) -> LocalizedStringResource {
        switch id {

        // Account & Profiles
        case .accountSignInOut: return LocalizedStringResource("Signs you in to, or out of, your Nuvio account. Signing in syncs your library and watch progress across devices. Either way, the local data on this Apple TV is cleared first.")
        case .accountConnectServer: return LocalizedStringResource("Points this Apple TV at a self-hosted Nuvio backend instead of the official one. Switching servers signs you out and clears local data on this Apple TV.")
        case .accountUseOfficialServer: return LocalizedStringResource("Switches back to the official Nuvio server at api.nuvio.tv. You are signed out and local data on this Apple TV is cleared.")
        case .accountRemoteSetup: return LocalizedStringResource("Starts a small web page on your home network so you can manage add-ons, Home rows, API keys and badge packs from a phone or laptop. Nothing changes until you confirm it here on the TV.")

        // Services
        case .servicesTrakt: return LocalizedStringResource("Connect shows a short code to enter at trakt.tv/activate. Once connected, what you watch here is marked watched on Trakt automatically. Press again to disconnect.")
        case .servicesActivationCancel: return LocalizedStringResource("Stops waiting for the code to be approved and goes back to the connect options. You can ask for a new code afterwards.")
        case .servicesSimkl: return LocalizedStringResource("Connect shows a short code to enter at simkl.com/pin. Once connected, what you watch here is marked watched on Simkl automatically. Press again to disconnect.")
        case .servicesSimklSyncNow: return LocalizedStringResource("Checks Simkl right away for changes made in another app or on the website. Nuvio also checks by itself, but not more often than every 15 minutes.")
        case .servicesSimklSyncInfo: return LocalizedStringResource("Opens a short explanation of what Nuvio sends to Simkl, how often it checks back, and why shows on hold or dropped disappear from Continue Watching.")
        case .servicesSimklAnimeId: return LocalizedStringResource("Chooses which ID identifies anime in Simkl. MyAnimeList and Kitsu keep each season separate. IMDB and TVDB group all seasons together. Default: IMDB.")
        case .servicesMdblist: return LocalizedStringResource("Connect shows a short code to enter on mdblist.com. Once connected, your MDBList watchlist and history sync with this Apple TV. Press again to disconnect.")
        case .servicesMoreLikeThisSource: return LocalizedStringResource("Picks where the More Like This row on a title page gets its suggestions. If the account you choose is not connected, TMDB is used instead. Default: Trakt.")
        case .servicesDebridProvider: return LocalizedStringResource("Connects or disconnects a debrid service. Debrid services download torrents on their servers and stream the finished file to you. Connect shows a short code to enter on your phone. After a sign-in expires, disconnect the service and connect it again.")
        case .servicesDebridDismiss: return LocalizedStringResource("Clears the failed sign-in message and goes back to the connect options for this service.")
        case .servicesDebridKey: return LocalizedStringResource("Lets you paste an API key for this debrid service instead of using the code sign-in. Typing a long key is easier from a phone through Remote Setup.")
        case .servicesDebridResolve: return LocalizedStringResource("Turns cached torrent results into direct streaming links for you automatically. It only appears once a debrid service is connected.")
        case .servicesDebridPrepare: return LocalizedStringResource("While a source list is open, this prepares direct links for the top cached sources, so Play can start at once. Off means links are only made when you pick one.")
        case .servicesDebridResolver: return LocalizedStringResource("Chooses which connected debrid service turns torrent results into links when you have more than one connected.")

        // Appearance
        case .appearanceTheme: return LocalizedStringResource("Sets the accent color used for highlights, buttons and focus across the app.")
        case .appearanceAccentFocusRing: return LocalizedStringResource("Draws a ring in your accent color around the focused poster or card. Off by default.")
        case .appearanceRingPosterColor: return LocalizedStringResource("Colors the focus ring with the focused poster's main color instead of your accent color. Off by default.")
        case .appearanceDepthPosterColor: return LocalizedStringResource("Tints each card's depth edge with its poster's main color as the artwork loads. Off by default.")
        case .appearanceNoZoomOnFocus: return LocalizedStringResource("Stops cards from growing when focused. They keep their size and show focus with a highlight and shadow. Off by default.")
        case .appearanceOledBlack: return LocalizedStringResource("Makes the app background pure black, which suits OLED screens. Cards keep their own colors so they still stand out.")
        case .appearanceRowEdgeFade: return LocalizedStringResource("Fades the left and right edges of rows so posters that run off the screen blend into the background. The left edge fades only after a row has scrolled. Off by default.")
        case .appearanceSettingsStyle: return LocalizedStringResource("Default shows an icon beside each Settings category. Minimal removes the icons and tightens the rows so more fit on screen.")
        case .appearanceNavigation: return LocalizedStringResource("Top Tabs keeps the tab bar across the top of the screen. Sidebar hides it and shows a floating panel that opens when you press Menu. Default: Top Tabs.")
        case .appearanceTypeface: return LocalizedStringResource("Chooses the font used across the app. Default: the Apple TV system font.")
        case .appearancePosterSize: return LocalizedStringResource("Sets how large posters appear in rows and grids. Larger posters leave less room for the description at the top of Home.")
        case .appearancePosterCorners: return LocalizedStringResource("Sets how round the poster corners are, from square to fully round.")
        case .appearanceHideTitles: return LocalizedStringResource("Shows posters without the title underneath. Off by default.")
        case .appearanceLandscapeRows: return LocalizedStringResource("Shows Home and Search catalog rows as wide 16:9 cards instead of tall posters. Off by default.")
        case .appearancePosterReset: return LocalizedStringResource("Puts the poster size, corners, title labels and wide-row choice back to their defaults.")
        case .appearanceHideHeroArtwork: return LocalizedStringResource("Hides the large artwork at the top of Home once you move down into the rows. Off by default, so the artwork stays visible.")
        case .appearanceCustomPosters: return LocalizedStringResource("Replaces catalog artwork with posters from a service such as RPDB. Opens a page where you enter the poster URL pattern.")
        case .appearanceCardDepth: return LocalizedStringResource("Adds a raised edge highlight and a glossy sheen to cards. Off by default.")
        case .appearanceCardDepthEdge: return LocalizedStringResource("Sets how strong the raised edge on cards is. Default: Subtle. Off removes the edge but keeps the sheen.")
        case .appearanceCardDepthSheen: return LocalizedStringResource("Sets how bright the glossy highlight across the top of a card is. Off removes it.")
        case .appearanceCardDepthCoverage: return LocalizedStringResource("Sets how far down the card the edge highlight reaches: just the top, half the card, or all the way around.")
        case .appearanceCardDepthSurface: return LocalizedStringResource("Turns the depth effect on or off for this kind of card. Each kind is on by default.")
        case .appearanceCardDepthReset: return LocalizedStringResource("Puts all card depth settings back to their defaults, which also turns card depth off.")
        case .appearanceBadgesFileSize: return LocalizedStringResource("Shows each stream's file size, such as 4.2 GB, as a small chip in the source list. On by default.")
        case .appearanceBadgesAddonLogo: return LocalizedStringResource("Shows the add-on's logo and name on the right of each source. Off by default.")
        case .appearanceBadgesAboveTitle: return LocalizedStringResource("Places the badge chips above the stream name instead of below its description.")
        case .appearanceBadgePack: return LocalizedStringResource("Set Active makes this badge pack decide which chips appear on streams. Delete removes the pack from this Apple TV.")
        case .appearanceBadgeImport: return LocalizedStringResource("Adds a badge pack from a JSON web address. Packs you import in the Nuvio phone app sync here on their own.")

        // Home Screen
        case .homeUpcoming: return LocalizedStringResource("Adds a row under Continue Watching with the next episodes of your shows that air in the next 14 days. On by default.")
        case .homeRefreshAddons: return LocalizedStringResource("Checks your installed add-ons again for catalogs. Use it if Home rows are missing even though add-ons are installed.")
        case .homeShowHero: return LocalizedStringResource("On shows a rotating banner at the top of Home, built from up to two of your catalogs. Off shows the focused title's artwork and description instead. On by default.")
        case .homeNuvioStyleHero: return LocalizedStringResource("On puts the title and description on the left, the artwork on the right, and keeps the banner in place while rows scroll. Off uses the classic layout with the logo at the lower left. Off by default.")
        case .homeHeroSources: return LocalizedStringResource("Opens the list of catalogs that can feed the rotating banner. Pick up to two.")
        case .homeHeroSource: return LocalizedStringResource("Turns this catalog on or off as a source for the rotating banner. At most two can be on at once.")
        case .homeTrailersOnFocus: return LocalizedStringResource("Plays a muted trailer preview after you rest on a poster for a moment. Off by default.")
        case .homeTrailerLocation: return LocalizedStringResource("Chooses whether the preview plays inside the poster or in the top banner. The banner only works with the Nuvio-style hero. Default: Poster.")
        case .homeHeroTrailerAutoplay: return LocalizedStringResource("Lets the top banner play its trailer by itself without waiting for focus. Off by default.")
        case .homeTrailerStartDelay: return LocalizedStringResource("Sets how long trailers on posters and in the hero wait before they start. Automatic waits until the rows stop moving, then one second. Default: Automatic.")
        case .homeCatalogType: return LocalizedStringResource("Adds the type to row names, so a row reads Popular - Movies instead of just Popular. On by default.")
        case .homeCatalogs: return LocalizedStringResource("Opens the list of catalogs that make up your Home rows. Switch each on or off and move them up or down to set the order.")
        case .homeCatalog: return LocalizedStringResource("Turns this row on or off on Home. Use the arrows to move it up or down.")

        // Detail Page
        case .detailLayout: return LocalizedStringResource("Cinematic puts the title over a full-width backdrop. Classic keeps the earlier page layout. Default: Cinematic.")
        case .detailIconOnlyButtons: return LocalizedStringResource("Shows the Play and other action buttons as icons without text. Off by default.")
        case .detailPosterBackdrop: return LocalizedStringResource("Shows the title's poster on the right side of the page's background. On by default.")
        case .detailTrailerAutoplay: return LocalizedStringResource("Plays the trailer full screen shortly after you open a title. On by default.")
        case .detailTrailerBackground: return LocalizedStringResource("Plays a muted trailer behind the description on title pages. On by default.")
        case .detailTrailerDuration: return LocalizedStringResource("Sets how long the background trailer plays before it stops. Default: Always, which plays until you leave.")
        case .detailTrailerSound: return LocalizedStringResource("Starts trailers with sound on. Press play/pause on the remote to mute. Off by default, so trailers start muted.")
        case .detailEpisodeRatings: return LocalizedStringResource("Chooses which episode cards show a rating badge: all of them, only watched ones, or none. Default: Show.")
        case .detailHideEpisodeSpoilers: return LocalizedStringResource("Blurs thumbnails and hides descriptions for episodes you have not watched yet. Off by default.")
        case .detailSectionStudioLogos: return LocalizedStringResource("Shows or hides the studio and network logos on title pages. On by default.")
        case .detailSectionParentalGuide: return LocalizedStringResource("Shows or hides the parental guide, which lists content warnings for the title. On by default.")
        case .detailSectionRatings: return LocalizedStringResource("Shows or hides the ratings from sites such as IMDb and Rotten Tomatoes. On by default.")
        case .detailSectionCast: return LocalizedStringResource("Shows or hides the cast and crew row. On by default.")
        case .detailSectionCollection: return LocalizedStringResource("Shows or hides the row of other titles in the same collection or saga. On by default.")
        case .detailSectionTrailers: return LocalizedStringResource("Shows or hides the row of trailers and extras. On by default.")
        case .detailSectionMoreLikeThis: return LocalizedStringResource("Shows or hides the row of similar titles. On by default.")
        case .detailSectionComments: return LocalizedStringResource("Shows or hides the comments section. On by default.")
        case .detailSectionAbout: return LocalizedStringResource("Shows or hides the About section with the title's details. On by default.")

        // Player
        case .playerDefaultPlayer: return LocalizedStringResource("Chooses whether streams open in the built-in player or in an installed external player. This row only appears when an external player is installed. Hold a stream to use the other one.")
        case .playerSkipIntro: return LocalizedStringResource("Shows a Skip button during intros and outros when they are known. On by default.")
        case .playerAutoSkipIntro: return LocalizedStringResource("Skips intros and anime openings by itself, without you pressing Skip. Off by default.")
        case .playerAutoSkipRecap: return LocalizedStringResource("Skips recap segments by itself, without you pressing Skip. Off by default.")
        case .playerAutoSkipOutro: return LocalizedStringResource("Skips outros and anime endings by itself, without you pressing Skip. Off by default.")
        case .playerAutoSkipCredits: return LocalizedStringResource("Skips movie end credits by itself but keeps post-credits scenes. Off by default.")
        case .playerEpisodeShuffle: return LocalizedStringResource("Adds a Shuffle button to series pages. Off by default.")
        case .playerPauseInfoCard: return LocalizedStringResource("Shows the title, source and time left after you have been paused for a while. This only works in the mpv player. On by default.")
        case .playerMatchFrameRate: return LocalizedStringResource("Switches the TV to the video's own frame rate and dynamic range while it plays. Off by default.")
        case .playerEnhancedRenderer: return LocalizedStringResource("Uses a different video renderer for better HDR color. It is experimental, works only on a real Apple TV and applies to the next video. Off by default.")
        case .playerNativeDolbyVision: return LocalizedStringResource("Plays Dolby Vision and HDR10 files in Apple's own player for true Dolby Vision on Apple TV 4K. Everything else stays on the mpv player. On by default.")
        case .playerP7FelMpv: return LocalizedStringResource("Some Dolby Vision discs (Profile 7 FEL) carry extra picture data that native playback must drop. This keeps those files on the mpv player as plain HDR10 so nothing is dropped. Off by default.")
        case .playerStreamingBuffer: return LocalizedStringResource("Sets how much memory the player may use to store video ahead of time. A larger buffer helps on a shaky connection. Default: Default.")
        case .playerNetworkReadahead: return LocalizedStringResource("Sets how many seconds of video the player downloads ahead of what you are watching. More seconds help on a slow connection. Default: Default.")
        case .playerPreloadNextEpisode: return LocalizedStringResource("Starts looking for the next episode's sources about 30 seconds before the Up Next card appears, so playback starts sooner. Off by default.")

        // Sources
        // beta.19-rc1 verdict (A): Best is now a real ranking (shared `StreamQualityRank`, W3-A).
        case .sourcesAutoPlayBest: return LocalizedStringResource("A plain press of Play starts the best source found so far: highest resolution, then HDR or Dolby Vision, then cached, then file size. Your source filters still apply. Hold Play to choose a source yourself. Off by default.")
        case .sourcesAutoPlayCachedOnly: return LocalizedStringResource("Auto-play only starts a link your debrid service already has cached. Otherwise it shows the source list. Off by default.")
        case .sourcesSort: return LocalizedStringResource("Sets the order of sources in the list, for every add-on. Default keeps each add-on's own order.")
        case .sourcesMinResolution: return LocalizedStringResource("Hides sources below this resolution. Sources with no resolution tag are kept.")
        case .sourcesDvFilter: return LocalizedStringResource("Any shows all sources. Only keeps Dolby Vision sources. Exclude hides them.")
        case .sourcesHdrFilter: return LocalizedStringResource("Any shows all sources. Only keeps HDR sources. Exclude hides them.")
        case .sourcesCachedOnlyFilter: return LocalizedStringResource("Hides sources your debrid service has not cached. This row only appears once a debrid service is connected. Off by default.")
        case .sourcesTmdbEnrichment: return LocalizedStringResource("Adds cast profiles, studios, collections and better artwork from TMDB to titles you open. It uses a key built into the app. Off by default.")
        case .sourcesTmdbKey: return LocalizedStringResource("Lets you use your own TMDB API key instead of the built-in one. Leave it empty to keep the built-in key. Removing your key goes back to the built-in one.")
        case .sourcesTmdbReleaseDates: return LocalizedStringResource("Uses TMDB's air dates instead of the dates your add-ons report. Off by default.")
        case .sourcesTmdbLanguage: return LocalizedStringResource("Sets the language of TMDB titles, descriptions and logos, including the Home hero. Device follows this Apple TV's language.")
        case .sourcesMdblistRatings: return LocalizedStringResource("Shows IMDb, Rotten Tomatoes, Metacritic, Trakt and Letterboxd scores on title pages. Off by default.")
        case .sourcesMdblistKey: return LocalizedStringResource("Lets you use your own MDBList API key. A personal key takes priority over a connected MDBList account.")
        case .sourcesLibrarySource: return LocalizedStringResource("Chooses where your library is saved and read from. If the service you pick is not connected, Nuvio Library is used instead. Default: Nuvio Library.")
        case .sourcesWatchProgressSource: return LocalizedStringResource("Chooses which service keeps Continue Watching and watched history. If the service you pick is not connected, Nuvio Sync is used instead. Default: Nuvio Sync.")
        case .sourcesRecentSearches: return LocalizedStringResource("Remembers what you search for and shows it on the Search screen. Off hides past searches and stops saving new ones. On by default.")
        case .sourcesHideDiscover: return LocalizedStringResource("Hides the Discover section on the Search screen so only the search field shows. Off by default.")
        case .sourcesSearchCatalog: return LocalizedStringResource("Turns this catalog on or off for Search. Fewer catalogs gives faster results. This applies to this Apple TV only.")
        case .sourcesPluginsEnabled: return LocalizedStringResource("Runs your enabled plugin providers when streams load. Plugins add extra sources.")
        case .sourcesPluginRepoAdd: return LocalizedStringResource("Installs a plugin repository from its manifest web address. The repository then syncs to your other Nuvio devices.")
        case .sourcesPluginRepo: return LocalizedStringResource("Removes this plugin repository and its providers from this Apple TV.")
        case .sourcesPluginScraper: return LocalizedStringResource("Turns this plugin provider on or off. Only enabled providers are used when streams load.")
        case .sourcesPluginsRefresh: return LocalizedStringResource("Downloads the provider code again from every installed repository.")

        // Subtitles & Audio
        case .subtitlesTextColor: return LocalizedStringResource("Sets the color of subtitle text. Default: White.")
        case .subtitlesSize: return LocalizedStringResource("Sets how large subtitles appear. Default: Medium.")
        case .subtitlesBackground: return LocalizedStringResource("Adds a dark box behind subtitles to make them easier to read. Default: Off.")
        case .subtitlesBold: return LocalizedStringResource("Uses a heavier font for subtitles. Off by default.")
        case .subtitlesOutline: return LocalizedStringResource("Draws a thin dark outline around subtitle text so it stands out on bright scenes. On by default.")
        case .subtitlesStripSdh: return LocalizedStringResource("Removes sound descriptions and speaker labels, such as [door slams], from text subtitles. Off by default.")
        case .subtitlesAudioLanguage: return LocalizedStringResource("When playback starts, picks the audio track in this language if the video has one.")
        case .subtitlesSubtitleLanguage: return LocalizedStringResource("When playback starts, picks the subtitle track in this language if one is available.")

        // About
        case .aboutVersion: return LocalizedStringResource("The app version and build number running on this Apple TV. Include it when you report a bug.")
        case .aboutBuild: return LocalizedStringResource("The beta release this build was cut from. It is empty on builds made directly in Xcode.")
        case .aboutCommit: return LocalizedStringResource("The exact code revision this build was made from. Include it when you report a bug.")
        case .aboutTvos: return LocalizedStringResource("The tvOS version installed on this Apple TV.")
        case .aboutDevice: return LocalizedStringResource("The model identifier of this Apple TV.")
        case .aboutSource: return LocalizedStringResource("Where the source code for this app is published.")
        case .aboutFonts: return LocalizedStringResource("The Open Sans typeface is bundled with the app and used under the SIL Open Font License 1.1.")

        // Developer
        case .devHeroPaint: return LocalizedStringResource("Records how the Home hero artwork is drawn so a problem can be photographed. Turn it on only when asked, then relaunch.")
        case .devTabBarDiag: return LocalizedStringResource("Shows scroll and push counters for the tab bar. Turn it on only when asked to capture a tab bar problem.")
        case .devHardTopEdge: return LocalizedStringResource("An A/B switch that changes how Home's top edge scrolls, to test a tab bar that reappears clipped. Try it only if asked.")
        case .devStreamDiag: return LocalizedStringResource("Logs stream lookups so you can see why a title finds no sources. Turn it on only when asked.")
        case .devTrailerDiag: return LocalizedStringResource("Records how a trailer is framed and played so a zoomed, letterboxed or stuttering trailer can be photographed. Turn it on only when asked.")
        case .devTrailerCacheReset: return LocalizedStringResource("Clears the saved zoom settings for trailers, so each trailer is measured again the next time it plays.")
        case .devDetailScrollAB: return LocalizedStringResource("An A/B switch that tries different ways of scrolling title pages to test a stutter. Leave it Off unless asked.")
        case .devDetailScrollProbe: return LocalizedStringResource("Counts hitches during one title page visit and logs the result when you press Menu to leave.")
        case .devTrailerMaxFps: return LocalizedStringResource("An A/B switch that prefers 30 fps trailers over higher frame rates to test choppy playback. Auto is the normal behavior.")
        case .devTrailerBuffer: return LocalizedStringResource("An A/B switch that sets how many seconds of trailer are buffered before playing. Auto is the normal behavior.")
        case .devTrailerLetterbox: return LocalizedStringResource("An A/B switch that skips the check for black bars around trailers. Leave it off unless asked.")
        case .devCollectionProbe: return LocalizedStringResource("Records how long each focus step takes on collection rows. Turn it on only when asked.")
        case .devCollectionProbeClear: return LocalizedStringResource("Clears what the collection frame probe has recorded so far.")
        case .devCollectionAB: return LocalizedStringResource("An A/B switch for how collection rows animate, to test choppy focus movement. 0 is the normal behavior.")
        case .devRowSettle: return LocalizedStringResource("Records where each Home row comes to rest as you scroll. Turn it on only when asked, then relaunch.")
        case .devTabBarGeometry: return LocalizedStringResource("Records the tab bar's position as you move through Home and other tabs. Turn it on only when asked, then relaunch.")
        case .devNoZoomReach: return LocalizedStringResource("An A/B switch that reserves extra room for row titles when No Zoom on Focus is on, to test titles that fade or bounce.")
        case .devShortRowFloor: return LocalizedStringResource("An A/B switch that makes short rows such as Continue Watching rest at the same height as poster rows.")
        case .devTabBarScrollLink: return LocalizedStringResource("An A/B switch that tells the tab bar which scroll view on Home to follow. Relaunch after changing it.")
        case .devTabBarRestFix: return LocalizedStringResource("An A/B switch for a tab bar that stays half shown on Home. Relink reconnects the tab bar to Home's rows once they first come to rest. Snap to Top moves the first row fully back to the top when it rests a few points low. Relaunch after changing it.")
        }
    }

    /// Optional small print under the description in the explainer (D11 / V5, mockup: "Also set
    /// in tvOS Settings › Video and Audio › Match Content"). `nil` = no footnote line, which is
    /// the default for every row. Add a `case .someId: return LocalizedStringResource("…")` above
    /// `default` for each row that needs one; same copy rules as `text(for:)`.
    static func footnote(for id: SettingsDescriptionID) -> LocalizedStringResource? {
        switch id {
        case .playerMatchFrameRate: return LocalizedStringResource("Also set in tvOS Settings › Video and Audio › Match Content.")
        case .playerStreamingBuffer: return LocalizedStringResource("Applies to the next playback.")
        case .playerNetworkReadahead: return LocalizedStringResource("Applies to the next playback.")
        case .servicesDebridPrepare: return LocalizedStringResource("Debrid services limit how many links you can make in a period. Preparing links ahead can use that allowance even if you never press Play, so use a lower number when you can.")
        case .devTrailerMaxFps: return LocalizedStringResource("Takes effect on next launch.")
        case .devTrailerBuffer: return LocalizedStringResource("Takes effect on next launch.")
        case .devTrailerLetterbox: return LocalizedStringResource("Takes effect on next launch.")
        case .devCollectionAB: return LocalizedStringResource("Takes effect on next launch.")
        case .devTabBarScrollLink: return LocalizedStringResource("Takes effect on next launch.")
        case .devTabBarRestFix: return LocalizedStringResource("Takes effect on next launch.")
        default: return nil
        }
    }
}

// MARK: - Category copy

extension SettingsCategory {
    /// One-line subtitle under the category title on the Settings root.
    var subtitle: LocalizedStringResource {
        switch self {
        case .accountProfiles: return LocalizedStringResource("Nuvio account and server, plus Remote Setup")
        case .services: return LocalizedStringResource("Trakt, Simkl and MDBList, plus debrid")
        case .appearance: return LocalizedStringResource("Theme and poster style, plus card depth and badges")
        case .homeScreen: return LocalizedStringResource("The hero and rows, plus trailer previews")
        case .detailPage: return LocalizedStringResource("Layout and trailers, plus which sections show")
        case .player: return LocalizedStringResource("Default player, skipping, video and buffering")
        case .sources: return LocalizedStringResource("Auto-play, filters, metadata and plugins")
        case .subtitlesAudio: return LocalizedStringResource("Subtitle style and preferred languages")
        case .about: return LocalizedStringResource("Version, build and device")
        case .developer: return LocalizedStringResource("Diagnostics and A/B switches")
        }
    }

    /// The explainer's text for the category: shown on the root while the category's row has
    /// focus, and inside the pane whenever the focused row carries no description of its own.
    var summary: LocalizedStringResource {
        switch self {
        case .accountProfiles:
            return LocalizedStringResource("Sign in or out of your Nuvio account and choose which server this Apple TV talks to. Remote Setup lets you manage add-ons, Home rows and keys from a phone browser.")
        case .services:
            return LocalizedStringResource("Connect the tracking services that record what you watch, and the debrid services that turn cached torrents into direct streams. Connections are per profile.")
        case .appearance:
            return LocalizedStringResource("Pick the accent color, the font and the navigation style. Shape how posters and cards look across the app. Stream badge packs are managed here too.")
        case .homeScreen:
            return LocalizedStringResource("Choose what the top of Home shows and which catalogs appear as rows, in what order. Trailer previews on focus are set here too.")
        case .detailPage:
            return LocalizedStringResource("Choose the title page layout, how trailers behave, and which sections appear under the main details. Episode spoiler protection is here too.")
        case .player:
            return LocalizedStringResource("Control how playback starts and behaves: the default player, intro skipping, frame-rate matching, Dolby Vision handling and buffering.")
        case .sources:
            return LocalizedStringResource("Decide which streams are picked and shown, where metadata and ratings come from, where your library and progress are stored, and which plugins and search catalogs run.")
        case .subtitlesAudio:
            return LocalizedStringResource("Set how subtitles look and which audio and subtitle languages are chosen automatically when playback starts.")
        case .about:
            return LocalizedStringResource("The exact version, build and commit running on this Apple TV. Include these when you report a bug.")
        case .developer:
            return LocalizedStringResource("Diagnostic readouts and test switches used when chasing a bug report. Leave them alone unless you've been asked to capture something.")
        }
    }
}
