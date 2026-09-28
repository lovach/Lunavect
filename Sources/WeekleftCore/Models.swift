import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
}
// Bound persisted dates to Foundation's calendar sentinels. Finite
// Doubles alone can still overflow countdown/diagnostic integer conversions.
private enum UsageDate {
    static func isValid(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }
    static func isStale(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return !isValid(date) || !age.isFinite || age < 0 || age > 900
    }
}

/// How a source reported a reset. Nil: an exact timestamp (status line, Codex).
/// Otherwise the source showed the reset truncated to this unit ("11:59pm" for
/// 23:59:59.767) and `resetsAt` holds the end of the shown unit, the first moment
/// the window has certainly reset, so nothing treats it as reset early (Q-05).
/// The `/usage` parser always sets it for a window with a reset; a saved `/usage`
/// window without it was written by an earlier version and is read as the start
/// of its shown minute (`UsageSnapshot.init(from:)`).
public enum ResetPrecision: String, Codable, Sendable { case minute, hour, day }

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date?
    public let resetPrecision: ResetPrecision?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public init(usedPercent: Double, durationMinutes: Int, resetsAt: Date?, resetPrecision: ResetPrecision? = nil) throws {
        guard usedPercent.isFinite, (0...100).contains(usedPercent), durationMinutes > 0,
              resetsAt.map(UsageDate.isValid) ?? true else { throw UsageError.invalidResponse }
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
        self.resetPrecision = resetsAt == nil ? nil : resetPrecision
    }
    private enum CodingKeys: String, CodingKey { case usedPercent, durationMinutes, resetsAt, resetPrecision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let used = try values.decode(Double.self, forKey: .usedPercent)
        let duration = try values.decode(Int.self, forKey: .durationMinutes)
        let reset = try values.decodeIfPresent(Date.self, forKey: .resetsAt)
        let precision = (try? values.decodeIfPresent(ResetPrecision.self, forKey: .resetPrecision)) ?? nil
        do { try self.init(usedPercent: used, durationMinutes: duration, resetsAt: reset, resetPrecision: precision) }
        catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid quota window", underlyingError: error))
        }
    }
    fileprivate func isPlausible(fetchedAt: Date) -> Bool {
        // Match the usage parser's allowance for CLI timestamps rounded to minutes.
        // Expired observations remain valid historical data; only a reset beyond
        // the observed window is impossible. Convert before multiplying to avoid overflow.
        resetsAt.map { $0.timeIntervalSince(fetchedAt) <= Double(durationMinutes) * 60 + 120 } ?? true
    }
    public func isExpired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    /// A `/usage` reading saved before resets carried their precision holds the
    /// start of the shown minute. The reset is certain at its end; a window
    /// observed at `observedAt` cannot run past `observedAt` plus its length.
    func completingShownMinute(observedAt: Date?) throws -> QuotaWindow {
        guard resetPrecision == nil, let resetsAt else { return self }
        var end = resetsAt.addingTimeInterval(60)
        if let observedAt { end = max(resetsAt, min(end, observedAt.addingTimeInterval(Double(durationMinutes) * 60))) }
        return try QuotaWindow(usedPercent: usedPercent, durationMinutes: durationMinutes, resetsAt: end, resetPrecision: .minute)
    }
    public func countdown(now: Date = Date(), language: String = L10n.selection) -> String {
        func text(_ key: String, _ args: String...) -> String { L10n.text(key, language: language, arguments: args) }
        guard let resetsAt else { return "—" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds.isFinite, UsageDate.isValid(now) else { return "—" }
        guard seconds > 0 else { return text("обновление") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        return DurationText.minutes(minutes, includesDays: true, language: language)
    }
}
public struct ModelQuota: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let window: QuotaWindow
    public let fetchedAt: Date
    public init(name: String, window: QuotaWindow, fetchedAt: Date) {
        self.name = name; self.window = window; self.fetchedAt = fetchedAt
    }
    private enum CodingKeys: String, CodingKey { case name, window, fetchedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        window = try values.decode(QuotaWindow.self, forKey: .window)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        guard UsageDate.isValid(fetchedAt) else {
            throw DecodingError.dataCorruptedError(forKey: .fetchedAt, in: values, debugDescription: "Invalid observation date")
        }
        guard window.isPlausible(fetchedAt: fetchedAt) else {
            throw DecodingError.dataCorruptedError(forKey: .window, in: values, debugDescription: "Reset exceeds the observed quota window")
        }
    }
    public func isStale(now: Date) -> Bool {
        UsageDate.isStale(fetchedAt, now: now) || !window.isPlausible(fetchedAt: fetchedAt) || window.isExpired(at: now)
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var weekly: QuotaWindow?
    public var fiveHour: QuotaWindow?
    public var fetchedAt: Date?
    public var source: String
    public var issue: String?
    /// Optional for compatibility with snapshots written before model quotas were supported.
    public var modelQuotas: [ModelQuota]?
    /// The provider confirmed that no rate-limit window applies (a Codex plan with
    /// unlimited credits or without windows). Absent in older snapshots.
    public var unlimited: Bool?
    public init(provider: ProviderID, weekly: QuotaWindow? = nil, fiveHour: QuotaWindow? = nil, fetchedAt: Date? = nil, source: String = "", issue: String? = nil, modelQuotas: [ModelQuota]? = nil, unlimited: Bool? = nil) {
        self.provider = provider; self.weekly = weekly; self.fiveHour = fiveHour; self.fetchedAt = fetchedAt; self.source = source; self.issue = issue; self.modelQuotas = modelQuotas
        self.unlimited = unlimited
    }
    private enum CodingKeys: String, CodingKey { case provider, weekly, fiveHour, fetchedAt, source, issue, modelQuotas, unlimited }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(ProviderID.self, forKey: .provider)
        weekly = try values.decodeIfPresent(QuotaWindow.self, forKey: .weekly)
        fiveHour = try values.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        source = try values.decode(String.self, forKey: .source)
        issue = try values.decodeIfPresent(String.self, forKey: .issue)
        modelQuotas = try values.decodeIfPresent([ModelQuota].self, forKey: .modelQuotas)
        unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited)
        if source == Self.usageProbeSource {
            // Written before `/usage` resets carried their precision (Q-05).
            let observed = fetchedAt
            do {
                weekly = try weekly?.completingShownMinute(observedAt: observed)
                fiveHour = try fiveHour?.completingShownMinute(observedAt: observed)
                modelQuotas = try modelQuotas?.map {
                    ModelQuota(name: $0.name, window: try $0.window.completingShownMinute(observedAt: $0.fetchedAt), fetchedAt: $0.fetchedAt)
                }
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid quota window", underlyingError: error))
            }
        }
        guard weekly.map({ $0.durationMinutes == 10080 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .weekly, in: values, debugDescription: "Invalid weekly duration")
        }
        guard fiveHour.map({ $0.durationMinutes == 300 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .fiveHour, in: values, debugDescription: "Invalid five-hour duration")
        }
        guard fetchedAt.map(UsageDate.isValid) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .fetchedAt, in: values, debugDescription: "Invalid observation date")
        }
        if let fetchedAt {
            for (key, window) in [(CodingKeys.weekly, weekly), (.fiveHour, fiveHour)] {
                guard window?.isPlausible(fetchedAt: fetchedAt) ?? true else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Reset exceeds the observed quota window")
                }
            }
        }
    }
    public func isStale(now: Date = Date()) -> Bool {
        observationIsStale(now: now) || [weekly, fiveHour].compactMap { $0 }.contains { isStale(window: $0, now: now) }
    }
    /// Freshness of one displayed quota is independent of another window's reset.
    public func isStale(window: QuotaWindow?, now: Date = Date()) -> Bool {
        guard let window, let fetchedAt else { return true }
        return observationIsStale(now: now) || !window.isPlausible(fetchedAt: fetchedAt) || window.isExpired(at: now)
    }
    private func observationIsStale(now: Date) -> Bool {
        guard let fetchedAt else { return true }
        return !freshnessVerified || issue != nil || UsageDate.isStale(fetchedAt, now: now)
    }
    /// statusLine supplies cached session quotas, without their server observation
    /// time. Receipt (even after an API response) cannot certify quota freshness.
    public var freshnessVerified: Bool { source != "Claude Code statusLine" }
    static let usageProbeSource = "Claude Code /usage"
    /// New data is expected only this long after a reset. A `/usage` reset is already
    /// the end of the minute the CLI showed (`ResetPrecision`); the CLI then needs a
    /// moment to load the new window. statusLine and Codex report exact epochs.
    /// The confirming probe keeps its moment: 90 s after the shown minute's start.
    public var resetGrace: TimeInterval { source == Self.usageProbeSource ? 30 : 5 }
    public var hasQuota: Bool { weekly != nil || fiveHour != nil }
    public func connectionQuotaTitle(now: Date = Date()) -> String {
        guard hasQuota || unlimited == true else { return "Ждём лимиты" }
        return isStale(now: now) ? "Лимиты сохранены" : "Лимиты получены"
    }
}
/// The state of one quota window, shared by the menu bar, widgets and settings
/// (01-quota.md §3). Unknown values stay unknown: after a reset without new data
/// neither the old value nor an assumed 100 % is shown.
public enum QuotaWindowStatus: Equatable, Sendable {
    /// No observation of this window.
    case unknown
    /// The provider applies no rate-limit window.
    case unlimited
    /// A value with a future (or unreported) reset; stale values are marked.
    case current(stale: Bool)
    /// 0 % remaining until the saved reset: it cannot change before then.
    case exhausted
    /// The saved reset has passed and no newer observation exists.
    case resetPassed(Date)
    /// Confirmed 0 % used and no reset yet: the window starts with the first request.
    case inactive(stale: Bool)

