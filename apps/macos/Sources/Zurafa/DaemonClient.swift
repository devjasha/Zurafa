import Combine
import Foundation
import Network

/// Every protocol message in one flat shape (docs/ipc-protocol.md); nil fields are left out on the wire.
struct Msg: Codable {
    var type: String
    var id: Int?
    var `protocol`: Int?
    var cols: Int?
    var rows: Int?
    var cwd: String?
    var command: [String]?
    var terminal: String?
    var data: Data? // base64, the default Data strategy of JSONEncoder and JSONDecoder
    var code: Int?
    var state: String?
    var message: String?
    var snapshot: EventSnapshot?
    var hosts: [RemoteHost]?
    var event: EventEnvelope?
    var subscription: String?
    var instance: String?
    var after_sequence: UInt64?
    var missed: UInt64?
    var end: UInt64? // output byte offset, so a replay and live output can be merged
    // hello_ok and server.status
    var stale: Bool?
    var pid: Int32?
    var started_at: Double?
    var listening: [String]?
    var tailscale_state: String?
    var tailscale_login: String?
    var tailscale_name: String?
}

struct DaemonError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// Splits a byte stream into frames: 4-byte big-endian length, then the body.
struct FrameDecoder {
    static let max = 16 << 20
    private var buf = Data()

    static func frame(_ body: Data) -> Data {
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + body
    }

    /// Appends bytes and returns every frame body they complete.
    mutating func push(_ bytes: Data) throws -> [Data] {
        buf.append(bytes)
        var out: [Data] = []
        while buf.count >= 4 {
            let n = buf.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard n <= Self.max else { throw DaemonError("frame too large") }
            guard buf.count >= 4 + n else { break }
            out.append(Data(buf.dropFirst(4).prefix(n)))
            buf = Data(buf.dropFirst(4 + n))
        }
        return out
    }
}

/// The app's single connection to zurafa-daemon. All state lives on the main actor.
@MainActor final class DaemonClient: ObservableObject {
    static let shared = DaemonClient()
    static let socket = ProcessInfo.processInfo.environment["ZURAFA_SOCKET"]
        ?? NSHomeDirectory() + "/Library/Application Support/\(applicationSupportName)/daemon.sock"

    private static var applicationSupportName: String {
        Bundle.main.object(forInfoDictionaryKey: "ZURAFAApplicationSupportName") as? String ?? "Zurafa"
    }

    /// True when the daemon is unreachable; the top bar shows a Reconnect banner.
    @Published private(set) var down = false
    /// The daemon runs older code than this app: an update replaced it on disk, or it predates
    /// the `stale` field. It keeps running until it is restarted.
    @Published private(set) var stale = false
    var onDisconnect: () -> Void = {}
    var onSnapshot: (EventSnapshot) -> Void = { _ in }
    var onEvent: (EventEnvelope) -> Void = { _ in }
    var onOutput: (String, Data, UInt64?) -> Void = { _, _, _ in }

