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
// W1-B ships every row's copy as the placeholder "TODO" (one throwaway catalog key); W3-A writes
// the real text and removes the placeholder test's skip.

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
    case devRowEdgeFade = "dev.rowEdgeFade"
    case devShortRowFloor = "dev.shortRowFloor"
    case devTabBarScrollLink = "dev.tabBarScrollLink"
}

enum SettingsDescriptions {
    /// Exhaustive switch: the compiler guarantees every id has copy.
    static func text(for id: SettingsDescriptionID) -> LocalizedStringResource {
        switch id {

        // Account & Profiles
        case .accountSignInOut: return LocalizedStringResource("TODO")
        case .accountConnectServer: return LocalizedStringResource("TODO")
        case .accountUseOfficialServer: return LocalizedStringResource("TODO")
        case .accountRemoteSetup: return LocalizedStringResource("TODO")

        // Services
        case .servicesTrakt: return LocalizedStringResource("TODO")
        case .servicesActivationCancel: return LocalizedStringResource("TODO")
        case .servicesSimkl: return LocalizedStringResource("TODO")
        case .servicesSimklSyncNow: return LocalizedStringResource("TODO")
        case .servicesSimklSyncInfo: return LocalizedStringResource("TODO")
        case .servicesSimklAnimeId: return LocalizedStringResource("TODO")
        case .servicesMdblist: return LocalizedStringResource("TODO")
        case .servicesMoreLikeThisSource: return LocalizedStringResource("TODO")
        case .servicesDebridProvider: return LocalizedStringResource("TODO")
        case .servicesDebridDismiss: return LocalizedStringResource("TODO")
        case .servicesDebridKey: return LocalizedStringResource("TODO")
        case .servicesDebridResolve: return LocalizedStringResource("TODO")
        case .servicesDebridPrepare: return LocalizedStringResource("TODO")
        case .servicesDebridResolver: return LocalizedStringResource("TODO")

        // Appearance
        case .appearanceTheme: return LocalizedStringResource("TODO")
        case .appearanceAccentFocusRing: return LocalizedStringResource("TODO")
        case .appearanceRingPosterColor: return LocalizedStringResource("TODO")
        case .appearanceDepthPosterColor: return LocalizedStringResource("TODO")
        case .appearanceNoZoomOnFocus: return LocalizedStringResource("TODO")
        case .appearanceOledBlack: return LocalizedStringResource("TODO")
        case .appearanceSettingsStyle: return LocalizedStringResource("TODO")
        case .appearanceNavigation: return LocalizedStringResource("TODO")
        case .appearanceTypeface: return LocalizedStringResource("TODO")
        case .appearancePosterSize: return LocalizedStringResource("TODO")
        case .appearancePosterCorners: return LocalizedStringResource("TODO")
        case .appearanceHideTitles: return LocalizedStringResource("TODO")
        case .appearanceLandscapeRows: return LocalizedStringResource("TODO")
        case .appearancePosterReset: return LocalizedStringResource("TODO")
        case .appearanceHideHeroArtwork: return LocalizedStringResource("TODO")
        case .appearanceCustomPosters: return LocalizedStringResource("TODO")
        case .appearanceCardDepth: return LocalizedStringResource("TODO")
        case .appearanceCardDepthEdge: return LocalizedStringResource("TODO")
        case .appearanceCardDepthSheen: return LocalizedStringResource("TODO")
        case .appearanceCardDepthCoverage: return LocalizedStringResource("TODO")
        case .appearanceCardDepthSurface: return LocalizedStringResource("TODO")
        case .appearanceCardDepthReset: return LocalizedStringResource("TODO")
        case .appearanceBadgesFileSize: return LocalizedStringResource("TODO")
        case .appearanceBadgesAddonLogo: return LocalizedStringResource("TODO")
        case .appearanceBadgesAboveTitle: return LocalizedStringResource("TODO")
        case .appearanceBadgePack: return LocalizedStringResource("TODO")
        case .appearanceBadgeImport: return LocalizedStringResource("TODO")

        // Home Screen
        case .homeUpcoming: return LocalizedStringResource("TODO")
        case .homeRefreshAddons: return LocalizedStringResource("TODO")
        case .homeShowHero: return LocalizedStringResource("TODO")
        case .homeNuvioStyleHero: return LocalizedStringResource("TODO")
        case .homeHeroSources: return LocalizedStringResource("TODO")
        case .homeHeroSource: return LocalizedStringResource("TODO")
        case .homeTrailersOnFocus: return LocalizedStringResource("TODO")
        case .homeTrailerLocation: return LocalizedStringResource("TODO")
        case .homeHeroTrailerAutoplay: return LocalizedStringResource("TODO")
        case .homeCatalogType: return LocalizedStringResource("TODO")
        case .homeCatalogs: return LocalizedStringResource("TODO")
        case .homeCatalog: return LocalizedStringResource("TODO")

        // Detail Page
        case .detailLayout: return LocalizedStringResource("TODO")
        case .detailIconOnlyButtons: return LocalizedStringResource("TODO")
        case .detailPosterBackdrop: return LocalizedStringResource("TODO")
        case .detailTrailerAutoplay: return LocalizedStringResource("TODO")
        case .detailTrailerBackground: return LocalizedStringResource("TODO")
        case .detailTrailerDuration: return LocalizedStringResource("TODO")
        case .detailTrailerSound: return LocalizedStringResource("TODO")
        case .detailEpisodeRatings: return LocalizedStringResource("TODO")
        case .detailHideEpisodeSpoilers: return LocalizedStringResource("TODO")
        case .detailSectionStudioLogos: return LocalizedStringResource("TODO")
        case .detailSectionParentalGuide: return LocalizedStringResource("TODO")
        case .detailSectionRatings: return LocalizedStringResource("TODO")
        case .detailSectionCast: return LocalizedStringResource("TODO")
        case .detailSectionCollection: return LocalizedStringResource("TODO")
        case .detailSectionTrailers: return LocalizedStringResource("TODO")
        case .detailSectionMoreLikeThis: return LocalizedStringResource("TODO")
        case .detailSectionComments: return LocalizedStringResource("TODO")
        case .detailSectionAbout: return LocalizedStringResource("TODO")

        // Player
        case .playerDefaultPlayer: return LocalizedStringResource("TODO")
        case .playerSkipIntro: return LocalizedStringResource("TODO")
        case .playerAutoSkipIntro: return LocalizedStringResource("TODO")
        case .playerAutoSkipRecap: return LocalizedStringResource("TODO")
        case .playerAutoSkipOutro: return LocalizedStringResource("TODO")
        case .playerAutoSkipCredits: return LocalizedStringResource("TODO")
        case .playerEpisodeShuffle: return LocalizedStringResource("TODO")
        case .playerPauseInfoCard: return LocalizedStringResource("TODO")
        case .playerMatchFrameRate: return LocalizedStringResource("TODO")
        case .playerEnhancedRenderer: return LocalizedStringResource("TODO")
        case .playerNativeDolbyVision: return LocalizedStringResource("TODO")
        case .playerP7FelMpv: return LocalizedStringResource("TODO")
        case .playerStreamingBuffer: return LocalizedStringResource("TODO")
        case .playerNetworkReadahead: return LocalizedStringResource("TODO")
        case .playerPreloadNextEpisode: return LocalizedStringResource("TODO")

        // Sources
        case .sourcesAutoPlayBest: return LocalizedStringResource("TODO")
        case .sourcesAutoPlayCachedOnly: return LocalizedStringResource("TODO")
        case .sourcesSort: return LocalizedStringResource("TODO")
        case .sourcesMinResolution: return LocalizedStringResource("TODO")
        case .sourcesDvFilter: return LocalizedStringResource("TODO")
        case .sourcesHdrFilter: return LocalizedStringResource("TODO")
        case .sourcesCachedOnlyFilter: return LocalizedStringResource("TODO")
        case .sourcesTmdbEnrichment: return LocalizedStringResource("TODO")
        case .sourcesTmdbKey: return LocalizedStringResource("TODO")
        case .sourcesTmdbReleaseDates: return LocalizedStringResource("TODO")
        case .sourcesTmdbLanguage: return LocalizedStringResource("TODO")
        case .sourcesMdblistRatings: return LocalizedStringResource("TODO")
        case .sourcesMdblistKey: return LocalizedStringResource("TODO")
        case .sourcesLibrarySource: return LocalizedStringResource("TODO")
        case .sourcesWatchProgressSource: return LocalizedStringResource("TODO")
        case .sourcesRecentSearches: return LocalizedStringResource("TODO")
        case .sourcesHideDiscover: return LocalizedStringResource("TODO")
        case .sourcesSearchCatalog: return LocalizedStringResource("TODO")
        case .sourcesPluginsEnabled: return LocalizedStringResource("TODO")
        case .sourcesPluginRepoAdd: return LocalizedStringResource("TODO")
        case .sourcesPluginRepo: return LocalizedStringResource("TODO")
        case .sourcesPluginScraper: return LocalizedStringResource("TODO")
        case .sourcesPluginsRefresh: return LocalizedStringResource("TODO")

        // Subtitles & Audio
        case .subtitlesTextColor: return LocalizedStringResource("TODO")
        case .subtitlesSize: return LocalizedStringResource("TODO")
        case .subtitlesBackground: return LocalizedStringResource("TODO")
        case .subtitlesBold: return LocalizedStringResource("TODO")
        case .subtitlesOutline: return LocalizedStringResource("TODO")
        case .subtitlesStripSdh: return LocalizedStringResource("TODO")
        case .subtitlesAudioLanguage: return LocalizedStringResource("TODO")
        case .subtitlesSubtitleLanguage: return LocalizedStringResource("TODO")

        // About
        case .aboutVersion: return LocalizedStringResource("TODO")
        case .aboutBuild: return LocalizedStringResource("TODO")
        case .aboutCommit: return LocalizedStringResource("TODO")
        case .aboutTvos: return LocalizedStringResource("TODO")
        case .aboutDevice: return LocalizedStringResource("TODO")
        case .aboutSource: return LocalizedStringResource("TODO")
        case .aboutFonts: return LocalizedStringResource("TODO")

        // Developer
        case .devHeroPaint: return LocalizedStringResource("TODO")
        case .devTabBarDiag: return LocalizedStringResource("TODO")
        case .devHardTopEdge: return LocalizedStringResource("TODO")
        case .devStreamDiag: return LocalizedStringResource("TODO")
        case .devTrailerDiag: return LocalizedStringResource("TODO")
        case .devTrailerCacheReset: return LocalizedStringResource("TODO")
        case .devDetailScrollAB: return LocalizedStringResource("TODO")
        case .devDetailScrollProbe: return LocalizedStringResource("TODO")
        case .devTrailerMaxFps: return LocalizedStringResource("TODO")
        case .devTrailerBuffer: return LocalizedStringResource("TODO")
        case .devTrailerLetterbox: return LocalizedStringResource("TODO")
        case .devCollectionProbe: return LocalizedStringResource("TODO")
        case .devCollectionProbeClear: return LocalizedStringResource("TODO")
        case .devCollectionAB: return LocalizedStringResource("TODO")
        case .devRowSettle: return LocalizedStringResource("TODO")
        case .devTabBarGeometry: return LocalizedStringResource("TODO")
        case .devNoZoomReach: return LocalizedStringResource("TODO")
        case .devRowEdgeFade: return LocalizedStringResource("TODO")
        case .devShortRowFloor: return LocalizedStringResource("TODO")
        case .devTabBarScrollLink: return LocalizedStringResource("TODO")
        }
    }

    /// Optional small print under the description in the explainer (D11 / V5, mockup: "Also set
    /// in tvOS Settings › Video and Audio › Match Content"). `nil` = no footnote line, which is
    /// the default for every row. Add a `case .someId: return LocalizedStringResource("…")` above
    /// `default` for each row that needs one; same copy rules as `text(for:)`.
    static func footnote(for id: SettingsDescriptionID) -> LocalizedStringResource? {
        switch id {
        default: return nil
        }
    }
}

// MARK: - Category copy

extension SettingsCategory {
    /// One-line subtitle under the category title on the Settings root.
    var subtitle: LocalizedStringResource {
        switch self {
        case .accountProfiles: return LocalizedStringResource("Nuvio account, server and Remote Setup")
        case .services: return LocalizedStringResource("Trakt, Simkl, MDBList and debrid")
        case .appearance: return LocalizedStringResource("Theme, posters, card depth and badges")
        case .homeScreen: return LocalizedStringResource("Hero, rows and trailer previews")
        case .detailPage: return LocalizedStringResource("Layout, trailers and sections")
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
            return LocalizedStringResource("Pick the accent colour, typeface and navigation style, and shape how posters and cards look across the app. Stream badge packs are managed here too.")
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
