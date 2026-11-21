import Darwin
import Foundation

/// The process-wide, one-way "first engine use" latch (disk cache, code review r2).
///
/// `LiveEngine.init` calls `noteEngineUse()` as its first statement, before `AetherEngine()` runs, and the
/// engine creates no directory before it is constructed. The launch cleanup decides and renames while
/// holding the same lock. So the two are mutually exclusive: either the rename completes before the first
/// engine exists (the engine then recreates `aether-segments` with intermediate directories), or the
/// cleanup finds the latch flipped and does nothing. Engine construction waits only for the decide and
/// rename step (directory listing, one flock probe per child, one rename), never for the deletion.
final class AetherEngineGate: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// No engine yet, no cleanup yet.
        case fresh
        /// The launch cleanup ran (once per process).
        case sweepClaimed
        /// An engine was (or is being) constructed in this process. Never left.
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

    /// Flips the latch for good. Blocks while a cleanup holds the lock.
    func noteEngineUse() {
        lock.lock()
        current = .engineUsed
        lock.unlock()
    }

    /// Runs `body` with the state, under the lock that `noteEngineUse()` takes.
    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&current)
    }
}

/// Launch cleanup of Aether segment folders left by a killed or crashed earlier process (disk cache,
/// code review r2). Only `tmp/aether-segments` and this cleanup's own `tmp/aether-segments.trash-*`
/// siblings are touched; nothing else in tmp.
///
/// Why it cannot remove a live session's folder:
/// 1. A tvOS app runs as one process with its own container; the Top Shelf extension has its own
///    container and does not link NuvioAether. Before this process constructs an engine, every folder
///    under this container's `aether-segments` belongs to a dead process.
/// 2. `AetherEngineGate`: the decision and the rename happen under the lock the first engine
///    construction takes, and only while no engine has been constructed (see the gate).
/// 3. Fail closed: if any child's `session.lock` is held by a flock (the engine's liveness marker,
///    `SessionDirectoryLiveness.markerName`), or any probe cannot be answered, nothing is removed.
///
/// Removal is rename-then-delete: under the lock `aether-segments` is renamed to a unique sibling, then
/// the sibling is deleted after the lock is released. Call `removeAtLaunch()` off the main thread.
public enum AetherLeftoverCache {
    /// The engine's segment base directory under `NSTemporaryDirectory()`. Duplicated from AetherEngine
    /// 7.71.2 `Video/SegmentCache.swift:218` and `Native/SoftwarePlaybackHost.swift:502` (the live DVR
    /// ring); `AetherLeftoverCacheTests.testEngineSourceStillUsesTheseNames` fails if they change.
    static let rootName = "aether-segments"
    /// The engine's per-session liveness marker, `Video/SessionDirectoryLiveness.swift:16`.
    static let markerName = "session.lock"
    /// Prefix of this cleanup's own renamed trees. Not a prefix the engine uses.
    static let trashPrefix = "aether-segments.trash-"
    /// Children probed under the lock at most; more means skip (keeps the engine's wait bounded).
    static let maxEntries = 1024

