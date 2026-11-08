import Foundation
import Network
import Security

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
/// - `GET  /api/status/{id}`→ `{status: pending|applying|confirmed|rejected|superseded|stale|invalid|read_only|partial|stale_rows|not_found}` (browser polls)
///
/// Threading: the listener + connections run on a private queue. The state snapshot and the
/// pending-change table are guarded by a lock; `onChangeProposed` is delivered on the main queue.
/// The server holds no SharedCore references — `RemoteSetupViewModel` feeds it data.
final class RemoteSetupServer {

    // MARK: - Wire models

    /// What the web page proposes. All fields optional so old/partial pages stay compatible.
    struct Proposal: Decodable {
        /// Stage C (C1): an installed add-on is named by its per-session `id` (the page never sees
        /// manifest URLs, which can carry debrid keys); only a NEW add-on carries the `url` the
        /// user typed. `RemoteSetupAddonIds.resolve` maps the list back to URLs on the TV.
        struct AddonEntry: Decodable {
            let id: String?
            let url: String?
            let enabled: Bool?
        }

        /// Full desired addon list, in order. Missing = leave addons untouched.
        let addons: [AddonEntry]?
        /// C1: the add-on ids of the TV list the page loaded, in order. An add-on list is applied
        /// only while the TV's list still matches it, so an add-on that arrived after the page
        /// loaded is never removed by omission.
        let addonBaseline: [String]?
        /// Full desired Home-row key order. Missing = leave order untouched.
        let rowOrder: [String]?
        /// Keys of rows that should be disabled (everything else in `rowOrder` is enabled).
        let disabledRowKeys: [String]?
        /// New API key; only sent when the user typed one (never echoes the saved key). TMDB has
        /// no key entry any more (upstream 60ee0160 bundles the key at compile time).
        let mdblistKey: String?
        /// Custom poster URL pattern. Blank clears it. May embed an API key: never logged.
        let posterPattern: String?
        /// Stream badge pack JSON URLs to import (staged additions only; removal happens on TV).
        let badgeUrls: [String]?
    }

    enum ChangeStatus: String {
        case pending
        /// Claimed by the TV's confirm and being applied; no longer supersedable. The page keeps
        /// polling until it settles as `confirmed` or `stale`.
        case applying
        case confirmed
        /// Declined by the user on the TV.
        case rejected
        /// Replaced by a newer proposal before the user decided.
        case superseded
        /// Refused by the TV without asking: an add-on id is unknown or its add-on left the list
        /// since the page loaded (the page reloads the TV's list).
        case stale
        /// Refused by the TV without asking: a new add-on address is not a valid manifest URL or
        /// is already installed (the page keeps its edits).
        case invalid
        /// Refused by the TV: the active profile's add-ons are inherited from another profile and
        /// the change would edit them (the page keeps its edits).
        case readOnly = "read_only"
        /// Applied, except some new add-ons whose install failed (`failedNewIndices`).
        case partial
        /// Refused without asking: a Home-row id is unknown to this session (the page reloads all).
        case staleRows = "stale_rows"
    }

    final class PendingChange {
        let id: String
        let proposal: Proposal
        var status: ChangeStatus = .pending
        /// Indices (among the proposal's NEW add-ons, in order) whose install failed; set with a
        /// `partial` outcome so the page can keep exactly those entries for a retry.
        var failedNewIndices: [Int] = []
        /// Review r4: new add-ons another change installed first with the other on/off setting.
        var conflicts = 0
        let createdAt = Date()

        init(proposal: Proposal) {
            self.id = UUID().uuidString
            self.proposal = proposal
        }
    }

    // MARK: - Public surface

