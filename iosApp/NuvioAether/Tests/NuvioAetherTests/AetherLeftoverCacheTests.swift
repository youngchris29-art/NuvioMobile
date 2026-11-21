import Darwin
import XCTest
import AetherEngine
@testable import NuvioAether

/// Cleanup of leftover Aether segment folders (disk cache, code review r2 and r4): the pure gate step and
/// decision, the IO shell against an injected scratch tmp (never the real tmp), the gate race, the
/// worst-case time under the lock, and the engine names.
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

    private func assertStep(_ state: AetherEngineGate.State, _ caller: C.Caller, inspects: Bool,
                            next: AetherEngineGate.State, line: UInt = #line) {
        let s = C.step(state, caller: caller)
        XCTAssertEqual(s.inspects, inspects, "\(state) \(caller)", line: line)
        XCTAssertEqual(s.next, next, "\(state) \(caller)", line: line)
    }

    /// The gate step, every state and caller (code review r4): the first call of the process inspects
    /// whoever makes it; nothing inspects twice; an engine never leaves the state un-inspected.
    func testGateStepTable() {
        assertStep(.fresh, .launch, inspects: true, next: .swept)
        assertStep(.fresh, .engine, inspects: true, next: .engineUsed)
        assertStep(.swept, .launch, inspects: false, next: .swept)
        assertStep(.swept, .engine, inspects: false, next: .engineUsed)
        assertStep(.engineUsed, .launch, inspects: false, next: .engineUsed)
        assertStep(.engineUsed, .engine, inspects: false, next: .engineUsed)
    }

    /// Every sequence of up to six calls from `.fresh`: exactly one inspect (the first call), and from
    /// the first engine call on the state is `.engineUsed`, with the inspect at or before it.
    func testEveryCallSequenceInspectsOnceAndBeforeTheFirstEngine() {
        var sequences: [[C.Caller]] = []
        var frontier: [[C.Caller]] = [[]]
        for _ in 0..<6 {
            frontier = frontier.flatMap { s in C.Caller.allCases.map { s + [$0] } }
            sequences += frontier
        }
        XCTAssertEqual(sequences.count, 2 + 4 + 8 + 16 + 32 + 64)
        for seq in sequences {
            var state = AetherEngineGate.State.fresh
            var inspects: [Int] = []
            var firstEngine: Int?
            for (i, caller) in seq.enumerated() {
                let (inspected, next) = C.step(state, caller: caller)
                if inspected { inspects.append(i) }
                if caller == .engine, firstEngine == nil { firstEngine = i }
                state = next
                if firstEngine != nil { XCTAssertEqual(state, .engineUsed, "\(seq)") }
            }
            XCTAssertEqual(inspects, [0], "\(seq)")
            if let firstEngine { XCTAssertLessThanOrEqual(inspects[0], firstEngine, "\(seq)") }
        }
    }

    func testNotInspectingAlwaysSkipsWhateverTheRoot() {
        let roots: [C.RootState?] = [nil, .missing, .unreadable(EACCES), .tooManyEntries, .entries([]),
                                     .entries([.markerUnheld]), .entries(Self.allProbes)]
        for r in roots {
            XCTAssertEqual(C.decide(inspects: false, root: r), .skip(.alreadyRan), "\(String(describing: r))")
        }
        XCTAssertEqual(C.decide(inspects: true, root: nil), .skip(.alreadyRan))
    }

    func testInspectedRootStates() {
        XCTAssertEqual(C.decide(inspects: true, root: .missing), .nothingToRename)
        XCTAssertEqual(C.decide(inspects: true, root: .unreadable(EACCES)), .skip(.probeFailed))
        XCTAssertEqual(C.decide(inspects: true, root: .tooManyEntries), .skip(.tooManyEntries))
        XCTAssertEqual(C.decide(inspects: true, root: .entries([])), .nothingToRename)
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
            let d = C.decide(inspects: true, root: .entries(l))
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

    /// Trash selection does not depend on the decision (code review r4): only `aether-segments.trash-<x>`.
    func testTrashSelectionTouchesOnlyOwnTrash() {
        let names = ["aether-segments", "aether-segments.trash-", "aether-segments.trash-A",
                     "aether-segments.trash-B", "aether-segments.trashy", "xaether-segments.trash-C",
                     "aether-software-packets-1", "aether-fel-history", "nuvio-remux", "other"]
        XCTAssertEqual(C.trashToRemove(tmpEntries: names), ["aether-segments.trash-A", "aether-segments.trash-B"])
        XCTAssertTrue(C.isTrashName(C.trashName(UUID())))
        XCTAssertFalse(C.isTrashName(C.rootName))
    }

    // MARK: IO shell (scratch tmp)

    /// The launch call then the trash deletion, as `removeAtLaunch()` runs them.
    private func launchCleanup(gate: AetherEngineGate, maxEntries: Int = C.maxEntries) -> (C.SweepReport, C.TrashReport) {
        (C.sweep(tmp: tmp, gate: gate, caller: .launch, maxEntries: maxEntries), C.removeTrash(tmp: tmp))
    }

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
        let (sweep, trash) = launchCleanup(gate: gate)

        XCTAssertEqual(sweep.outcome, "renamed")
        XCTAssertEqual(sweep.childrenSeen, 5)
        XCTAssertEqual(sweep.failures, [])
        XCTAssertEqual(trash, C.TrashReport(removed: 2, failures: []))
        XCTAssertEqual(tmpNames(), ["aether-fel-history", "aether-software-packets-1", "other"])
        XCTAssertEqual(gate.state, .swept)
    }

    /// A held marker: `aether-segments` is left byte for byte. Old trash is still deleted (code review r4:
    /// trash deletion is independent of the decision).
    func testHeldMarkerRenamesNothingButOldTrashGoes() throws {
        try session()
        let live = try session()
        try session("parked-\(UUID().uuidString)")
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        hold(live)
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        let (sweep, trash) = launchCleanup(gate: AetherEngineGate())

        XCTAssertEqual(sweep.outcome, "skipped: a session marker is held")
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(trash.removed, 1)
        XCTAssertEqual(tmpNames(), ["aether-segments"])
    }

    func testFailedProbeRenamesNothing() throws {
        let dir = try session(marker: false)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("session.lock"),
                                                   withDestinationURL: tmp.appendingPathComponent("elsewhere"))
        try session()

        let (sweep, _) = launchCleanup(gate: AetherEngineGate())

        XCTAssertEqual(sweep.outcome, "skipped: a probe failed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testTooManyEntriesRenamesNothing() throws {
        for _ in 0..<4 { try session() }
        let (over, _) = launchCleanup(gate: AetherEngineGate(), maxEntries: 3)
        XCTAssertEqual(over.outcome, "skipped: too many entries")
        XCTAssertTrue(exists(root))
        let (atLimit, _) = launchCleanup(gate: AetherEngineGate(), maxEntries: 4)
        XCTAssertEqual(atLimit.outcome, "renamed")
        XCTAssertFalse(exists(root))
    }

    /// Engine first (code review r4): the first engine's own call renames the leftovers before it
    /// returns; the later launch call does not inspect again but still deletes the trash.
    func testEngineFirstRemovesLeftoversBeforeTheEngine() throws {
        let leftover = try session()
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        let gate = AetherEngineGate()

        let engine = C.sweep(tmp: tmp, gate: gate, caller: .engine)
        XCTAssertEqual(engine.outcome, "renamed")
        XCTAssertFalse(exists(leftover), "the leftover is still in place when the engine would be built")
        XCTAssertEqual(gate.state, .engineUsed)

        let (launch, trash) = launchCleanup(gate: gate)
        XCTAssertEqual(launch.outcome, "skipped: already ran")
        XCTAssertEqual(trash.removed, 2)
        XCTAssertEqual(tmpNames(), [])
        XCTAssertEqual(gate.state, .engineUsed)
    }

    /// After the inspect, every engine construction takes the lock only.
    func testLaterEnginesDoNotInspect() throws {
        let gate = AetherEngineGate()
        XCTAssertEqual(C.sweep(tmp: tmp, gate: gate, caller: .engine).outcome, "nothing to rename")
        let later = try session()
        let again = C.sweep(tmp: tmp, gate: gate, caller: .engine)
        XCTAssertEqual(again.outcome, "skipped: already ran")
        XCTAssertEqual(again.inspectSeconds, 0)
        XCTAssertTrue(exists(later))
    }

    func testRunsOncePerProcess() throws {
        let gate = AetherEngineGate()
        XCTAssertEqual(launchCleanup(gate: gate).0.outcome, "nothing to rename")
        let leftover = try session()
        XCTAssertEqual(launchCleanup(gate: gate).0.outcome, "skipped: already ran")
        XCTAssertEqual(C.sweep(tmp: tmp, gate: gate, caller: .engine).outcome, "skipped: already ran")
        XCTAssertTrue(exists(leftover))
    }

    func testMissingRootStillClearsOldTrash() throws {
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        let (sweep, trash) = launchCleanup(gate: AetherEngineGate())
        XCTAssertEqual(sweep.outcome, "nothing to rename")
        XCTAssertEqual(trash, C.TrashReport(removed: 1, failures: []))
        XCTAssertEqual(tmpNames(), [])
    }

    func testEmptyTmpIsFine() {
        let (sweep, trash) = launchCleanup(gate: AetherEngineGate())
        XCTAssertEqual(sweep.outcome, "nothing to rename")
        XCTAssertEqual(sweep.childrenSeen, 0)
        XCTAssertEqual(sweep.failures, [])
        XCTAssertEqual(trash, C.TrashReport(removed: 0, failures: []))
    }

    /// The first engine's call waits while the launch call holds the lock, then goes ahead without
    /// inspecting again.
    func testEngineWaitsForTheLaunchRename() throws {
        try session()
        let gate = AetherEngineGate()
        let returned = DispatchSemaphore(value: 0)
        var engineReport: C.SweepReport?
        var blockedWhileLocked = false
        let scratch: URL = tmp
        let launch = C.sweep(tmp: scratch, gate: gate, caller: .launch, underLock: {
            DispatchQueue.global().async {
                engineReport = C.sweep(tmp: scratch, gate: gate, caller: .engine)
                returned.signal()
            }
            blockedWhileLocked = returned.wait(timeout: .now() + 0.2) == .timedOut
        })
        XCTAssertTrue(blockedWhileLocked)
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(launch.outcome, "renamed")
        XCTAssertEqual(engineReport?.outcome, "skipped: already ran")
        XCTAssertEqual(gate.state, .engineUsed)
    }

    /// The race the gate exists for (code review r4 version): the launch call against the first engine
    /// (its call, then the engine making its folder with no marker, so only the gate protects it) on two
    /// threads. Whichever wins, the leftover is gone before the engine makes its folder, the new folder
    /// survives, and exactly one side inspected.
    func testLaunchAgainstFirstEngineAlwaysCleansFirstAndNeverLosesTheNewSession() throws {
        var engineInspected = 0
        var launchInspected = 0
        for i in 0..<400 {
            let base = tmp.appendingPathComponent("race-\(i)", isDirectory: true)
            let leftover = try session(in: base.appendingPathComponent("aether-segments", isDirectory: true))
            let gate = AetherEngineGate()
            let liveSeg = base.appendingPathComponent("aether-segments/live/seg-0-0.m4s")
            var launch: C.SweepReport?
            var engine: C.SweepReport?
            var leftoverAtEngine = true
            DispatchQueue.concurrentPerform(iterations: 2) { k in
                if k == 0 {
                    // Odd iterations hold the launch side back a little, so the engine wins often too.
                    if i % 2 == 1 { usleep(UInt32.random(in: 0...400)) }
                    launch = C.sweep(tmp: base, gate: gate, caller: .launch)
                } else {
                    engine = C.sweep(tmp: base, gate: gate, caller: .engine)
                    leftoverAtEngine = FileManager.default.fileExists(atPath: leftover.path)
                    // What SegmentCache.init does next: createDirectory with intermediates, then files.
                    try? FileManager.default.createDirectory(at: liveSeg.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? Data([7]).write(to: liveSeg)
                }
            }
            _ = C.removeTrash(tmp: base)
            XCTAssertFalse(leftoverAtEngine, "iteration \(i): the leftover was still there when the engine started")
            XCTAssertTrue(exists(liveSeg), "iteration \(i): the new session's folder was removed")
            XCTAssertFalse(exists(leftover), "iteration \(i)")
            switch (launch?.outcome, engine?.outcome) {
            case ("renamed"?, "skipped: already ran"?): launchInspected += 1
            case ("skipped: already ran"?, "renamed"?): engineInspected += 1
            default: XCTFail("iteration \(i): launch=\(String(describing: launch)) engine=\(String(describing: engine))")
            }
            XCTAssertEqual(gate.state, .engineUsed)
        }
        XCTAssertEqual(launchInspected + engineInspected, 400)
        print("[LeftoverRace] launch first \(launchInspected), engine first \(engineInspected)")
    }

    /// The worst case added to the first engine construction (code review r4): the entry cap's worth of
    /// session folders, each with a marker to open and flock, inspected and renamed under the lock. The
    /// bound asserted is loose (simulator timing); the measured time is printed for the spec.
    func testWorstCaseTimeUnderTheLockAtTheEntryCap() throws {
        for i in 0..<C.maxEntries {
            let dir = root.appendingPathComponent("s\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("session.lock"))
        }
        let atCap = C.sweep(tmp: tmp, gate: AetherEngineGate(), caller: .engine)
        XCTAssertEqual(atCap.outcome, "renamed")
        XCTAssertEqual(atCap.childrenSeen, C.maxEntries)
        XCTAssertLessThan(atCap.inspectSeconds, 2.0)
        _ = C.removeTrash(tmp: tmp)

        // One over the cap: the listing stops at cap + 1 names, before any probe.
        for i in 0...C.maxEntries {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("s\(i)", isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        let over = C.sweep(tmp: tmp, gate: AetherEngineGate(), caller: .engine)
        XCTAssertEqual(over.outcome, "skipped: too many entries")
        print(String(format: "[LeftoverTiming] under lock: %.2f ms at %d children (inspect + rename), %.2f ms over the cap",
                     atCap.inspectSeconds * 1000, C.maxEntries, over.inspectSeconds * 1000))
    }

    // MARK: Engine names

    /// The revision SwiftPM pinned for `aetherengine` in the app project's Package.resolved.
    static func pinnedEngineRevision(iosApp: URL) -> String? {
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
    static func gitCommit(of checkout: URL) -> String? {
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

    // MARK: Pending deletion (code review r5)

    /// The await resolves only after a deletion queued before it has finished.
    func testPendingDeletionWaitsForDeletionQueuedBeforeIt() async throws {
        try session("x", in: tmp.appendingPathComponent("aether-segments.trash-OLD"))
        let gate = AetherEngineGate()
        XCTAssertEqual(C.sweep(tmp: tmp, gate: gate, caller: .engine).outcome, "nothing to rename")
        let queue = DispatchQueue(label: "test.trash")
        let scratch: URL = tmp
        queue.async {
            Thread.sleep(forTimeInterval: 0.3)
            _ = C.removeTrash(tmp: scratch)
        }
        let finished = await C.pendingDeletionFinished(tmp: tmp, gate: gate, queue: queue, timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertEqual(tmpNames(), [], "free space read now would still count the trash")
    }

    /// Nothing ran the inspect-and-rename yet: the await runs it (as the launch call would), then
    /// deletes, then resolves.
    func testPendingDeletionAttemptsTheCleanupWhenNothingRanIt() async throws {
        let leftover = try session()
        let gate = AetherEngineGate()
        let finished = await C.pendingDeletionFinished(tmp: tmp, gate: gate, queue: DispatchQueue(label: "test.trash"),
                                                       timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertFalse(exists(leftover))
        XCTAssertEqual(tmpNames(), [])
        XCTAssertEqual(gate.state, .swept)
    }

    /// After an engine exists the await never inspects: a live session's folder is left alone.
    func testPendingDeletionAfterAnEngineTouchesNoSession() async throws {
        let gate = AetherEngineGate()
        _ = C.sweep(tmp: tmp, gate: gate, caller: .engine)
        let live = try session()
        let finished = await C.pendingDeletionFinished(tmp: tmp, gate: gate, queue: DispatchQueue(label: "test.trash"),
                                                       timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertTrue(exists(live))
        XCTAssertEqual(gate.state, .engineUsed)
    }

    /// A deletion that outlasts the bound: the await gives up at the bound, and the queue finishes later.
    func testPendingDeletionGivesUpAtTheBound() async throws {
        let queue = DispatchQueue(label: "test.trash")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let start = Date()
        let finished = await C.pendingDeletionFinished(tmp: tmp, gate: AetherEngineGate(), queue: queue, timeout: 0.2)
        let waited = Date().timeIntervalSince(start)
        release.signal()
        XCTAssertFalse(finished)
        XCTAssertGreaterThanOrEqual(waited, 0.15)
        XCTAssertLessThan(waited, 2)
        XCTAssertEqual(C.pendingDeletionWaitSeconds, 3)
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
