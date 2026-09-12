import Foundation

public enum ActivityImportIssue: String, Codable, CaseIterable, Sendable {
    case unreadable, missingSource, malformed, invalidTiming, incompleteTask, unmatchedTool, recordTooLarge, budget, symlink
    public var title: String {
        switch self {
        case .unreadable: return L("Не удалось прочитать")
        case .missingSource: return L("Каталог журналов не найден")
        case .malformed: return L("Повреждённые записи")
        case .invalidTiming: return L("Несогласованное время")
        case .incompleteTask: return L("Незавершённые задачи")
        case .unmatchedTool: return L("Не удалось сопоставить инструмент")
        case .recordTooLarge: return L("Слишком большие записи метаданных")
        case .budget: return L("Достигнут предел чтения")
        case .symlink: return L("Пропущены символические ссылки")
        }
    }
}

/// Aggregate diagnostics only; never paths, session IDs, tool arguments or messages.
public struct ActivityImportReport: Codable, Equatable, Sendable {
    public struct Provider: Codable, Equatable, Sendable {
        public let id: ProviderID
        public var filesRead = 0
        public var filesWithoutTiming = 0
        public var recordsRecovered = 0
        public var taskRecords = 0
        public var agentRecords = 0
        public var toolRecords = 0
        public var bytesRead = 0
        public var longStringsOmitted = 0
        public var recoveredSeconds: TimeInterval = 0
        public var daysRecovered = 0
        public var firstRecovered: Date?
        public var lastRecovered: Date?
        public var issues: [ActivityImportIssue: Int] = [:]
        public init(id: ProviderID) { self.id = id }
        private enum CodingKeys: String, CodingKey {
            case id, filesRead, filesWithoutTiming, recordsRecovered, taskRecords, agentRecords, toolRecords, bytesRead, longStringsOmitted, recoveredSeconds, daysRecovered, firstRecovered, lastRecovered, issues
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ProviderID.self, forKey: .id)
            filesRead = try c.decodeIfPresent(Int.self, forKey: .filesRead) ?? 0
            filesWithoutTiming = try c.decodeIfPresent(Int.self, forKey: .filesWithoutTiming) ?? 0
            recordsRecovered = try c.decodeIfPresent(Int.self, forKey: .recordsRecovered) ?? 0
            taskRecords = try c.decodeIfPresent(Int.self, forKey: .taskRecords) ?? 0
            agentRecords = try c.decodeIfPresent(Int.self, forKey: .agentRecords) ?? 0
            toolRecords = try c.decodeIfPresent(Int.self, forKey: .toolRecords) ?? 0
            bytesRead = try c.decodeIfPresent(Int.self, forKey: .bytesRead) ?? 0
            longStringsOmitted = try c.decodeIfPresent(Int.self, forKey: .longStringsOmitted) ?? 0
            recoveredSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .recoveredSeconds) ?? 0
            daysRecovered = try c.decodeIfPresent(Int.self, forKey: .daysRecovered) ?? 0
            firstRecovered = try c.decodeIfPresent(Date.self, forKey: .firstRecovered)
            lastRecovered = try c.decodeIfPresent(Date.self, forKey: .lastRecovered)
            issues = try c.decodeIfPresent([ActivityImportIssue: Int].self, forKey: .issues) ?? [:]
        }
    }
    public static let currentVersion = 3
    public var version = Self.currentVersion
    public var providers: [Provider] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, providers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        providers = try c.decodeIfPresent([Provider].self, forKey: .providers) ?? []
    }
    public var limited: Bool { providers.contains { !$0.issues.isEmpty } }
}


public enum ActivityPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var title: String {
        switch self { case .day: return L("День"); case .week: return L("Неделя"); case .month: return L("Месяц") }
    }
    public var caption: String {
        switch self { case .day: return L("Сегодня"); case .week: return L("За 7 дней"); case .month: return L("За 30 дней") }
    }
    public var dayCount: Int { self == .day ? 1 : self == .week ? 7 : 30 }
    public var widgetURL: URL { URL(string: "lunavect://activity?period=\(rawValue)")! }
    public static func from(widgetURL url: URL) -> ActivityPeriod? {
        guard url.scheme == "lunavect", url.host == "activity", url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let periods = components.queryItems?.filter { $0.name == "period" } ?? []
        guard periods.count <= 1 else { return nil }
        return periods.isEmpty ? .week : periods.first?.value.flatMap(ActivityPeriod.init(rawValue:))
    }
}

/// Only time ranges and provider flags are persisted. No session IDs, titles or content.
public struct ActivityInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// 0 = observed without confirmed work, 1 = Claude, 2 = Codex, 3 = both.
    public var providers: Int
    public var recovered: Bool?
    /// Sources whose state was actually observed. Missing in older files; activity itself remains evidence.
    public var observedProviders: Int?
    public var knownProviders: Int { providers | (observedProviders ?? 0) }
    public init(start: Date, end: Date, providers: Int, recovered: Bool? = nil, observedProviders: Int? = nil) {
        self.start = start; self.end = end; self.providers = providers; self.recovered = recovered
        self.observedProviders = observedProviders
    }
}

