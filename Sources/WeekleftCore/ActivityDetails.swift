import Foundation

/// Private app-only metadata. Never copied to the WidgetKit snapshot or diagnostics.
public struct ActivityDetailRecord: Codable, Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var intervals: [ActivityInterval]
    public var id: String { provider.rawValue + ":" + sessionID + ":" + cwd }
    public init(provider: ProviderID, sessionID: String, title: String = "", cwd: String = "", intervals: [ActivityInterval] = []) {
        self.provider = provider; self.sessionID = sessionID; self.title = title; self.cwd = cwd; self.intervals = intervals
    }
    public var displayTitle: String { title.isEmpty ? L("Название недоступно") : title }
    public var projectName: String { cwd.isEmpty ? L("Без проекта") : URL(fileURLWithPath: cwd).lastPathComponent }
    public func totals(in range: DateInterval) -> ActivityTotals {
        var result = ActivityTotals()
        for span in intervals {
            let seconds = min(range.end, span.end).timeIntervalSince(max(range.start, span.start))
            if seconds > 0 { result.add(seconds: seconds, providers: span.providers, recovered: span.recovered == true) }
        }
        return result
    }
}

public struct ActivityDetails: Codable, Equatable, Sendable {
    public private(set) var records: [String: ActivityDetailRecord] = [:]
    public init() {}
    public mutating func append(_ session: AgentSession, start: Date, end: Date) {
        guard start < end else { return }
        let incoming = ActivityDetailRecord(provider: session.provider, sessionID: session.sessionID,
                                           title: session.title, cwd: session.cwd)
        var record = records[incoming.id] ?? incoming
        record.title = incoming.title
        let mask = session.provider == .claude ? 1 : 2
        if let last = record.intervals.last, last.end == start, last.recovered != true {
            record.intervals[record.intervals.count - 1].end = end
        } else { record.intervals.append(ActivityInterval(start: start, end: end, providers: mask, observedProviders: mask)) }
        records[record.id] = record
    }
    public mutating func merge(_ incoming: [ActivityDetailRecord], now: Date) {
        for value in incoming {
            var record = records[value.id] ?? value
            record.intervals = ActivityHistory.union((records[value.id]?.intervals ?? []) + value.intervals)
            if record.title.isEmpty { record.title = value.title }
            records[record.id] = record
        }
        prune(now: now)
    }
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-35 * 86400)
        var remaining = 100_000
        let recent = records.values.sorted { ($0.intervals.last?.end ?? .distantPast) > ($1.intervals.last?.end ?? .distantPast) }
        records = [:]
        for var record in recent.prefix(2000) where remaining > 0 {
            record.intervals = record.intervals.compactMap { span in
                guard span.end > cutoff, span.start < span.end else { return nil }
                var span = span; span.start = max(cutoff, span.start); return span
            }
            record.intervals = Array(record.intervals.suffix(remaining)); remaining -= record.intervals.count
            if !record.intervals.isEmpty { records[record.id] = record }
        }
    }
    public func selected(in range: DateInterval, providers: [ProviderID]) -> [ActivityDetailRecord] {
        var ranked: [(record: ActivityDetailRecord, active: TimeInterval)] = []
        for record in records.values where providers.contains(record.provider) {
            let active = record.totals(in: range).active
            if active > 0 { ranked.append((record, active)) }
        }
        ranked.sort { lhs, rhs in lhs.active == rhs.active ? lhs.record.id < rhs.record.id : lhs.active > rhs.active }
        return ranked.map { $0.record }
    }
    public static func totals(for records: [ActivityDetailRecord], in range: DateInterval) -> ActivityTotals {
        ActivityDetailRecord(provider: .claude, sessionID: "aggregate", intervals: ActivityHistory.union(records.flatMap(\.intervals))).totals(in: range)
    }
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/activity-details.json")
    }
    public static func load(from url: URL = fileURL) throws -> ActivityDetails {
        guard FileManager.default.fileExists(atPath: url.path) else { return ActivityDetails() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.records.count <= 2000, result.records.values.reduce(0, { $0 + $1.intervals.count }) <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
        for (key, record) in result.records {
            guard key == record.id, !record.sessionID.isEmpty, record.sessionID.count <= 128,
                  record.title.count <= 1000, record.cwd.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            var end = Date.distantPast
            for span in record.intervals {
                guard span.start >= end, span.end > span.start, span.providers == (record.provider == .claude ? 1 : 2) else { throw CocoaError(.fileReadCorruptFile) }
                end = span.end
            }
        }
        return result
    }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SessionHooks.secureWrite(JSONEncoder().encode(self), to: url)
    }
}
