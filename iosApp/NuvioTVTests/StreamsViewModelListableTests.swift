import XCTest
import SharedCore
@testable import NuvioTV

/// Batch D U2 (upstream 94976222): which streams the picker lists. `StreamsViewModel.apply` runs
/// every shared stream through `isListable`; the auto-play walk uses its own narrower filters.
@MainActor
final class StreamsViewModelListableTests: XCTestCase {

    private let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                            filename: nil, proxyHeaders: nil, audioDelayMs: nil)

    private func stream(url: String? = nil, infoHash: String? = nil, externalUrl: String? = nil,
                        ytId: String? = nil, addonId: String = "addon:x") -> StreamItem {
        StreamItem(
            name: "Stream", title: nil, description: nil, url: url, infoHash: infoHash, fileIdx: nil,
            externalUrl: externalUrl, ytId: ytId, sources: [], sourceName: nil, addonName: "Add-on", addonId: addonId,
            addonLogo: nil, streamType: nil, behaviorHints: hints,
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false
        )
    }

    func testDirectLinkIsListedWithOrWithoutDebrid() {
        let direct = stream(url: "https://cdn.example.com/file.mkv")
        XCTAssertTrue(StreamsViewModel.isListable(stream: direct, debridEnabled: false))
        XCTAssertTrue(StreamsViewModel.isListable(stream: direct, debridEnabled: true))
    }

    func testTorrentFromAnInstalledAddonNeedsDebrid() {
        let torrent = stream(infoHash: "feedface")
        XCTAssertFalse(StreamsViewModel.isListable(stream: torrent, debridEnabled: false))
        XCTAssertTrue(StreamsViewModel.isListable(stream: torrent, debridEnabled: true))
    }

    func testYouTubeOnlyStreamIsListed() {
        // Before U2 the picker dropped it: no direct link, no debrid candidate. It now shows, and
        // picking it resolves the video on the device (`StreamPickerView.internalPlay`).
        let yt = stream(ytId: "dQw4w9WgXcQ")
        let resolveId: String? = yt.youTubeIdToResolve
        XCTAssertEqual(resolveId, "dQw4w9WgXcQ", "the shared model flags a ytId-only stream for resolving")
        XCTAssertTrue(StreamsViewModel.isListable(stream: yt, debridEnabled: false))
        XCTAssertTrue(StreamsViewModel.isListable(stream: yt, debridEnabled: true))
    }

    func testYouTubeIdBesideALinkIsNotAResolveCase() {
        // The link plays as before; the ytId is ignored (shared `youTubeIdToResolve` is nil).
        let both = stream(url: "https://cdn.example.com/file.mkv", ytId: "dQw4w9WgXcQ")
        let resolveId: String? = both.youTubeIdToResolve
        XCTAssertNil(resolveId)
        XCTAssertTrue(StreamsViewModel.isListable(stream: both, debridEnabled: false))
        XCTAssertFalse(StreamPickerView.isYouTubeResolved(both))
        XCTAssertTrue(StreamPickerView.isYouTubeResolved(stream(ytId: "dQw4w9WgXcQ")))
        XCTAssertFalse(StreamPickerView.isYouTubeResolved(nil))
    }

    func testNothingPlayableIsNotListed() {
        XCTAssertFalse(StreamsViewModel.isListable(stream: stream(), debridEnabled: true))
    }
}
