import Combine
import XCTest
import SharedCore
@testable import NuvioTV

/// W3-16 (BUG-207, Steven rc11: "stream selection page: scrolling isn't smooth"): the stream picker's
/// rows are plain values (`StreamRowModel`) behind an `Equatable` row view, built once in
/// `StreamsViewModel.apply(_:)`. These pin the two things that make that safe: `==` sees every input
/// that changes what a row draws (a row skipped on a stale model would freeze the spinner, the
/// rejected caption, the badge settings, the Instant-suffix title or the player menu), and an
/// identical republish costs the picker nothing.
@MainActor
final class StreamRowModelTests: XCTestCase {

    // MARK: - Builders

    private func hints(size: Int64? = nil) -> StreamBehaviorHints {
        StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil,
                            videoSize: size.map { KotlinLong(value: $0) }, filename: nil,
                            proxyHeaders: nil, audioDelayMs: nil)
    }

    private func stream(
        name: String? = "Torrentio 4K",
        description: String? = "Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GROUP",
        url: String? = "https://cdn.example.com/movie.mkv",
        infoHash: String? = nil,
        ytId: String? = nil,
        addonId: String = "addon:x",
        addonName: String = "Add-on",
        sourceName: String? = nil,
        addonLogo: String? = nil,
        size: Int64? = nil,
        badges: [StreamBadge] = [],
        cache: StreamDebridCacheStatus? = nil
    ) -> StreamItem {
        StreamItem(
            name: name, title: nil, description: description, url: url, infoHash: infoHash, fileIdx: nil,
            externalUrl: nil, ytId: ytId, sources: [], sourceName: sourceName, addonName: addonName, addonId: addonId,
            addonLogo: addonLogo, streamType: nil, behaviorHints: hints(size: size),
            clientResolve: nil, debridCacheStatus: cache, externalSubtitles: [], badges: badges
        )
    }

    private func badge(_ name: String, image: String = "") -> StreamBadge {
        StreamBadge(name: name, imageURL: image, tagColor: "#222222", tagStyle: "filled",
                    textColor: "#FFFFFF", borderColor: "")
    }

    private func cached(provider: String = "rd", name: String = "Real-Debrid") -> StreamDebridCacheStatus {
        StreamDebridCacheStatus(providerId: provider, providerName: name, state: .cached,
                                cachedName: nil, cachedSize: nil)
    }

    private func make(_ stream: StreamItem, key: String = "addon:x#k",
                      display: StreamRowDisplay = StreamRowDisplay()) -> StreamRowModel {
        StreamRowModel.make(stream: stream, facts: StreamFactsParser.shared.parse(stream: stream),
                            key: key, display: display,
                            providerLabel: { $0.providerName })
    }

    // MARK: - make

    func testMakeCarriesWhatTheRowDraws() {
        let s = stream(addonLogo: "https://cdn.example.com/logo.png", size: 3_000_000_000,
                       badges: [badge("4K"), badge("DV", image: "https://cdn.example.com/dv.png")])
        let model = make(s, display: StreamRowDisplay(showFileSize: true, badgesOnTop: true,
                                                      showAddonLogo: true, instantSuffix: false))
        XCTAssertEqual(model.key, "addon:x#k")
        XCTAssertEqual(model.id, "addon:x#k")
        XCTAssertEqual(model.title, "Torrentio 4K")
        XCTAssertEqual(model.description, "Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GROUP")
        XCTAssertEqual(model.badges.map(\.name), ["4K", "DV"])
        XCTAssertEqual(model.badges[1].imageURL, "https://cdn.example.com/dv.png")
        XCTAssertEqual(model.sizeBytes, 3_000_000_000)
        XCTAssertTrue(model.badgesOnTop)
        XCTAssertTrue(model.showsAddonColumn)
        XCTAssertEqual(model.addonName, "Add-on")
        XCTAssertEqual(model.addonLogo, "https://cdn.example.com/logo.png")
        XCTAssertFalse(model.isYouTube)
        XCTAssertEqual(model.playbackKey, s.playbackStreamKey)
        XCTAssertFalse(model.playbackKey.isEmpty)
        XCTAssertTrue(model.hasBadgeRow)
        // Readable-row fields (the default fixture parses as 2160p WEB-DL HEVC, DV, Atmos DD+).
        XCTAssertEqual(model.resolution, 2160)
        XCTAssertEqual(model.headline, "4K")
        XCTAssertEqual(model.title, "Torrentio 4K", "with a headline the title is the plain label")
        XCTAssertEqual(model.hdrMark, "DV")
        XCTAssertTrue(model.hasVideoLine)
        XCTAssertTrue(model.hasAudioLine)
        XCTAssertNil(model.cachedState, "a plain HTTP link is not a debrid candidate")
        XCTAssertEqual(model.audio, "Atmos DD+", "Direction C: the audio label alone")
        // The four view-state inputs start empty.
        XCTAssertFalse(model.isResolving)
        XCTAssertFalse(model.failedRecently)
        XCTAssertTrue(model.players.isEmpty)
        XCTAssertNil(model.defaultPlayerId)
    }

    func testAnEmptyDescriptionAndLogoBecomeNil() {
        let model = make(stream(description: "", addonLogo: ""))
        XCTAssertNil(model.description)
        XCTAssertNil(model.addonLogo)
        XCTAssertNil(make(stream(description: nil)).description)
    }

    func testTheSizeChipFollowsTheSettingAndTheStream() {
        let sized = stream(size: 1_000_000)
        XCTAssertEqual(make(sized, display: StreamRowDisplay(showFileSize: true)).sizeBytes, 1_000_000)
        XCTAssertNil(make(sized, display: StreamRowDisplay(showFileSize: false)).sizeBytes,
                     "the size chip is off: no size, so no chip")
        XCTAssertNil(make(stream(size: nil), display: StreamRowDisplay(showFileSize: true)).sizeBytes)
        XCTAssertFalse(make(stream(size: nil)).hasBadgeRow, "no badges and no size: no badge row")
        XCTAssertFalse(make(stream(size: 5)).hasBadgeRow, "the size moved to the headline line: it no longer makes a badge row")
        XCTAssertTrue(make(stream(badges: [badge("HDR")])).hasBadgeRow)
    }

    func testAYouTubeOnlyStreamIsFlagged() {
        let yt = stream(url: nil, ytId: "dQw4w9WgXcQ")
        XCTAssertTrue(make(yt).isYouTube)
        XCTAssertFalse(make(stream(url: "https://cdn.example.com/a.mkv", ytId: "dQw4w9WgXcQ")).isYouTube)
    }

    // MARK: - The Instant suffix

    func testTheInstantSuffixNeedsTheSettingACachedStatusAndAProviderName() {
        let plain = stream(cache: nil)
        let hit = stream(cache: cached())
        XCTAssertEqual(StreamRowModel.title(for: hit, instantSuffix: false, providerLabel: { $0.providerName }),
                       "Torrentio 4K")
        XCTAssertEqual(StreamRowModel.title(for: plain, instantSuffix: true, providerLabel: { $0.providerName }),
                       "Torrentio 4K")
        let suffixed = StreamRowModel.title(for: hit, instantSuffix: true, providerLabel: { $0.providerName })
        XCTAssertTrue(suffixed.hasPrefix("Torrentio 4K"), suffixed)
        XCTAssertTrue(suffixed.contains("Real-Debrid"), suffixed)
        XCTAssertTrue(suffixed.contains("Instant"), suffixed)
        // No provider name to show: the plain title.
        XCTAssertEqual(StreamRowModel.title(for: hit, instantSuffix: true, providerLabel: { _ in "" }),
                       "Torrentio 4K")
        // A status that is not CACHED never gets the suffix.
        let checking = StreamDebridCacheStatus(providerId: "rd", providerName: "Real-Debrid", state: .checking,
                                               cachedName: nil, cachedSize: nil)
        XCTAssertEqual(StreamRowModel.title(for: stream(cache: checking), instantSuffix: true,
                                            providerLabel: { $0.providerName }), "Torrentio 4K")
    }

    // MARK: - ==

    private func base() -> StreamRowModel {
        make(stream(size: 2_000_000_000, badges: [badge("4K")]))
    }

    func testEqualInputsGiveEqualModels() {
        XCTAssertEqual(base(), base())
        // A rebuilt-from-fresh-Kotlin-objects model compares equal too (the republish case).
        XCTAssertEqual(make(stream(size: 2_000_000_000, badges: [badge("4K")])),
                       make(stream(size: 2_000_000_000, badges: [badge("4K")])))
    }

    func testTheSpinnerIsPartOfEquality() {
        let idle = base().applying(isResolving: false, failedRecently: false, players: [], defaultPlayerId: nil)
        let busy = base().applying(isResolving: true, failedRecently: false, players: [], defaultPlayerId: nil)
        XCTAssertNotEqual(idle, busy)
        XCTAssertTrue(busy.isResolving)
    }

    func testTheRejectedFlagIsPartOfEquality() {
        let ok = base().applying(isResolving: false, failedRecently: false, players: [], defaultPlayerId: nil)
        let failed = base().applying(isResolving: false, failedRecently: true, players: [], defaultPlayerId: nil)
        XCTAssertNotEqual(ok, failed)
        XCTAssertTrue(failed.failedRecently)
    }

    func testTheBadgeSettingsArePartOfEquality() {
        let s = stream(addonLogo: "https://cdn.example.com/l.png", size: 2_000_000_000, badges: [badge("4K")])
        let defaults = make(s)
        XCTAssertNotEqual(defaults, make(s, display: StreamRowDisplay(showFileSize: false)), "file-size chip")
        XCTAssertNotEqual(defaults, make(s, display: StreamRowDisplay(badgesOnTop: true)), "placement")
        XCTAssertNotEqual(defaults, make(s, display: StreamRowDisplay(showAddonLogo: true)), "add-on column")
    }

    func testTheInstantSuffixTitleIsPartOfEquality() {
        // No resolution: with a headline the title never carries the suffix (D3), so this case needs a title-led row.
        let hit = stream(name: "Torrentio", description: "release", cache: cached())
        let off = StreamRowModel.make(stream: hit,
                                      facts: StreamFactsParser.shared.parse(stream: hit),
                                      key: "k", display: StreamRowDisplay(instantSuffix: false),
                                      providerLabel: { $0.providerName })
        let on = StreamRowModel.make(stream: hit,
                                      facts: StreamFactsParser.shared.parse(stream: hit),
                                      key: "k", display: StreamRowDisplay(instantSuffix: true),
                                      providerLabel: { $0.providerName })
        XCTAssertNotEqual(off.title, on.title)
        XCTAssertNotEqual(off, on)
    }

    func testThePlayerListAndItsDefaultArePartOfEquality() {
        let infuse = StreamRowPlayer(id: "infuse", name: "Infuse")
        let vlc = StreamRowPlayer(id: "vlc", name: "VLC")
        func with(_ players: [StreamRowPlayer], _ defaultId: String?) -> StreamRowModel {
            base().applying(isResolving: false, failedRecently: false, players: players, defaultPlayerId: defaultId)
        }
        XCTAssertEqual(with([infuse], nil), with([infuse], nil))
        XCTAssertNotEqual(with([], nil), with([infuse], nil), "a player was installed")
        XCTAssertNotEqual(with([infuse], nil), with([infuse, vlc], nil), "a second player")
        XCTAssertNotEqual(with([infuse, vlc], nil), with([vlc, infuse], nil), "order is the menu's order")
        XCTAssertNotEqual(with([infuse], nil), with([infuse], "infuse"), "the default changed")
    }

    func testTheResolutionIsDerivedFromTheRelease() {
        let uhd = make(stream(name: "Torrentio", description: "Movie.2024.2160p.WEB-DL.HEVC-GROUP"))
        let fhd = make(stream(name: "Torrentio", description: "Movie.2024.1080p.WEB-DL.HEVC-GROUP"))
        XCTAssertNotEqual(uhd, fhd)
        XCTAssertEqual(uhd.resolution, 2160)
        XCTAssertEqual(fhd.resolution, 1080)
        XCTAssertNil(make(stream(name: "Torrentio", description: "Movie.2024.WEB-DL")).resolution)
    }

    // MARK: - Readable row fields (polish D1/D3)

    private let torrentHash = "0123456789abcdef0123456789abcdef01234567"

    func testMakeDerivesTheFactLines() {
        let model = make(stream())
        XCTAssertEqual(model.videoFacts.count, 2, "source type and codec: \(model.videoFacts)")
        XCTAssertEqual(model.videoFacts.first, "WEB-DL")
        XCTAssertEqual(model.audioFacts.first, "Atmos DD+", "the parser reads no channel layout from DDP5.1: \(model.audioFacts)")
    }

    func testAStreamWithNoResolutionShowsItsTitle() {
        let model = make(stream(name: "Stream", description: "release"))
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.headline)
        XCTAssertNil(model.hdrMark, "no headline, no mark")
        XCTAssertEqual(model.title, "Stream")
    }

    func testNoResolutionPlusCachedKeepsTheSuffixAndDropsTheGlyph() {
        let s = stream(name: "Torrentio", description: "release", url: nil, infoHash: torrentHash, cache: cached())
        let model = make(s, display: StreamRowDisplay(instantSuffix: true))
        XCTAssertNil(model.headline)
        XCTAssertTrue(model.title.contains("Instant"), model.title)
        XCTAssertNil(model.cachedState, "exactly one of the title and the glyph says Instant")
    }

    func testAHeadlineMovesInstantFromTheTitleToTheGlyph() {
        let s = stream(name: "Torrentio", description: "Movie.2024.2160p.WEB-DL", url: nil, infoHash: torrentHash,
                       cache: cached())
        let model = make(s, display: StreamRowDisplay(instantSuffix: true))
        XCTAssertEqual(model.headline, "4K")
        XCTAssertEqual(model.title, "Torrentio", "no suffix with a headline")
        XCTAssertEqual(model.cachedState, .instant(provider: "Real-Debrid"))
    }

    func testNoResolutionCachedWithTheSuffixOffShowsTheGlyph() {
        let s = stream(name: "Torrentio", description: "release", url: nil, infoHash: torrentHash, cache: cached())
        let model = make(s, display: StreamRowDisplay(instantSuffix: false))
        XCTAssertEqual(model.title, "Torrentio")
        XCTAssertEqual(model.cachedState, .instant(provider: "Real-Debrid"))
    }

    func testAPlainHttpStreamWithACachedStatusHasNoGlyph() {
        let model = make(stream(cache: cached()), display: StreamRowDisplay(instantSuffix: true))
        XCTAssertNil(model.cachedState, "facts.cached is nil for a direct link")
    }

    // MARK: - Equality of the readable row fields

    func testTheHeadlineAndHdrMarkAreDerivedFromTheRelease() {
        let dv = make(stream(name: "T", description: "Movie.2024.2160p.WEB-DL.DV.HEVC"))
        let hdr10 = make(stream(name: "T", description: "Movie.2024.2160p.WEB-DL.HDR10.HEVC"))
        XCTAssertEqual(dv.headline, hdr10.headline)
        XCTAssertNotEqual(dv.hdrMark, hdr10.hdrMark)
        XCTAssertNotEqual(dv, hdr10)
        let hd = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.DV.HEVC"))
        XCTAssertNotEqual(dv.headline, hd.headline)
        XCTAssertNotEqual(dv, hd)
    }

    func testTheVideoFactsAreDerivedFromTheRelease() {
        let web = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC"))
        let blu = make(stream(name: "T", description: "Movie.2024.1080p.BluRay.HEVC"))
        XCTAssertNotEqual(web.videoFacts, blu.videoFacts)
        XCTAssertNotEqual(web, blu)
    }

    func testTheAudioFactsAreDerivedFromTheRelease() {
        let ddp = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.DDP5.1.HEVC"))
        let aac = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.AAC.HEVC"))
        XCTAssertNotEqual(ddp.audioFacts, aac.audioFacts)
        XCTAssertNotEqual(ddp, aac)
        let withLanguage = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.AAC.HEVC.FRENCH"))
        XCTAssertNotEqual(aac, withLanguage, "a language was added to the audio line")
    }

    func testTheCachedStateIsDerivedFromTheCacheStatus() {
        func model(_ cache: StreamDebridCacheStatus?, torrent: Bool) -> StreamRowModel {
            make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL", url: torrent ? nil : "https://cdn.example.com/a.mkv",
                        infoHash: torrent ? torrentHash : nil, cache: cache))
        }
        let instant = model(cached(), torrent: true)
        let notCached = model(StreamDebridCacheStatus(providerId: "rd", providerName: "Real-Debrid", state: .notCached,
                                                      cachedName: nil, cachedSize: nil), torrent: true)
        let plain = model(nil, torrent: false)
        XCTAssertEqual(instant.cachedState, .instant(provider: "Real-Debrid"))
        XCTAssertNil(plain.cachedState)
        XCTAssertNotEqual(instant, plain)
        XCTAssertNotEqual(instant.cachedState, notCached.cachedState)
        XCTAssertNotEqual(instant, notCached)
    }

    // MARK: - Equality of the readable row fields (one field at a time)

    /// A copy of `m` through the memberwise init with only the named fields replaced, so the two
    /// models differ in that one field alone (`description` and the playback key stay equal).
    /// `.some(nil)` sets an optional field to nil; the default leaves it as it was.
    private func copy(_ m: StreamRowModel, resolution: Int?? = .none, headline: String?? = .none,
                      hdrMark: String?? = .none, videoFacts: [String]? = nil, audioFacts: [String]? = nil,
                      cachedState: StreamRowCachedState?? = .none, showsAddonName: Bool? = nil,
                      audio: String?? = .none) -> StreamRowModel {
        StreamRowModel(
            key: m.key, title: m.title, description: m.description, badges: m.badges, sizeBytes: m.sizeBytes,
            badgesOnTop: m.badgesOnTop, showsAddonColumn: m.showsAddonColumn, showsAddonName: showsAddonName ?? m.showsAddonName, addonName: m.addonName,
            addonLogo: m.addonLogo, isYouTube: m.isYouTube, playbackKey: m.playbackKey,
            resolution: resolution ?? m.resolution, headline: headline ?? m.headline,
            hdrMark: hdrMark ?? m.hdrMark, videoFacts: videoFacts ?? m.videoFacts,
            audioFacts: audioFacts ?? m.audioFacts, cachedState: cachedState ?? m.cachedState,
            audio: audio ?? m.audio, wide: m.wide, addonText: m.addonText, nameLines: m.nameLines,
            addonCachedState: m.addonCachedState, sizeInAddonText: m.sizeInAddonText
        )
    }

    func testTheAddonNameIsAlwaysDrawnOnAHeadlineRow() {
        let headlineStream = stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC", addonName: "Comet",
                                    addonLogo: "https://cdn.example.com/logo.png")
        let off = make(headlineStream, display: StreamRowDisplay(showAddonLogo: false))
        XCTAssertNotNil(off.headline)
        XCTAssertTrue(off.showsAddonName, "the headline replaced the title, so the name is drawn")
        XCTAssertFalse(off.showsAddonColumn, "the logo stays behind the setting")
        XCTAssertTrue(off.spokenLabel.contains("Comet"), off.spokenLabel)
        let on = make(headlineStream, display: StreamRowDisplay(showAddonLogo: true))
        XCTAssertTrue(on.showsAddonName)
        XCTAssertTrue(on.showsAddonColumn)
    }

    func testARepositoryGroupRowShowsTheProviderNotTheRepository() {
        let s = stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC",
                       addonId: "plugin-repo:https://repo.example/manifest.json", addonName: "My Repo",
                       sourceName: "Provider A")
        let model = make(s)
        XCTAssertEqual(model.addonName, "Provider A")
        XCTAssertTrue(model.showsAddonName)
        XCTAssertTrue(model.spokenLabel.contains("Provider A"), model.spokenLabel)
        XCTAssertFalse(model.spokenLabel.contains("My Repo"), model.spokenLabel)
    }

    func testARepositoryGroupRowNamesTheProviderWithoutAHeadlineAndTheLogoOff() {
        // Review r1: no resolution in the title or release, logo column off: the provider still shows.
        let s = stream(name: "Stream", description: "generic release",
                       addonId: "plugin-repo:https://repo.example/manifest.json", addonName: "My Repo",
                       sourceName: "Provider A")
        let off = make(s, display: StreamRowDisplay(showAddonLogo: false))
        XCTAssertNil(off.headline)
        XCTAssertTrue(off.showsAddonName)
        XCTAssertEqual(off.addonName, "Provider A")
        XCTAssertTrue(off.spokenLabel.contains("Provider A"), off.spokenLabel)
        // A plain add-on row with the same shape keeps the setting (its header names the add-on).
        let plain = make(stream(name: "Stream", description: "generic release", addonId: "com.comet", addonName: "Comet"),
                         display: StreamRowDisplay(showAddonLogo: false))
        XCTAssertFalse(plain.showsAddonName)
    }

    func testOtherRowsAndMissingProviderNamesKeepTheAddonName() {
        let pluginRow = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC",
                                    addonId: "plugin:abc", addonName: "Provider A", sourceName: "Provider A"))
        XCTAssertEqual(pluginRow.addonName, "Provider A")
        let repoPrefix = "plugin-repo:https://repo.example/manifest.json"
        for source in [nil, "", "  "] as [String?] {
            let model = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC",
                                    addonId: repoPrefix, addonName: "My Repo", sourceName: source))
            XCTAssertEqual(model.addonName, "My Repo", "sourceName \(String(describing: source))")
        }
        let addonRow = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC",
                                   addonId: "com.comet", addonName: "Comet", sourceName: "Ignored"))
        XCTAssertEqual(addonRow.addonName, "Comet")
    }

    func testTheSpokenLabelCarriesFailedYouTubeAndBadges() {
        let s = stream(name: "T", description: "Movie.2024.1080p.WEB-DL.HEVC", ytId: "abc123", badges: [badge("DV")])
        let model = make(s)
        XCTAssertFalse(model.spokenLabel.contains("Failed recently"))
        let failed = model.applying(isResolving: false, failedRecently: true, players: [], defaultPlayerId: nil)
        XCTAssertTrue(failed.spokenLabel.hasSuffix("Failed recently"), failed.spokenLabel)
        XCTAssertTrue(failed.spokenLabel.contains("DV"), "badge names are read")
        XCTAssertEqual(failed.isYouTube, model.isYouTube)
        if model.isYouTube { XCTAssertTrue(failed.spokenLabel.contains("YouTube")) }
    }

    func testATitleFallbackRowFollowsTheSetting() {
        let plain = stream(name: "Stream", description: "release", addonName: "Comet")
        let off = make(plain, display: StreamRowDisplay(showAddonLogo: false))
        XCTAssertNil(off.headline)
        XCTAssertFalse(off.showsAddonName)
        XCTAssertFalse(off.spokenLabel.contains("Comet"))
        let on = make(plain, display: StreamRowDisplay(showAddonLogo: true))
        XCTAssertTrue(on.showsAddonName)
        XCTAssertTrue(on.showsAddonColumn)
    }

    func testEachReadableRowFieldAloneBreaksEquality() {
        let base = make(stream(name: "T", description: "Movie.2024.1080p.WEB-DL.DV.HEVC"))
        XCTAssertEqual(base, copy(base), "the helper changes nothing by itself")
        XCTAssertNotEqual(base, copy(base, resolution: .some(720)), "resolution")
        XCTAssertNotEqual(base, copy(base, headline: .some("720p")), "headline")
        XCTAssertNotEqual(base, copy(base, hdrMark: .some("HDR10")), "hdrMark")
        XCTAssertNotEqual(base, copy(base, hdrMark: .some(nil)), "hdrMark cleared")
        XCTAssertNotEqual(base, copy(base, showsAddonName: !base.showsAddonName), "showsAddonName")
        XCTAssertNotEqual(base, copy(base, videoFacts: base.videoFacts + ["AV1"]), "videoFacts")
        XCTAssertNotEqual(base, copy(base, audioFacts: base.audioFacts + ["French"]), "audioFacts")
        XCTAssertNotEqual(base, copy(base, audio: .some("TrueHD")), "audio")
        XCTAssertNotEqual(copy(base, audio: .some("TrueHD")), copy(base, audio: .some(nil)), "audio cleared")
        XCTAssertNotEqual(base, copy(base, cachedState: .some(.instant(provider: "Real-Debrid"))), "cachedState")
        XCTAssertNotEqual(copy(base, cachedState: .some(.instant(provider: "A"))),
                          copy(base, cachedState: .some(.instant(provider: "B"))), "cachedState provider")
        XCTAssertNotEqual(copy(base, cachedState: .some(.instant(provider: nil))),
                          copy(base, cachedState: .some(.notCached)), "cachedState case")
    }

    func testTheKeyTitleDescriptionAndBadgesArePartOfEquality() {
        XCTAssertNotEqual(base(), make(stream(size: 2_000_000_000, badges: [badge("4K")]), key: "addon:x#other"))
        XCTAssertNotEqual(base(), make(stream(name: "Other", size: 2_000_000_000, badges: [badge("4K")])))
        XCTAssertNotEqual(base(), make(stream(description: "Other.Release", size: 2_000_000_000, badges: [badge("4K")])))
        XCTAssertNotEqual(base(), make(stream(size: 2_000_000_000, badges: [badge("HDR")])))
        XCTAssertNotEqual(base(), make(stream(size: 2_000_000_000, badges: [])))
    }

    func testTheRowViewComparesOnlyItsModel() {
        let a = StreamRowView(model: base(), onSelect: {}, onBuiltIn: {}, onExternal: { _ in })
        let b = StreamRowView(model: base(), onSelect: { _ = 1 }, onBuiltIn: {}, onExternal: { _ in })
        XCTAssertTrue(a == b, "the closures are not part of the row's identity")
        let busy = StreamRowView(model: base().applying(isResolving: true, failedRecently: false, players: [],
                                                         defaultPlayerId: nil),
                                 onSelect: {}, onBuiltIn: {}, onExternal: { _ in })
        XCTAssertFalse(a == busy)
    }

    // MARK: - StreamsViewModel.apply (F4)

    private func state(_ groups: [AddonStreamGroup], loading: Bool = false) -> StreamsUiState {
        StreamsUiState(
            requestToken: "t", groups: groups, activeAddonIds: [], installedAddonIds: ["addon:x"],
            selectedFilter: nil, isAnyLoading: loading, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    private func addonGroup(_ streams: [StreamItem], id: String = "addon:x", loading: Bool = false) -> AddonStreamGroup {
        AddonStreamGroup(addonName: "Add-on", addonId: id, streams: streams, isLoading: loading, error: nil)
    }

    private func twoStreams(url: String = "https://cdn.example.com/b.mkv") -> [StreamItem] {
        [stream(name: "A", description: "A.release", url: "https://cdn.example.com/a.mkv"),
         stream(name: "B", description: "B.release", url: url)]
    }

    func testApplyBuildsOneRowAndKeyPerStream() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([addonGroup(twoStreams())]))
        XCTAssertEqual(vm.groups.count, 1)
        let g = vm.groups[0]
        XCTAssertEqual(g.streams.count, 2)
        XCTAssertEqual(g.rows.count, 2)
        XCTAssertEqual(g.rowKeys.count, 2)
        XCTAssertEqual(g.rows.map(\.key), g.rowKeys, "the rows carry the focus keys")
        XCTAssertEqual(Set(g.rowKeys).count, 2)
        XCTAssertEqual(vm.firstRowKey, g.rowKeys.first)
        XCTAssertEqual(g.rows.map(\.title), ["A", "B"])
    }

    func testAnIdenticalRepublishPublishesNothing() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        var sends = 0
        let sub = vm.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }

        vm.apply(state([addonGroup(twoStreams())]))
        XCTAssertGreaterThan(sends, 0, "the first emission publishes the list")
        let afterFirst = sends

        // The same list again, from fresh Kotlin objects: a streaming add-on re-emits like this.
        vm.apply(state([addonGroup(twoStreams())]))
        XCTAssertEqual(sends, afterFirst, "an equal list must not invalidate the picker")
    }

    func testARowKeepsItsKeyAcrossRepublishes() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([addonGroup(twoStreams())], loading: true))
        let keys = vm.groups[0].rowKeys
        // A second add-on streams in and the first one finishes.
        vm.apply(state([addonGroup(twoStreams()), addonGroup([stream(name: "C", description: "C.release",
                                                                     url: "https://cdn.example.com/c.mkv",
                                                                     addonId: "addon:y")], id: "addon:y")],
                          loading: false))
        XCTAssertEqual(vm.groups.count, 2)
        XCTAssertEqual(vm.groups[0].rowKeys, keys, "initial focus and restore rely on stable keys")
    }

    func testALoadingFlipRepublishesButReusesTheRows() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        var sends = 0
        let sub = vm.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }
        vm.apply(state([addonGroup(twoStreams(), loading: true)], loading: true))
        let rows = vm.groups[0].rows
        XCTAssertTrue(vm.groups[0].isLoading)
        let before = sends

        vm.apply(state([addonGroup(twoStreams(), loading: false)], loading: false))
        XCTAssertGreaterThan(sends, before, "the header spinner must go")
        XCTAssertFalse(vm.groups[0].isLoading)
        XCTAssertEqual(vm.groups[0].rows, rows)
    }

    /// A debrid preparation swaps a resolved URL into the same row (same name, description and hash,
    /// so the same key): the list must republish, or a press would play the stale stream.
    func testASwappedStreamUnderTheSameKeyIsRepublished() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([addonGroup(twoStreams(url: "https://cdn.example.com/b.mkv"))]))
        let keys = vm.groups[0].rowKeys

        vm.apply(state([addonGroup(twoStreams(url: "https://cdn.example.com/b-resolved.mkv"))]))
        XCTAssertEqual(vm.groups[0].rowKeys, keys, "same identity, same focus keys")
        let url: String? = vm.groups[0].streams[1].url
        XCTAssertEqual(url, "https://cdn.example.com/b-resolved.mkv")
    }

    func testAnEmptyListClearsTheFirstRowKey() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.apply(state([addonGroup(twoStreams())]))
        XCTAssertNotNil(vm.firstRowKey)
        vm.apply(state([]))
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.firstRowKey)
    }
}
