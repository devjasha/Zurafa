import Foundation
import UIKit
import Network

/// The phone's one connection to the Mac's zurafa-daemon, over its tailnet listener (port 7297).
/// The Mac admits only devices signed in to its own Tailscale account, so there is no pairing step.
@MainActor final class MacClient: ObservableObject {
    static let shared = MacClient()
    static let defaultPort: UInt16 = 7297

    enum State: Equatable { case idle, connecting, connected, failed(String) }

    @Published private(set) var state = State.idle
    @Published private(set) var snapshot: EventSnapshot?
    @Published private(set) var hosts: [RemoteHost] = []
    /// Goes up on every successful connect, so open terminals know to attach again.
    @Published private(set) var generation = 0
    /// The Mac's look; kept across launches so the app opens in it before connecting. Nil until a Mac has sent one.
    @Published private(set) var appearance: MacAppearance? = UserDefaults.standard.data(forKey: "macAppearance")
        .flatMap { try? JSONDecoder().decode(MacAppearance.self, from: $0) } {
        didSet { UserDefaults.standard.set(appearance.flatMap { try? JSONEncoder().encode($0) }, forKey: "macAppearance") }
    }
    var onOutput: (String, Data, UInt64?) -> Void = { _, _, _ in }
    /// A pane a tapped notification asked to show.
    @Published var openPane: String?
    /// This phone's APNs token, handed to the Mac so its notifications reach the phone.
    var pushToken: String? {
        didSet { registerPush() }
    }

