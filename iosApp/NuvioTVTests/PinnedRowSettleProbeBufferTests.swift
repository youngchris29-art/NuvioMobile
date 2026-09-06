import XCTest
@testable import NuvioTV

/// Unit tests for `PinnedRowSettleProbe`'s head-preserving ring buffer (beta.18-rc2, BUG-89) — the
/// persisted `debug.pinnedRowSettleProbe.lines` buffer the About pane renders for a device-pass
/// photo. Mirrors `HomeHeroProbeBufferTests` exactly, because the buffer is the same mechanism with
/// its own key and its own head/tail sizing: the first `headMaxLines` lines are frozen forever and
/// only a `tailMaxLines` window rolls after that, with a single elision-count marker once eviction
/// has actually started.
///
/// `PinnedRowSettleProbe.log(_:)` is NOT gated by `PinnedRowSettleProbe.enabled` internally — every
/// call site (`BrowseComponents.swift`, `HomeView.swift`) wraps its own call in
/// `if PinnedRowSettleProbe.enabled { … }`, but `log` itself always appends. So this test drives
/// the real buffer directly via `@testable import` without touching the `debug.pinnedRowSettleProbe`
/// default at all — which is read once into a `static let` at first access anyway, so flipping it
/// after the fact would do nothing.
///
/// Same caveat as the hero buffer's test: `headLines`/`tailLines`/`elidedTailCount` are
/// process-global statics with no reset hook (by design — "fresh statics for this process" starts
/// clean each real launch). Within one xctest run all test methods share that process, so this file
/// assumes it is the only thing in the target that calls `PinnedRowSettleProbe.log`; a zero-padded,
/// uniquely-prefixed marker per call keeps the assertions robust to any accidental prior appends
/// rather than assuming the buffer starts empty.
final class PinnedRowSettleProbeBufferTests: XCTestCase {

    func testHeadPreservedTailRolledWithElisionMarker() {
        PinnedRowSettleProbe.resetForTesting()   // Codex rc5 r1 (P3): a pristine buffer, every run
        let totalLines = 200
        let head = PinnedRowSettleProbe.headMaxLines   // 12
        let tail = PinnedRowSettleProbe.tailMaxLines   // 28
        XCTAssertEqual(head, 12, "test assumes the documented head size; update the math below if this constant changes")
        XCTAssertEqual(tail, 28, "test assumes the documented tail size; update the math below if this constant changes")
        // The capture protocol's whole budget: a 6-row walk down and back up must fit inside the
        // displayed window without eliding anything (see the probe's sizing note).
        XCTAssertEqual(head + tail, 40, "displayed capacity is the ~40-line volume cap the emit sites are budgeted against")

        for i in 1...totalLines {
            PinnedRowSettleProbe.log(String(format: "prsbt-probe-line-%04d", i))
        }

        guard let display = UserDefaults.standard.stringArray(forKey: PinnedRowSettleProbe.linesKey) else {
            XCTFail("expected \(PinnedRowSettleProbe.linesKey) to be populated after PinnedRowSettleProbe.log calls")
            return
        }

        // head + 1 marker + tail, once eviction has begun (it has: 200 lines fed against a
        // 12 + 28 = 40-line displayed capacity).
        XCTAssertEqual(display.count, head + 1 + tail, "unexpected displayed line count: \(display.count)")

        // First `head` entries are the FIRST `head` lines ever logged (frozen, never evicted) —
        // each stamped "<N>ms prsbt-probe-line-NNNN", so a suffix match on the zero-padded,
        // fixed-width marker is unambiguous (no digit-count collisions).
        for idx in 0..<head {
            let expectedSuffix = String(format: "prsbt-probe-line-%04d", idx + 1)
            XCTAssertTrue(
                display[idx].hasSuffix(expectedSuffix),
                "head[\(idx)] = \(display[idx]) does not end with \(expectedSuffix)"
            )
        }

        // Elision marker sits between head and tail. Its count reflects everything logged past
        // head + tail capacity: 200 - 12 - 28 = 160 (assuming this test owns the whole process's
        // worth of `PinnedRowSettleProbe.log` calls — see the caveat above).
        let expectedElided = totalLines - head - tail
        XCTAssertTrue(
            display[head].contains("\(expectedElided) lines elided"),
            "marker line = \(display[head]), expected an elided count of \(expectedElided)"
        )

        // Last `tail` entries are the LAST `tail` lines logged: 200-28+1 = 173 through 200.
        let tailStart = totalLines - tail + 1
        for offset in 0..<tail {
            let displayIdx = head + 1 + offset
            let expectedSuffix = String(format: "prsbt-probe-line-%04d", tailStart + offset)
            XCTAssertTrue(
                display[displayIdx].hasSuffix(expectedSuffix),
                "tail[\(offset)] = \(display[displayIdx]) does not end with \(expectedSuffix)"
            )
        }

        // Every line carries the `<N>ms ` launch stamp the pane's reader dates the walk by.
        for line in display where !line.contains("lines elided") {
            XCTAssertNotNil(
                line.range(of: #"^\d+ms "#, options: .regularExpression),
                "line is missing its sinceLaunch stamp: \(line)"
            )
        }
    }
}
