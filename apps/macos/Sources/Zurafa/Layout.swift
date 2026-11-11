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

/// Where a pane sits in its tab, and the side it slides in from when new (a split's second half).
struct PaneFrame: Equatable {
    let id: String
    let rect: CGRect
    let from: Axis?
}

/// A split's divider: its path in the tree, for resizing, and the box the split divides.
struct SplitHandle: Equatable {
    let path: [Int]
    let axis: Axis
    let ratio: Double
    let rect: CGRect
}

extension Layout {
    /// Every pane's frame in `rect`, divided by the split ratios: one flat list, so a pane keeps its
    /// identity (and animates) when splits form or close around it.
    func frames(in rect: CGRect, from: Axis? = nil) -> [PaneFrame] {
        switch self {
        case .pane(let id): [PaneFrame(id: id, rect: rect, from: from)]
        case .split(let axis, let ratio, let first, let second):
            first.frames(in: rect.halves(axis, ratio).0) + second.frames(in: rect.halves(axis, ratio).1, from: second.isPane ? axis : nil)
        }
    }

    func splits(in rect: CGRect, path: [Int] = []) -> [SplitHandle] {
        guard case .split(let axis, let ratio, let first, let second) = self else { return [] }
        let (a, b) = rect.halves(axis, ratio)
        return [SplitHandle(path: path, axis: axis, ratio: ratio, rect: rect)] + first.splits(in: a, path: path + [0]) + second.splits(in: b, path: path + [1])
    }

    private var isPane: Bool { if case .pane = self { true } else { false } }
}

private extension CGRect {
    func halves(_ axis: Axis, _ ratio: Double) -> (CGRect, CGRect) {
        axis == .horizontal ? divided(atDistance: width * ratio, from: .minXEdge) : divided(atDistance: height * ratio, from: .minYEdge)
    }
}
