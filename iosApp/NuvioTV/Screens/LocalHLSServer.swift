import Foundation
import Network

// Phase 2 of the hybrid player: a loopback HTTP/1.1 file server that hands the `RemuxSession`'s
// emitted HLS directory (init/media segments + playlists) to AVPlayer. Binds 127.0.0.1 only, on a
// random-token path prefix, so nothing off-device — and no other local app scanning loopback — can
// read it. Supports GET with byte ranges (206), which AVPlayer uses for fMP4. Read-only static file
// serving; the NWListener pattern mirrors RemoteSetupServer.swift. See docs/tvos-hybrid-player-plan.md.

/// One-shot flag; `fire()` returns true exactly once. Lets a @Sendable closure resolve without
/// mutating a captured `var` (a Swift 6 concurrency error).
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

nonisolated final class LocalHLSServer: @unchecked Sendable {
    private let rootDir: URL
    /// Per-session path token; every request must be `/{token}/{file}`.
    let token: String
    /// When set, served `.m3u8` playlists have their video CODECS token rewritten on the fly — this
    /// FFmpeg build's dash muxer emits an empty video token in the master playlist. Doing it at serve
    /// time is race-free during progressive playback (the muxer may rewrite the file mid-stream).
    private let videoCodecToken: String?

    private let queue = DispatchQueue(label: "media.nuvio.hls-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16?

    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return _port }

    init(rootDir: URL, videoCodecToken: String? = nil) {
        self.rootDir = rootDir
        self.videoCodecToken = videoCodecToken
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Start listening on loopback and return the URL of `masterName` within the served directory,
    /// or nil if no port could be bound. `completion` runs on the main queue.
    func start(masterName: String, completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard listener == nil else {
            let existing = _port.map { url(port: $0, path: masterName) }
            lock.unlock()
            DispatchQueue.main.async { completion(existing) }
            return
        }
        lock.unlock()
        attemptStart(portOffset: 0, masterName: masterName, completion: completion)
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

    private func attemptStart(portOffset: UInt16, masterName: String, completion: @escaping (URL?) -> Void) {
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
            attemptStart(portOffset: portOffset + 1, masterName: masterName, completion: completion)
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
                DispatchQueue.main.async { completion(self.url(port: boundPort, path: masterName)) }
            case .failed, .cancelled:
                guard resolved.fire() else { return }
                candidate.cancel()
                self.lock.lock()
                if self.listener === candidate { self.listener = nil }
                self.lock.unlock()
                self.attemptStart(portOffset: portOffset + 1, masterName: masterName, completion: completion)
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection: connection, buffer: Data())
        }
        candidate.start(queue: queue)
    }

    // MARK: - Request handling (GET only)

    private static let maxHeaderBytes = 32 * 1024

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxHeaderBytes { connection.cancel(); return }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(connection: connection, buffer: buffer) }
                return
            }
            guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
                self.send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8), on: connection)
                return
            }
            self.handle(head: head, on: connection)
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2, requestLine[0].uppercased() == "GET" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("GET only".utf8), on: connection)
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
        serveFile(path: path, rangeHeader: rangeHeader, on: connection)
    }

    private func serveFile(path: String, rangeHeader: String?, on connection: NWConnection) {
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
        let fileURL = rootDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8), on: connection)
            return
        }
        let ctype = Self.contentType(for: name)

        // Playlists are small and fetched whole — rewrite the master CODECS on the fly and serve 200.
        if name.hasSuffix(".m3u8"), let videoCodecToken, let text = String(data: data, encoding: .utf8) {
            let fixed = Data(Self.rewriteMasterCodecs(text, videoToken: videoCodecToken).utf8)
            send(status: "200 OK", contentType: ctype, body: fixed, on: connection, extraHeaders: ["Accept-Ranges": "bytes"])
            return
        }

        if let rangeHeader, let (start, end) = Self.parseRange(rangeHeader, total: data.count) {
            send(status: "206 Partial Content", contentType: ctype, body: data.subdata(in: start..<(end + 1)),
                 on: connection, extraHeaders: [
                    "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                    "Accept-Ranges": "bytes",
                 ])
        } else {
            send(status: "200 OK", contentType: ctype, body: data, on: connection, extraHeaders: ["Accept-Ranges": "bytes"])
        }
    }

    // MARK: - Response

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Rewrite the first (video) token of every `CODECS="…"` on an `#EXT-X-STREAM-INF` line to
    /// `videoToken`. Media playlists have no such line, so this is a no-op on them.
    private static func rewriteMasterCodecs(_ text: String, videoToken: String) -> String {
        guard !videoToken.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("#EXT-X-STREAM-INF:"),
                  let open = line.range(of: "CODECS=\""),
                  let close = line[open.upperBound...].firstIndex(of: "\"") else { return line }
            var tokens = line[open.upperBound..<close].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if tokens.isEmpty { tokens = [videoToken] } else { tokens[0] = videoToken }
            return line.replacingCharacters(in: open.upperBound..<close, with: tokens.joined(separator: ","))
        }.joined(separator: "\n")
    }

    private static func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mpd") { return "application/dash+xml" }
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
