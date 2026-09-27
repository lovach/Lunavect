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
            if seconds > 0 { result.add(seconds: seconds, providers: span.providers, recovered: span.providers != 0 && span.providers & ~span.recoveredProviderMask == 0) }
        }
        return result
    }
}

public struct ActivityDetails: Codable, Equatable, Sendable {
    /// Stored size budget, below the 32,000,000 B read limit: older records are
    /// dropped first so a full file can always be read back.
    public static let maximumBytes = 24_000_000
    public private(set) var records: [String: ActivityDetailRecord] = [:]
    public init() {}
    public mutating func append(_ session: AgentSession, start: Date, end: Date, reconcilingClockCorrection: Bool = false) {
        guard start < end else { return }
        let incoming = ActivityDetailRecord(provider: session.provider, sessionID: session.sessionID,
                                           title: session.title, cwd: session.cwd)
        var record = records[incoming.id] ?? incoming
        // An observation without a title must not erase a name recorded earlier.
        if !incoming.title.isEmpty { record.title = incoming.title }
        let mask = session.provider == .claude ? 1 : 2
        if let last = record.intervals.last, last.end > start {
            // Same guard as ActivityHistory.append: an overlap without a clock
            // correction is ignored, never stored out of order.
            guard reconcilingClockCorrection else { return }
            record.intervals = ActivityHistory.union(record.intervals + [ActivityInterval(start: start, end: end, providers: mask, observedProviders: mask)])
        } else if let last = record.intervals.last, last.end == start, last.recovered != true {
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
        var bytes = 16
        for var record in recent.prefix(2000) where remaining > 0 {
            record.intervals = record.intervals.compactMap { span in
                guard span.end > cutoff, span.start < span.end else { return nil }
                var span = span; span.start = max(cutoff, span.start); return span
            }
            record.intervals = Array(record.intervals.suffix(remaining))
            guard !record.intervals.isEmpty else { continue }
            let size = Self.encodedUpperBound(record)
            guard bytes + size <= Self.maximumBytes else { break }
            bytes += size; remaining -= record.intervals.count
            records[record.id] = record
        }
    }
    /// A conservative JSONEncoder size: every escaped character (including "/")
    /// and every optional interval field is counted at its largest encoding.
    static func encodedUpperBound(_ record: ActivityDetailRecord) -> Int {
        func json(_ text: String) -> Int {
            text.unicodeScalars.reduce(2) { total, scalar in
                total + (scalar == "\"" || scalar == "\\" || scalar == "/" ? 2 : scalar.value < 0x20 ? 6 : String(scalar).utf8.count)
            }
        }
        let key = json(record.id), fields = json(record.provider.rawValue) + json(record.sessionID) + json(record.title) + json(record.cwd)
        return key + fields + 96 + record.intervals.count * 200
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
        let data = try LocalStateRecovery.read(from: url, maximumBytes: 32_000_000)
        var result = try JSONDecoder().decode(Self.self, from: data)
        guard result.records.count <= 2000, result.records.values.reduce(0, { $0 + $1.intervals.count }) <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
        for (key, record) in result.records {
            guard key == record.id, !record.sessionID.isEmpty, record.sessionID.count <= 128,
                  record.title.count <= 1000, record.cwd.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            var end = Date.distantPast, ordered = true
            for span in record.intervals {
                guard span.end > span.start, span.providers == (record.provider == .claude ? 1 : 2),
                      span.recoveredProviders.map({ (0...3).contains($0) && ($0 & span.providers) == $0 }) ?? true,
                      span.liveObservedProviders.map({ (0...3).contains($0) && ($0 & span.knownProviders) == $0 }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
                if span.start < end { ordered = false }
                end = max(end, span.end)
            }
            // Overlapping or unordered valid spans are repaired, not a reason to
            // move the whole project breakdown aside.
            if !ordered { result.records[key]?.intervals = ActivityHistory.union(record.intervals) }
        }
        return result
    }
    public func save(to url: URL = fileURL, synchronize: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: url, synchronize: synchronize)
    }
}