    private(set) var address = ""
    private var conn: NWConnection?
    private var upgraded = false
    private var head = Data()
    private var decoder = FrameDecoder()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Msg, Error>] = [:]
    private var refreshing = false

    /// `my-mac`, `my-mac.tail1234.ts.net`, `100.x.y.z`, optionally with `:port`.
    static func endpoint(_ address: String) -> (host: String, port: UInt16) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]) {
            return (String(trimmed[..<colon]), port)
        }
        return (trimmed, defaultPort)
    }

    func connect(to address: String) {
        self.address = address
        drop(conn, reason: nil)
        let (host, port) = Self.endpoint(address)
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return state = .failed("Enter your Mac's Tailscale name.") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        (conn, upgraded, head, decoder, state) = (c, false, Data(), FrameDecoder(), .connecting)
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self, self.conn === c else { return }
                switch s {
                case .ready: self.upgrade(c, host: host)
                case .waiting(let e), .failed(let e):
                    self.drop(c, reason: "Can't reach \(host) (\(e.localizedDescription)). Is Tailscale on here and on the Mac?")
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    /// Reconnects after the app comes back, unless the user never connected.
    func resume() {
        if !address.isEmpty, state != .connected, state != .connecting { connect(to: address) }
    }

    func disconnect() {
        drop(conn, reason: nil)
        (address, snapshot, hosts) = ("", nil, [])
    }

    func request(_ object: [String: JSONValue]) async throws -> Msg {
        guard state == .connected, let c = conn else { throw DaemonError("Not connected to your Mac") }
        return try await call(JSONEncoder().encode(object), on: c)
    }

    func request(_ m: Msg) async throws -> Msg {
        guard state == .connected, let c = conn else { throw DaemonError("Not connected to your Mac") }
        return try await call(JSONEncoder().encode(m), on: c)
    }

    /// Fire-and-forget; dropped while disconnected.
    func send(_ m: Msg) {
        // Msg only holds strings, numbers and Data, so encoding cannot fail
        if state == .connected, let c = conn { c.send(content: FrameDecoder.frame(try! JSONEncoder().encode(m)), completion: .idempotent) }
    }

    func refreshHosts() {
        Task { hosts = (try? await request(["type": .string("hosts.list")]).hosts) ?? hosts }
    }

    private func upgrade(_ c: NWConnection, host: String) {
        let get = "GET /zurafa HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\nUpgrade: zurafa\r\n\r\n"
        c.send(content: Data(get.utf8), completion: .idempotent)
        receive(c)
    }

    /// After the 101, the stream carries the same frames as the Mac's Unix socket.
    private func handshake(_ c: NWConnection) {
        Task {
            do {
                let hello = try await call(JSONEncoder().encode(Msg(type: "hello", protocol: 2)), on: c)
                guard hello.type == "hello_ok", hello.protocol == 2 else { throw DaemonError("The Mac's Zurafa is too old; update it.") }
                let sub = try await call(JSONEncoder().encode(["type": JSONValue.string("events.subscribe_all"), "subscription": .string("phone")]), on: c)
                guard conn === c else { return }
                snapshot = sub.snapshot
                state = .connected
                generation += 1
                refreshHosts()
                registerPush()
                // An older Mac app never sends one; keep what we have.
                if let look = try? await request(["type": .string("ui.appearance")]).appearance { appearance = look }
            } catch {
                drop(c, reason: error.localizedDescription)
            }
        }
    }

    private func call(_ body: Data, on c: NWConnection) async throws -> Msg {
        guard conn === c else { throw DaemonError("Not connected to your Mac") }
        let id = nextID
        nextID += 1
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw DaemonError("invalid request") }
        object["id"] = id
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await withCheckedThrowingContinuation { k in
            pending[id] = k
            c.send(content: FrameDecoder.frame(data), completion: .idempotent)
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            MainActor.assumeIsolated {
                guard let self, self.conn === c else { return }
                do {
                    var bytes = data ?? Data()
                    if !self.upgraded {
                        self.head.append(bytes)
                        guard let end = self.head.range(of: Data("\r\n\r\n".utf8)) else {
                            if self.head.count > 8192 { throw DaemonError("Unexpected reply from the Mac") }
                            return done ? self.drop(c, reason: "The Mac closed the connection") : self.receive(c)
                        }
                        let status = String(decoding: self.head[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
                        guard status == "101" else { throw DaemonError(Self.explain(String(status))) }
                        bytes = self.head[end.upperBound...]
                        self.upgraded = true
                        self.handshake(c)
                    }
                    for f in try self.decoder.push(bytes) { self.dispatch(try JSONDecoder().decode(Msg.self, from: f)) }
                } catch {
                    return self.drop(c, reason: error.localizedDescription)
                }
                if done || err != nil { self.drop(c, reason: "Lost the connection to your Mac") } else { self.receive(c) }
            }
        }
    }

    private static func explain(_ status: String) -> String {
        switch status {
        case "403": "The Mac only lets in devices signed in to its own Tailscale account."
        default: "The Mac answered HTTP \(status) instead of Zurafa."
        }
    }

    private func dispatch(_ m: Msg) {
        if let id = m.id, let k = pending.removeValue(forKey: id) {
            m.type == "error" ? k.resume(throwing: DaemonError(m.message ?? "daemon error")) : k.resume(returning: m)
        } else if m.type == "output", let t = m.terminal, let data = m.data {
            onOutput(t, data, m.end)
        } else if m.type == "appearance" {
            if let look = m.appearance { appearance = look }
        } else if m.type == "events.event" {
            refresh()
        } else if m.type == "events.gap" {
            refresh(resync: true)
        }
    }

    /// shortcut: any event reloads the whole snapshot (coalesced); apply events one by one if the phone ever shows lag.
    private func refresh(resync: Bool = false) {
        guard !refreshing || resync else { return }
        refreshing = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            refreshing = false
            let body: [String: JSONValue] = resync ? ["type": .string("events.resync"), "subscription": .string("phone")] : ["type": .string("events.snapshot")]
            if let s = try? await request(body).snapshot { snapshot = s }
        }
    }

    private func drop(_ c: NWConnection?, reason: String?) {
        guard let c, conn === c else { return }
        conn = nil
        c.cancel()
        let p = pending
        pending = [:]
        p.values.forEach { $0.resume(throwing: DaemonError("Lost the connection to your Mac")) }
        state = reason.map(State.failed) ?? .idle
    }
}

extension MacClient {
    func registerPush() {
        guard let pushToken, state == .connected else { return }
        #if DEBUG
        let sandbox = true // Xcode builds get Apple's development push service
        #else
        let sandbox = false
        #endif
        // The vendor id names this phone, so a reinstall replaces its old token on the Mac.
        let name = UIDevice.current.identifierForVendor?.uuidString ?? ""
        Task { _ = try? await request(["type": .string("push.register"), "device": .object(["token": .string(pushToken), "sandbox": .bool(sandbox), "name": .string(name)])]) }
    }

    /// Answers a permission prompt from its notification, if the pane is still asking; as the Mac's banner does.
    func answerPermission(_ pane: String, approve: Bool) async {
        if state != .connected {
            if address.isEmpty, let saved = UserDefaults.standard.string(forKey: "macAddress"), !saved.isEmpty { connect(to: saved) } else { resume() }
        }
        for _ in 0..<40 where state != .connected { try? await Task.sleep(for: .milliseconds(250)) }
        let block = snapshot?.sessions.values.lazy.compactMap { $0.blocks[pane] }.first
        guard block?.statuses.records.values.contains(where: { $0.state == "blocked" && $0.kind == "permission" }) == true else {
            return openPane = pane
        }
        // Claude Code's prompt highlights "Yes" first; Escape declines.
        send(Msg(type: "input", terminal: pane, data: Data((approve ? "\r" : "\u{1b}").utf8)))
        try? await Task.sleep(for: .milliseconds(500)) // let the bytes leave before iOS suspends the app
    }

    var sessions: [SessionSnapshot] {
        (snapshot?.sessions.values).map { $0.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending } } ?? []
    }

    /// The Mac spawns it at 80×24; the terminal screen resizes it to the phone once open. Returns the new pane.
    func openTab(in session: SessionSnapshot) async throws -> String? {
        try await openTab(in: session.sessionID, label: session.remote == nil ? "Shell" : "SSH")
    }

    func openTab(in session: String, label: String) async throws -> String? {
        try await request(["type": .string("layout.tab"), "session": .string(session), "label": .string(label), "cols": .number(80), "rows": .number(24)]).terminal
    }

    func close(_ pane: String, in session: String) async throws {
        _ = try await request(["type": .string("layout.command"), "command": .object(["op": .string("close"), "session": .string(session), "block": .string(pane)])])
    }
}
