import Foundation

/// BUG-89 / BUG-66 (beta.18-rc2, Steven's video): a release-safe, PHOTOGRAPHABLE record of what
/// Home's pinned-row settle machinery decided — the same evidence a `[HomeScrollProbe]` device log
/// carries, for a tester who has a sideload and a TV and no console.
///
/// Why a second probe rather than more lines in `HomeHeroProbe`. They answer different questions
/// and are captured under different protocols: the hero probe's contract is a COLD LAUNCH left
/// untouched for 90 seconds, and its head-preserving buffer freezes exactly that launch window.
/// The settle evidence is the opposite shape — it only exists once the tester WALKS the rows, and
/// the interesting lines are the ones produced minutes after launch. Mixing them would push one
/// out of the other's photo. So: same mechanism, own key, own buffer, own toggle
/// (`debug.pinnedRowSettleProbe`), and deliberately independent of `HomeGeometryProbe.enabled` so
/// a tester can capture rests without also turning the console firehose on.
///
/// Relationship to the existing `[HomeScrollProbe]` NSLogs: none. This type NEVER NSLogs. Every
/// call site keeps its own `HomeGeometryProbe.enabled`-gated NSLog exactly as it was — the console
/// contract and its tokens are unchanged — and simply mirrors the same text in here when this
/// probe is on. Routing the NSLog through this type instead would have doubled every line whenever
/// both knobs were set, and would have changed what a device console prints, which is the one
/// thing a diagnostics change must not do.
///
/// Head/tail sizing, against the capture protocol ("relaunch, walk down every row on Home and back
/// up, then photograph this pane"): a 6-row walk down and back is ~12 focus hops, each of which
/// resolves ONE settle decision, plus a launch `regime`/`plan` pair and a handful of belt events.
/// 12 frozen head lines hold the launch regime and the first few rests; the 28-line rolling tail
/// holds the end of the walk, which is where the last row's rest lives. 41 displayed lines total.
enum PinnedRowSettleProbe {

    /// Read ONCE at first access, like every other probe knob in this tree (`HomeHeroProbe`,
    /// `TrailerProbe`, `CollectionFocusAB`) — hence the "relaunch" in the About pane's subtitle.
    /// `UserDefaults.bool(forKey:)` also coerces the String "YES" an `-debug.pinnedRowSettleProbe
    /// YES` launch argument lands in the argument domain, so the harness can arm it without a
    /// `defaults write`.
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.pinnedRowSettleProbe")

    nonisolated static let t0 = Date()
    /// `nonisolated` for the same reason `HomeHeroProbe.sinceLaunchMs` is: the target defaults to
    /// MainActor isolation and `log` below is called from geometry callbacks and deferred settle
    /// work items. Pure `Date` math, safe from any executor.
    nonisolated static var sinceLaunchMs: Int { Int(Date().timeIntervalSince(t0) * 1000) }

    nonisolated static let linesKey = "debug.pinnedRowSettleProbe.lines"

    /// Frozen launch head — never evicted. Holds the regime/plan pair and the first rests.
    nonisolated static let headMaxLines = 12
    /// Rolling recent window. Holds the end of the walk, where the last row's rest lands.
    nonisolated static let tailMaxLines = 28

    nonisolated(unsafe) private static var headLines: [String] = []
    nonisolated(unsafe) private static var tailLines: [String] = []
    /// Lines dropped from the tail stream once `tailLines` is full. Stays 0 (no marker rendered)
    /// until eviction genuinely begins.
    nonisolated(unsafe) private static var elidedTailCount = 0
    nonisolated private static let bufferLock = NSLock()

    /// Appends `line`, stamped with its milliseconds-since-launch, to the persisted head-preserving
    /// ring buffer. Same shape as `HomeHeroProbe.log`, minus the NSLog (see the type doc).
    ///
    /// NOT gated by `enabled` internally — every call site wraps its own call in
    /// `if PinnedRowSettleProbe.enabled { … }`, which is what keeps the cost of an off probe to one
    /// static `Bool` read on paths that run per settle. The unit test drives this directly for the
    /// same reason `HomeHeroProbeBufferTests` can: `enabled` is a launch-latched `static let` that
    /// flipping a default after the fact could not affect anyway.
    ///
    /// Write-through to `UserDefaults` on every call, deliberately: the capture protocol is
    /// "relaunch, walk, photograph", and the app may be backgrounded or killed between the walk and
    /// the tester reaching Settings. The buffer is at most 41 short strings, so the write is cheap
    /// and bounded, exactly as it is for the hero probe.
    ///
    /// `headLines`/`tailLines` are fresh statics per process, so each launch starts the buffer
    /// clean without needing a reset flag — a relaunch is the reset.
    /// TEST ONLY (Codex rc5 r1, P3): clears the process-global buffer and its persisted mirror so
    /// `PinnedRowSettleProbeBufferTests` can assert an exact head/tail/elision shape regardless of
    /// what the hosting app logged before the test ran, and can run twice in one process. Never
    /// called from app code: the head is frozen by design for the tester's photo.
    nonisolated static func resetForTesting() {
        bufferLock.lock()
        headLines.removeAll()
        tailLines.removeAll()
        elidedTailCount = 0
        bufferLock.unlock()
        UserDefaults.standard.removeObject(forKey: linesKey)
    }

    nonisolated static func log(_ line: String) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let stamped = "\(sinceLaunchMs)ms \(line)"
        if headLines.count < headMaxLines {
            headLines.append(stamped)
        } else {
            tailLines.append(stamped)
            if tailLines.count > tailMaxLines {
                tailLines.removeFirst()
                elidedTailCount += 1
            }
        }
        var display = headLines
        if elidedTailCount > 0 {
            display.append("\u{2026} \(elidedTailCount) lines elided \u{2026}")
        }
        display.append(contentsOf: tailLines)
        UserDefaults.standard.set(display, forKey: linesKey)
    }
}
