import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
}
public struct QuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    public init(usedPercent: Double, durationMinutes: Int, resetsAt: Date?) throws {
        guard usedPercent.isFinite, (0...100).contains(usedPercent), durationMinutes > 0 else { throw UsageError.invalidResponse }
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
    public func isExpired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func countdown(now: Date = Date(), language: String = L10n.selection) -> String {
        func text(_ key: String, _ args: String...) -> String { L10n.text(key, language: language, arguments: args) }
        guard let resetsAt else { return "—" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return text("обновление") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return text("{0} д {1} ч", String(minutes / 1440), String((minutes % 1440) / 60)) }
        if minutes >= 60 { return text("{0} ч {1} м", String(minutes / 60), String(minutes % 60)) }
        return text("{0} м", String(minutes))
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
    public func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > 900 || window.isExpired(at: now) }
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
    public func isStale(now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        return issue != nil || now.timeIntervalSince(fetchedAt) > 900 || (weekly?.isExpired(at: now) ?? false) || (fiveHour?.isExpired(at: now) ?? false)
    }
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
