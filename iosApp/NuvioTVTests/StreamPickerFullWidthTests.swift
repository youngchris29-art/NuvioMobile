import XCTest
import SharedCore
@testable import NuvioTV

/// GitHub #25: "Source Layout" (Two-Pane / Full Width) and "Row Text" (Nuvio / Add-on's Own). The
/// row model's add-on text (name lines, description, size dedupe, Nuvio's own cached state only),
/// the compact row and VoiceOver in both modes, the display flags taking part in row identity, the
/// launch knobs, the Settings defaults and copy.
@MainActor
final class StreamPickerFullWidthTests: XCTestCase {

    // MARK: - Builders

    private func hints(size: Int64? = nil) -> StreamBehaviorHints {
        StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil,
                            videoSize: size.map { KotlinLong(value: $0) }, filename: nil,
                            proxyHeaders: nil, audioDelayMs: nil)
    }

    /// An AIOStreams-style stream: a multi-line `name` and a formatter-written `description`.
    private func stream(
        name: String? = "AIOStreams\n  4K ⚡ RD  \n\n",
        title: String? = nil,
        description: String? = "Movie (2024)\n🎞️ WEB-DL · HEVC · DV\n🔊 Atmos DD+ 5.1\n💾 1.9 GB · 👤 120",
        url: String? = "https://cdn.example.com/movie.mkv",
        infoHash: String? = nil,
        size: Int64? = 2_000_000_000,
        badges: [StreamBadge] = [],
        cache: StreamDebridCacheStatus? = nil
    ) -> StreamItem {
        StreamItem(
            name: name, title: title, description: description, url: url, infoHash: infoHash, fileIdx: nil,
            externalUrl: nil, ytId: nil, sources: [], sourceName: nil, addonName: "AIOStreams", addonId: "aio",
            addonLogo: nil, streamType: nil, behaviorHints: hints(size: size),
            clientResolve: nil, debridCacheStatus: cache, externalSubtitles: [], badges: badges
        )
    }

    private func status(_ state: StreamDebridCacheState) -> StreamDebridCacheStatus {
        StreamDebridCacheStatus(providerId: "rd", providerName: "RD", state: state, cachedName: nil, cachedSize: nil)
    }

    private func badge(_ name: String) -> StreamBadge {
        StreamBadge(name: name, imageURL: "", tagColor: "#222222", tagStyle: "filled",
                    textColor: "#FFFFFF", borderColor: "")
    }

    private func make(_ stream: StreamItem, addonText: Bool, fullWidth: Bool = false,
                      showFileSize: Bool = true, badgesOnTop: Bool = false) -> StreamRowModel {
        StreamRowModel.make(stream: stream, facts: StreamFactsParser.shared.parse(stream: stream),
                            key: "aio#k",
                            display: StreamRowDisplay(showFileSize: showFileSize, badgesOnTop: badgesOnTop,
                                                      showAddonLogo: false, instantSuffix: false,
                                                      fullWidth: fullWidth, addonText: addonText),
                            providerLabel: { $0.providerName })
    }

    // MARK: - Display defaults and identity

    func testDisplayDefaultsChangeNothing() {
        let display = StreamRowDisplay()
        XCTAssertFalse(display.fullWidth)
        XCTAssertFalse(display.addonText)
    }

    func testTheNewDisplayFlagsTakePartInEquality() {
        XCTAssertNotEqual(StreamRowDisplay(), StreamRowDisplay(fullWidth: true))
        XCTAssertNotEqual(StreamRowDisplay(), StreamRowDisplay(addonText: true))
        XCTAssertNotEqual(make(stream(), addonText: false), make(stream(), addonText: true),
                          "a Row Text flip must rebuild the row")
        XCTAssertNotEqual(make(stream(), addonText: false), make(stream(), addonText: false, fullWidth: true),
                          "a Source Layout flip must rebuild the row")
    }

    // MARK: - Add-on text in the row model

    func testNameLinesAreSplitTrimmedAndEmptiesDropped() {
        let model = make(stream(), addonText: true)
        XCTAssertTrue(model.addonText)
        XCTAssertEqual(model.nameLines, ["AIOStreams", "4K ⚡ RD"])
        XCTAssertEqual(StreamRowModel.textLines(nil), [])
        XCTAssertEqual(StreamRowModel.textLines(" \n \n"), [])
        XCTAssertEqual(StreamRowModel.textLines("a\r\nb"), ["a", "b"])
    }

    func testDescriptionIsTheAddonsTextWithTheLegacyTitleFallback() {
        XCTAssertEqual(make(stream(), addonText: true).description,
                       "Movie (2024)\n🎞️ WEB-DL · HEVC · DV\n🔊 Atmos DD+ 5.1\n💾 1.9 GB · 👤 120")
        let legacy = stream(title: "Movie.2024.1080p.WEB-DL", description: nil)
        XCTAssertEqual(make(legacy, addonText: true).description, "Movie.2024.1080p.WEB-DL",
                       "an add-on that fills only `title` still shows its text")
        XCTAssertNil(make(legacy, addonText: false).description, "Nuvio text keeps today's description rule")
        XCTAssertNil(make(stream(title: "  ", description: ""), addonText: true).description)
    }

    func testTheSizeIsAlwaysDrawn() {
        // Review r3: the add-on's text may carry the size past the resting line limit, so the row
        // keeps its own size rather than risk showing none.
        XCTAssertEqual(StreamFileSizeChip.label(for: 2_000_000_000), "1.9 GB")
        XCTAssertEqual(make(stream(), addonText: true).sizeBytes, 2_000_000_000)
        XCTAssertEqual(make(stream(description: "Movie.2024.2160p.WEB-DL"), addonText: true).sizeBytes, 2_000_000_000)
        XCTAssertNil(make(stream(), addonText: true, showFileSize: false).sizeBytes, "File Size Badges off")
    }

    func testTheNameShowsItsSourceOnlyAsALeadingWholeWordOfTheFirstLine() {
        XCTAssertTrue(StreamRowModel.nameShowsSource("AIOStreams", nameLines: ["AIOStreams", "4K"]))
        XCTAssertTrue(StreamRowModel.nameShowsSource("aiostreams", nameLines: ["AIOStreams 4K ⚡"]))
        XCTAssertTrue(StreamRowModel.nameShowsSource("Torrentio", nameLines: ["Torrentio: RD+", "4K"]))
        XCTAssertFalse(StreamRowModel.nameShowsSource("Torrentio", nameLines: ["4K", "Torrentio: RD+"]),
                       "a later line may be pushed out of view by a wrapping first line")
        XCTAssertFalse(StreamRowModel.nameShowsSource("RD", nameLines: ["RDX 4K"]), "never a word prefix")
        XCTAssertFalse(StreamRowModel.nameShowsSource("RD", nameLines: ["HDR RD"]), "only at the start of the line")
        XCTAssertFalse(StreamRowModel.nameShowsSource(" ", nameLines: ["x"]))
        XCTAssertFalse(StreamRowModel.nameShowsSource("A", nameLines: []))
    }

    func testShowAddonLogoKeepsTheSourceLabelOnAnAddonTextRow() {
        let model = StreamRowModel.make(stream: stream(), facts: StreamFactsParser.shared.parse(stream: stream()),
                                        key: "aio#k",
                                        display: StreamRowDisplay(showAddonLogo: true, addonText: true),
                                        providerLabel: { $0.providerName })
        XCTAssertTrue(model.showsAddonName, "the logo setting wins over the name dedupe")
        XCTAssertTrue(model.showsAddonColumn)
    }

    func testAddonCachedStateComesOnlyFromNuviosOwnDebridCheck() {
        let torrent = stream(name: "[RD+] AIOStreams\n4K", url: nil, infoHash: "abc123")
        XCTAssertNil(make(torrent, addonText: true).drawnCachedState,
                     "the add-on marks its own cache in its text: not repeated")
        XCTAssertEqual(make(stream(url: nil, infoHash: "abc123", cache: status(.cached)), addonText: true).drawnCachedState,
                       .instant(provider: "RD"))
        XCTAssertEqual(make(stream(url: nil, infoHash: "abc123", cache: status(.notCached)), addonText: true).drawnCachedState,
                       .notCached)
        XCTAssertNil(make(stream(url: nil, infoHash: "abc123", cache: status(.checking)), addonText: true).drawnCachedState)
        XCTAssertNil(make(stream(url: nil, infoHash: "abc123", cache: status(.cached)), addonText: false).addonCachedState,
                     "Nuvio text never fills the add-on cached state")
    }

    func testAnAddonTextRowNamesItsSourceUnlessItsNameDoes() {
        XCTAssertFalse(make(stream(), addonText: true).showsAddonName, "\"AIOStreams\" is already in the name")
        let bare = make(stream(name: "4K ⚡ RD"), addonText: true)
        XCTAssertTrue(bare.showsAddonName, "two add-ons can send the same name under one heading")
        XCTAssertEqual(bare.addonName, "AIOStreams")
        XCTAssertTrue(bare.spokenLabel.hasPrefix("4K ⚡ RD, AIOStreams, "), bare.spokenLabel)
    }

    func testBadgesAreFilledInBothRowTextModes() {
        let s = stream(badges: [badge("4K"), badge("DV")])
        XCTAssertEqual(make(s, addonText: false).badges.map(\.name), ["4K", "DV"])
        XCTAssertEqual(make(s, addonText: true).badges.map(\.name), ["4K", "DV"])
        XCTAssertEqual(make(s, addonText: true, fullWidth: true, badgesOnTop: true).badges.map(\.name), ["4K", "DV"])
        XCTAssertTrue(make(s, addonText: true, badgesOnTop: true).badgesOnTop, "Badge Placement is honoured")
    }

    func testParsingStillRunsInAddonText() {
        // Ranking, tiers and Best Pick read the parsed fields; add-on text changes only what is drawn.
        let model = make(stream(name: "AIOStreams\n2160p"), addonText: true)
        XCTAssertEqual(model.resolution, 2160)
        XCTAssertEqual(model.headline, "4K")
    }

    // MARK: - Wide Nuvio row

    func testWideNuvioRowFoldsTheFactLines() {
        let model = make(stream(name: "Torrentio\n4k", description: "Movie.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GROUP"),
                         addonText: false, fullWidth: true)
        XCTAssertTrue(model.wide)
        XCTAssertFalse(model.addonText)
        XCTAssertTrue(model.hasWideFactLine)
        XCTAssertEqual(model.hasWideFactLine, model.hasVideoLine || model.hasAudioLine)
    }

    func testCardCapAppliesOnlyOnFullWidth() {
        XCTAssertEqual(StreamPickerWideMetrics.cardMaxWidth(fullWidth: true), 1100)
        XCTAssertEqual(StreamPickerWideMetrics.cardMaxWidth(fullWidth: false), .infinity)
    }

    func testAddonTextRestCaps() {
        // Christian after the device pass (2026-11-08): the description shows 3 lines at rest in
        // both layouts, the whole text after the dwell; the name keeps 3.
        XCTAssertEqual(StreamPickerWideMetrics.descriptionRestLines, 3)
        XCTAssertEqual(StreamPickerWideMetrics.nameRestLines, 3)
    }

    // MARK: - Two-Pane poster (option (a) after the device pass)

    func testPosterFillsA1080pPaneBetweenTheOldAndTheNewSize() throws {
        typealias P = StreamPickerInfoPanel
        // The box measured ~840 pt; the facts and progress lines are one body line each (~39 pt).
        let reserved = P.reservedHeight(factsHeight: 39, progressHeight: 39)
        XCTAssertEqual(reserved, 180 + 39 + 39 + 4 * 24)
        let width = try XCTUnwrap(P.posterWidth(paneHeight: 840, reserved: reserved))
        XCTAssertEqual(width, ((840 - reserved) / 1.5).rounded(.down))
        XCTAssertGreaterThanOrEqual(width, 300)
        XCTAssertLessThan(width, 360)
        // Two facts lines (an episode with a long name) still leave a poster on the box.
        let twoLines = try XCTUnwrap(P.posterWidth(paneHeight: 840, reserved: P.estimatedReservedHeight))
        XCTAssertGreaterThanOrEqual(twoLines, P.posterMinimumWidth)
        XCTAssertLessThan(twoLines, width)
    }

    func testPosterCapsAt360OnATallPane() {
        typealias P = StreamPickerInfoPanel
        XCTAssertEqual(P.posterWidth(paneHeight: 2000, reserved: P.estimatedReservedHeight), 360)
        XCTAssertEqual(P.posterWidth(paneHeight: 540 + 400, reserved: 400), 360)
    }

    func testPosterHidesWhenEvenTheOldSizeDoesNotFit() {
        typealias P = StreamPickerInfoPanel
        let reserved = P.estimatedReservedHeight
        // Exactly 260 × 390 fits; one point less does not.
        XCTAssertEqual(P.posterWidth(paneHeight: reserved + 390, reserved: reserved), 260)
        XCTAssertNil(P.posterWidth(paneHeight: reserved + 389, reserved: reserved))
        XCTAssertNil(P.posterWidth(paneHeight: 500, reserved: reserved))
        XCTAssertNil(P.posterWidth(paneHeight: 0, reserved: reserved))
        XCTAssertNil(P.posterWidth(paneHeight: .infinity, reserved: reserved))
    }

    // MARK: - Compact row

    func testCompactPartsInAddonText() {
        let parts = StreamPickerCopy.compactParts(make(stream(), addonText: true))
        XCTAssertEqual(parts.lead, "AIOStreams 4K ⚡ RD")
        XCTAssertEqual(parts.facts, "Movie (2024)")
        XCTAssertNil(parts.glyph)
        XCTAssertEqual(parts.size, "1.9 GB", "the compact row always keeps its size (its one line truncates)")
        let onFirstLine = StreamPickerCopy.compactParts(make(stream(description: "💾 1.9 GB · WEB-DL"), addonText: true))
        XCTAssertEqual(onFirstLine.size, "1.9 GB")
        XCTAssertEqual(parts.trailing, "AIOStreams")

        let cachedPlain = make(stream(description: "Movie.2024", url: nil, infoHash: "h", cache: status(.cached)),
                               addonText: true)
        let p2 = StreamPickerCopy.compactParts(cachedPlain)
        XCTAssertEqual(p2.glyph, "checkmark.circle")
        XCTAssertEqual(p2.size, "1.9 GB")
    }

    func testAFailedCompactAddonRowKeepsItsSource() {
        let failed = make(stream(name: "4K ⚡ RD"), addonText: true)
            .applying(isResolving: false, failedRecently: true, players: [], defaultPlayerId: nil)
        XCTAssertEqual(StreamPickerCopy.compactParts(failed).trailing, "Failed recently · AIOStreams")
    }

    func testDwellKeyChangesWithTheText() {
        XCTAssertNotEqual(StreamRowDwell.DwellKey(focused: true, hasText: false),
                          StreamRowDwell.DwellKey(focused: true, hasText: true),
                          "a Row Text flip on the focused row re-arms the dwell")
    }

    func testCompactSpokenLabelInAddonText() {
        XCTAssertEqual(StreamPickerCopy.compactSpokenLabel(make(stream(), addonText: true)),
                       "AIOStreams 4K ⚡ RD, Movie (2024), 🎞️ WEB-DL · HEVC · DV, 🔊 Atmos DD+ 5.1, 💾 1.9 GB · 👤 120, 1.9 GB, AIOStreams",
                       "every description line is read, not only the one drawn")
    }

    func testCompactNuvioModeIsUnchanged() {
        let parts = StreamPickerCopy.compactParts(make(stream(name: "Torrentio\n4k"), addonText: false))
        XCTAssertEqual(parts.lead.hasPrefix("4K"), true)
    }

    // MARK: - VoiceOver

    func testSpokenLabelInAddonTextReadsNameDescriptionAndTail() {
        let model = make(stream(description: "Movie (2024)\nWEB-DL\n\n🔊 Atmos", badges: [badge("DV")]),
                         addonText: true)
        XCTAssertEqual(model.spokenLabel, "AIOStreams, 4K ⚡ RD, Movie (2024), WEB-DL, 🔊 Atmos, 1.9 GB, DV")
        let onTop = make(stream(description: "💾 1.9 GB", badges: [badge("DV")], cache: status(.cached)),
                         addonText: true, badgesOnTop: true)
        XCTAssertEqual(onTop.spokenLabel, "DV, AIOStreams, 4K ⚡ RD, 💾 1.9 GB, 1.9 GB, RD Instant")
        let failed = make(stream(description: nil, size: nil), addonText: true)
            .applying(isResolving: false, failedRecently: true, players: [], defaultPlayerId: nil)
        XCTAssertEqual(failed.spokenLabel, "AIOStreams, 4K ⚡ RD, Failed recently")
    }

    func testSpokenLabelInNuvioTextStillLeadsWithTheHeadline() {
        let model = make(stream(name: "Torrentio\n4k", description: "Movie.2024.2160p.WEB-DL"), addonText: false)
        XCTAssertTrue(model.spokenLabel.hasPrefix("4K"), model.spokenLabel)
    }

    // MARK: - View model

    private func settings(layout: StreamSourceLayout, rowText: StreamRowText) throws -> StreamBadgeSettingsUiState {
        StreamBadgeSettingsRepository.shared.ensureLoaded()
        let base = try XCTUnwrap(StreamBadgeSettingsRepository.shared.uiState.value_ as? StreamBadgeSettingsUiState)
        return StreamBadgeSettingsUiState(
            rules: base.rules, showFileSizeBadges: base.showFileSizeBadges, showAddonLogo: base.showAddonLogo,
            showInPlayer: base.showInPlayer, playerBadgeSource: base.playerBadgeSource,
            badgePlacement: base.badgePlacement, backgroundMode: base.backgroundMode, groupingMode: .quality,
            listOpensWith: .fullList, sourceLayout: layout, rowText: rowText
        )
    }

    private func uiState(_ groups: [AddonStreamGroup]) -> StreamsUiState {
        StreamsUiState(
            requestToken: "t", groups: groups, activeAddonIds: [], installedAddonIds: [],
            selectedFilter: nil, isAnyLoading: false, emptyStateReason: nil, autoPlayStream: nil,
            autoPlayCandidates: [], isDirectAutoPlayFlow: false, showDirectAutoPlayOverlay: false,
            overlayMessage: nil
        )
    }

    func testViewModelDefaultsAreTwoPaneAndNuvio() {
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        guard StreamSourceLayoutDebugOverride.layout() == nil, StreamRowTextDebugOverride.mode() == nil else { return }
        XCTAssertEqual(vm.sourceLayout, .twoPane)
        XCTAssertEqual(vm.rowText, .nuvio)
        XCTAssertFalse(vm.isFullWidth)
    }

    func testASettingsFlipRebuildsTheRows() throws {
        guard StreamSourceLayoutDebugOverride.layout() == nil, StreamRowTextDebugOverride.mode() == nil else { return }
        let vm = StreamsViewModel(type: "movie", videoId: "tt1")
        vm.listOpensWith = { .fullList }
        vm.receive(badgeSettings: try settings(layout: .twoPane, rowText: .nuvio))
        vm.receive(uiState([AddonStreamGroup(addonName: "AIOStreams", addonId: "aio", streams: [stream()],
                                             isLoading: false, error: nil)]))
        let before = try XCTUnwrap(vm.groups.first?.rows.first)
        XCTAssertFalse(before.addonText)
        XCTAssertFalse(before.wide)

        vm.receive(badgeSettings: try settings(layout: .twoPane, rowText: .addon))
        let addon = try XCTUnwrap(vm.groups.first?.rows.first)
        XCTAssertTrue(addon.addonText)
        XCTAssertEqual(addon.nameLines, ["AIOStreams", "4K ⚡ RD"])

        vm.receive(badgeSettings: try settings(layout: .fullWidth, rowText: .addon))
        XCTAssertTrue(vm.isFullWidth)
        XCTAssertTrue(try XCTUnwrap(vm.groups.first?.rows.first).wide)
    }

    // MARK: - Launch knobs

    func testDebugKeyNames() {
        XCTAssertEqual(StreamSourceLayoutDebugOverride.debugKey, "debug.sourceLayout")
        XCTAssertEqual(StreamRowTextDebugOverride.debugKey, "debug.rowText")
    }

    func testKnobsParseTheirSpellingsAndRejectTheRest() {
        XCTAssertEqual(StreamSourceLayoutDebugOverride.parse(" full "), .fullWidth)
        XCTAssertEqual(StreamSourceLayoutDebugOverride.parse("FULL_WIDTH"), .fullWidth)
        XCTAssertEqual(StreamSourceLayoutDebugOverride.parse("two"), .twoPane)
        XCTAssertEqual(StreamSourceLayoutDebugOverride.parse("Two_Pane"), .twoPane)
        XCTAssertNil(StreamSourceLayoutDebugOverride.parse(nil))
        XCTAssertNil(StreamSourceLayoutDebugOverride.parse("wide"))
        XCTAssertEqual(StreamRowTextDebugOverride.parse("addon"), .addon)
        XCTAssertEqual(StreamRowTextDebugOverride.parse("Add-on"), .addon)
        XCTAssertEqual(StreamRowTextDebugOverride.parse(" NUVIO "), .nuvio)
        XCTAssertNil(StreamRowTextDebugOverride.parse(""))
        XCTAssertNil(StreamRowTextDebugOverride.parse("own"))
    }

    func testKnobsReadOnlyWhenPresentAndOnlyInDebug() throws {
        let suite = "StreamPickerFullWidthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(StreamSourceLayoutDebugOverride.layout(defaults))
        XCTAssertNil(StreamRowTextDebugOverride.mode(defaults))
        defaults.set("FULL", forKey: StreamSourceLayoutDebugOverride.debugKey)
        defaults.set("ADDON", forKey: StreamRowTextDebugOverride.debugKey)
        #if DEBUG
        XCTAssertEqual(StreamSourceLayoutDebugOverride.layout(defaults), .fullWidth)
        XCTAssertEqual(StreamRowTextDebugOverride.mode(defaults), .addon)
        #else
        XCTAssertNil(StreamSourceLayoutDebugOverride.layout(defaults))
        XCTAssertNil(StreamRowTextDebugOverride.mode(defaults))
        #endif
    }

    // MARK: - Settings

    func testSettingsViewModelReadsTheDefaultsBeforeTheRepositoryEmits() {
        let vm = BadgeSettingsViewModel()
        XCTAssertEqual(vm.sourceLayout, StreamSourceLayout.twoPane)
        XCTAssertEqual(vm.rowText, StreamRowText.nuvio)
    }

    func testOptionsListTheDefaultFirst() {
        XCTAssertEqual(SourceSettingOptions.sourceLayouts, [.twoPane, .fullWidth])
        XCTAssertEqual(SourceSettingOptions.rowTextModes, [.nuvio, .addon])
        XCTAssertEqual(SourceSettingOptions.sourceLayoutName(for: .twoPane), "Two-Pane")
        XCTAssertEqual(SourceSettingOptions.sourceLayoutName(for: .fullWidth), "Full Width")
        XCTAssertEqual(SourceSettingOptions.rowTextName(for: .nuvio), "Nuvio")
        XCTAssertEqual(SourceSettingOptions.rowTextName(for: .addon), "Add-on's Own")
    }

    func testDescriptionCopyNamesBothOptionsAndTheDefault() {
        let layout = String(localized: SettingsDescriptions.text(for: .sourcesLayout))
        XCTAssertTrue(layout.hasPrefix("Two-Pane "), layout)
        XCTAssertTrue(layout.contains("Full Width "), layout)
        XCTAssertTrue(layout.hasSuffix("Default: Two-Pane."), layout)
        let rowText = String(localized: SettingsDescriptions.text(for: .sourcesRowText))
        XCTAssertTrue(rowText.hasPrefix("Nuvio "), rowText)
        XCTAssertTrue(rowText.contains("Add-on's Own "), rowText)
        XCTAssertTrue(rowText.hasSuffix("Default: Nuvio."), rowText)
    }
}