    public static func of(_ window: QuotaWindow?, stale: Bool, now: Date, unlimited: Bool = false) -> Self {
        guard let window else { return unlimited ? .unlimited : .unknown }
        if let reset = window.resetsAt {
            if reset <= now { return .resetPassed(reset) }
            return window.remaining < 1 ? .exhausted : .current(stale: stale)
        }
        return window.usedPercent == 0 ? .inactive(stale: stale) : .current(stale: stale)
    }
    /// The remaining percentage a surface may show; nil shows a dash.
    public func remaining(of window: QuotaWindow?) -> Double? {
        switch self {
        case .current, .exhausted, .inactive: return window?.remaining
        case .unknown, .unlimited, .resetPassed: return nil
        }
    }
    /// A saved value that may have changed since it was observed ("*").
    public var isStale: Bool {
        switch self {
        case .current(let stale), .inactive(let stale): return stale
        default: return false
        }
    }
    /// One sentence per state, identical on every surface; nil when the value speaks for itself.
    public func note(now: Date, language: String = L10n.selection) -> String? {
        switch self {
        case .resetPassed(let date):
            let locale = L10n.locale(language: AppLanguage.resolve(language))
            let time = date.formatted(Calendar.current.isDate(date, inSameDayAs: now)
                ? .dateTime.hour().minute().locale(locale)
                : .dateTime.day().month().hour().minute().locale(locale))
            return L10n.text("Сброс был в {0}, ждём первые данные нового окна", language: language, arguments: [time])
        case .inactive: return L10n.text("Окно начнётся с первым запросом", language: language)
        case .unlimited: return L10n.text("Без лимитов", language: language)
        case .unknown, .current, .exhausted: return nil
        }
    }
}
extension UsageSnapshot {
    public func status(of window: QuotaWindow?, now: Date = Date()) -> QuotaWindowStatus {
        .of(window, stale: isStale(window: window, now: now), now: now, unlimited: unlimited == true)
    }
}
extension ModelQuota {
    public func status(now: Date = Date()) -> QuotaWindowStatus { .of(window, stale: isStale(now: now), now: now) }
}

