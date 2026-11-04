import XCTest
@testable import NuvioTV
import SharedCore

/// `PlaybackContext.subtitleRequestExtras`: the stream's behaviorHints (filename / videoSize /
/// videoHash) reach the add-on subtitle request's extras segment, with the shared URL-basename
/// fallback and the local-file exclusion.
final class PlaybackSubtitleExtrasTests: XCTestCase {

    private func context(url: String, filename: String? = nil, size: Int64? = nil, hash: String? = nil) -> PlaybackContext {
        PlaybackContext(
            url: URL(string: url)!, title: "Movie", contentType: "movie", parentMetaId: "tt1", videoId: "tt1",
            season: nil, episode: nil, poster: nil, background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [],
            fileSizeBytes: size, streamFilename: filename, videoHash: hash
        )
    }

    func testAllHintsGoOutInStremioOrder() {
        let extras = context(url: "https://cdn.example.com/dl/abc", filename: "Movie 2024.mkv",
                             size: 1_632_335_363, hash: "9d8c1e6c3d434f50").subtitleRequestExtras
        XCTAssertEqual(extras?.toPathSegment(),
                       "videoHash=9d8c1e6c3d434f50&videoSize=1632335363&filename=Movie%202024.mkv")
    }

    func testFilenameFallsBackToUrlBasename() {
        let extras = context(url: "https://cdn.example.com/files/Show.S01E02.mkv?token=1", size: 42).subtitleRequestExtras
        XCTAssertEqual(extras?.filename, "Show.S01E02.mkv")
        XCTAssertEqual(extras?.videoSize?.int64Value, 42)
        XCTAssertNil(extras?.videoHash)
    }

    func testNothingUsableMeansNoExtras() {
        XCTAssertNil(context(url: "https://cdn.example.com/stream").subtitleRequestExtras)
    }

    func testLocalFilesCarryNoExtras() {
        XCTAssertNil(context(url: "file:///tmp/Movie.mkv", filename: "Movie.mkv", size: 42).subtitleRequestExtras)
    }

    func testHashableSourcesMatchTheSharedRule() {
        XCTAssertTrue(SubtitleRequestExtrasKt.isHashableSubtitleSource(url: "https://cdn.example.com/a.mkv"))
        XCTAssertFalse(SubtitleRequestExtrasKt.isHashableSubtitleSource(url: "http://127.0.0.1:8080/index.m3u8"))
    }
}
