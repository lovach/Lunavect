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
            case id, filesRead, filesWithoutTiming, recordsRecovered, taskRecords, agentRecords, toolRecords, bytesRead,
                longStringsOmitted, recoveredSeconds, daysRecovered, firstRecovered, lastRecovered, issues
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
    /// Active sources supported only by imported history. Missing fields retain
    /// the legacy whole-interval provenance when decoding older storage.
    public var recoveredProviders: Int?
    /// Sources actually observed live, including idle observations. This is
    /// separate from known coverage, which may include another imported source.
    public var liveObservedProviders: Int?
    public var recoveredProviderMask: Int { recoveredProviders ?? (recovered == true ? providers : 0) }
    public var liveObservedProviderMask: Int { liveObservedProviders ?? (recovered == true ? 0 : observedProviders ?? 0) }
    /// Sources whose state was actually observed. Missing in older files; activity itself remains evidence.
    public var observedProviders: Int?
    public var knownProviders: Int { providers | (observedProviders ?? 0) }
    public init(start: Date, end: Date, providers: Int, recovered: Bool? = nil, observedProviders: Int? = nil, recoveredProviders: Int? = nil, liveObservedProviders: Int? = nil) {
        self.start = start; self.end = end; self.providers = providers; self.recovered = recovered
        self.observedProviders = observedProviders
        self.recoveredProviders = recoveredProviders; self.liveObservedProviders = liveObservedProviders
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
        DurationText.activity(seconds)
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
    /// Optional fields migrate pre-provider histories without changing their
    /// existing cutoff. Newly enabled sources get their own first-observation edge.
    public private(set) var providerImportCutoffs: [String: Date]?
    public private(set) var providerImportVersions: [String: Int]?
    public var needsImport: Bool { importedAt == nil || (importReport?.version ?? 0) < ActivityImportReport.currentVersion }
    public init() {}
    public mutating func append(start: Date, end: Date, providers: Int, observedProviders: Int? = nil, reconcilingClockCorrection: Bool = false) {
        guard start < end, (0...3).contains(providers), observedProviders.map({ (0...3).contains($0) && ($0 & providers) == providers }) ?? true else { return }
        if let last = intervals.last, last.end > start {
            guard reconcilingClockCorrection else { return }
            intervals = Self.union(intervals + [ActivityInterval(start: start, end: end, providers: providers, observedProviders: observedProviders)])
            prune(at: max(last.end, end))
            return
        }
        if let last = intervals.last, last.end == start, last.providers == providers,
            last.observedProviders == observedProviders, last.recoveredProviderMask == 0,
            last.liveObservedProviderMask == (observedProviders ?? 0)
        {
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
    public func needsImport(providers: Set<ProviderID>) -> Bool {
        providers.contains { (providerImportVersions?[$0.rawValue] ?? 0) < ActivityImportReport.currentVersion }
    }
    public mutating func prepareImport(providers: Set<ProviderID>, now: Date) -> [ProviderID: Date] {
        if providerImportCutoffs == nil {
            providerImportCutoffs = [:]; providerImportVersions = [:]
            if let importCutoff {
                var known = Set(importReport?.providers.map(\.id) ?? [])
                for id in ProviderID.allCases where intervals.contains(where: { $0.knownProviders & (id == .claude ? 1 : 2) != 0 }) { known.insert(id) }
                if known.isEmpty { known = providers }
                for id in known {
                    providerImportCutoffs?[id.rawValue] = importCutoff
                    if importedAt != nil { providerImportVersions?[id.rawValue] = importReport?.version ?? 0 }
                }
            }
        }
        for id in providers where providerImportCutoffs?[id.rawValue] == nil {
            let firstObservation = intervals.first { $0.knownProviders & (id == .claude ? 1 : 2) != 0 }?.start
            providerImportCutoffs?[id.rawValue] = min(now, firstObservation ?? now)
        }
        if importCutoff == nil { importCutoff = providerImportCutoffs?.values.min() ?? now }
        return Dictionary(uniqueKeysWithValues: providers.map { ($0, providerImportCutoffs?[$0.rawValue] ?? now) })
    }
    /// Union historical work before recording began. New live observations always survive.
    public mutating func mergeRecovered(_ spans: [ActivityInterval], now: Date, limited: Bool, report: ActivityImportReport? = nil,
                                       providers: Set<ProviderID>? = nil) {
        let boundaries = providers.map { prepareImport(providers: $0, now: now) }
        let boundary = boundaries?.values.max() ?? prepareImport(now: now)
        let cutoff = now.addingTimeInterval(-35 * 86400)
        let incoming = spans.flatMap { span -> [ActivityInterval] in
            guard (1...3).contains(span.providers) else { return [] }
            return ProviderID.allCases.compactMap { id in
                let mask = id == .claude ? 1 : 2
                guard span.providers & mask != 0, providers?.contains(id) ?? true else { return nil }
                let start = max(cutoff, span.start), end = min(boundaries?[id] ?? boundary, span.end)
                guard start < end else { return nil }
                return ActivityInterval(start: start, end: end, providers: mask, recovered: true)
            }
        }
        intervals = Self.union(intervals + incoming)
        let storageLimited = intervals.count > 50_000
        prune(at: now)
        importedAt = now; importWasLimited = limited || storageLimited
        if var report {
            if storageLimited, !report.providers.isEmpty { report.providers[0].issues[.budget, default: 0] += 1 }
            if let providers, let previous = importReport, previous.version == report.version {
                report.providers += previous.providers.filter { !providers.contains($0.id) }
                report.providers.sort { $0.id.rawValue < $1.id.rawValue }
            }
            importReport = report
        }
        if let providers {
            importWasLimited = limited || storageLimited || (importReport?.limited ?? false)
            if providerImportVersions == nil { providerImportVersions = [:] }
            for id in providers { providerImportVersions?[id.rawValue] = ActivityImportReport.currentVersion }
        }
    }
    /// A sweep avoids counting overlapping tasks, copies, or providers twice.
    public static func union(_ spans: [ActivityInterval]) -> [ActivityInterval] {
        struct Event { let date: Date; let delta: Int; let span: ActivityInterval }
        var events: [Event] = []
        for span in spans where span.start < span.end && (0...3).contains(span.providers) {
            events.append(Event(date: span.start, delta: 1, span: span))
            events.append(Event(date: span.end, delta: -1, span: span))
        }
        events.sort { $0.date < $1.date }
        var count = 0, explicitObservations = 0
        var active = [0, 0], liveActive = [0, 0], observed = [0, 0], liveObserved = [0, 0]
        var previous: Date?, result: [ActivityInterval] = []
        for event in events {
            if let previous, previous < event.date, count > 0 {
                let mask = (active[0] > 0 ? 1 : 0) | (active[1] > 0 ? 2 : 0)
                let liveMask = (liveActive[0] > 0 ? 1 : 0) | (liveActive[1] > 0 ? 2 : 0)
                let recoveredMask = mask & ~liveMask
                let liveObservedMask = (liveObserved[0] > 0 ? 1 : 0) | (liveObserved[1] > 0 ? 2 : 0)
                let known: Int? = explicitObservations > 0 ? (mask | (observed[0] > 0 ? 1 : 0) | (observed[1] > 0 ? 2 : 0)) : nil
                if let last = result.last, last.end == previous, last.providers == mask,
                   last.recoveredProviderMask == recoveredMask, last.observedProviders == known,
                   last.liveObservedProviderMask == liveObservedMask {
                    result[result.count - 1].end = event.date
                } else {
                    result.append(ActivityInterval(start: previous, end: event.date, providers: mask,
                        recovered: recoveredMask != 0 ? true : nil, observedProviders: known,
                        recoveredProviders: recoveredMask, liveObservedProviders: liveObservedMask))
                }
            }
            count += event.delta
            if event.span.observedProviders != nil { explicitObservations += event.delta }
            for (index, mask) in [1, 2].enumerated() {
                if event.span.providers & mask != 0 { active[index] += event.delta }
                if event.span.providers & ~event.span.recoveredProviderMask & mask != 0 { liveActive[index] += event.delta }
                if (event.span.observedProviders ?? 0) & mask != 0 { observed[index] += event.delta }
                if event.span.liveObservedProviderMask & mask != 0 { liveObserved[index] += event.delta }
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
            .map { calendar.startOfDay(for: $0) }
        var pointDates = dates
        // dateInterval ends at the next real midnight, including days whose midnight is skipped by DST.
        if period == .day, let tomorrow = calendar.dateInterval(of: .day, for: today)?.end {
            pointDates = []; var cursor = today
            while cursor < tomorrow {
                pointDates.append(cursor)
                guard let end = calendar.dateInterval(of: .hour, for: cursor)?.end, end > cursor else { break }
                cursor = end
            }
        }
        var result = ActivitySummary(
            period: period, days: dates.map { ActivityDay(date: $0) }, points: pointDates.map { ActivityDay(date: $0) },
            hours: Array(repeating: 0, count: 24), totals: ActivityTotals(),
            lastObservedAt: selectedIntervals.last(where: { $0.start < now }).map { min(now, $0.end) },
            lastLiveObservedAt: selectedIntervals.last(where: { $0.start < now && $0.liveObservedProviderMask & mask != 0 }).map { min(now, $0.end) })
        guard let start = dates.first else { return result }
        let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
        let pointIndices = Dictionary(uniqueKeysWithValues: pointDates.enumerated().map { ($1, $0) })
        for span in selectedIntervals where span.end > start && span.start < now {
            var cursor = max(start, span.start)
            let end = min(now, span.end)
            // Combined activity is wall time: overlapping live work already
            // proves that second, even when another source was recovered.
            let activeMask = span.providers & mask
            let recovered = activeMask != 0 && activeMask & ~span.recoveredProviderMask == 0
            while cursor < end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let boundary = min(end, hour.end)
                guard boundary > cursor else { break }
                let seconds = boundary.timeIntervalSince(cursor)
                if let index = indices[calendar.startOfDay(for: cursor)] {
                    result.days[index].totals.add(seconds: seconds, providers: activeMask, recovered: recovered)
                    result.totals.add(seconds: seconds, providers: activeMask, recovered: recovered)
                    let pointDate = period == .day ? hour.start : result.days[index].date
                    if let point = pointIndices[pointDate] { result.points[point].totals.add(seconds: seconds, providers: activeMask, recovered: recovered) }
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
                  span.observedProviders.map({ (0...3).contains($0) && ($0 & span.providers) == span.providers }) ?? true,
                  span.recoveredProviders.map({ (0...3).contains($0) && ($0 & span.providers) == $0 }) ?? true,
                  span.liveObservedProviders.map({ (0...3).contains($0) && ($0 & span.knownProviders) == $0 }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            previous = span.end
        }
        return history
    }
    public static var fileURL: URL { SnapshotStore.directory.appendingPathComponent("activity.json") }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LocalStateRecovery.write(JSONEncoder().encode(self), to: url)
    }
}
