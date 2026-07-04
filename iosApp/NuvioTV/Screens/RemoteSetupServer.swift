import Foundation
import Network

/// A tiny HTTP/1.1 server (Network.framework `NWListener`) that lets the user configure the app
/// from a phone/laptop browser on the same network — the tvOS analog of Android TV's
/// `AddonConfigServer` (NanoHTTPD). Massive text-entry relief vs the tvOS keyboard.
///
/// Endpoints (all JSON unless noted):
/// - `GET  /`               → the embedded config web page (see `RemoteSetupWebPage`)
/// - `GET  /api/state`      → current addons / home rows / key presence snapshot
/// - `POST /api/apply`      → proposes a change; returns `{id, status: "pending_confirmation"}`.
///                            Nothing is applied until the user confirms ON THE TV (alert in
///                            Settings) — same trust model as Android.
/// - `GET  /api/status/{id}`→ `{status: pending|confirmed|rejected|not_found}` (browser polls)
///
/// Threading: the listener + connections run on a private queue. The state snapshot and the
/// pending-change table are guarded by a lock; `onChangeProposed` is delivered on the main queue.
/// The server holds no SharedCore references — `RemoteSetupViewModel` feeds it data.
final class RemoteSetupServer {

    // MARK: - Wire models

    /// What the web page proposes. All fields optional so old/partial pages stay compatible.
    struct Proposal: Decodable {
        struct AddonEntry: Decodable {
            let url: String
            let enabled: Bool?
        }

        /// Full desired addon list, in order. Missing = leave addons untouched.
        let addons: [AddonEntry]?
        /// Full desired Home-row key order. Missing = leave order untouched.
        let rowOrder: [String]?
        /// Keys of rows that should be disabled (everything else in `rowOrder` is enabled).
        let disabledRowKeys: [String]?
        /// New API keys; only sent when the user typed one (never echoes saved keys).
        let tmdbKey: String?
        let mdblistKey: String?
    }

    enum ChangeStatus: String {
        case pending
        case confirmed
        case rejected
    }

    final class PendingChange {
        let id: String
        let proposal: Proposal
        var status: ChangeStatus = .pending

        init(proposal: Proposal) {
            self.id = UUID().uuidString
            self.proposal = proposal
        }
    }

    // MARK: - Public surface

    /// Fired (on main) when a browser POSTs a proposal. The host UI shows a confirm alert and
    /// then calls `confirm(id:)` or `reject(id:)`.
    var onChangeProposed: ((PendingChange) -> Void)?

    private(set) var port: UInt16?

    /// Starts listening; tries ports 8080…8089. `completion` (main queue) gets the bound port,
    /// or nil if every port failed.
    func start(completion: @escaping (UInt16?) -> Void) {
        guard listener == nil else {
            completion(port)
            return
        }
        attemptStart(portOffset: 0, completion: completion)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    /// Replaces the JSON served at `/api/state`. Called from the main actor whenever repos emit.
    func updateState(_ json: Data) {
        lock.lock()
        stateJSON = json
        lock.unlock()
    }

    func confirm(id: String) {
        setStatus(id: id, status: .confirmed)
    }

    func reject(id: String) {
        setStatus(id: id, status: .rejected)
    }

    // MARK: - Internals

    private let queue = DispatchQueue(label: "nuvio.remote-setup-server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var stateJSON = Data("{}".utf8)
    private var pending: [String: PendingChange] = [:]

    private func setStatus(id: String, status: ChangeStatus) {
        lock.lock()
        pending[id]?.status = status
        lock.unlock()
    }

    private func attemptStart(portOffset: UInt16, completion: @escaping (UInt16?) -> Void) {
        guard portOffset < 10, let nwPort = NWEndpoint.Port(rawValue: 8080 + portOffset) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let candidate: NWListener
        do {
            candidate = try NWListener(using: .tcp, on: nwPort)
        } catch {
            attemptStart(portOffset: portOffset + 1, completion: completion)
            return
        }

        var resolved = false
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !resolved else { return }
                resolved = true
                self.listener = candidate
                self.port = 8080 + portOffset
                DispatchQueue.main.async { completion(8080 + portOffset) }
            case .failed, .cancelled:
                guard !resolved else { return }
                resolved = true
                candidate.cancel()
                self.attemptStart(portOffset: portOffset + 1, completion: completion)
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        candidate.start(queue: queue)
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 1024 * 1024 {
                connection.cancel()
                return
            }
            if let request = HttpRequest(parsing: buffer) {
                self.respond(to: request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(connection: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HttpRequest, on connection: NWConnection) {
        let response: HttpResponse
        switch (request.method, request.path) {
        case ("GET", "/"):
            response = HttpResponse(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: Data(RemoteSetupWebPage.html.utf8)
            )
        case ("GET", "/api/state"):
            lock.lock()
            let body = stateJSON
            lock.unlock()
            response = HttpResponse(status: "200 OK", contentType: "application/json", body: body)
        case ("POST", "/api/apply"):
            response = handleApply(body: request.body)
        case ("GET", let path) where path.hasPrefix("/api/status/"):
            let id = String(path.dropFirst("/api/status/".count))
            lock.lock()
            let status = pending[id]?.status.rawValue ?? "not_found"
            lock.unlock()
            response = HttpResponse.json(["status": status])
        default:
            response = HttpResponse(
                status: "404 Not Found",
                contentType: "text/plain",
                body: Data("Not found".utf8)
            )
        }

        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleApply(body: Data) -> HttpResponse {
        guard let proposal = try? JSONDecoder().decode(Proposal.self, from: body) else {
            return HttpResponse.json(["error": "Invalid request body"], status: "400 Bad Request")
        }
        let change = PendingChange(proposal: proposal)
        lock.lock()
        // A new proposal supersedes any stale pending one (mirrors Android).
        for other in pending.values where other.status == .pending {
            other.status = .rejected
        }
        pending[change.id] = change
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onChangeProposed?(change)
        }
        return HttpResponse.json(["status": "pending_confirmation", "id": change.id])
    }
}

// MARK: - Minimal HTTP plumbing

private struct HttpRequest {
    let method: String
    let path: String
    let body: Data

    /// Returns nil while the request is still incomplete (caller keeps receiving).
    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        guard requestParts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        guard available >= contentLength else { return nil }

        self.method = requestParts[0].uppercased()
        // Strip any query string; none of our routes use one.
        self.path = requestParts[1].components(separatedBy: "?")[0]
        self.body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
    }
}

private struct HttpResponse {
    let status: String
    let contentType: String
    let body: Data

    static func json(_ object: [String: String], status: String = "200 OK") -> HttpResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HttpResponse(status: status, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Device IP

enum DeviceIpAddress {
    /// First non-loopback IPv4 address, preferring Wi-Fi/Ethernet interfaces (en0/en1).
    static func current() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: host)
                if ip != "127.0.0.1" {
                    addresses.append((name, ip))
                }
            }
        }
        let preferred = addresses.first { $0.name.hasPrefix("en") }
        return (preferred ?? addresses.first)?.ip
    }
}
