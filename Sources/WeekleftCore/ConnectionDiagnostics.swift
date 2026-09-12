import Foundation

/// An allowlist, not a scrubbed copy of logs. No session objects or CLI output
/// can enter a shareable report.
public struct ConnectionDiagnostic: Codable, Equatable, Identifiable {
    public enum Repair: String {
        case install, signIn, events, refresh, reviewUsage, checkSignIn
        public var title: String {
            switch self {
            case .install: return "Установить компонент"
            case .signIn: return "Войти снова"
            case .events: return "Восстановить события"
            case .refresh: return "Обновить данные"
            case .reviewUsage: return "Завершить настройку Claude Code"
            case .checkSignIn: return "Проверить вход"
            }
        }
    }
    public enum State: String, Codable { case missingClient, signedOut, authUnknown, sourceError, waitingForQuota, staleQuota, eventsMissing, ready }
    public let provider: ProviderID
    public let clientFound: Bool
    public let eventsConfigured: Bool
    public let state: State
    public let quotaAgeMinutes: Int?
    public let errorCode: String?
    public var id: ProviderID { provider }

    public init(provider: ProviderID, clientFound: Bool, signIn: ClientConnection.SignInState,
                eventsConfigured: Bool, snapshot: UsageSnapshot?, sessionIssue: String?, now: Date = Date()) {
        self.provider = provider; self.clientFound = clientFound; self.eventsConfigured = eventsConfigured
        quotaAgeMinutes = snapshot?.fetchedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
        let issue = snapshot?.issue
        // Exact known values only. Raw provider errors can contain personal paths.
        let known: [(UsageError, String)] = [(.timeout, "timeout"), (.invalidResponse, "unsupported_response"),
            (.notSignedIn, "sign_in_required"), (.claudeSignInRequired, "claude_setup_required"),
            (.claudeUsageUnavailable, "claude_usage_unavailable"), (.statusLineDisabled, "events_disabled"),
            (.claudeQuotaStale, "stale_quota"), (.waitingForClaude, "waiting_for_quota"),
            (.missingCLI, "missing_client"), (.claudeCLIUnavailable, "missing_client")]
        errorCode = issue.map { value in known.first { $0.0.errorDescription == value }?.1 ?? "source_error" }
            ?? (sessionIssue == nil ? nil : "session_source_error")
        if !clientFound { state = .missingClient }
        else if signIn == .signedOut { state = .signedOut }
        else if signIn == .unavailable { state = .authUnknown }
        else if let issue, issue != UsageError.waitingForClaude.errorDescription && issue != UsageError.claudeQuotaStale.errorDescription { state = .sourceError }
        else if snapshot?.hasQuota != true { state = .waitingForQuota }
        else if snapshot?.isStale(now: now) != false { state = .staleQuota }
        else if !eventsConfigured || sessionIssue != nil { state = .eventsMissing }
        else { state = .ready }
    }
    public var title: String {
        switch state {
        case .missingClient: return "Официальный клиент не найден"
        case .signedOut: return "Нужен вход в аккаунт"
        case .authUnknown: return "Клиент не подтвердил состояние входа"
        case .sourceError: return "Источник не передал свежие данные"
        case .waitingForQuota: return "Ждём первые лимиты"
        case .staleQuota: return "Сохранённые лимиты устарели"
        case .eventsMissing: return "Нужно проверить события сессий"
        case .ready: return "Подключение работает"
        }
    }
    public var repair: Repair? {
        switch state {
        case .missingClient: return .install
        case .signedOut: return .signIn
        case .authUnknown: return .checkSignIn
        case .eventsMissing: return eventsConfigured ? .refresh : .events
        case .sourceError:
            if errorCode == "claude_setup_required" { return .reviewUsage }
            if errorCode == "sign_in_required" { return .signIn }
            if errorCode == "events_disabled" { return .events }
            return .refresh
        case .waitingForQuota, .staleQuota: return .refresh
        case .ready: return nil
        }
    }
    public var guidance: String {
        switch state {
        case .missingClient, .signedOut, .authUnknown: return "Продолжим с нужного шага. Уже выполненную настройку повторять не нужно."
        case .sourceError: return "Проверьте интернет и официальный клиент. Повторная проверка запросит лимиты заново. Сохранённые значения остаются на месте."
        case .waitingForQuota, .staleQuota: return "Повторите проверку. Если данные не появятся, откройте мастер подключения и завершите настройку клиента."
        case .eventsMissing: return "Восстановим обработчики Lunavect, сохранив остальные настройки. Codex может отдельно запросить доверие через /hooks."
        case .ready: return "Свежие лимиты получены, локальные обработчики настроены. События сессий появляются во время работы в клиенте."
        }
    }
}

public enum ConnectionSetupRoute {
    public static func next(clientFound: Bool, signIn: ClientConnection.SignInState,
                            configured: Bool, enabled: Bool) -> Int {
        if !clientFound { return 0 }
        if signIn != .signedIn { return 1 }
        return configured && enabled ? 3 : 2
    }
}

public struct ConnectionDiagnosticReport: Encodable {
    public let schema = 1
    public let appVersion: String
    public let build: String
    public let macOS: String
    public let connections: [ConnectionDiagnostic]
    public init(appVersion: String, build: String, macOS: String, connections: [ConnectionDiagnostic]) {
        func version(_ value: String) -> String {
            value.range(of: "^[0-9]+([.][0-9]+){0,3}$", options: .regularExpression) != nil ? value : "unknown"
        }
        self.appVersion = version(appVersion); self.build = version(build); self.macOS = version(macOS); self.connections = connections
    }
    public func text() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
