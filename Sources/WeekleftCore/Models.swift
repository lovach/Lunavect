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

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public init(usedPercent: Double, durationMinutes: Int, resetsAt: Date?) throws {
        guard usedPercent.isFinite, (0...100).contains(usedPercent), durationMinutes > 0,
              resetsAt.map(UsageDate.isValid) ?? true else { throw UsageError.invalidResponse }
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
    private enum CodingKeys: String, CodingKey { case usedPercent, durationMinutes, resetsAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let used = try values.decode(Double.self, forKey: .usedPercent)
        let duration = try values.decode(Int.self, forKey: .durationMinutes)
        let reset = try values.decodeIfPresent(Date.self, forKey: .resetsAt)
        do { try self.init(usedPercent: used, durationMinutes: duration, resetsAt: reset) }
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
    public init(provider: ProviderID, weekly: QuotaWindow? = nil, fiveHour: QuotaWindow? = nil, fetchedAt: Date? = nil, source: String = "", issue: String? = nil, modelQuotas: [ModelQuota]? = nil) {
        self.provider = provider; self.weekly = weekly; self.fiveHour = fiveHour; self.fetchedAt = fetchedAt; self.source = source; self.issue = issue; self.modelQuotas = modelQuotas
    }
    private enum CodingKeys: String, CodingKey { case provider, weekly, fiveHour, fetchedAt, source, issue, modelQuotas }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(ProviderID.self, forKey: .provider)
        weekly = try values.decodeIfPresent(QuotaWindow.self, forKey: .weekly)
        fiveHour = try values.decodeIfPresent(QuotaWindow.self, forKey: .fiveHour)
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        source = try values.decode(String.self, forKey: .source)
        issue = try values.decodeIfPresent(String.self, forKey: .issue)
        modelQuotas = try values.decodeIfPresent([ModelQuota].self, forKey: .modelQuotas)
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
    public var hasQuota: Bool { weekly != nil || fiveHour != nil }
    public func connectionQuotaTitle(now: Date = Date()) -> String {
        guard hasQuota else { return "Ждём лимиты" }
        return isStale(now: now) ? "Лимиты сохранены" : "Лимиты получены"
    }
}
public enum UsageError: LocalizedError {
    case invalidResponse, missingCLI, timeout, notSignedIn, waitingForClaude, statusLineDisabled, claudeQuotaStale, claudeCLIUnavailable, claudeSignInRequired, claudeUsageUnavailable
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
        case .claudeUsageUnavailable: return "Claude Code не передал свежие лимиты. Проверьте подключение и доступность команды /usage. Повторим автоматически через 5 минут."
        case .statusLineDisabled: return "Строка состояния отключена настройкой disableAllHooks в Claude Code."
        }
    }
}

public enum UsageParser {
    public static func codex(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        // Never substitute a model-specific (e.g. Spark) bucket for the main account limit.
        let legacy = result["rateLimits"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? legacy.flatMap { (($0["limitId"] as? String) == nil || ($0["limitId"] as? String) == "codex") ? $0 : nil }
        guard let bucket else { throw UsageError.invalidResponse }
        var weekly: QuotaWindow?, five: QuotaWindow?
        for key in ["primary", "secondary"] {
            guard let raw = bucket[key] as? [String: Any] else { continue }
            guard let used = raw["usedPercent"] as? NSNumber, let minutes = raw["windowDurationMins"] as? Int else { throw UsageError.invalidResponse }
            let window = try QuotaWindow(usedPercent: used.doubleValue, durationMinutes: minutes, resetsAt: (raw["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
            if minutes == 10080 { weekly = window }
            if minutes == 300 { five = window }
        }
        return UsageSnapshot(provider: .codex, weekly: weekly, fiveHour: five, fetchedAt: now, source: "Codex CLI")
    }
    public static func claude(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        func window(_ key: String, _ minutes: Int) throws -> QuotaWindow? {
            guard let raw = result[key] as? [String: Any] else { return nil }
            guard let used = raw["used_percentage"] as? NSNumber else { throw UsageError.invalidResponse }
            guard let epoch = raw["resets_at"] as? NSNumber, epoch.doubleValue.isFinite, epoch.doubleValue > 0 else { throw UsageError.invalidResponse }
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
