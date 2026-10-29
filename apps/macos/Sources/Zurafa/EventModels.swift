import Foundation

/// Unknown event names and additional payload fields are retained as values, never fatal decoding errors.
indirect enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v.isFinite, v.rounded() == v { Int(exactly: v) } else { nil } }
}

struct ProgramStatus: Codable, Equatable {
    var state: String
    var kind: String?
    var progress: Int?
    var app: String?
    var title: String?
    var msg: String?
}

struct StatusRecords: Codable { var records: [String: ProgramStatus] }
struct RemoteHost: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var hostname: String
    var user: String?
    var port: Int

    var destination: String { user.map { "\($0)@\(hostname)" } ?? hostname }
    var addressLabel: String { port == 22 ? hostname : "\(hostname):\(port)" }
    // shortcut: matches macOS's default shared VM subnet only; store a flag if users change it.
    var isLocalVM: Bool { hostname.hasPrefix("192.168.64.") }
    var isKali: Bool { isLocalVM && "\(label) \(hostname)".localizedCaseInsensitiveContains("kali") }
    /// What a shell on this host shows as, before any program on it is detected.
    var shellProgram: Program { isKali ? .kali : isLocalVM ? .vm : .ssh }
    var wire: JSONValue {
        .object(["id": .string(id), "label": .string(label), "hostname": .string(hostname),
                 "user": user.map(JSONValue.string) ?? .null, "port": .number(Double(port))])
    }
}
struct BlockSnapshot: Codable {
    var blockID: String
    var running: Bool
    var exitCode: Int?
    var statuses: StatusRecords
    var title: String?
    var pwd: String?
    var foreground: ForegroundProcess?
    /// The pane whose agent spawned this one; absent from older daemons.
    var parent: String?
    /// Milliseconds since the Unix epoch.
    var started: Double?
    enum CodingKeys: String, CodingKey { case blockID = "block_id", running, exitCode = "exit_code", statuses, title, pwd, foreground, parent, started }
}
struct ForegroundProcess: Codable {
    var name: String
    var cwd: String
    var pid: UInt32
    var executable: String?
    var argv: [String]?
}
struct WindowSnapshot: Codable {
    var windowID: String
    var label: String
    var layout: Layout
    var selectedBlock: String
    var zoomedBlock: String?
    enum CodingKeys: String, CodingKey { case windowID = "window_id", label, layout, selectedBlock = "selected_block", zoomedBlock = "zoomed_block" }
}
struct SessionSnapshot: Codable {
    var sessionID: String
    var label: String
    var remote: RemoteHost?
    var revision: UInt64
    var activeWindow: String?
    var windows: [WindowSnapshot]
    var blocks: [String: BlockSnapshot]
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", label, remote, revision, activeWindow = "active_window", windows, blocks }
}
struct EventSnapshot: Codable {
    var protocolVersion: Int
    var instance: String
    var sequence: UInt64
    var sessions: [String: SessionSnapshot]
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", instance, sequence, sessions }
}
struct EventEnvelope: Codable {
    var protocolVersion: Int
    var instance: String
    var sequence: UInt64
    var timestamp: UInt64
    var category: String
    var sessionID: String?
    var blockID: String?
    var type: String?
    var name: String?
    var payload: JSONValue
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", instance, sequence, timestamp, category, sessionID = "session_id", blockID = "block_id", type, name, payload }
    var eventName: String { category == "terminal" ? "terminal.\(name ?? "")" : type ?? "" }
}

struct EventCursor {
    private(set) var instance: String?
    private(set) var sequence: UInt64 = 0

    mutating func establish(_ snapshot: EventSnapshot) {
        instance = snapshot.instance
        sequence = snapshot.sequence
    }

    mutating func accept(_ event: EventEnvelope) -> Bool {
        guard instance == event.instance, event.sequence == sequence + 1 else { return false }
        sequence = event.sequence
        return true
    }
}
