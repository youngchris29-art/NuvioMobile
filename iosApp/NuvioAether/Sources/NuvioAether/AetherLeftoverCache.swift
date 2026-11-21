import Darwin
import Foundation

/// The process-wide gate between the leftover cleanup and the first engine (disk cache, code review r2
/// and r4).
///
/// One lock and a one-way state. The cleanup's inspect-and-rename runs under the lock at most once per
/// process, from whichever caller gets there first: the launch call (normally, off the playback path) or
/// the first engine construction (`AetherLeftoverCache.beforeEngineConstruction()`, the first statement
/// of `LiveEngine.init`, before `AetherEngine()` runs). The engine creates no directory before it is
/// constructed, so whichever thread wins, the order is always inspect-and-rename, then engine.
final class AetherEngineGate: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// No inspect-and-rename yet, no engine yet.
        case fresh
        /// The launch call ran the inspect-and-rename; no engine yet.
        case swept
        /// An engine was (or is being) constructed. The inspect-and-rename ran before it. Never left.
        case engineUsed
    }

    static let shared = AetherEngineGate()

    private let lock = NSLock()
    private var current: State = .fresh

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Runs `body` with the state, under the lock.
    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&current)
    }
}

/// Cleanup of Aether segment folders left by a killed or crashed earlier process (disk cache, code
/// review r2 and r4). Only `tmp/aether-segments` and this cleanup's own `tmp/aether-segments.trash-*`
/// siblings are touched; nothing else in tmp.
///
/// Why it cannot remove a live session's folder:
/// 1. A tvOS app runs as one process with its own container; the Top Shelf extension has its own
///    container and does not link NuvioAether. Before this process constructs an engine, every folder
///    under this container's `aether-segments` belongs to a dead process.
/// 2. `AetherEngineGate`: the inspect-and-rename runs under the gate's lock, once, and always before the
///    first engine construction (which runs it itself when the launch call has not yet).
/// 3. Fail closed: if any child's `session.lock` is held by a flock (the engine's liveness marker,
///    `SessionDirectoryLiveness.markerName`), or any probe cannot be answered, nothing is renamed.
///
/// Removal is rename-then-delete. Under the lock `aether-segments` is renamed to a unique sibling; the
/// deletion of every `aether-segments.trash-*` sibling runs later on a serial utility queue, outside
/// the gate. Deleting trash is always safe: only this cleanup makes those names, and only from a tree
/// whose markers were all free at rename time.
public enum AetherLeftoverCache {
    /// The engine's segment base directory under `NSTemporaryDirectory()`. Duplicated from AetherEngine
    /// 7.71.2 `Video/SegmentCache.swift:218` and `Native/SoftwarePlaybackHost.swift:502` (the live DVR
    /// ring); `AetherLeftoverCacheTests.testEngineSourceStillUsesTheseNames` fails if they change.
    static let rootName = "aether-segments"
    /// The engine's per-session liveness marker, `Video/SessionDirectoryLiveness.swift:16`.
    static let markerName = "session.lock"
    /// Prefix of this cleanup's own renamed trees. Not a prefix the engine uses.
    static let trashPrefix = "aether-segments.trash-"
    /// Children probed under the lock at most; more means skip. The listing stops reading at
    /// `maxEntries + 1`, so the time under the lock is bounded by this count, not by the folder.
    static let maxEntries = 1024

    /// Where the trash deletion runs: one serial queue, so the launch call and the first engine never
    /// delete the same tree at once.
    private static let trashQueue = DispatchQueue(label: "nuvio.aether.leftover-trash", qos: .utility)

    // MARK: Pure decision

    /// Who asks for the inspect-and-rename.
    enum Caller: String, Equatable, Sendable, CaseIterable {
        /// `removeAtLaunch()`, from the app's launch.
        case launch
        /// `beforeEngineConstruction()`, the first statement of `LiveEngine.init`.
        case engine
    }

