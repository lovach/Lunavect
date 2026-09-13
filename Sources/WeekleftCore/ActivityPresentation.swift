import Foundation

public enum ActivitySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, claude, codex, comparison
    public static var allCases: [Self] { [.all, .claude, .codex] }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "Claude + Codex"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .comparison: return "Claude + Codex"
        }
    }
    public var canonical: Self { self == .comparison ? .all : self }
    public var provider: ProviderID? { ProviderID(rawValue: rawValue) }
    public func providers(from enabled: [ProviderID]) -> [ProviderID] {
        guard let provider else { return enabled }
        return enabled.contains(provider) ? [provider] : []
    }
    public static func available(for providers: [ProviderID]) -> [Self] {
        (providers.count > 1 ? [.all] : []) + providers.compactMap { Self(rawValue: $0.rawValue) }
    }
    public func widgetURL(period: ActivityPeriod) -> URL {
        URL(string: "lunavect://activity?period=\(period.rawValue)&source=\(rawValue)")!
    }
    public static func from(widgetURL url: URL) -> Self? {
        guard ActivityPeriod.from(widgetURL: url) != nil else { return nil }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "source" } ?? []
        guard values.count <= 1 else { return nil }
        return values.isEmpty ? .all : values.first?.value.flatMap(Self.init(rawValue:))
    }
}

public enum ActivityChartScale {
    public static func ceiling(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 60 }
        let steps: [Double] = [60, 120, 180, 300, 600, 900, 1200, 1800, 2700, 3600,
                               5400, 7200, 10800, 14400, 21600, 28800, 36000, 43200,
                               50400, 57600, 64800, 72000, 86400]
        return steps.first { $0 >= value } ?? ceil(value / 21600) * 21600
    }
    public static func tick(_ seconds: TimeInterval, maximum: TimeInterval) -> String {
        let value = maximum <= 3600 ? seconds / 60 : seconds / 3600
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))
    }
    public static func unit(maximum: TimeInterval) -> String { maximum <= 3600 ? L("мин") : L("ч") }
    public static func label(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return "0" }
        if seconds < 60 { return L("{0} с", String(Int(seconds))) }
        return seconds >= 3600 && seconds.truncatingRemainder(dividingBy: 3600) == 0
            ? L("{0} ч", String(Int(seconds / 3600))) : L("{0} мин", String(Int(seconds / 60)))
    }
}

/// One small file per configuration prevents read/modify/write races between different widgets.
/// Identically configured widgets share their selected point; history and quota files are untouched.
public enum ActivityWidgetSelection {
    public static let kinds = ["LunavectActivityWidget", "LunavectOverviewWidget"]
    private static func url(kind: String, period: ActivityPeriod, source: ActivitySource, directory: URL) -> URL? {
        guard kinds.contains(kind) else { return nil }
        return directory.appendingPathComponent("ActivitySelection", isDirectory: true)
            .appendingPathComponent("\(kind)-\(period.rawValue)-\(source.canonical.rawValue).json")
    }
    public static func read(kind: String, period: ActivityPeriod, source: ActivitySource, directory: URL = SnapshotStore.directory) -> Date? {
        guard let url = url(kind: kind, period: period, source: source, directory: directory),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }
    public static func write(_ date: Date?, kind: String, period: ActivityPeriod, source: ActivitySource, directory: URL = SnapshotStore.directory) throws {
        guard let url = url(kind: kind, period: period, source: source, directory: directory) else { return }
        if let date {
            guard date.timeIntervalSince1970.isFinite else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LocalStateRecovery.write(JSONEncoder().encode(date), to: url)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public struct ActivityChartSeries: Identifiable, Sendable {
    public let provider: ProviderID
    public let summary: ActivitySummary
    public var id: ProviderID { provider }
    public func totals(at date: Date?) -> ActivityTotals {
        date.flatMap { selected in summary.points.first { $0.date == selected }?.totals } ?? summary.totals
    }
}

public struct ActivityChartData: Sendable {
    public let summary: ActivitySummary
    public let series: [ActivityChartSeries]
    public let now: Date
    public let limited: Bool
    public var points: [ActivityDay] { summary.points }
    public var maximum: Double { ActivityChartScale.ceiling(series.flatMap { $0.summary.points }.map { $0.totals.active }.max() ?? 0) }
    public var hasData: Bool { series.contains { $0.summary.hasObservations } }
    public var stale: Bool { series.contains { $0.summary.lastLiveObservedAt.map { now.timeIntervalSince($0) > 300 } ?? false } }
    public init(history: ActivityHistory, now: Date = Date(), period: ActivityPeriod = .week, providers: [ProviderID] = ProviderID.allCases, calendar: Calendar = .current) {
        self.now = now; limited = history.importWasLimited == true
        summary = history.summary(now: now, calendar: calendar, period: period, providers: providers)
        series = providers.map { ActivityChartSeries(provider: $0, summary: history.summary(now: now, calendar: calendar, period: period, providers: [$0])) }
    }
    public func validSelection(_ date: Date?) -> Date? {
        points.first(where: { $0.date == date && $0.date <= now })?.date
    }
    public func adjacent(to date: Date?, offset: Int) -> Date? {
        let eligible = points.filter { $0.date <= now }
        guard !eligible.isEmpty else { return nil }
        let index = eligible.firstIndex { $0.date == date } ?? eligible.count - 1
        return eligible[min(eligible.count - 1, max(0, index + offset))].date
    }
}

public enum ActivityChartText {
    public static func axis(_ date: Date, period: ActivityPeriod, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeZone = calendar.timeZone
        switch period {
        case .day: formatter.dateFormat = "HH"
        case .week: formatter.setLocalizedDateFormatFromTemplate("EEE")
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMdd")
        }
        return formatter.string(from: date)
    }
    public static func value(_ totals: ActivityTotals, compact: Bool = true) -> String {
        guard totals.observed > 0 else { return "—" }
        let prefix = totals.recovered > 0 ? "≈ " : ""
        return prefix + DurationText.activity(totals.active)
    }

    public static func range(_ summary: ActivitySummary, compact: Bool = false) -> String {
        guard let first = summary.points.first?.date, let last = summary.days.last?.date else { return "—" }
        if summary.period == .day { return L("Сегодня") }
        let formatter = DateIntervalFormatter(); formatter.locale = L10n.locale
        formatter.dateTemplate = compact ? "dMM" : "dMMM"
        return formatter.string(from: first, to: last)
    }
    public static func point(_ date: Date, period: ActivityPeriod, calendar: Calendar = .current, compact: Bool = false) -> String {
        if period == .day {
            let end = calendar.date(byAdding: .hour, value: 1, to: date) ?? date
            let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeZone = calendar.timeZone
            formatter.dateFormat = calendar.dateInterval(of: .day, for: date)?.duration != 86400 ? "HH:mm z" : "HH:mm"
            return formatter.string(from: date) + "–" + formatter.string(from: end)
        }
        if compact { return date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)) }
        return date.formatted(.dateTime.day().month(.abbreviated).weekday(.abbreviated).locale(L10n.locale))
    }
    public static func isCurrent(_ date: Date, period: ActivityPeriod, now: Date, calendar: Calendar = .current) -> Bool {
        period == .day ? calendar.isDate(date, equalTo: now, toGranularity: .hour) : calendar.isDate(date, inSameDayAs: now)
    }
}