    /// Fired (on main) when a browser POSTs a proposal. The host UI shows a confirm alert and
    /// then calls `confirm(id:)` or `reject(id:)`.
    var onChangeProposed: ((PendingChange) -> Void)?
    /// C2: called on the main queue for every request that presented this session's token, so
    /// the TV can show "Page opened". Review r2: stored under `lock` (the listener queue reads
    /// it), and a call from a session that has since ended (New code, Stop) is dropped.
    var onAuthorizedRequest: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return authorizedRequestHandler }
        set { lock.lock(); authorizedRequestHandler = newValue; lock.unlock() }
    }
    private var authorizedRequestHandler: (() -> Void)?

    private(set) var port: UInt16?

    /// Per-session pairing token (HI-001). Included in the QR/display URL as `?t=…`; every route
    /// rejects requests that don't present it, so a LAN port-scanner can't read the config
    /// (addon manifest URLs may embed debrid API keys). Regenerated on every `start()`.
    var sessionToken: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    /// Starts listening; tries ports 8080…8089. `completion` (main queue) gets the bound port,
    /// or nil if every port failed.
    func start(completion: @escaping (UInt16?) -> Void) {
        lock.lock()
        guard listener == nil else {
            let current = port
            lock.unlock()
            DispatchQueue.main.async { completion(current) }
            return
        }
        generation += 1
        token = Self.makeToken()
        // Review r16: a new session never serves the previous one's snapshot (its ids mean
        // nothing now); the page sees an empty state until the watchers publish.
        stateJSON = Data("{}".utf8)
        let gen = generation
        lock.unlock()
        attemptStart(portOffset: 0, generation: gen, completion: completion)
    }

    func stop() {
        lock.lock()
        // Invalidate in-flight start attempts (HI-002): a candidate listener that reaches `.ready`
        // after this point must cancel itself instead of resurrecting the server.
        generation += 1
        let active = listener
        listener = nil
        port = nil
        token = nil
        pending.removeAll()
        pendingOrder.removeAll()
        lastProposalAt = nil
        stateJSON = Data("{}".utf8)
        lock.unlock()
        active?.cancel()
    }

    /// Replaces the JSON served at `/api/state`. Called from the main actor whenever repos emit.
    func updateState(_ json: Data) {
        lock.lock()
        stateJSON = json
        lock.unlock()
    }

    /// Claims `id` for applying: true, and the change is marked `applying`, only if it was still
    /// pending. Atomic with supersession, so a change replaced by a newer proposal is never
    /// applied after the fact. The caller settles it with `finishApplying`.
    func claimForConfirm(id: String) -> Bool {
        settle(id: id, status: .applying)
    }

    /// Settles a claimed change as `confirmed`, or as the refusal that stopped it.
    func finishApplying(id: String, status: ChangeStatus, failedNewIndices: [Int] = [], conflicts: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard let change = pending[id], change.status == .applying else { return }
        change.status = status
        change.failedNewIndices = failedNewIndices
        change.conflicts = conflicts
    }

    /// Settles a still-pending change as declined or refused; a no-op for one already settled.
    func reject(id: String, status: ChangeStatus = .rejected) {
        _ = settle(id: id, status: status)
    }

    /// True while `id` is still awaiting a decision (not superseded, refused or decided).
    func isPending(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[id]?.status == .pending
    }

    // MARK: - Internals

    private let queue = DispatchQueue(label: "nuvio.remote-setup-server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var stateJSON = Data("{}".utf8)
    private var pending: [String: PendingChange] = [:]
    /// Insertion order of `pending` ids, oldest first, so the table stays bounded (ME-003).
    private var pendingOrder: [String] = []
    private var lastProposalAt: Date?
    /// Seconds between accepted proposals (ME-003); lowered only by tests.
    var minProposalInterval: TimeInterval = 1.0
    private var token: String?
    /// Bumped by `start()` and `stop()`; callbacks from a superseded attempt see a stale value
    /// and bail (HI-002).
    private var generation = 0

    /// Bytes a single connection may buffer before being dropped (headers + body).
    private static let maxRequestBytes = 256 * 1024
    /// Largest accepted request body; proposal JSON is tiny, so this is generous (ME-001/ME-003).
    private static let maxBodyBytes = 128 * 1024

    /// 10 chars from a 32-symbol confusable-free alphabet (~50 bits) — high enough entropy for a
    /// transient LAN session while staying typeable from the on-screen URL.
    private static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 10)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return UUID().uuidString }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private func settle(id: String, status: ChangeStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let change = pending[id], change.status == .pending else { return false }
        change.status = status
        return true
    }

    private func attemptStart(portOffset: UInt16, generation: Int, completion: @escaping (UInt16?) -> Void) {
        guard portOffset < 10, let nwPort = NWEndpoint.Port(rawValue: 8080 + portOffset) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let candidate: NWListener
        do {
            candidate = try NWListener(using: .tcp, on: nwPort)
        } catch {
            attemptStart(portOffset: portOffset + 1, generation: generation, completion: completion)
            return
        }

        // Retain the candidate immediately (HI-002): if the user stops before it reaches `.ready`,
        // `stop()` can cancel it rather than leaving an orphan that later resurrects the server.
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            candidate.cancel()
            return
        }
        listener = candidate
        lock.unlock()

        var resolved = false
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !resolved else { return }
                resolved = true
                self.lock.lock()
                guard generation == self.generation else {
                    self.lock.unlock()
                    candidate.cancel()
                    return
                }
                self.port = 8080 + portOffset
                self.lock.unlock()
                DispatchQueue.main.async { completion(8080 + portOffset) }
            case .failed, .cancelled:
                guard !resolved else { return }
                resolved = true
                candidate.cancel()
                self.lock.lock()
                let superseded = generation != self.generation
                if !superseded, self.listener === candidate { self.listener = nil }
                self.lock.unlock()
                if !superseded {
                    self.attemptStart(portOffset: portOffset + 1, generation: generation, completion: completion)
                }
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
            if error != nil || buffer.count > Self.maxRequestBytes {
                connection.cancel()
                return
            }
            switch HttpRequest.parse(buffer, maxBodyBytes: Self.maxBodyBytes) {
            case .request(let request):
                self.respond(to: request, on: connection)
            case .invalid:
                // Malformed framing (bad/negative/duplicate Content-Length, non-UTF8 head, …)
                // gets a clean 400 instead of a crash or a hung read (ME-001).
                self.send(
                    HttpResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8)),
                    on: connection
                )
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: HttpResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond(to request: HttpRequest, on connection: NWConnection) {
        // Every route — including the landing page — requires the session's pairing token,
        // presented either as the `?t=` query param (QR/typed URL) or the `X-Setup-Token`
        // header (the page's own API calls). Everything else gets an opaque 403 (HI-001).
        lock.lock()
        let expected = token
        let session = generation
        let onAuthorized = authorizedRequestHandler
        lock.unlock()
        let presented = request.query["t"] ?? request.headers["x-setup-token"]
        guard let expected, let presented, presented == expected else {
            send(
                HttpResponse(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8)),
                on: connection
            )
            return
        }
        if let onAuthorized {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.generation == session && self.token == expected
                self.lock.unlock()
                if current { onAuthorized() }
            }
        }

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
            response = handleApply(body: request.body, session: session, token: expected)
        case ("GET", let path) where path.hasPrefix("/api/status/"):
            let id = String(path.dropFirst("/api/status/".count))
            lock.lock()
            let status = pending[id]?.status.rawValue ?? "not_found"
            let failed = pending[id]?.failedNewIndices ?? []
            let conflicts = pending[id]?.conflicts ?? 0
            lock.unlock()
            var fields = ["status": status]
            if !failed.isEmpty { fields["failedNew"] = failed.map(String.init).joined(separator: ",") }
            if conflicts > 0 { fields["conflicts"] = String(conflicts) }
            response = HttpResponse.json(fields)
        default:
            response = HttpResponse(
                status: "404 Not Found",
                contentType: "text/plain",
                body: Data("Not found".utf8)
            )
        }

        send(response, on: connection)
    }

    /// Test seam: the state JSON a page would load.
    func stateForTesting() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stateJSON
    }

    /// Test seam: the status a page polling `id` would see (nil once evicted).
    func statusForTesting(id: String) -> ChangeStatus? {
        lock.lock()
        defer { lock.unlock() }
        return pending[id]?.status
    }

    /// Test seam: submits a proposal body as `POST /api/apply` would and returns its change id
    /// (nil when refused), without a listener.
    func submitForTesting(_ body: Data, session: Int? = nil) -> String? {
        lock.lock()
        let current = (generation, token)
        lock.unlock()
        let response = handleApply(body: body, session: session ?? current.0, token: current.1)
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return json?["id"] as? String
    }

    /// Test seam: the current session's generation (bumped by every start and stop).
    func sessionForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// `session` and `token` are what the request was authorised against; review r3: they are
    /// checked again under the lock that stores the proposal, so a request authorised just before
    /// New code (or Stop) cannot land in the next session.
    private func handleApply(body: Data, session: Int, token authorised: String?) -> HttpResponse {
        guard let proposal = try? JSONDecoder().decode(Proposal.self, from: body) else {
            return HttpResponse.json(["error": "Invalid request body"], status: "400 Bad Request")
        }
        let change = PendingChange(proposal: proposal)
        let now = Date()
        lock.lock()
        guard generation == session, token == authorised else {
            lock.unlock()
            return HttpResponse(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8))
        }
        // Simple rate limit: one proposal per second. Stops a misbehaving peer from replacing the
        // on-TV confirmation alert in a loop (ME-003).
        if let last = lastProposalAt, now.timeIntervalSince(last) < minProposalInterval {
            lock.unlock()
            return HttpResponse.json(["error": "Too many requests"], status: "429 Too Many Requests")
        }
        lastProposalAt = now
        // A new proposal supersedes any stale pending one (mirrors Android).
        for other in pending.values where other.status == .pending {
            other.status = .superseded
        }
        pending[change.id] = change
        pendingOrder.append(change.id)
        // Keep a small bounded history — enough for the browser's status polling of the current
        // and recently superseded proposals, without growing for the session's lifetime (ME-003).
        // Only settled changes are evicted: a change still being applied (slow installs) keeps
        // its entry so its page learns the real outcome (C1 review r11). The newest, pending
        // one is never the oldest while anything older is settled.
        while pendingOrder.count > 8,
              let index = pendingOrder.firstIndex(where: { pending[$0]?.status != .applying && $0 != change.id }) {
            pending.removeValue(forKey: pendingOrder.remove(at: index))
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onChangeProposed?(change)
        }
        return HttpResponse.json(["status": "pending_confirmation", "id": change.id])
    }
}

