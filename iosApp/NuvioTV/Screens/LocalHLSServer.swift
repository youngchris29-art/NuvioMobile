import Foundation
import Network

// Phase 2/4 of the hybrid player: a loopback HTTP/1.1 server that feeds AVPlayer the owned segmenter's
// output. It SYNTHESIZES a complete VOD playlist up front from the `SegmentMap` (every segment, exact
// EXTINF, EXT-X-ENDLIST) — required because tvOS 27 rejects EVENT/growing playlists — and serves the
// `seg-NNNNN.m4s` files JUST-IN-TIME: a request for a segment the remux hasn't produced yet blocks
// (async, no thread held) until the file appears, up to a bounded timeout. Binds 127.0.0.1 only, on a
// random-token path prefix, so nothing off-device can read the stream. GET + HEAD, byte ranges (206).
// The NWListener pattern mirrors RemoteSetupServer.swift. See docs/tvos-hybrid-player-plan.md.

/// One-shot flag; `fire()` returns true exactly once. Lets a @Sendable closure resolve without
/// mutating a captured `var` (a Swift 6 concurrency error).
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

/// Per-connection liveness flag, flipped when the connection reaches a terminal state, so a JIT block
/// stops polling as soon as the client abandons the request. Read/written from the concurrent conn
/// queue, hence the lock.
private nonisolated final class ConnLive: @unchecked Sendable {
    private let lock = NSLock()
    private var _alive = true
    var alive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }
    func kill() { lock.lock(); _alive = false; lock.unlock() }
}