    private var conn: NWConnection?
    private var live = false // hello_ok received on `conn`
    private var decoder = FrameDecoder()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Msg, Error>] = [:]
    private var ready: Task<Void, Error>?
    private var cursor = EventCursor()
    private var resyncing = false

    /// Connects, launching the daemon if nobody answers. Also the Reconnect action.
    func start() {
        if ready != nil && !down { return }
        down = false
        ready = Task {
            do {
                if (try? await connect()) != nil { return }
                try launch()
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(100))
                    if (try? await connect()) != nil { return }
                }
                throw DaemonError("zurafa-daemon did not answer at \(Self.socket)")
            } catch {
                down = true
                throw error
            }
        }
    }

    func request(_ m: Msg) async throws -> Msg {
        try await ready?.value
        guard live, let c = conn else { throw DaemonError("daemon not connected") }
        return try await call(m, on: c)
    }

    func request(_ object: [String: JSONValue]) async throws -> Msg {
        try await ready?.value
        guard live, let c = conn else { throw DaemonError("daemon not connected") }
        return try await call(try JSONEncoder().encode(object), on: c)
    }

    func snapshot() async throws -> EventSnapshot {
        guard let s = try await request(["type": .string("events.snapshot")]).snapshot else {
            throw DaemonError("snapshot reply missing state")
        }
        return s
    }

    /// Fire-and-forget; dropped while disconnected.
    func send(_ m: Msg) {
        if live, let c = conn { write(m, on: c) }
    }

    private func connect() async throws {
        let c = NWConnection(to: .unix(path: Self.socket), using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] s in
            MainActor.assumeIsolated {
                switch s {
                case .waiting, .failed, .cancelled: self?.drop(c)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(c)
        let hello = try await call(Msg(type: "hello", protocol: 2), on: c)
        guard hello.type == "hello_ok", hello.protocol == 2 else { throw DaemonError("daemon requires protocol 2") }
        stale = hello.stale ?? true
        guard let snapshot = try await call(try JSONEncoder().encode(["type": JSONValue.string("events.subscribe_all"), "subscription": .string("app")]), on: c).snapshot else {
            throw DaemonError("subscription reply missing snapshot")
        }
        accept(snapshot)
        live = true
        down = false
    }

    private func call(_ m: Msg, on c: NWConnection) async throws -> Msg {
        try await call(JSONEncoder().encode(m), on: c)
    }

    private func call(_ body: Data, on c: NWConnection) async throws -> Msg {
        guard conn === c else { throw DaemonError("daemon not connected") }
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

    private func write(_ m: Msg, on c: NWConnection) {
        // Msg only holds strings, numbers and Data, so encoding cannot fail
        c.send(content: FrameDecoder.frame(try! JSONEncoder().encode(m)), completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            MainActor.assumeIsolated {
                guard let self, self.conn === c else { return }
                do {
                    for f in try self.decoder.push(data ?? Data()) { self.dispatch(try JSONDecoder().decode(Msg.self, from: f)) }
                } catch {
                    return self.drop(c)
                }
                if done || err != nil { self.drop(c) } else { self.receive(c) }
            }
        }
    }

    private func dispatch(_ m: Msg) {
        if let id = m.id, let k = pending.removeValue(forKey: id) {
            m.type == "error" ? k.resume(throwing: DaemonError(m.message ?? "daemon error")) : k.resume(returning: m)
        } else if m.type == "output", let t = m.terminal, let data = m.data {
            onOutput(t, data, m.end)
        } else if m.type == "events.event", let event = m.event {
            if !cursor.accept(event) { return resync() }
            onEvent(event)
        } else if m.type == "events.gap" || m.type == "output.gap" {
            resync()
        }
    }

    private func accept(_ snapshot: EventSnapshot) {
        cursor.establish(snapshot)
        onSnapshot(snapshot)
    }

    private func resync() {
        guard !resyncing, live else { return }
        resyncing = true
        Task {
            defer { resyncing = false }
            do {
                guard let snapshot = try await request(["type": .string("events.resync"), "subscription": .string("app")]).snapshot else {
                    throw DaemonError("resync reply missing snapshot")
                }
                accept(snapshot)
            } catch { down = true; conn?.cancel() }
        }
    }

    private func drop(_ c: NWConnection) {
        guard conn === c else { return }
        let wasLive = live
        (conn, live, decoder) = (nil, false, FrameDecoder())
        c.cancel()
        let p = pending
        pending = [:]
        p.values.forEach { $0.resume(throwing: DaemonError("daemon disconnected")) }
        if wasLive {
            down = true
            onDisconnect()
            ready = nil
            start()
        }
    }

    /// Starts the daemon in its own session so it outlives the app (and a Ctrl-C in `swift run`).
    private func launch() throws {
        let path = ProcessInfo.processInfo.environment["ZURAFA_DAEMON"]
            ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("zurafa-daemon").path
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let argv = [path, "--socket", Self.socket].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        let r = posix_spawn(&pid, path, &files, &attr, argv, environ)
        guard r == 0 else { throw DaemonError("cannot launch \(path): \(String(cString: strerror(r)))") }
        DispatchQueue.global().async { waitpid(pid, nil, 0) } // reap it if it dies while the app runs
    }
}
