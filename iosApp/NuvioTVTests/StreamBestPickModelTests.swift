import XCTest
@testable import NuvioTV

/// Direction C: the best-pick card's text rules (`StreamPickerCopy`) and the value types they feed
/// (`StreamBestPickModel`, `StreamAlternativeModel`). Pure: rows are built by hand, sizes are read
/// through `StreamFileSizeChip.label` rather than hard-coded.
@MainActor
final class StreamBestPickModelTests: XCTestCase {

    // MARK: - Builder

    private func row(key: String = "k", title: String = "Torrentio - TB Instant", headline: String? = "1080p",
                     hdrMark: String? = nil, videoFacts: [String] = [], audio: String? = nil,
                     cached: StreamRowCachedState? = nil, size: Int64? = nil,
                     addon: String = "Torrentio") -> StreamRowModel {
        StreamRowModel(
            key: key, title: title, description: nil, badges: [], sizeBytes: size, badgesOnTop: false,
            showsAddonColumn: false, showsAddonName: true, addonName: addon, addonLogo: nil, isYouTube: false,
            playbackKey: "pk-" + key, resolution: nil, headline: headline, hdrMark: hdrMark,
            videoFacts: videoFacts, audioFacts: [], cachedState: cached, audio: audio
        )
    }

    // MARK: - HDR