public enum UsageError: LocalizedError {
    case invalidResponse, missingCLI, timeout, notSignedIn, waitingForClaude, statusLineDisabled, claudeQuotaStale, claudeCLIUnavailable, claudeSignInRequired, claudeUsageUnavailable
    /// Earlier wording still stored in saved snapshots, recognized by diagnostics.
    static let retiredMessages: [String: UsageError] = [
        "Claude Code не передал свежие лимиты. Проверьте подключение и доступность команды /usage. Повторим автоматически через 5 минут.": .claudeUsageUnavailable
    ]
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Источник вернул неподдерживаемые данные."
        case .missingCLI: return "Укажите путь к Codex CLI в настройках."
        case .timeout: return "Источник не ответил за 25 секунд."
        case .notSignedIn: return "Войдите в аккаунт через Codex и обновите данные."
        case .waitingForClaude: return "Ожидание данных из Claude Code. После подключения продолжите обычную сессию."
        case .claudeQuotaStale: return "Лимиты Claude устарели. Lunavect автоматически запросит новые данные через Claude Code."
        case .claudeCLIUnavailable: return "Для автоматического обновления лимитов установите Claude Code и войдите в свой аккаунт."
        case .claudeSignInRequired: return "Откройте Claude Code в терминале и завершите его настройку или вход. Lunavect повторит запрос автоматически."
        case .claudeUsageUnavailable: return "Claude Code не передал свежие лимиты. Сохранённые данные остаются на месте; Lunavect повторит запрос позже."
        case .statusLineDisabled: return "Строка состояния отключена настройкой disableAllHooks в Claude Code."
        }
    }
}