public struct ActivityTotals: Equatable, Sendable {
    public var observed: TimeInterval = 0
    public var active: TimeInterval = 0
    public var claude: TimeInterval = 0
    public var codex: TimeInterval = 0
    public var recovered: TimeInterval = 0
    public init() {}
    mutating func add(seconds: TimeInterval, providers: Int, recovered: Bool = false) {
        observed += seconds
        if providers != 0 { active += seconds }
        if providers & 1 != 0 { claude += seconds }
        if providers & 2 != 0 { codex += seconds }
        if recovered && providers != 0 { self.recovered += seconds }
    }
}

public struct ActivityDay: Identifiable, Sendable {
    public var date: Date
    public var totals = ActivityTotals()
    public var id: Date { date }
}

public struct ActivitySummary: Sendable {
    public var period: ActivityPeriod
    public var days: [ActivityDay]
    public var points: [ActivityDay]
    public var hours: [TimeInterval]
    public var totals: ActivityTotals
    public var lastObservedAt: Date?
    public var lastLiveObservedAt: Date? = nil
    public var today: ActivityTotals { days.last?.totals ?? ActivityTotals() }
    public var peakHour: Int? {
        guard let maximum = hours.max(), maximum > 0 else { return nil }
        return hours.firstIndex(of: maximum)
    }
    public var hasObservations: Bool { totals.observed > 0 }
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return seconds > 0 ? L("< 1 м") : L("0 м") }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? L("{0} ч {1} м", String(minutes / 60), String(minutes % 60)) : L("{0} м", String(minutes))
    }
    public var peakLabel: String {
        guard let hour = peakHour else { return "—" }
        return String(format: "%02d–%02d", hour, hour + 1)
    }
}

