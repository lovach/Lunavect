import Foundation

/// Local ordering only; provider conversations are never modified.
public struct SessionArrangement: Codable, Equatable {
    public var order: [String] = []
    public var pinned: Set<String> = []
    public init() {}
    public func arranged(_ rows: [AgentSession]) -> [AgentSession] {
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return rows.enumerated().sorted { a, b in
            let ap = pinned.contains(a.element.id), bp = pinned.contains(b.element.id)
            if ap != bp { return ap }
            let ar = ranks[a.element.id] ?? Int.max, br = ranks[b.element.id] ?? Int.max
            return ar == br ? a.offset < b.offset : ar < br
        }.map(\.element)
    }
    public mutating func move(_ id: String, before target: String, after: Bool = false, visible: [String]) {
        guard id != target, visible.contains(id), visible.contains(target),
              pinned.contains(id) == pinned.contains(target) else { return }
        // Preserve hidden/filter-excluded IDs, while recording today's visible order.
        var next = order.filter { !visible.contains($0) }
        var moving = visible.filter { $0 != id }
        moving.insert(id, at: moving.firstIndex(of: target)! + (after ? 1 : 0))
        next.append(contentsOf: moving)
        order = next
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
