import XCTest
import SwiftUI
import SharedCore
@testable import NuvioTV

/// Polish D1/W3-16 F2: a row at rest draws no file line, so a description never changes a resting row's height.
@MainActor
final class StreamRowDescriptionTests: XCTestCase {
    /// Of the eight focus / dwell / text combinations exactly one draws the file line. The dwell
    /// timing itself (500 ms, the unanimated collapse) is a `.task` that needs a live focus engine:
    /// device step 4 covers it, not a unit test.
    func testExactlyOneCombinationDrawsTheFileLine() {
        let flags = [false, true]
        var shown: [String] = []
        for focused in flags {
            for dwelled in flags {
                for hasText in flags where StreamRowDwell.showsLine(focused: focused, dwelled: dwelled, hasText: hasText) {
                    shown.append("focused=\(focused) dwelled=\(dwelled) hasText=\(hasText)")
                }
            }
        }
        XCTAssertEqual(shown, ["focused=true dwelled=true hasText=true"], "only a focused, dwelled row with text")
    }

    private func model(description: String?) -> StreamRowModel {
        let hints = StreamBehaviorHints(bingeGroup: nil, notWebReady: false, videoHash: nil, videoSize: nil,
                                        filename: nil, proxyHeaders: nil, audioDelayMs: nil)
        let stream = StreamItem(
            name: "Torrentio", title: nil, description: description, url: "https://cdn.example.com/a.mkv",
            infoHash: nil, fileIdx: nil, externalUrl: nil, ytId: nil, sources: [], sourceName: nil,
            addonName: "Add-on", addonId: "addon:x", addonLogo: nil, streamType: nil, behaviorHints: hints,
            clientResolve: nil, debridCacheStatus: nil, externalSubtitles: [], badges: [], debridResolved: false)
        return StreamRowModel.make(stream: stream,
                                   facts: StreamFactsParser.shared.parse(stream: stream),
                                   key: "k", display: StreamRowDisplay(),
                                   providerLabel: { $0.providerName })
    }

    func testARestingRowHasTheSameHeightWithOrWithoutADescription() {
        func height(_ description: String?) -> CGFloat {
            let view = StreamRowView(model: model(description: description), onSelect: {}, onBuiltIn: {},
                                     onExternal: { _ in })
            let host = UIHostingController(rootView: view.frame(width: 1200))
            return host.sizeThatFits(in: CGSize(width: 1200, height: 4000)).height
        }
        // The description carries no facts (the parser also reads it), so the rows differ only by the file line.
        let with = height("Some.Release.Name.With.No.Tags-GROUP")
        let without = height(nil)
        XCTAssertGreaterThan(without, 0)
        XCTAssertEqual(with, without, accuracy: 0.5, "rest draws no file line")
    }
}