nonisolated final class LocalHLSServer: @unchecked Sendable {
    private let rootDir: URL
    /// Per-session path token; every request must be `/{token}/{file}`.
    let token: String
    private let listenerQueue = DispatchQueue(label: "media.nuvio.hls-listener")
    /// Concurrent so a segment request that blocks waiting for the remux can't starve the parallel
    /// requests AVPlayer issues (playlist refetch, init, the next segment). Blocking is done by async
    /// re-scheduling (never a held thread), so no connection stalls another.
    private let connQueue = DispatchQueue(label: "media.nuvio.hls-conn", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16?

    // Synthesized-VOD configuration.
    private let map: SegmentMap
    /// Master-playlist signaling; mutable so the coordinator can retry with reduced signaling when a
    /// strict AVPlayer rejects the full DV form at the master stage.
    private var _signaling: VideoSignaling
    private let audioCodec: String?
    private let bandwidth: Int
    let masterName = "master.m3u8"
    let mediaName = "media.m3u8"

    // JIT serve tuning.
    /// Max time to block a not-yet-produced segment. Well under CFNetwork's ~60s request timeout so a
    /// blocked GET never surfaces as a fatal network error — on timeout we return a retryable 503.
    private let blockTimeout: TimeInterval = 20
    /// How many segments past the current remux frontier we'll wait for (covers AVPlayer's forward
    /// buffer). Beyond this a request is a real forward seek the linear remux can't serve soon → 503.
    private let blockMargin = 6

    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return _port }

    init(rootDir: URL, map: SegmentMap, signaling: VideoSignaling, audioCodec: String?, bandwidth: Int) {
        self.rootDir = rootDir
        self.map = map
        self._signaling = signaling
        self.audioCodec = audioCodec
        self.bandwidth = bandwidth
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Swap the master-playlist signaling (used for the minimal-signaling retry).
    func setSignaling(_ signaling: VideoSignaling) {
        lock.lock(); _signaling = signaling; lock.unlock()
    }

    /// The master playlist exactly as a client would receive it right now (for failure diagnostics).
    func renderedMasterPlaylist() -> String? { renderedPlaylist(named: masterName) }

    /// A synthesized playlist exactly as a client would receive it right now (for failure diagnostics).
    func renderedPlaylist(named name: String) -> String? {
        switch name {
        case masterName:
            lock.lock(); let signaling = _signaling; lock.unlock()
            return map.masterPlaylist(signaling: signaling, audioCodec: audioCodec,
                                      bandwidth: bandwidth, mediaName: mediaName)
        case mediaName:
            return map.mediaPlaylist()
        default:
            return nil
        }
    }

    /// Start listening on loopback and return the URL of the master playlist, or nil if no port could
    /// be bound. `completion` runs on the main queue.
    func start(masterName: String, completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard listener == nil else {
            let existing = _port.map { url(port: $0, path: self.masterName) }
            lock.unlock()
            DispatchQueue.main.async { completion(existing) }
            return
        }
        lock.unlock()
        attemptStart(portOffset: 0, completion: completion)
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        _port = nil
        lock.unlock()
        active?.cancel()
    }

    /// `http://127.0.0.1:{port}/{token}/{path}`
    func url(port: UInt16, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/\(path)")!
    }

    // MARK: - Listener

    private func attemptStart(portOffset: UInt16, completion: @escaping (URL?) -> Void) {
        guard portOffset < 20, let nwPort = NWEndpoint.Port(rawValue: 8190 + portOffset) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Loopback-only bind: nothing outside the device can reach the remuxed stream.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let candidate: NWListener
        do {
            candidate = try NWListener(using: params)
        } catch {
            attemptStart(portOffset: portOffset + 1, completion: completion)
            return
        }

        lock.lock(); listener = candidate; lock.unlock()

        // Fires exactly once (ready OR failed), guarded so the @Sendable listener callback can't
        // race a second resolution — Swift 6 forbids mutating a captured `var` here.
        let resolved = OnceFlag()
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard resolved.fire() else { return }
                let boundPort = 8190 + portOffset
                self.lock.lock(); self._port = boundPort; self.lock.unlock()
                DispatchQueue.main.async { completion(self.url(port: boundPort, path: self.masterName)) }
            case .failed, .cancelled:
                guard resolved.fire() else { return }
                candidate.cancel()
                self.lock.lock()
                let isCurrent = self.listener === candidate
                if isCurrent { self.listener = nil }
                self.lock.unlock()
                // Only a genuine bind failure re-attempts the next port. A deliberate stop() sets
                // listener=nil and cancels us — rebinding then would resurrect a stopped server.
                guard isCurrent else { return }
                self.attemptStart(portOffset: portOffset + 1, completion: completion)
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // Per-connection liveness: a JIT block that outlives an abandoned request (AVPlayer cancels
            // a prefetch, or the item is torn down) should stop polling immediately, not run its full
            // timeout. The connection's terminal states flip this.
            let live = ConnLive()
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: live.kill()
                default: break
                }
            }
            connection.start(queue: self.connQueue)
            self.receive(connection: connection, buffer: Data(), live: live)
        }
        candidate.start(queue: listenerQueue)
    }

    // MARK: - Request handling (GET / HEAD)

    private static let maxHeaderBytes = 32 * 1024

    private func receive(connection: NWConnection, buffer: Data, live: ConnLive) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxHeaderBytes { connection.cancel(); return }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(connection: connection, buffer: buffer, live: live) }
                return
            }
            guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
                self.send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8), on: connection)
                return
            }
            self.handle(head: head, on: connection, live: live)
        }
    }

    private func handle(head: String, on connection: NWConnection, live: ConnLive) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first?.uppercased() ?? ""
        guard requestLine.count >= 2, method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("GET/HEAD only".utf8), on: connection)
            return
        }
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                rangeHeader = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestLine[1]
        serveFile(path: path, rangeHeader: rangeHeader, isHead: method == "HEAD", on: connection, live: live)
    }

    private func serveFile(path: String, rangeHeader: String?, isHead: Bool, on connection: NWConnection, live: ConnLive) {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count == 2, comps[0] == token else {
            send(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8), on: connection)
            return
        }
        let name = comps[1]
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else {
            send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad path".utf8), on: connection)
            return
        }

        // Synthesized VOD playlists — generated from the SegmentMap, never files on disk. Complete and
        // ENDLIST-terminated from the first fetch so tvOS 27 treats the stream as VOD.
        if name.hasSuffix(".m3u8") {
            guard let text = renderedPlaylist(named: name) else {
                send(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8), on: connection, requestPath: name)
                return
            }
            send(status: "200 OK", contentType: Self.contentType(for: name), body: Data(text.utf8), on: connection,
                 extraHeaders: ["Accept-Ranges": "bytes"], requestPath: name, isHead: isHead)
            return
        }

        // init.mp4 / seg-NNNNN.m4s — produced just-in-time by the remux; block until present.
        serveSegmentJIT(name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection,
                        deadline: Date().addingTimeInterval(blockTimeout), decided: false, live: live)
    }

    /// Serve a media file if it exists; otherwise block (by async re-scheduling, holding no thread)
    /// until the remux produces it, up to `deadline`. A request far past the remux frontier (a forward
    /// seek the linear remux can't satisfy soon) fast-fails 503; a request past the last segment 404s;
    /// a block that times out returns a retryable 503; an abandoned connection stops the loop at once.
    private func serveSegmentJIT(name: String, rangeHeader: String?, isHead: Bool,
                                 on connection: NWConnection, deadline: Date, decided: Bool, live: ConnLive) {
        guard live.alive else { connection.cancel(); return }   // client gave up mid-block
        let fileURL = rootDir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            serveBytes(data, name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection)
            return
        }

        // First visit: decide whether to wait at all.
        if !decided, let idx = Self.segmentIndex(name) {
            if idx > map.count {
                send(status: "404 Not Found", contentType: "text/plain", body: Data("Past end".utf8),
                     on: connection, requestPath: name)
                return
            }
            let frontier = currentFrontier()
            if idx > frontier + blockMargin {
                // Forward seek beyond what the remux will reach soon. 503 is retryable; the coordinator's
                // stall watchdog escalates a sustained forward-seek stall to the mpv fallback.
                send(status: "503 Service Unavailable", contentType: "text/plain", body: Data("Ahead of remux".utf8),
                     on: connection, extraHeaders: ["Retry-After": "1"], requestPath: name)
                return
            }
        }

        if Date() >= deadline {
            send(status: "503 Service Unavailable", contentType: "text/plain", body: Data("Remux timeout".utf8),
                 on: connection, extraHeaders: ["Retry-After": "1"], requestPath: name)
            return
        }
        connQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.serveSegmentJIT(name: name, rangeHeader: rangeHeader, isHead: isHead,
                                  on: connection, deadline: deadline, decided: true, live: live)
        }
    }

    private func serveBytes(_ data: Data, name: String, rangeHeader: String?, isHead: Bool, on connection: NWConnection) {
        let ctype = Self.contentType(for: name)
        if let rangeHeader, let (start, end) = Self.parseRange(rangeHeader, total: data.count) {
            send(status: "206 Partial Content", contentType: ctype, body: data.subdata(in: start..<(end + 1)),
                 on: connection, extraHeaders: [
                    "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                    "Accept-Ranges": "bytes",
                 ], requestPath: name, isHead: isHead)
        } else {
            send(status: "200 OK", contentType: ctype, body: data, on: connection,
                 extraHeaders: ["Accept-Ranges": "bytes"], requestPath: name, isHead: isHead)
        }
    }

    /// Highest completed segment index present on disk (0 if none). Completion is signalled by the
    /// atomic `.part` → final rename in `SegmentWriter`, so a present `seg-NNNNN.m4s` is whole.
    private func currentFrontier() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootDir.path)) ?? []
        var maxIdx = 0
        for n in names where n.hasSuffix(".m4s") {
            if let idx = Self.segmentIndex(n), idx > maxIdx { maxIdx = idx }
        }
        return maxIdx
    }

    /// Parse the 1-based index from `seg-NNNNN.m4s`, or nil for `init.mp4` / anything else.
    static func segmentIndex(_ name: String) -> Int? {
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    // MARK: - Response

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection,
                      extraHeaders: [String: String] = [:], requestPath: String? = nil, isHead: Bool = false) {
        #if DEBUG
        // Request log: shows exactly what AVPlayer fetched (and where it stopped) during device runs.
        if let requestPath { print("[HLS] \(status.prefix(3)) \(isHead ? "HEAD " : "")\(requestPath) (\(body.count)b)") }
        #endif
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        // Send the header and body as two ordered sends (NWConnection preserves order) rather than
        // concatenating — that keeps the (memory-mapped) segment body from being copied into a second
        // full-size buffer, which on concurrent large-segment serves is a real transient-memory spike.
        let headData = Data(head.utf8)
        if isHead || body.isEmpty {
            connection.send(content: headData, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.send(content: headData, completion: .contentProcessed { _ in })
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mp4") { return "video/mp4" }
        if name.hasSuffix(".m4s") { return "video/iso.segment" }
        return "application/octet-stream"
    }

    /// Parse a single `bytes=start-end` / `bytes=start-` / `bytes=-suffix` range against `total`.
    private static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard total > 0, let eq = header.firstIndex(of: "="),
              header[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else { return nil }
        let spec = header[header.index(after: eq)...].split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let start: Int, end: Int
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            start = max(0, total - suffix); end = total - 1
        } else {
            guard let s = Int(parts[0]) else { return nil }
            start = s
            end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? (total - 1), total - 1)
        }
        guard start >= 0, start <= end, start < total else { return nil }
        return (start, end)
    }
}
