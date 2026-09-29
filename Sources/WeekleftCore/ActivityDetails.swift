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
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: url, synchronize: synchronize)
    }
}

/// One source of one day (Claude, Codex, or both together as wall time).
public struct ActivityDayPart: Codable, Equatable, Sendable {
    public var active: TimeInterval = 0
    /// The part of `active` recovered from client logs (shown with ≈).
    public var recovered: TimeInterval = 0
    /// `active` by local hour of day.
    public var hours: [TimeInterval] = Array(repeating: 0, count: 24)
    /// Work time per project folder name.
    public var projects: [String: TimeInterval] = [:]
    /// Time sessions waited for the user, observed live only.
    public var waitingInput: TimeInterval = 0
    public var waitingPermission: TimeInterval = 0
    /// Waits that ended that day, in seconds, for the typical wait.
    public var waits: [TimeInterval] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case active, recovered, hours, projects, waitingInput, waitingPermission, waits }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        active = try values.decodeIfPresent(TimeInterval.self, forKey: .active) ?? 0
        recovered = try values.decodeIfPresent(TimeInterval.self, forKey: .recovered) ?? 0
        let hours = try values.decodeIfPresent([TimeInterval].self, forKey: .hours) ?? []
        self.hours = hours.count == 24 ? hours : Array(repeating: 0, count: 24)
        projects = try values.decodeIfPresent([String: TimeInterval].self, forKey: .projects) ?? [:]
        waitingInput = try values.decodeIfPresent(TimeInterval.self, forKey: .waitingInput) ?? 0
        waitingPermission = try values.decodeIfPresent(TimeInterval.self, forKey: .waitingPermission) ?? 0
        waits = try values.decodeIfPresent([TimeInterval].self, forKey: .waits) ?? []
    }
    /// Whole seconds keep the file small; nothing shown is finer than a minute.
    mutating func add(_ seconds: TimeInterval, hour: Int, recovered: Bool) {
        active += seconds; hours[hour] += seconds
        if recovered { self.recovered += seconds }
    }
    mutating func round() {
        active = active.rounded(); recovered = min(active, recovered.rounded())
        hours = hours.map { $0.rounded() }; projects = projects.mapValues { $0.rounded() }.filter { $0.value > 0 }
    }
}

/// A session's work on one day and the project it belongs to.
public struct ActivityDaySession: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var seconds: TimeInterval
    public var project: String
    public init(provider: ProviderID, seconds: TimeInterval, project: String) {
        self.provider = provider; self.seconds = seconds; self.project = project
    }
}

/// One local calendar day of agent work.
public struct ActivityDayRecord: Codable, Equatable, Sendable {
    /// "claude", "codex" and "all" (wall time with any agent at work).
    public var parts: [String: ActivityDayPart] = [:]
    /// Keyed by provider and session identifier.
    public var sessions: [String: ActivityDaySession] = [:]
    public init() {}
    public static let allKey = "all"
    public func part(_ providers: [ProviderID]) -> ActivityDayPart? {
        providers.count == 1 ? parts[providers[0].rawValue] : parts[Self.allKey]
    }
    var isEmpty: Bool { (parts[Self.allKey]?.active ?? 0) <= 0 && sessions.isEmpty && !hasWaiting }
    var hasWaiting: Bool { parts.values.contains { $0.waitingInput > 0 || $0.waitingPermission > 0 || !$0.waits.isEmpty } }
}

/// Daily totals kept after the 35-day history and session details are pruned, so
/// Year and All time stay available (owner request 29.09). Days inside the history
/// window are recomputed from it; older days are frozen. Waiting is observed live
/// and kept across recomputation. Roughly 1 KB a day.
public struct ActivityArchive: Codable, Equatable, Sendable {
    /// Keyed by the local calendar day, "yyyy-MM-dd".
    public var days: [String: ActivityDayRecord] = [:]
    /// Set once client logs older than the history window have been read.
    public var backfillVersion: Int?
    public static let currentBackfillVersion = 1
    /// Days this recent are recomputed from the history; the day at its cutoff is partial.
    public static let historyDays = 34
    public init() {}

