import Foundation
import CoreGraphics

/// Only Lunavect's list preference. Never mutates provider sessions or transcripts.
public struct SessionVisibility {
    public static let retention: TimeInterval = 35 * 86400
    private struct HiddenSession: Codable {
        var hiddenAt: Date
        var phase: SessionPhase?
        var eventAt: Date?
        var turnStartedAt: Date?
        var title: String?
        var project: String?
        var removed: Bool?
        var removedAt: Date?
        /// Last coarse observation in which a source still listed the session.
        var seenAt: Date?
    }
    private struct Saved: Codable { var sessions: [String: HiddenSession] }
    private var records: [String: HiddenSession]
    public var hidden: Set<String> { Set(records.filter { $0.value.removed != true }.keys) }
    public struct Summary: Identifiable, Equatable {
        public let id: String
        public let title: String?
        public let project: String?
        public let hiddenAt: Date
        public var provider: ProviderID? { ProviderID(rawValue: String(id.split(separator: ":").first ?? "")) }
    }
    public var summaries: [Summary] {
        records.filter { $0.value.removed != true }.map { id, record in
            Summary(id: id, title: id.hasPrefix("codex:") ? SessionParser.codexTitle(record.title) : record.title,
                    project: record.project, hiddenAt: record.hiddenAt)
        }.sorted { $0.hiddenAt == $1.hiddenAt ? $0.id < $1.id : $0.hiddenAt > $1.hiddenAt }
    }
    public mutating func updateTitles(_ titles: [String: String]) throws {
        var next = records
        var changed = false
        for (id, title) in titles where !title.isEmpty && next[id] != nil && next[id]?.removed != true {
            if next[id]?.title != title { next[id]?.title = title; changed = true }
        }
        if changed { try save(next) }
    }
    /// Drop displayed history, retaining only the cutoff needed to prevent reimport.
    /// A genuinely new task removes this cutoff through restoreNewTasks.
    public mutating func removeHidden(_ ids: Set<String>, now: Date = Date()) throws {
        var next = records
        for id in ids where next[id] != nil {
            next[id]?.removed = true; next[id]?.removedAt = now; next[id]?.title = nil; next[id]?.project = nil
        }
        try save(next)
    }
    /// Repair hidden entries produced by old builds from lifecycle-only launches.
    /// Keep removal cutoffs, so a subsequent real task can still restore the ID.
    public mutating func removeUnstartedClaudeLifecycles(_ sessions: [AgentSession]) throws {
        let ids = Set(sessions.filter {
            $0.isUnstartedClaudeLifecycle
        }.map(\.id)).intersection(hidden)
        if !ids.isEmpty { try removeHidden(ids) }
    }
    private let url: URL
    public init(url: URL, now: Date = Date()) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { records = [:]; return }
        let data = try Data(contentsOf: url)
        if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = saved.sessions
        } else {
            // Older builds stored only IDs. The file's last write is a conservative
            // cutoff: never treat an old running event as a new task after migration.
            let ids = try JSONDecoder().decode(Set<String>.self, from: data)
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
            records = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, HiddenSession(hiddenAt: modified))
            })
        }
        try pruneRemoved(now: now)
    }
    @discardableResult public mutating func pruneRemoved(now: Date = Date()) throws -> Int {
        let kept = records.filter { _, record in
            record.removed != true || now.timeIntervalSince(record.removedAt ?? record.hiddenAt) <= Self.retention
        }
        let removed = records.count - kept.count
        if removed > 0 { try save(kept) }
        return removed
    }
    /// Call on a coarse cadence with every row the sources still report. A hidden
    /// session stays hidden while it is listed. Only a record of a completely
    /// observed provider that has not been listed, hidden or active for
    /// `retention` expires, so auto-hide cannot grow the list without bound and a
    /// partial or disabled source never releases a session that may still exist.
    @discardableResult public mutating func observe(_ ids: Set<String>, completeProviders: Set<ProviderID>, now: Date = Date()) throws -> Int {
        var next = records, expired = 0, changed = false
        for (id, record) in records where record.removed != true {
            if ids.contains(id) {
                if record.seenAt != now { next[id]?.seenAt = now; changed = true }
            } else if let provider = ProviderID(rawValue: String(id.split(separator: ":").first ?? "")),
                      completeProviders.contains(provider) {
                let last = max(record.hiddenAt, record.eventAt ?? .distantPast, record.seenAt ?? .distantPast)
                if now.timeIntervalSince(last) > Self.retention { next.removeValue(forKey: id); expired += 1; changed = true }
            }
        }
        if changed { try save(next) }
        return expired
    }
    public mutating func hide(_ session: AgentSession, now: Date = Date()) throws {
        var next = records
        next[session.id] = HiddenSession(hiddenAt: now, phase: session.phase,
                                        eventAt: session.observedAt, turnStartedAt: session.turnStartedAt,
                                        title: session.title, project: session.cwd.isEmpty ? nil : session.project)
        try save(next)
    }
    public mutating func setHidden(_ id: String, _ value: Bool) throws {
        var next = records
        if value { next[id] = HiddenSession(hiddenAt: Date()) } else { next.removeValue(forKey: id) }
        try save(next)
    }
    /// A new task cancels hiding. Polls and tool events from the same task do not.
    @discardableResult public mutating func restoreNewTasks(_ sessions: [AgentSession], now: Date = Date()) throws -> Set<String> {
        var next = records
        var restored: Set<String> = []
        var changed = false
        for row in sessions {
            guard var record = next[row.id], row.evidence != .catalog, row.isCurrent(now: now),
                  row.observedAt > record.hiddenAt,
                  row.observedAt >= (record.eventAt ?? .distantPast) else { continue }
            let newTurn = row.turnStartedAt.map {
                $0 > record.hiddenAt && $0 > (record.turnStartedAt ?? .distantPast)
            } ?? false
            // Older event sources may lack a turn timestamp. Require an observed
            // inactive -> active transition with a real new event, never catalog polling.
            let newActivity = row.turnStartedAt == nil && row.evidence != .catalog &&
                row.phase.isActive && record.phase.map { !$0.isActive && $0 != .unknown } == true &&
                row.updatedAt > record.hiddenAt && row.observedAt > (record.eventAt ?? .distantPast)
            if newTurn || newActivity {
                next.removeValue(forKey: row.id); restored.insert(row.id); changed = true
            } else if record.phase != row.phase {
                record.phase = row.phase; record.eventAt = row.observedAt
                next[row.id] = record; changed = true
            }
        }
        if changed { try save(next) }
        return restored
    }
    public mutating func restoreAll() throws { try save([:]) }
    private mutating func save(_ next: [String: HiddenSession]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionHooks.secureWrite(JSONEncoder().encode(Saved(sessions: next)), to: url)
        records = next
    }
    public func visible(_ sessions: [AgentSession]) -> [AgentSession] { sessions.filter { records[$0.id] == nil } }
}