public enum UsageParser {
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number
    }
    public static func codex(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        // Never substitute a model-specific (e.g. Spark) bucket for the main account limit.
        let legacy = result["rateLimits"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? legacy.flatMap { (($0["limitId"] as? String) == nil || ($0["limitId"] as? String) == "codex") ? $0 : nil }
        guard let bucket else { throw UsageError.invalidResponse }
        var weekly: QuotaWindow?, five: QuotaWindow?
        for key in ["primary", "secondary"] {
            guard let raw = bucket[key] as? [String: Any] else { continue }
            guard let used = number(raw["usedPercent"]), number(raw["windowDurationMins"]) != nil,
                  let minutes = raw["windowDurationMins"] as? Int else { throw UsageError.invalidResponse }
            var reset: Date?
            if let value = raw["resetsAt"], !(value is NSNull) {
                guard let epoch = number(value) else { throw UsageError.invalidResponse }
                reset = Date(timeIntervalSince1970: epoch.doubleValue)
            }
            let window = try QuotaWindow(usedPercent: used.doubleValue, durationMinutes: minutes, resetsAt: reset)
            if minutes == 10080 { weekly = window }
            if minutes == 300 { five = window }
        }
        // A reached usage limit is 100 % of the binding window, even when the
        // server's rounded percentage is lower. Credit depletion is not a window.
        let reachedTypes = ["rate_limit_reached", "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached"]
        if let type = bucket["rateLimitReachedType"] as? String, reachedTypes.contains(type) {
            let binding = max(weekly?.usedPercent ?? -1, five?.usedPercent ?? -1)
            if let window = weekly, window.usedPercent == binding {
                weekly = try QuotaWindow(usedPercent: 100, durationMinutes: window.durationMinutes, resetsAt: window.resetsAt)
            }
            if let window = five, window.usedPercent == binding {
                five = try QuotaWindow(usedPercent: 100, durationMinutes: window.durationMinutes, resetsAt: window.resetsAt)
            }
        }
        var snapshot = UsageSnapshot(provider: .codex, weekly: weekly, fiveHour: five, fetchedAt: now, source: "Codex CLI")
        // No window at all in the account bucket (unlimited credits, some team
        // plans): a known answer, not missing data.
        if !["primary", "secondary"].contains(where: { bucket[$0] is [String: Any] }) { snapshot.unlimited = true }
        return snapshot
    }
    public static func claude(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        func window(_ key: String, _ minutes: Int) throws -> QuotaWindow? {
            guard let raw = result[key] as? [String: Any] else { return nil }
            guard let used = number(raw["used_percentage"]), (0...100).contains(used.doubleValue) else { throw UsageError.invalidResponse }
            // Windows are independent (Q-10): one that has not started (resets_at
            // null) or carries no usable reset is absent; the other window stays.
            guard let epoch = number(raw["resets_at"]), epoch.doubleValue > 0 else { return nil }
            let date = Date(timeIntervalSince1970: epoch.doubleValue)
            return try QuotaWindow(usedPercent: used.doubleValue, durationMinutes: minutes, resetsAt: date)
        }
        guard result.keys.contains("seven_day") || result.keys.contains("five_hour") else { throw UsageError.invalidResponse }
        return try UsageSnapshot(provider: .claude, weekly: window("seven_day", 10080), fiveHour: window("five_hour", 300), fetchedAt: now, source: "Claude Code statusLine")
    }
    public static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