    public static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Recomputes the last `recentDays` days from the history (by default every day it still covers);
    /// waiting observed live is kept. Live updates pass 2: only today and a span across midnight change.
    public mutating func refresh(history: ActivityHistory, details: ActivityDetails, now: Date, recentDays: Int = historyDays,
                                 calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -min(recentDays, Self.historyDays), to: today) else { return }
        let computed = Self.records(intervals: history.intervals, details: Array(details.records.values), from: first, to: now, calendar: calendar)
        var day = first
        while day <= today {
            let key = Self.key(day, calendar: calendar)
            var record = computed[key] ?? ActivityDayRecord()
            if let previous = days[key] { record.keepWaiting(from: previous) }
            if record.isEmpty { days.removeValue(forKey: key) } else { days[key] = record }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    /// Days older than the history window from client logs; a day already kept is never replaced.
    public mutating func fill(from result: ActivityImportResult, before boundary: Date, calendar: Calendar = .current) {
        guard let start = result.intervals.map(\.start).min(), start < boundary else { return }
        let computed = Self.records(intervals: result.intervals.map { var span = $0; span.recovered = true; span.recoveredProviders = span.providers; return span },
                                    details: result.details, from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: boundary), calendar: calendar)
        for (key, record) in computed where days[key] == nil && !record.isEmpty { days[key] = record }
    }

    /// Adds live waiting of one provider's session (answers or permissions).
    public mutating func addWaiting(_ provider: ProviderID, permission: Bool, seconds: TimeInterval, at date: Date, calendar: Calendar = .current) {
        guard seconds > 0, seconds.isFinite else { return }
        let key = Self.key(date, calendar: calendar)
        var record = days[key] ?? ActivityDayRecord()
        for name in [provider.rawValue, ActivityDayRecord.allKey] {
            var part = record.parts[name] ?? ActivityDayPart()
            if permission { part.waitingPermission += seconds } else { part.waitingInput += seconds }
            record.parts[name] = part
        }
        days[key] = record
    }
    /// A finished wait, for the typical wait of a period.
    public mutating func addWait(_ provider: ProviderID, seconds: TimeInterval, endedAt date: Date, calendar: Calendar = .current) {
        guard seconds >= 5, seconds.isFinite else { return }
        let key = Self.key(date, calendar: calendar)
        var record = days[key] ?? ActivityDayRecord()
        for name in [provider.rawValue, ActivityDayRecord.allKey] {
            var part = record.parts[name] ?? ActivityDayPart()
            if part.waits.count < 500 { part.waits.append(seconds.rounded()) }
            record.parts[name] = part
        }
        days[key] = record
    }

    /// Per-day records from intervals (history or recovered) and per-session details.
    static func records(intervals: [ActivityInterval], details: [ActivityDetailRecord], from start: Date, to end: Date,
                        calendar: Calendar) -> [String: ActivityDayRecord] {
        var result: [String: ActivityDayRecord] = [:]
        func split(_ span: ActivityInterval, _ body: (String, Int, TimeInterval) -> Void) {
            var cursor = max(start, span.start)
            let stop = min(end, span.end)
            while cursor < stop {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { return }
                let boundary = min(stop, hour.end)
                guard boundary > cursor else { return }
                body(key(cursor, calendar: calendar), calendar.component(.hour, from: cursor), boundary.timeIntervalSince(cursor))
                cursor = boundary
            }
        }
        // Only spans that reach the window; days are updated in place, not copied per hour.
        let inWindow = { (span: ActivityInterval) in span.providers != 0 && span.end > start && span.start < end }
        for span in intervals where inWindow(span) {
            let recovered = span.providers & ~span.recoveredProviderMask == 0
            split(span) { day, hour, seconds in
                for (name, bit) in [(ActivityDayRecord.allKey, 3), (ProviderID.claude.rawValue, 1), (ProviderID.codex.rawValue, 2)] where span.providers & bit != 0 {
                    let partRecovered = name == ActivityDayRecord.allKey ? recovered : span.recoveredProviderMask & bit != 0
                    result[day, default: ActivityDayRecord()].parts[name, default: ActivityDayPart()].add(seconds, hour: hour, recovered: partRecovered)
                }
            }
        }
        // Projects: parallel sessions of one project count once, per source and together.
        var projectSpans: [String: [String: [ActivityInterval]]] = [:]
        for record in details {
            let spans = record.intervals.filter(inWindow)
            guard !spans.isEmpty else { continue }
            let project = record.projectName
            projectSpans[record.provider.rawValue, default: [:]][project, default: []] += spans
            projectSpans[ActivityDayRecord.allKey, default: [:]][project, default: []] += spans
            let sessionKey = record.provider.rawValue + ":" + record.sessionID
            for span in spans {
                split(span) { day, _, seconds in
                    result[day, default: ActivityDayRecord()].sessions[sessionKey, default: ActivityDaySession(provider: record.provider, seconds: 0, project: project)].seconds += seconds
                }
            }
        }
        for (name, projects) in projectSpans {
            for (project, spans) in projects {
                for span in ActivityHistory.union(spans) where span.providers != 0 {
                    split(span) { day, _, seconds in
                        result[day, default: ActivityDayRecord()].parts[name, default: ActivityDayPart()].projects[project, default: 0] += seconds
                    }
                }
            }
        }
        for key in result.keys {
            for name in result[key]!.parts.keys { result[key]!.parts[name]!.round() }
            result[key]!.sessions = result[key]!.sessions.mapValues { var value = $0; value.seconds = value.seconds.rounded(); return value }
                .filter { $0.value.seconds > 0 }
        }
        return result
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/activity-archive.json")
    }
    public static func load(from url: URL = fileURL) throws -> ActivityArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return ActivityArchive() }
        let data = try LocalStateRecovery.read(from: url, maximumBytes: 32_000_000)
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.days.count <= 36_600, archive.days.keys.allSatisfy({ $0.count == 10 }) else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }
    public func save(to url: URL = fileURL, synchronize: Bool = false) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: url, synchronize: synchronize)
    }
}