public struct ActivityHistory: Codable, Equatable, Sendable {
    public private(set) var intervals: [ActivityInterval] = []
    public private(set) var importCutoff: Date?
    public private(set) var importedAt: Date?
    public private(set) var importWasLimited: Bool?
    public private(set) var importReport: ActivityImportReport?
    public var needsImport: Bool { importedAt == nil || (importReport?.version ?? 0) < ActivityImportReport.currentVersion }
    public init() {}
    public mutating func append(start: Date, end: Date, providers: Int, observedProviders: Int? = nil) {
        guard start < end, (0...3).contains(providers), observedProviders.map({ (0...3).contains($0) && ($0 & providers) == providers }) ?? true,
              intervals.last.map({ $0.end <= start }) ?? true else { return }
        if let last = intervals.last, last.end == start, last.providers == providers, last.observedProviders == observedProviders, last.recovered != true {
            intervals[intervals.count - 1].end = end
        } else { intervals.append(ActivityInterval(start: start, end: end, providers: providers, observedProviders: observedProviders)) }
        prune(at: end)
    }
    private mutating func prune(at end: Date) {
        let cutoff = end.addingTimeInterval(-35 * 86400)
        intervals.removeAll { $0.end <= cutoff }
        if !intervals.isEmpty, intervals[0].start < cutoff { intervals[0].start = cutoff }
        // Bound storage even when state changes every second for weeks.
        if intervals.count > 50_000 { intervals.removeFirst(intervals.count - 50_000) }
    }
    public mutating func prepareImport(now: Date) -> Date {
        if importCutoff == nil { importCutoff = min(now, intervals.first?.start ?? now) }
        return importCutoff!
    }
    /// Union historical work before recording began. New live observations always survive.
    public mutating func mergeRecovered(_ spans: [ActivityInterval], now: Date, limited: Bool, report: ActivityImportReport? = nil) {
        let boundary = prepareImport(now: now)
        let cutoff = now.addingTimeInterval(-35 * 86400)
        let incoming = spans.compactMap { span -> ActivityInterval? in
            let start = max(cutoff, span.start), end = min(boundary, span.end)
            guard start < end, (1...3).contains(span.providers) else { return nil }
            return ActivityInterval(start: start, end: end, providers: span.providers, recovered: true)
        }
        intervals = Self.union(intervals + incoming)
        let storageLimited = intervals.count > 50_000
        prune(at: now)
        importedAt = now; importWasLimited = limited || storageLimited
        if var report {
            if storageLimited, !report.providers.isEmpty { report.providers[0].issues[.budget, default: 0] += 1 }
            importReport = report
        }
    }
    /// A sweep avoids counting overlapping tasks, copies, or providers twice.
    public static func union(_ spans: [ActivityInterval]) -> [ActivityInterval] {
        struct Event { let date: Date; let delta: Int; let mask: Int; let recovered: Bool; let observed: Int? }
        var events: [Event] = []
        for span in spans where span.start < span.end && (0...3).contains(span.providers) {
            events.append(Event(date: span.start, delta: 1, mask: span.providers, recovered: span.recovered == true, observed: span.observedProviders))
            events.append(Event(date: span.end, delta: -1, mask: span.providers, recovered: span.recovered == true, observed: span.observedProviders))
        }
        events.sort { $0.date < $1.date }
        var counts = [0, 0, 0, 0, 0, 0, 0], previous: Date?, result: [ActivityInterval] = []
        for event in events {
            if let previous, previous < event.date, counts[0] > 0 {
                let mask = (counts[1] > 0 ? 1 : 0) | (counts[2] > 0 ? 2 : 0)
                let recovered: Bool? = counts[3] > 0 ? true : nil
                let observed: Int? = counts[6] > 0 ? (mask | (counts[4] > 0 ? 1 : 0) | (counts[5] > 0 ? 2 : 0)) : nil
                if let last = result.last, last.end == previous, last.providers == mask, last.recovered == recovered, last.observedProviders == observed {
                    result[result.count - 1].end = event.date
                } else { result.append(ActivityInterval(start: previous, end: event.date, providers: mask, recovered: recovered, observedProviders: observed)) }
            }
            counts[0] += event.delta
            if event.mask & 1 != 0 { counts[1] += event.delta }
            if event.mask & 2 != 0 { counts[2] += event.delta }
            if event.recovered { counts[3] += event.delta }
            if let observed = event.observed {
                counts[6] += event.delta
                if observed & 1 != 0 { counts[4] += event.delta }
                if observed & 2 != 0 { counts[5] += event.delta }
            }
            previous = event.date
        }
        return result
    }
    public func summary(now: Date = Date(), calendar: Calendar = .current, period: ActivityPeriod = .week, providers: [ProviderID] = ProviderID.allCases) -> ActivitySummary {
        let mask = providers.reduce(0) { $0 | ($1 == .claude ? 1 : 2) }
        // Legacy unknown idle intervals preserve the combined total, but cannot prove a provider-specific zero.
        let selectedIntervals = intervals.filter { mask != 0 && ($0.knownProviders & mask != 0 || (mask == 3 && $0.providers == 0 && $0.observedProviders == nil)) }
        let today = calendar.startOfDay(for: now)
        let dates = (-(period.dayCount - 1)...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        var pointDates = dates
        if period == .day, let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            pointDates = []; var cursor = today
            while cursor < tomorrow {
                pointDates.append(cursor)
                guard let end = calendar.dateInterval(of: .hour, for: cursor)?.end, end > cursor else { break }
                cursor = end
            }
        }
        var result = ActivitySummary(period: period, days: dates.map { ActivityDay(date: $0) }, points: pointDates.map { ActivityDay(date: $0) }, hours: Array(repeating: 0, count: 24), totals: ActivityTotals(), lastObservedAt: selectedIntervals.last(where: { $0.start < now }).map { min(now, $0.end) },
                                     lastLiveObservedAt: selectedIntervals.last(where: { $0.start < now && $0.observedProviders != nil && $0.recovered != true }).map { min(now, $0.end) })
        guard let start = dates.first else { return result }
        let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
        let pointIndices = Dictionary(uniqueKeysWithValues: pointDates.enumerated().map { ($1, $0) })
        for span in selectedIntervals where span.end > start && span.start < now {
            var cursor = max(start, span.start)
            let end = min(now, span.end)
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let boundary = min(end, hour.end)
                guard boundary > cursor else { break }
                let seconds = boundary.timeIntervalSince(cursor)
                if let index = indices[calendar.startOfDay(for: cursor)] {
                    result.days[index].totals.add(seconds: seconds, providers: span.providers & mask, recovered: span.recovered == true)
                    result.totals.add(seconds: seconds, providers: span.providers & mask, recovered: span.recovered == true)
                    let pointDate = period == .day ? hour.start : result.days[index].date
                    if let point = pointIndices[pointDate] { result.points[point].totals.add(seconds: seconds, providers: span.providers & mask, recovered: span.recovered == true) }
                    if span.providers & mask != 0 { result.hours[calendar.component(.hour, from: cursor)] += seconds }
                }
                cursor = boundary
            }
        }
        return result
    }
    public static func load(from url: URL = fileURL) throws -> ActivityHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return ActivityHistory() }
        let data = try Data(contentsOf: url)
        let history = try JSONDecoder().decode(ActivityHistory.self, from: data)
        var previous = Date.distantPast
        for span in history.intervals {
            guard span.start >= previous, span.end > span.start, (0...3).contains(span.providers),
                  span.observedProviders.map({ (0...3).contains($0) && ($0 & span.providers) == span.providers }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            previous = span.end
        }
        return history
    }
    public static var fileURL: URL { SnapshotStore.directory.appendingPathComponent("activity.json") }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