/// One action on finger lift, never on momentum. Vertical scroll locks out row actions.
public struct SessionSwipe {
    public enum Action { case open, hide }
    public private(set) var offset = 0.0
    public private(set) var horizontal = false
    private var vertical = false
    private var x = 0.0
    private var y = 0.0
    public init() {}
    public static func target(at point: CGPoint, regions: [String: CGRect], viewport: CGRect) -> String? {
        guard viewport.contains(point) else { return nil }
        return regions.first(where: { $0.value.contains(point) })?.key
    }
    public mutating func update(dx: Double, dy: Double) {
        guard !vertical else { return }
        x += dx; y += dy
        if !horizontal {
            if abs(y) > 8 && abs(y) >= abs(x) { vertical = true; return }
            if abs(x) > 8 && abs(x) > abs(y) * 1.5 { horizontal = true }
        }
        if horizontal {
            // Continuous rubber-band resistance, without a hard stop at 100 pt.
            let distance = abs(x)
            let softened = distance <= 64 ? distance : 64 + 40 * (1 - exp(-(distance - 64) / 80))
            offset = x < 0 ? -softened : softened
        }
    }
    public mutating func finish(cancelled: Bool = false) -> Action? {
        defer { self = Self() }
        guard !cancelled, horizontal, abs(offset) >= 64 else { return nil }
        return offset > 0 ? .open : .hide
    }
}

public enum SessionVisibilityError: LocalizedError, Equatable {
    case unreadable
    public var errorDescription: String? {
        L("Не удалось прочитать список скрытых сессий. Проверьте доступ к файлу и повторите действие.")
    }
}