private extension ActivityDayRecord {
    mutating func keepWaiting(from previous: ActivityDayRecord) {
        for (name, old) in previous.parts where old.waitingInput > 0 || old.waitingPermission > 0 || !old.waits.isEmpty {
            var part = parts[name] ?? ActivityDayPart()
            part.waitingInput = old.waitingInput; part.waitingPermission = old.waitingPermission; part.waits = old.waits
            parts[name] = part
        }
    }
}

/// The statistics ranges of Settings. Day, week and month keep their detailed
/// history charts; year and all time are built from the daily archive.
public enum StatisticsRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, year, all
    public var id: String { rawValue }
    public var period: ActivityPeriod? {
        switch self { case .day: return .day; case .week: return .week; case .month: return .month; case .year, .all: return nil }
    }
    public var title: String {
        switch self {
        case .day: return L("День"); case .week: return L("Неделя"); case .month: return L("Месяц")
        case .year: return L("Год"); case .all: return L("Всё время")
        }
    }
}

/// What one chart point adds up.
public enum StatisticsBucket: Sendable, Equatable { case day, week, month }

/// Everything the statistics cards show for one range and source, from the daily archive.
public struct ActivityArchiveSummary: Sendable {
    public struct Point: Sendable, Equatable {
        public var start: Date
        public var claude: TimeInterval = 0, codex: TimeInterval = 0, together: TimeInterval = 0
        public var recovered = false
        /// False for a point before the first recorded day: unknown, not zero.
        public var known = true
    }
    public struct Project: Sendable, Equatable { public var name: String; public var seconds: TimeInterval }
    public var range: DateInterval
    public var bucket: StatisticsBucket
    public var points: [Point] = []
    public var claude: TimeInterval = 0, codex: TimeInterval = 0, together: TimeInterval = 0
    public var recovered = false
    /// The first day with any record for this source.
    public var firstDay: Date?
    /// Per provider: its line starts there; earlier values are unknown, not zero.
    public var firstDays: [ProviderID: Date] = [:]
    public var peakHour: Int?
    /// The busiest week for a year, month for all time, day otherwise.
    public var busiest: Point?
    /// Seconds by weekday (0 = the calendar's first weekday) and hour.
    public var weekdayHours: [[TimeInterval]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var projects: [Project] = []
    public var waitingInput: TimeInterval = 0, waitingPermission: TimeInterval = 0
    public var typicalWait: TimeInterval?
    public var sessions = 0
    public var averageSession: TimeInterval?
    public var longestSession: (seconds: TimeInterval, project: String)?
    public var hasWork: Bool { together > 0 }
    public var waiting: TimeInterval { waitingInput + waitingPermission }

    public static func make(_ archive: ActivityArchive, range kind: StatisticsRange, providers: [ProviderID], now: Date,
                            calendar: Calendar = .current) -> ActivityArchiveSummary {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let dated = archive.days.compactMap { key, record in ActivityArchive.date(key, calendar: calendar).map { ($0, record) } }
            .filter { $0.1.part(providers).map { $0.active > 0 } ?? false }
        let firstDay = dated.map(\.0).min()
        var firstDays: [ProviderID: Date] = [:]
        for provider in providers {
            firstDays[provider] = archive.days.compactMap { key, record in
                (record.parts[provider.rawValue]?.active ?? 0) > 0 ? ActivityArchive.date(key, calendar: calendar) : nil
            }.min()
        }
        let span: Int
        switch kind {
        case .day: span = 1
        case .week: span = 7
        case .month: span = 30
        case .year: span = 365
        case .all: span = max(1, (calendar.dateComponents([.day], from: firstDay ?? today, to: today).day ?? 0) + 1)
        }
        let start = calendar.date(byAdding: .day, value: -(span - 1), to: today) ?? today
        let bucket: StatisticsBucket = kind == .year ? .week : kind == .all ? (span < 62 ? .day : span < 366 ? .week : .month) : .day
        var result = ActivityArchiveSummary(range: DateInterval(start: start, end: tomorrow), bucket: bucket)
        result.firstDay = firstDay; result.firstDays = firstDays
        func bucketStart(_ date: Date) -> Date {
            switch bucket {
            case .day: return calendar.startOfDay(for: date)
            case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            case .month: return calendar.dateInterval(of: .month, for: date)?.start ?? date
            }
        }
        // Every bucket of the range, so a quiet week is zero and time before the first record is unknown.
        var cursor = bucketStart(start), index: [Date: Int] = [:]
        while cursor < tomorrow {
            let known = firstDay.map { bucketEnd(cursor) > $0 } ?? false
            index[cursor] = result.points.count
            result.points.append(Point(start: cursor, known: known))
            guard let next = advance(cursor) else { break }
            cursor = next
        }
        func advance(_ date: Date) -> Date? {
            switch bucket {
            case .day: return calendar.date(byAdding: .day, value: 1, to: date)
            case .week: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
            case .month: return calendar.date(byAdding: .month, value: 1, to: date)
            }
        }
        func bucketEnd(_ date: Date) -> Date { advance(date) ?? date }
        var hours = Array(repeating: TimeInterval(0), count: 24)
        var sessions: [String: (seconds: TimeInterval, project: String)] = [:]
        var waits: [TimeInterval] = []
        var projects: [String: TimeInterval] = [:]
        for (day, record) in archive.days.compactMap({ key, value in ActivityArchive.date(key, calendar: calendar).map { ($0, value) } })
            where day >= start && day < tomorrow {
            guard let part = record.part(providers) else { continue }
            let claude = record.parts[ProviderID.claude.rawValue]?.active ?? 0, codex = record.parts[ProviderID.codex.rawValue]?.active ?? 0
            let selectedClaude = providers.contains(.claude) ? claude : 0, selectedCodex = providers.contains(.codex) ? codex : 0
            result.claude += selectedClaude; result.codex += selectedCodex; result.together += part.active
            if part.recovered > 0 { result.recovered = true }
            if let i = index[bucketStart(day)] {
                result.points[i].claude += selectedClaude; result.points[i].codex += selectedCodex; result.points[i].together += part.active
                if part.recovered > 0 { result.points[i].recovered = true }
                result.points[i].known = true
            }
            let weekday = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
            for hour in 0..<24 { hours[hour] += part.hours[hour]; result.weekdayHours[weekday][hour] += part.hours[hour] }
            for (name, seconds) in part.projects { projects[name, default: 0] += seconds }
            result.waitingInput += part.waitingInput; result.waitingPermission += part.waitingPermission
            waits += part.waits
            for (key, session) in record.sessions where providers.contains(session.provider) {
                sessions[key, default: (0, session.project)].seconds += session.seconds
            }
        }
        if let maximum = hours.max(), maximum > 0 { result.peakHour = hours.firstIndex(of: maximum) }
        result.busiest = result.points.filter { $0.together > 0 }.max { $0.together < $1.together }
        result.projects = projects.map { Project(name: $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
        let lengths = sessions.values.filter { $0.seconds >= 60 }
        result.sessions = lengths.count
        if !lengths.isEmpty {
            result.averageSession = lengths.reduce(0) { $0 + $1.seconds } / Double(lengths.count)
            if let longest = lengths.max(by: { $0.seconds < $1.seconds }) { result.longestSession = (longest.seconds, longest.project) }
        }
        if !waits.isEmpty { let sorted = waits.sorted(); result.typicalWait = sorted[sorted.count / 2] }
        return result
    }

    /// Up to the last 53 weeks as calendar cells, oldest first, aligned to the calendar's week.
    /// With `since`, weeks that end before that day are left out: they hold no records.
    public static func calendarCells(_ archive: ActivityArchive, providers: [ProviderID], now: Date, since: Date? = nil,
                                     calendar: Calendar = .current) -> [(date: Date, seconds: TimeInterval?)] {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard var first = calendar.date(byAdding: .weekOfYear, value: -52, to: weekStart) else { return [] }
        if let since, let recorded = calendar.dateInterval(of: .weekOfYear, for: since)?.start, recorded > first {
            first = min(recorded, weekStart)
        }
        let weeks = (calendar.dateComponents([.weekOfYear], from: first, to: weekStart).weekOfYear ?? 52) + 1
        var cells: [(Date, TimeInterval?)] = []
        var day = first
        while cells.count < weeks * 7 {
            let seconds = day > today ? nil : archive.days[ActivityArchive.key(day, calendar: calendar)]?.part(providers)?.active ?? 0
            cells.append((day, seconds))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return cells
    }
}