    /// One gate step: whether this call runs the inspect-and-rename, and the state it leaves. Total.
    /// Invariant: a step that leaves `.engineUsed` from `.fresh` inspects, so no engine ever exists in a
    /// process whose inspect-and-rename has not run.
    static func step(_ state: AetherEngineGate.State, caller: Caller) -> (inspects: Bool, next: AetherEngineGate.State) {
        switch (state, caller) {
        case (.fresh, .launch): return (true, .swept)
        case (.fresh, .engine): return (true, .engineUsed)
        case (.swept, .launch): return (false, .swept)
        case (.swept, .engine), (.engineUsed, .engine): return (false, .engineUsed)
        case (.engineUsed, .launch): return (false, .engineUsed)
        }
    }

    /// One direct child of `aether-segments`, as the probe found it.
    enum EntryProbe: Equatable, Sendable {
        case notADirectory
        /// A directory without `session.lock` (a crash between mkdir and the marker).
        case markerAbsent
        /// The marker exists and a non-blocking exclusive flock succeeded (then released).
        case markerUnheld
        /// The marker's flock is held: a live session somewhere.
        case markerHeld
        /// lstat, open or flock failed with this errno: unknown, so treated as possibly live.
        case probeFailed(Int32)
    }

    enum RootState: Equatable, Sendable {
        case missing
        case unreadable(Int32)
        case tooManyEntries
        case entries([EntryProbe])
    }

    enum Skip: String, Equatable, Sendable {
        case alreadyRan = "already ran"
        case liveSession = "a session marker is held"
        case probeFailed = "a probe failed"
        case tooManyEntries = "too many entries"
    }

    enum Decision: Equatable, Sendable {
        case rename
        case nothingToRename
        case skip(Skip)
    }

    /// Whether the inspect-and-rename may rename `aether-segments`. Total and fail closed: a call that
    /// does not inspect (the step said so) skips; otherwise anything other than a fully answered listing
    /// with no held marker and no failed probe is a skip.
    static func decide(inspects: Bool, root: RootState?) -> Decision {
        guard inspects, let root else { return .skip(.alreadyRan) }
        switch root {
        case .missing: return .nothingToRename
        case .unreadable: return .skip(.probeFailed)
        case .tooManyEntries: return .skip(.tooManyEntries)
        case .entries(let probes):
            if probes.contains(.markerHeld) { return .skip(.liveSession) }
            if probes.contains(where: { if case .probeFailed = $0 { return true } else { return false } }) {
                return .skip(.probeFailed)
            }
            return probes.isEmpty ? .nothingToRename : .rename
        }
    }

    /// The tmp entries the trash deletion removes: this cleanup's renamed trees, whatever the decision
    /// (the one just made, and any an earlier process left). Never `aether-segments` itself.
    static func trashToRemove(tmpEntries: [String]) -> [String] {
        tmpEntries.filter(isTrashName).sorted()
    }

    static func isTrashName(_ name: String) -> Bool {
        name.hasPrefix(trashPrefix) && name.count > trashPrefix.count
    }

    static func trashName(_ id: UUID) -> String { trashPrefix + id.uuidString }

    // MARK: IO shell

    /// What one inspect-and-rename call did, for the log line and tests.
    struct SweepReport: Equatable, Sendable {
        let caller: Caller
        let decision: Decision
        let childrenSeen: Int
        let failures: [String]
        /// Time spent under the gate's lock on the inspect-and-rename (0 when it did not inspect).
        let inspectSeconds: Double

        /// "renamed", "nothing to rename", or "skipped: <reason>".
        var outcome: String {
            switch decision {
            case .rename: return "renamed"
            case .nothingToRename: return "nothing to rename"
            case .skip(let why): return "skipped: \(why.rawValue)"
            }
        }
    }

    struct TrashReport: Equatable, Sendable {
        let removed: Int
        let failures: [String]
    }

    private static var tmpURL: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// The app's launch hook, called once from `NuvioTVApp.init`; returns at once. On the serial trash
    /// queue: the inspect-and-rename if no engine has run it yet, then the trash deletion (always).
    /// Runs whatever the disk cache setting says (a cache written under an earlier setting is still
    /// cleaned).
    public static func removeAtLaunch() {
        trashQueue.async {
            let sweep = self.sweep(tmp: tmpURL, gate: .shared, caller: .launch)
            let trash = removeTrash(tmp: tmpURL)
            log(sweep, trash)
        }
    }