    // MARK: Pure decision

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
        /// Not looked at (the gate was not fresh).
        case notInspected
        case missing
        case unreadable(Int32)
        case tooManyEntries
        case entries([EntryProbe])
    }

    enum Skip: String, Equatable, Sendable {
        case engineInUse = "engine already in use"
        case alreadyRan = "already ran"
        case liveSession = "a session marker is held"
        case probeFailed = "a probe failed"
        case tooManyEntries = "too many entries"
    }

    enum Decision: Equatable, Sendable {
        case rename
        case nothingToRename
        case skip(Skip)

        var isSkip: Bool { if case .skip = self { return true } else { return false } }
    }

    /// Whether the cleanup may rename `aether-segments`. Total and fail closed: anything other than a
    /// fresh gate and a fully answered listing with no held marker is a skip.
    static func decide(gate: AetherEngineGate.State, root: RootState) -> Decision {
        switch gate {
        case .engineUsed: return .skip(.engineInUse)
        case .sweepClaimed: return .skip(.alreadyRan)
        case .fresh: break
        }
        switch root {
        case .notInspected: return .skip(.probeFailed)
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

    /// The tmp entries to delete after the lock is released: this cleanup's renamed trees (the one just
    /// made and any an interrupted earlier cleanup left). Nothing on a skip.
    static func trashToRemove(decision: Decision, tmpEntries: [String]) -> [String] {
        guard !decision.isSkip else { return [] }
        return tmpEntries.filter(isTrashName).sorted()
    }

    static func isTrashName(_ name: String) -> Bool {
        name.hasPrefix(trashPrefix) && name.count > trashPrefix.count
    }

    static func trashName(_ id: UUID) -> String { trashPrefix + id.uuidString }

    // MARK: IO shell

    /// What one run did, for the log line and tests.
    public struct Report: Equatable, Sendable {
        /// "renamed", "nothing to rename", or "skipped: <reason>".
        public let outcome: String
        public let childrenSeen: Int
        public let trashRemoved: Int
        public let failures: [String]
    }

    /// The app's launch hook. Once per process, regardless of the disk cache setting (a cache written
    /// under an earlier setting is still cleaned). Call off the main thread: the deletion can take seconds.
    @discardableResult
    public static func removeAtLaunch() -> Report {
        let report = run(tmp: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                         gate: .shared)
        if report.outcome != "nothing to rename" || report.trashRemoved > 0 || !report.failures.isEmpty {
            AetherLog.hostLine("[AetherCache] launch cleanup: \(report.outcome), children=\(report.childrenSeen) "
                               + "trashRemoved=\(report.trashRemoved)"
                               + (report.failures.isEmpty ? "" : " failures=\(report.failures.joined(separator: "; "))"))
        }
        return report
    }

    /// `tmp` is injected (tests use a scratch directory, never the real tmp). `underLock` runs while the
    /// gate's lock is held, after the decision and any rename (tests only).
    static func run(tmp: URL, gate: AetherEngineGate, maxEntries: Int = maxEntries,
                    underLock: (() -> Void)? = nil) -> Report {
        let root = tmp.appendingPathComponent(rootName, isDirectory: true)
        var failures: [String] = []
        var seen = 0
        let decision: Decision = gate.withLock { state in
            let before = state
            guard before == .fresh else {
                return decide(gate: before, root: .notInspected)
            }
            state = .sweepClaimed
            let listing = inspect(root: root, maxEntries: maxEntries)
            if case .entries(let probes) = listing { seen = probes.count }
            var d = decide(gate: before, root: listing)
            if d == .rename {
                let target = tmp.appendingPathComponent(trashName(UUID()), isDirectory: true)
                if Darwin.rename(root.path, target.path) != 0 {
                    failures.append("rename errno=\(errno)")
                    d = .nothingToRename
                }
            }
            underLock?()
            return d
        }

        let names = decision.isSkip ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        var removed = 0
        for name in trashToRemove(decision: decision, tmpEntries: names) {
            do {
                try FileManager.default.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
                removed += 1
            } catch {
                failures.append("remove \(name): \((error as NSError).code)")
            }
        }

        let outcome: String
        switch decision {
        case .rename: outcome = "renamed"
        case .nothingToRename: outcome = "nothing to rename"
        case .skip(let why): outcome = "skipped: \(why.rawValue)"
        }
        return Report(outcome: outcome, childrenSeen: seen, trashRemoved: removed, failures: failures)
    }

    /// Lists the direct children of `root` and probes each directory's marker. Never creates, never
    /// follows a symlink.
    static func inspect(root: URL, maxEntries: Int) -> RootState {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            return errno == ENOENT ? .missing : .unreadable(errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .unreadable(ENOTDIR) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            return .unreadable(Int32((error as NSError).code))
        }
        guard names.count <= maxEntries else { return .tooManyEntries }
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
