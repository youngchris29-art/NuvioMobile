import Darwin
import XCTest
import AetherEngine
@testable import NuvioAether

/// Launch cleanup of leftover Aether segment folders (disk cache, code review r2): the pure decision,
/// the IO shell against an injected scratch tmp (never the real tmp), the gate, and the engine names.
final class AetherLeftoverCacheTests: XCTestCase {
    private typealias C = AetherLeftoverCache
    private var tmp: URL!
    private var heldFDs: [Int32] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        heldFDs.forEach { _ = Darwin.close($0) }
        heldFDs = []
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    private var root: URL { tmp.appendingPathComponent("aether-segments", isDirectory: true) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func tmpNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted()
    }

    /// A session folder as the engine lays it out: init segment, media segments, marker.
    @discardableResult
    private func session(_ name: String = UUID().uuidString, marker: Bool = true, in base: URL? = nil) throws -> URL {
        let dir = (base ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: dir.appendingPathComponent("init.mp4"))
        for i in 0..<3 { try Data(repeating: 2, count: 128).write(to: dir.appendingPathComponent("seg-\(i)-0.m4s")) }
        if marker { try Data().write(to: dir.appendingPathComponent("session.lock")) }
        return dir
    }

    /// Holds the marker's flock the way a live session does (its own open file description).
    private func hold(_ dir: URL) {
        let fd = open(dir.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        heldFDs.append(fd)
    }

    // MARK: Pure decision

    private static let allProbes: [C.EntryProbe] = [
        .notADirectory, .markerAbsent, .markerUnheld, .markerHeld, .probeFailed(EIO),
    ]

    func testGateNotFreshAlwaysSkipsWhateverTheRoot() {
        let roots: [C.RootState] = [.notInspected, .missing, .unreadable(EACCES), .tooManyEntries, .entries([]),
                                    .entries([.markerUnheld]), .entries(Self.allProbes)]
        for r in roots {
            XCTAssertEqual(C.decide(gate: .engineUsed, root: r), .skip(.engineInUse), "\(r)")
            XCTAssertEqual(C.decide(gate: .sweepClaimed, root: r), .skip(.alreadyRan), "\(r)")
        }
    }

    func testFreshGateRootStates() {
        XCTAssertEqual(C.decide(gate: .fresh, root: .missing), .nothingToRename)
        XCTAssertEqual(C.decide(gate: .fresh, root: .unreadable(EACCES)), .skip(.probeFailed))
        XCTAssertEqual(C.decide(gate: .fresh, root: .tooManyEntries), .skip(.tooManyEntries))
        XCTAssertEqual(C.decide(gate: .fresh, root: .notInspected), .skip(.probeFailed))
        XCTAssertEqual(C.decide(gate: .fresh, root: .entries([])), .nothingToRename)
    }

    /// Every listing of up to four children over the five probe kinds (781 listings): a held marker
    /// anywhere skips, then any failed probe skips, and only then a non-empty listing renames.
    func testEveryListingUpToFourChildren() {
        var listings: [[C.EntryProbe]] = [[]]
        var frontier: [[C.EntryProbe]] = [[]]
        for _ in 0..<4 {
            frontier = frontier.flatMap { l in Self.allProbes.map { l + [$0] } }
            listings += frontier
        }
        XCTAssertEqual(listings.count, 1 + 5 + 25 + 125 + 625)
        for l in listings {
            let d = C.decide(gate: .fresh, root: .entries(l))
            if l.contains(.markerHeld) {
                XCTAssertEqual(d, .skip(.liveSession), "\(l)")
            } else if l.contains(.probeFailed(EIO)) {
                XCTAssertEqual(d, .skip(.probeFailed), "\(l)")
            } else if l.isEmpty {
                XCTAssertEqual(d, .nothingToRename)
            } else {
                XCTAssertEqual(d, .rename, "\(l)")
            }
        }
    }

    func testTrashSelectionTouchesOnlyOwnTrash() {
        let names = ["aether-segments", "aether-segments.trash-", "aether-segments.trash-A",
                     "aether-segments.trash-B", "aether-segments.trashy", "xaether-segments.trash-C",
                     "aether-software-packets-1", "aether-fel-history", "nuvio-remux", "other"]
        XCTAssertEqual(C.trashToRemove(decision: .rename, tmpEntries: names),
                       ["aether-segments.trash-A", "aether-segments.trash-B"])
        XCTAssertEqual(C.trashToRemove(decision: .nothingToRename, tmpEntries: names),
                       ["aether-segments.trash-A", "aether-segments.trash-B"])
        for s in [C.Skip.engineInUse, .alreadyRan, .liveSession, .probeFailed, .tooManyEntries] {
            XCTAssertEqual(C.trashToRemove(decision: .skip(s), tmpEntries: names), [], "\(s)")
        }
        XCTAssertTrue(C.isTrashName(C.trashName(UUID())))
        XCTAssertFalse(C.isTrashName(C.rootName))
    }

    // MARK: IO shell (scratch tmp)

    func testLeftoversAndOldTrashRemovedOthersUntouched() throws {
        try session()
        try session(marker: false)
        try session("parked-\(UUID().uuidString)")
        try session("dvr-\(UUID().uuidString)")
        try Data([1]).write(to: root.appendingPathComponent("stray.bin"))
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        try session("keep", in: tmp.appendingPathComponent("aether-fel-history"))
        try session("keep", in: tmp.appendingPathComponent("aether-software-packets-1"))
        try session("keep", in: tmp.appendingPathComponent("other"))

        let gate = AetherEngineGate()
        let report = C.run(tmp: tmp, gate: gate)

        XCTAssertEqual(report.outcome, "renamed")
        XCTAssertEqual(report.childrenSeen, 5)
        XCTAssertEqual(report.trashRemoved, 2)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(tmpNames(), ["aether-fel-history", "aether-software-packets-1", "other"])
        XCTAssertEqual(gate.state, .sweepClaimed)
    }

    func testHeldMarkerAnywhereRemovesNothing() throws {
        try session()
        let live = try session()
        try session("parked-\(UUID().uuidString)")
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        hold(live)
        let before = try FileManager.default.subpathsOfDirectory(atPath: tmp.path).sorted()

        let report = C.run(tmp: tmp, gate: AetherEngineGate())

        XCTAssertEqual(report.outcome, "skipped: a session marker is held")
        XCTAssertEqual(report.trashRemoved, 0)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: tmp.path).sorted(), before)
    }

    func testFailedProbeRemovesNothing() throws {
        let dir = try session(marker: false)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("session.lock"),
                                                   withDestinationURL: tmp.appendingPathComponent("elsewhere"))
        try session()

        let report = C.run(tmp: tmp, gate: AetherEngineGate())

        XCTAssertEqual(report.outcome, "skipped: a probe failed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testTooManyEntriesRemovesNothing() throws {
        for _ in 0..<4 { try session() }
        let report = C.run(tmp: tmp, gate: AetherEngineGate(), maxEntries: 3)
        XCTAssertEqual(report.outcome, "skipped: too many entries")
        XCTAssertTrue(exists(root))
        let atLimit = C.run(tmp: tmp, gate: AetherEngineGate(), maxEntries: 4)
        XCTAssertEqual(atLimit.outcome, "renamed")
        XCTAssertFalse(exists(root))
    }

    func testLatchFlippedRemovesNothingAndDoesNotBlockTheEngine() throws {
        let leftover = try session()
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        let gate = AetherEngineGate()
        gate.noteEngineUse()

        let report = C.run(tmp: tmp, gate: gate)

        XCTAssertEqual(report.outcome, "skipped: engine already in use")
        XCTAssertTrue(exists(leftover))
        XCTAssertTrue(exists(tmp.appendingPathComponent("aether-segments.trash-OLD")))
        let start = Date()
        gate.noteEngineUse()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(gate.state, .engineUsed)
    }

    func testRunsOncePerProcess() throws {
        let gate = AetherEngineGate()
        XCTAssertEqual(C.run(tmp: tmp, gate: gate).outcome, "nothing to rename")
        let leftover = try session()
        XCTAssertEqual(C.run(tmp: tmp, gate: gate).outcome, "skipped: already ran")
        XCTAssertTrue(exists(leftover))
    }

    func testMissingRootStillClearsOldTrash() throws {
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        let report = C.run(tmp: tmp, gate: AetherEngineGate())
        XCTAssertEqual(report.outcome, "nothing to rename")
        XCTAssertEqual(report.trashRemoved, 1)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(tmpNames(), [])
    }

    func testEmptyTmpIsFine() {
        let report = C.run(tmp: tmp, gate: AetherEngineGate())
        XCTAssertEqual(report, C.Report(outcome: "nothing to rename", childrenSeen: 0, trashRemoved: 0, failures: []))
    }

    /// Engine construction waits for the decide-and-rename step, and goes ahead right after it.
    func testEngineUseWaitsForTheRename() throws {
        try session()
        let gate = AetherEngineGate()
        let returned = DispatchSemaphore(value: 0)
        var blockedWhileLocked = false
        let report = C.run(tmp: tmp, gate: gate, underLock: {
            DispatchQueue.global().async {
                gate.noteEngineUse()
                returned.signal()
            }
            blockedWhileLocked = returned.wait(timeout: .now() + 0.2) == .timedOut
        })
        XCTAssertTrue(blockedWhileLocked)
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(report.outcome, "renamed")
        XCTAssertEqual(gate.state, .engineUsed)
    }

    /// The race the gate exists for, with no marker on the new session so the latch alone protects it:
    /// "first engine use" (then the engine making its folder) against the cleanup on two threads. The
    /// new session's folder must survive every iteration, whichever side wins.
    func testFirstEngineUseAgainstCleanupNeverLosesTheNewSession() throws {
        var renamed = 0
        var skipped = 0
        for i in 0..<400 {
            let base = tmp.appendingPathComponent("race-\(i)", isDirectory: true)
            let leftover = try session(in: base.appendingPathComponent("aether-segments", isDirectory: true))
            let gate = AetherEngineGate()
            let liveSeg = base.appendingPathComponent("aether-segments/live/seg-0-0.m4s")
            var report: C.Report?
            DispatchQueue.concurrentPerform(iterations: 2) { k in
                if k == 0 {
                    report = C.run(tmp: base, gate: gate)
                } else {
                    gate.noteEngineUse()
                    // What SegmentCache.init does next: createDirectory with intermediates, then files.
                    try? FileManager.default.createDirectory(at: liveSeg.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? Data([7]).write(to: liveSeg)
                }
            }
            XCTAssertTrue(exists(liveSeg), "iteration \(i): the new session's folder was removed")
            switch report?.outcome {
            case "renamed"?: renamed += 1; XCTAssertFalse(exists(leftover), "iteration \(i)")
            case "skipped: engine already in use"?: skipped += 1; XCTAssertTrue(exists(leftover), "iteration \(i)")
            default: XCTFail("iteration \(i): \(String(describing: report))")
            }
            XCTAssertEqual(gate.state, .engineUsed)
        }
        XCTAssertEqual(renamed + skipped, 400)
    }

    // MARK: Engine names

    /// The revision SwiftPM pinned for `aetherengine` in the app project's Package.resolved.
    private static func pinnedEngineRevision(iosApp: URL) -> String? {
        let url = iosApp.appendingPathComponent(
            "iosApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = json["pins"] as? [[String: Any]],
              let pin = pins.first(where: { ($0["identity"] as? String)?.lowercased() == "aetherengine" }),
              let state = pin["state"] as? [String: Any]
        else { return nil }
        return state["revision"] as? String
    }

    /// The checkout's current commit from `.git/HEAD` (a raw sha, or a ref resolved via its file or packed-refs).
    private static func gitCommit(of checkout: URL) -> String? {
        let git = checkout.appendingPathComponent(".git")
        func isSha(_ s: String) -> Bool { s.count == 40 && s.allSatisfy(\.isHexDigit) }
        guard let head = (try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if isSha(head) { return head }
        guard head.hasPrefix("ref: ") else { return nil }
        let ref = String(head.dropFirst(5))
        if let sha = (try? String(contentsOf: git.appendingPathComponent(ref), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), isSha(sha) { return sha }
        let packed = (try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
            let sha = String(line.prefix(40))
            if isSha(sha) { return sha }
        }
        return nil
    }

    /// The cleanup duplicates the engine's directory and marker names (it imports no engine type). They
    /// are internal to AetherEngine, so this reads the pinned checkout's source, which the package test
    /// command provides through `-clonedSourcePackagesDirPath`.
    func testEngineSourceStillUsesTheseNames() throws {
        XCTAssertEqual(AetherEngine.version, "7.71.2", "engine bumped: re-read the names below")
        let iosApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pinned = Self.pinnedEngineRevision(iosApp: iosApp)
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["AETHER_ENGINE_CHECKOUT"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env))
        }
        roots += ["build/DerivedData/SourcePackages", "build/DerivedDataPkg/SourcePackages"]
            .map { iosApp.appendingPathComponent($0).appendingPathComponent("checkouts/AetherEngine") }
        // A checkout is usable only when its commit equals the pinned revision (no stale copies).
        guard let root = roots.first(where: {
            exists($0.appendingPathComponent("Sources/AetherEngine"))
                && pinned != nil && Self.gitCommit(of: $0) == pinned
        }) else {
            throw XCTSkip("No AetherEngine checkout at the pinned revision \(pinned ?? "unknown"). "
                + "Run with AETHER_ENGINE_CHECKOUT=<path to the AetherEngine checkout at the pinned revision>.")
        }
        let src = root.appendingPathComponent("Sources/AetherEngine")
        func read(_ rel: String) throws -> String {
            try String(contentsOf: src.appendingPathComponent(rel), encoding: .utf8)
        }
        let rootLiteral = ".appendingPathComponent(\"\(C.rootName)\", isDirectory: true)"
        XCTAssertTrue(try read("Video/SegmentCache.swift").contains(rootLiteral))
        XCTAssertTrue(try read("Native/SoftwarePlaybackHost.swift").contains(rootLiteral))
        XCTAssertTrue(try read("Video/SessionDirectoryLiveness.swift")
            .contains("static let markerName = \"\(C.markerName)\""))
        XCTAssertFalse(C.trashPrefix == C.rootName + "/")
        // The engine never names a sibling with our trash prefix.
        for rel in ["Video/SegmentCache.swift", "Native/SoftwarePlaybackHost.swift", "Video/ParkedSegmentSession.swift"] {
            XCTAssertFalse(try read(rel).contains(C.trashPrefix), rel)
        }
    }
}