// MARK: - Minimal HTTP plumbing

private enum HttpParseResult {
    /// Not enough bytes yet — caller keeps receiving.
    case incomplete
    /// Structurally malformed — caller responds 400 and closes.
    case invalid
    case request(HttpRequest)
}

private struct HttpRequest {
    let method: String
    let path: String
    /// Percent-decoded query parameters (the pairing token arrives as `?t=…`).
    let query: [String: String]
    /// Header fields, keys lowercased.
    let headers: [String: String]
    let body: Data

    static func parse(_ buffer: Data, maxBodyBytes: Int) -> HttpParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // No end-of-headers within a generous window → header flood, not a slow client.
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        guard requestParts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { contentLengths.append(value) }
            headers[key] = value
        }

        // Exactly one well-formed, nonnegative, bounded Content-Length (or none → 0). Negative
        // values previously produced an inverted body range and crashed the app (ME-001);
        // duplicates/conflicts are request smuggling by another name.
        var contentLength = 0
        if !contentLengths.isEmpty {
            guard Set(contentLengths).count == 1,
                  let parsed = Int(contentLengths[0]),
                  parsed >= 0, parsed <= maxBodyBytes
            else { return .invalid }
            contentLength = parsed
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        if available < contentLength { return .incomplete }

        let target = requestParts[1]
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding, !key.isEmpty else { continue }
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }

        return .request(HttpRequest(
            method: requestParts[0].uppercased(),
            path: String(pathAndQuery[0]),
            query: query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        ))
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
