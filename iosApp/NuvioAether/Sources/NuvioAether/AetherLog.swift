import Foundation
internal import AetherEngine

/// Engine log plumbing (contract 9). Lines are already redacted by the engine (`EngineLog.emit` strips the
/// credential shapes it knows plus every registered secret) before they reach the handler.
public enum AetherLog {
    /// The serial queue every engine line hops onto before the host sink sees it: lines arrive on
    /// demuxer, producer and server threads, and the sink must see them one at a time, in order.
    static let queue = DispatchQueue(label: "nuvio.aether.log", qos: .utility)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var secretCounts: [String: Int] = [:]

    /// Installs the process-wide line sink once (app start, not per session). Later calls are ignored and
    /// return false, so a second caller cannot steal the stream.
    @discardableResult
    public static func install(_ sink: @escaping @Sendable (String) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return false }
        installed = true
        EngineLog.handler = { line in
            queue.async { sink(line) }
        }
        return true
    }

    /// Registers values that must never appear in a log line. Counted, so two sessions holding the same
    /// token keep it redacted until both release it. Values under 4 bytes are ignored (the engine's rule).
    static func register(_ values: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for v in values where v.utf8.count >= 4 {
            if EngineLog.registerSecret(v) { secretCounts[v, default: 0] += 1 }
        }
    }

    static func unregister(_ values: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for v in values {
            guard let n = secretCounts[v], n > 0 else { continue }
            EngineLog.unregisterSecret(v)
            secretCounts[v] = n > 1 ? n - 1 : nil
        }
    }

    /// The line as the engine would deliver it, with credentials stripped, for a host line printed next to
    /// the engine's (a request URL, say).
    public static func redacted(_ line: String) -> String {
        EngineLog.redacted(line)
    }

    /// A façade line through the engine's own funnel (redacted, same sink and OSLog subsystem).
    static func hostLine(_ line: String) {
        EngineLog.emit(line)
    }

    /// Flushes the queue (tests and the debug harness).
    public static func drain() {
        queue.sync {}
    }
}