    func testHdrSpelledOut() {
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("DV"), "Dolby Vision")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("DV · HDR10"), "Dolby Vision + HDR10")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("DV · HDR10+"), "Dolby Vision + HDR10+")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("DV · HLG"), "Dolby Vision + HLG")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("DV · HDR"), "Dolby Vision + HDR")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("HDR10+"), "HDR10+")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("HDR10"), "HDR10")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("HLG"), "HLG")
        XCTAssertEqual(StreamPickerCopy.hdrSpelledOut("HDR"), "HDR")
        XCTAssertNil(StreamPickerCopy.hdrSpelledOut(nil))
        XCTAssertNil(StreamPickerCopy.hdrSpelledOut("  "), "a blank mark is no mark")
    }

    // MARK: - Headline

    func testCardHeadlineSpellsOutHdrAndAddsTheFirstAudioTerm() {
        XCTAssertEqual(StreamPickerCopy.cardHeadline(row(headline: "4K", hdrMark: "DV", audio: "Atmos DD+ 5.1")),
                       "4K Dolby Vision · Atmos DD+ 5.1")
        XCTAssertEqual(StreamPickerCopy.cardHeadline(row(headline: "1080p", hdrMark: nil, audio: "AAC 2.0")),
                       "1080p · AAC 2.0")
        XCTAssertEqual(StreamPickerCopy.cardHeadline(row(headline: "4K", hdrMark: "DV · HDR10", audio: nil)),
                       "4K Dolby Vision + HDR10")
        XCTAssertEqual(StreamPickerCopy.cardHeadline(row(headline: "1080p", hdrMark: nil, audio: nil)), "1080p")
    }

    func testCardHeadlineFallsBackToTheTitleWithoutAHeadline() {
        let r = row(title: "Torrentio - TB Instant", headline: nil, hdrMark: nil, audio: "AAC")
        XCTAssertEqual(StreamPickerCopy.cardHeadline(r), "Torrentio - TB Instant",
                       "no headline: the title alone, no audio term")
    }

    // MARK: - Facts line

    func testCardFactsOrderAndCachedWords() {
        let size: Int64 = 3_100_000_000
        let label = StreamFileSizeChip.label(for: size)
        let sep = " · "
        XCTAssertEqual(
            StreamPickerCopy.cardFacts(row(videoFacts: ["WEB-DL", "HEVC"], cached: .instant(provider: "TB"),
                                           size: size, addon: "Torrentio")),
            ["Torrentio", "WEB-DL", "HEVC", label, "cached on TB"].joined(separator: sep))
        let noProvider = StreamPickerCopy.cardFacts(row(videoFacts: ["WEB-DL"], cached: .instant(provider: nil),
                                                         size: size, addon: "Torrentio"))
        XCTAssertEqual(noProvider, ["Torrentio", "WEB-DL", label, "cached"].joined(separator: sep))
        let notCached = StreamPickerCopy.cardFacts(row(videoFacts: [], cached: .notCached, size: size))
        XCTAssertEqual(notCached, ["Torrentio", label, "not cached"].joined(separator: sep))
    }

    func testCardFactsNameTheProviderOfARepositoryGroupStream() {
        let item = StreamItem(
            name: "T", title: nil, description: "Movie.2024.1080p.WEB-DL.HEVC", url: "https://cdn.example.com/m.mkv",
            infoHash: nil, fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: "Provider A",
            addonName: "My Repo", addonId: "plugin-repo:https://repo.example/manifest.json", addonLogo: nil,
            streamType: nil,
            behaviorHints: StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                               filename: nil, proxyHeaders: nil, audioDelayMs: nil),
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: []
        )
        let model = StreamRowModel.make(stream: item, facts: StreamFactsParser.shared.parse(stream: item),
                                        key: "k", display: StreamRowDisplay(), providerLabel: { $0.providerName })
        let facts = StreamPickerCopy.cardFacts(model)
        XCTAssertNotNil(facts)
        XCTAssertTrue(facts?.hasPrefix("Provider A") == true, facts ?? "nil")
        XCTAssertFalse(facts?.contains("My Repo") == true, facts ?? "nil")
    }

    func testCardFactsDropMissingParts() {
        XCTAssertEqual(StreamPickerCopy.cardFacts(row(videoFacts: ["WEB-DL"], cached: nil, size: nil)),
                       "Torrentio · WEB-DL", "no cached state and no size: neither part")
        let size: Int64 = 1_000_000_000
        XCTAssertEqual(StreamPickerCopy.cardFacts(row(videoFacts: [], cached: nil, size: size)),
                       "Torrentio · " + StreamFileSizeChip.label(for: size))
        XCTAssertNil(StreamPickerCopy.cardFacts(row(videoFacts: [], cached: nil, size: nil, addon: "")),
                     "every part missing: the line is not drawn")
        XCTAssertNil(StreamPickerCopy.cardFacts(row(videoFacts: [], cached: nil, size: nil, addon: "  ")))
    }

    // MARK: - Rank line, kicker, pills

    func testRankLine() {
        XCTAssertEqual(StreamPickerCopy.rankLine(considered: 73),
                       "Best of 73 · resolution, then HDR, then cached, then size")
        XCTAssertEqual(StreamPickerCopy.rankLine(considered: 1),
                       "Best of 1 · resolution, then HDR, then cached, then size")
    }

    func testKicker() {
        XCTAssertEqual(StreamPickerCopy.kicker(settled: true, resumeLabel: nil), "Best Pick")
        XCTAssertEqual(StreamPickerCopy.kicker(settled: false, resumeLabel: nil), "Best So Far")
        XCTAssertEqual(StreamPickerCopy.kicker(settled: true, resumeLabel: "Resume from 12:04"),
                       "Best Pick · Resume from 12:04")
        XCTAssertEqual(StreamPickerCopy.kicker(settled: true, resumeLabel: "  "), "Best Pick", "blank resume label")
    }

    func testPillTitles() {
        let size: Int64 = 1_900_000_000
        let label = StreamFileSizeChip.label(for: size)
        XCTAssertEqual(StreamPickerCopy.pillTitle(.bestFhd, row(size: size)), "Best 1080p · " + label)
        XCTAssertEqual(StreamPickerCopy.pillTitle(.bestFhd, row(size: nil)), "Best 1080p")
        XCTAssertEqual(StreamPickerCopy.pillTitle(.bestDirect, row(size: size)), "Best direct link · " + label)
        XCTAssertEqual(StreamPickerCopy.pillTitle(.bestDirect, row(size: nil)), "Best direct link")
        XCTAssertEqual(StreamPickerCopy.pillTitle(.showAll, row(size: size)), "", "Show all has no row")
        XCTAssertEqual(StreamPickerCopy.showAllTitle(73), "Show all 73")
        XCTAssertEqual(StreamPickerCopy.moreText(10), "10 more")
        XCTAssertEqual(StreamPickerCopy.moreText(1), "1 more")
        XCTAssertEqual(StreamPickerCopy.moreSpokenLabel(sectionTitle: "1080p", hidden: 10), "1080p, 10 more")
    }

    // MARK: - Spoken label

    func testCardSpokenLabelJoinsKickerHeadlineFactsAndRank() {
        let model = StreamBestPickModel(rowKey: "k", isSettled: true, headline: "4K Dolby Vision",
                                        facts: "Torrentio · WEB-DL", rankLine: "Best of 6 · x", considered: 6)
        XCTAssertEqual(StreamPickerCopy.cardSpokenLabel(model, resumeLabel: nil),
                       "Best Pick, 4K Dolby Vision, Torrentio · WEB-DL, Best of 6 · x")
        XCTAssertEqual(StreamPickerCopy.cardSpokenLabel(model, resumeLabel: "Resume from 1:00"),
                       "Best Pick · Resume from 1:00, 4K Dolby Vision, Torrentio · WEB-DL, Best of 6 · x")
        let noFacts = StreamBestPickModel(rowKey: "k", isSettled: false, headline: "1080p", facts: nil,
                                          rankLine: "Best of 2 · x", considered: 2)
        XCTAssertEqual(StreamPickerCopy.cardSpokenLabel(noFacts, resumeLabel: nil),
                       "Best So Far, 1080p, Best of 2 · x", "facts nil: three parts")
    }

    // MARK: - Equality

    func testEachBestPickFieldAloneBreaksEquality() {
        let base = StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h", facts: "f",
                                       rankLine: "r", considered: 3)
        XCTAssertEqual(base, StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h", facts: "f",
                                                 rankLine: "r", considered: 3))
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k2", isSettled: true, headline: "h", facts: "f",
                                                    rankLine: "r", considered: 3), "rowKey")
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k", isSettled: false, headline: "h", facts: "f",
                                                    rankLine: "r", considered: 3), "isSettled")
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h2", facts: "f",
                                                    rankLine: "r", considered: 3), "headline")
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h", facts: nil,
                                                    rankLine: "r", considered: 3), "facts")
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h", facts: "f",
                                                    rankLine: "r2", considered: 3), "rankLine")
        XCTAssertNotEqual(base, StreamBestPickModel(rowKey: "k", isSettled: true, headline: "h", facts: "f",
                                                    rankLine: "r", considered: 4), "considered")
    }

    func testEachAlternativeFieldAloneBreaksEquality() {
        let base = StreamAlternativeModel(kind: .bestFhd, rowKey: "k", title: "t")
        XCTAssertEqual(base, StreamAlternativeModel(kind: .bestFhd, rowKey: "k", title: "t"))
        XCTAssertNotEqual(base, StreamAlternativeModel(kind: .bestDirect, rowKey: "k", title: "t"), "kind")
        XCTAssertNotEqual(base, StreamAlternativeModel(kind: .bestFhd, rowKey: "k2", title: "t"), "rowKey")
        XCTAssertNotEqual(base, StreamAlternativeModel(kind: .bestFhd, rowKey: "k", title: "t2"), "title")
    }

    func testAlternativeKeysAndIdentifiers() {
        XCTAssertEqual(StreamAlternativeModel(kind: .bestFhd, rowKey: "k", title: "").focusKey, "alt:fhd")
        XCTAssertEqual(StreamAlternativeModel(kind: .bestDirect, rowKey: "k", title: "").focusKey, "alt:direct")
        XCTAssertEqual(StreamAlternativeModel(kind: .showAll, rowKey: nil, title: "").focusKey, "alt:all")
        XCTAssertEqual(StreamAlternativeModel(kind: .showAll, rowKey: nil, title: "").accessibilityID,
                       "stream_picker_show_all")
        XCTAssertEqual(StreamBestPickModel.focusKey, "bestpick")
    }
}