    /// The first statement of `LiveEngine.init`, before `AetherEngine()`. The first engine of the
    /// process runs the bounded inspect-and-rename here, synchronously under the gate's lock, if the
    /// launch call has not run it yet (or waits for the launch call's to finish), then schedules the
    /// trash deletion on the serial queue. Every later engine only takes the lock once.
    static func beforeEngineConstruction() {
        let sweep = self.sweep(tmp: tmpURL, gate: .shared, caller: .engine)
        guard sweep.decision != .skip(.alreadyRan) else { return }
        trashQueue.async {
            let trash = removeTrash(tmp: tmpURL)
            log(sweep, trash)
        }
    }

    private static func log(_ sweep: SweepReport, _ trash: TrashReport) {
        let failures = sweep.failures + trash.failures
        guard sweep.decision != .nothingToRename || trash.removed > 0 || !failures.isEmpty else { return }
        AetherLog.hostLine("[AetherCache] leftover cleanup (\(sweep.caller.rawValue)): \(sweep.outcome), "
                           + "children=\(sweep.childrenSeen) "
                           + "underLock=\(String(format: "%.1f", sweep.inspectSeconds * 1000))ms "
                           + "trashRemoved=\(trash.removed)"
                           + (failures.isEmpty ? "" : " failures=\(failures.joined(separator: "; "))"))
    }

    /// The inspect-and-rename step. `tmp` and `gate` are injected (tests use a scratch directory and a
    /// fresh gate, never the real tmp). `underLock` runs while the gate's lock is held, after the
    /// decision and any rename (tests only).
    static func sweep(tmp: URL, gate: AetherEngineGate, caller: Caller, maxEntries: Int = maxEntries,
                      underLock: (() -> Void)? = nil) -> SweepReport {
        let root = tmp.appendingPathComponent(rootName, isDirectory: true)
        var failures: [String] = []
        var seen = 0
        var held = 0.0
        let decision: Decision = gate.withLock { state in
            let (inspects, next) = step(state, caller: caller)
            state = next
            guard inspects else {
                underLock?()
                return decide(inspects: false, root: nil)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let listing = inspect(root: root, maxEntries: maxEntries)
            if case .entries(let probes) = listing { seen = probes.count }
            var d = decide(inspects: true, root: listing)
            if d == .rename {
                let target = tmp.appendingPathComponent(trashName(UUID()), isDirectory: true)
                if Darwin.rename(root.path, target.path) != 0 {
                    failures.append("rename errno=\(errno)")
                    d = .nothingToRename
                }
            }
            held = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            underLock?()
            return d
        }
        return SweepReport(caller: caller, decision: decision, childrenSeen: seen, failures: failures,
                           inspectSeconds: held)
    }

    /// Deletes every `aether-segments.trash-*` sibling in `tmp`. Outside the gate; safe at any time.
    static func removeTrash(tmp: URL) -> TrashReport {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        var removed = 0
        var failures: [String] = []
        for name in trashToRemove(tmpEntries: names) {
            do {
                try FileManager.default.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
                removed += 1
            } catch {
                failures.append("remove \(name): \((error as NSError).code)")
            }
        }
        return TrashReport(removed: removed, failures: failures)
    }

    /// Lists the direct children of `root` (reading at most `maxEntries + 1` names) and probes each
    /// directory's marker. Never creates, never follows a symlink.
    static func inspect(root: URL, maxEntries: Int) -> RootState {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            return errno == ENOENT ? .missing : .unreadable(errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .unreadable(ENOTDIR) }
        guard let dir = opendir(root.path) else { return .unreadable(errno) }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { return .unreadable(errno) }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maxEntries else { return .tooManyEntries }
            names.append(name)
        }
        return .entries(names.map { probe(root.appendingPathComponent($0)) })
    }

    static func probe(_ entry: URL) -> EntryProbe {
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { return .probeFailed(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .notADirectory }
        let path = entry.appendingPathComponent(markerName).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .markerAbsent : .probeFailed(errno) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return (errno == EWOULDBLOCK || errno == EAGAIN) ? .markerHeld : .probeFailed(errno)
        }
        flock(fd, LOCK_UN)
        return .markerUnheld
    }
}
