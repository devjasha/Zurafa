import Foundation

enum Axis: String, Codable { case horizontal, vertical }

/// A read-only rendering projection of the daemon's binary layout tree.
indirect enum Layout: Equatable, Codable {
    case pane(String)
    case split(axis: Axis, ratio: Double, first: Layout, second: Layout)

    private enum CodingKeys: String, CodingKey { case type, blockID = "block_id", axis, ratio, first, second }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "block": self = .pane(try c.decode(String.self, forKey: .blockID))
        case "split": self = .split(axis: try c.decode(Axis.self, forKey: .axis),
                                   ratio: try c.decode(Double.self, forKey: .ratio),
                                   first: try c.decode(Layout.self, forKey: .first),
                                   second: try c.decode(Layout.self, forKey: .second))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown layout node")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id):
            try c.encode("block", forKey: .type)
            try c.encode(id, forKey: .blockID)
        case .split(let axis, let ratio, let first, let second):
            try c.encode("split", forKey: .type)
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }

    var panes: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }
}
