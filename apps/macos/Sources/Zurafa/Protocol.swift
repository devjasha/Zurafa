import Foundation

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
    var since: UInt64? // attach: only the output after this offset
    var gap: Bool? // attach: `since` was no longer buffered, so `data` is the whole buffer
    // hello_ok and server.status
    var stale: Bool?
    var pid: Int32?
    var started_at: Double?
    var listening: [String]?
    var tailscale_state: String?
    var tailscale_login: String?
    var tailscale_name: String?
    var appearance: MacAppearance? // ui.appearance and its broadcast
    var devices: [PushDevice]? // push.list
    var path: String? // ui.paste_image: where the Mac saved the phone's image
}

/// A phone that wants agent notifications, registered with `push.register`.
struct PushDevice: Codable {
    var token: String // APNs device token, hex
    var sandbox: Bool // development builds go through Apple's sandbox
    var name: String
}

/// The Mac's look with its theme resolved for both appearances, so the phone draws exactly what the Mac draws.
struct MacAppearance: Codable, Equatable {
    struct Colors: Codable, Equatable {
        var background: UInt32
        var foreground: UInt32
        var accent: UInt32
        var cursor: UInt32
        var selection: UInt32?
        var palette: [UInt32] // the 16 ANSI colors
    }
    var mode: String // system, light or dark
    var light: Colors
    var dark: Colors
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
