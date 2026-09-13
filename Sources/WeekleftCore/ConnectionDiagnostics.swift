import Foundation

/// A bounded allowlist of facts about an operation. Never retains a response,
/// user agent, arbitrary error description, path, transcript or credential.
public struct ClientIntegrationIssue: Error, Codable, Equatable, Sendable, LocalizedError {
    public enum Capability: String, Codable, Sendable {
        case initialization, sessionCatalog, rateLimits, statusLine, usageProbe, authentication
    }
    public enum Reason: String, Codable, Sendable {
        case unsupportedResponse, unsupportedOperation, missingClient, clientPathUnavailable
        case timedOut, signInRequired, setupRequired, disabled, configurationChanged
        case waitingForData, staleData, sourceUnavailable, incompleteCatalog
    }
    public let provider: ProviderID
    public let capability: Capability
    public let reason: Reason
    public init(provider: ProviderID, capability: Capability, reason: Reason) {
        self.provider = provider; self.capability = capability; self.reason = reason
    }
    public var code: String { provider.rawValue + "." + capability.rawValue + "." + reason.rawValue }
    public var errorDescription: String? { message }
    public var message: String {
        switch reason {
        case .unsupportedResponse: return "Формат ответа клиента пока не поддерживается. Сохранённые данные остаются на месте."
        case .unsupportedOperation: return "Клиент не поддерживает нужную операцию. Проверьте его версию и официальную инструкцию."
        case .missingClient: return "Официальный клиент не найден."
        case .clientPathUnavailable: return "Клиент по выбранному пути недоступен. Выберите исполняемый файл заново."
        case .timedOut: return "Клиент не ответил вовремя. Повторите проверку."
        case .signInRequired: return "Войдите в официальный клиент и повторите проверку."
        case .setupRequired: return "Завершите первый запуск в официальном клиенте и повторите проверку."
        case .disabled: return "Обработчики событий выключены в настройках источника."
        case .configurationChanged: return "Настройки изменились во время подключения. Повторите действие."
        case .waitingForData: return "Клиент пока не передал эти данные."
        case .staleData: return "Сохранённые данные устарели. Повторите проверку."
        case .incompleteCatalog: return "Каталог сессий получен не полностью"
        case .sourceUnavailable: return "Источник временно недоступен. Сохранённые данные остаются на месте."
        }
    }
    public var repair: ConnectionDiagnostic.Repair {
        switch reason {
        case .unsupportedResponse, .unsupportedOperation: return .reviewClient
        case .missingClient: return .install
        case .clientPathUnavailable: return .chooseClient
        case .signInRequired: return .signIn
        case .setupRequired: return .reviewUsage
        case .disabled, .configurationChanged: return .events
        case .timedOut, .waitingForData, .staleData, .sourceUnavailable, .incompleteCatalog: return .refresh
        }
    }
    public static func classify(_ error: Error, provider: ProviderID, capability: Capability) -> Self? {
        if error is CancellationError { return nil }
        if let issue = error as? Self { return issue }
        let reason: Reason
        switch error {
        case UsageError.invalidResponse, SessionError.invalidResponse, is DecodingError: reason = .unsupportedResponse
        case UsageError.missingCLI, UsageError.claudeCLIUnavailable: reason = .missingClient
        case SessionOpeningError.unavailableConfiguredCodex: reason = .clientPathUnavailable
        case SessionOpeningError.missingCLI(_:): reason = .missingClient
        case UsageError.timeout, SessionError.timeout: reason = .timedOut
        case UsageError.notSignedIn: reason = .signInRequired
        case UsageError.claudeSignInRequired: reason = .setupRequired
        case UsageError.statusLineDisabled, SessionError.disabled: reason = .disabled
        case SessionError.changedConfig: reason = .configurationChanged
        case UsageError.waitingForClaude: reason = .waitingForData
        case UsageError.claudeQuotaStale: reason = .staleData
        default: reason = .sourceUnavailable
        }
        return Self(provider: provider, capability: capability, reason: reason)
    }
    /// Compatibility for snapshots persisted before typed diagnostics existed.
    /// Only exact app-owned messages are recognized; arbitrary text stays private.
    public static func legacy(_ text: String?, provider: ProviderID, capability: Capability) -> Self? {
        guard let text else { return nil }
        let known: [UsageError] = [.invalidResponse, .missingCLI, .timeout, .notSignedIn, .waitingForClaude,
            .statusLineDisabled, .claudeQuotaStale, .claudeCLIUnavailable, .claudeSignInRequired, .claudeUsageUnavailable]
        if let error = known.first(where: { $0.errorDescription == text }) { return classify(error, provider: provider, capability: capability) }
        // Typed messages contain only fixed strings and can be recognized when an
        // older snapshot surface still persists its issue as a string.
        let reasons: [Reason] = [.unsupportedResponse, .unsupportedOperation, .missingClient, .clientPathUnavailable,
            .timedOut, .signInRequired, .setupRequired, .disabled, .configurationChanged, .waitingForData, .staleData, .sourceUnavailable, .incompleteCatalog]
        return reasons.first { Self(provider: provider, capability: capability, reason: $0).message == text }
            .map { Self(provider: provider, capability: capability, reason: $0) }
    }
}

/// Checks only the fields consumed by Lunavect's documented local interfaces.
/// Unknown extra fields and future status values do not invent a capability or
/// cause a version guess; absent optional quotas stay absent.
public enum ClientResponseContract {
    private static func unsupported(_ provider: ProviderID, _ capability: ClientIntegrationIssue.Capability) -> ClientIntegrationIssue {
        ClientIntegrationIssue(provider: provider, capability: capability, reason: .unsupportedResponse)
    }
    public static func codexResult(_ message: [String: Any], capability: ClientIntegrationIssue.Capability) throws -> [String: Any] {
        if let error = message["error"], !(error is NSNull) {
            guard let object = error as? [String: Any], let code = object["code"] as? Int else { throw unsupported(.codex, capability) }
            throw ClientIntegrationIssue(provider: .codex, capability: capability,
                                         reason: code == -32601 ? .unsupportedOperation : .sourceUnavailable)
        }
        guard let result = message["result"] as? [String: Any] else { throw unsupported(.codex, capability) }
        return result
    }
    public static func validateCodexThreadList(_ result: [String: Any]) throws {
        guard let rows = result["data"] as? [[String: Any]] else { throw unsupported(.codex, .sessionCatalog) }
        if let cursor = result["nextCursor"], !(cursor is NSNull), !(cursor is String) { throw unsupported(.codex, .sessionCatalog) }
        for row in rows {
            guard let id = row["id"] as? String, SessionParser.validID(id) else { throw unsupported(.codex, .sessionCatalog) }
            if let status = row["status"], !(status is NSNull) {
                guard let object = status as? [String: Any], object["type"] is String else { throw unsupported(.codex, .sessionCatalog) }
            }
        }
    }
    public static func validateCodexRateLimits(_ result: [String: Any]) throws {
        guard result.keys.contains("rateLimits") || result.keys.contains("rateLimitsByLimitId") else { throw unsupported(.codex, .rateLimits) }
        for key in ["rateLimits", "rateLimitsByLimitId"] {
            if let value = result[key], !(value is NSNull), !(value is [String: Any]) { throw unsupported(.codex, .rateLimits) }
        }
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        if let value = buckets?["codex"], !(value is NSNull), !(value is [String: Any]) { throw unsupported(.codex, .rateLimits) }
        let legacy = result["rateLimits"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? legacy.flatMap { (($0["limitId"] as? String) == nil || ($0["limitId"] as? String) == "codex") ? $0 : nil }
        guard let bucket else { throw ClientIntegrationIssue(provider: .codex, capability: .rateLimits, reason: .waitingForData) }
        for key in ["primary", "secondary"] {
            if let value = bucket[key], !(value is NSNull), !(value is [String: Any]) { throw unsupported(.codex, .rateLimits) }
        }
    }
    public static func claudeRateLimits(_ root: [String: Any]) throws -> [String: Any]? {
        guard let value = root["rate_limits"], !(value is NSNull) else { return nil }
        guard let limits = value as? [String: Any] else { throw unsupported(.claude, .statusLine) }
        var hasWindow = false
        for key in ["five_hour", "seven_day"] {
            guard let window = limits[key], !(window is NSNull) else { continue }
            guard window is [String: Any] else { throw unsupported(.claude, .statusLine) }
            hasWindow = true
        }
        return hasWindow ? limits : nil
    }
}


/// An allowlist, not a scrubbed copy of logs. No session objects or CLI output
/// can enter a shareable report.
public struct ConnectionDiagnostic: Codable, Equatable, Identifiable {
    public enum Repair: String {
        case install, signIn, events, refresh, reviewUsage, checkSignIn, reviewClient, chooseClient
        public var title: String {
            switch self {
            case .reviewClient: return "Открыть инструкцию клиента"
            case .chooseClient: return "Выбрать клиент"
            case .install: return "Установить компонент"
            case .signIn: return "Войти снова"
            case .events: return "Восстановить события"
            case .refresh: return "Обновить данные"
            case .reviewUsage: return "Завершить настройку Claude Code"
            case .checkSignIn: return "Проверить вход"
            }
        }
    }
    public enum State: String, Codable {
        case missingClient, signedOut, authUnknown, sourceError, unsupportedResponse, unsupportedOperation,
            clientPathUnavailable, waitingForQuota, staleQuota, eventsMissing, incompleteCatalog, ready
    }
    public let provider: ProviderID
    public let clientFound: Bool
    public let eventsConfigured: Bool
    public let state: State
    public let quotaAgeMinutes: Int?
    public let errorCode: String?
    public let sourceIssue: ClientIntegrationIssue?
    public var id: ProviderID { provider }

    public init(provider: ProviderID, clientFound: Bool, signIn: ClientConnection.SignInState,
                eventsConfigured: Bool, snapshot: UsageSnapshot?, sessionIssue: String?, now: Date = Date(),
                sourceIssue: ClientIntegrationIssue? = nil) {
        self.provider = provider; self.clientFound = clientFound; self.eventsConfigured = eventsConfigured
        let typed = sourceIssue?.provider == provider ? sourceIssue : nil
        self.sourceIssue = typed
        quotaAgeMinutes = snapshot?.fetchedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
        let issue = snapshot?.issue
        // Exact known values only. Raw provider errors can contain personal paths.
        let known: [(UsageError, String)] = [(.timeout, "timeout"), (.invalidResponse, "unsupported_response"),
            (.notSignedIn, "sign_in_required"), (.claudeSignInRequired, "claude_setup_required"),
            (.claudeUsageUnavailable, "claude_usage_unavailable"), (.statusLineDisabled, "events_disabled"),
            (.claudeQuotaStale, "stale_quota"), (.waitingForClaude, "waiting_for_quota"),
            (.missingCLI, "missing_client"), (.claudeCLIUnavailable, "missing_client")]
        let compatibilityIssue = ClientIntegrationIssue.legacy(issue, provider: provider, capability: provider == .codex ? .rateLimits : .usageProbe)
            ?? ClientIntegrationIssue.legacy(sessionIssue, provider: provider, capability: .sessionCatalog)
        let effectiveIssue = typed ?? compatibilityIssue
        errorCode = typed?.code ?? issue.map { value in known.first { $0.0.errorDescription == value }?.1 ?? "source_error" }
            ?? (sessionIssue == nil ? nil : "session_source_error")
        if effectiveIssue?.reason == .clientPathUnavailable { state = .clientPathUnavailable }
        else if !clientFound { state = .missingClient }
        else if signIn == .signedOut { state = .signedOut }
        else if effectiveIssue?.reason == .unsupportedResponse { state = .unsupportedResponse }
        else if effectiveIssue?.reason == .unsupportedOperation { state = .unsupportedOperation }
        else if effectiveIssue?.reason == .incompleteCatalog { state = .incompleteCatalog }
        else if signIn == .unavailable { state = .authUnknown }
        else if effectiveIssue?.reason == .waitingForData { state = .waitingForQuota }
        else if effectiveIssue?.reason == .staleData { state = .staleQuota }
        else if let typed, ![.waitingForData, .staleData].contains(typed.reason) { state = .sourceError }
        else if let issue, issue != UsageError.waitingForClaude.errorDescription && issue != UsageError.claudeQuotaStale.errorDescription { state = .sourceError }
        else if snapshot?.hasQuota != true { state = .waitingForQuota }
        else if snapshot?.isStale(now: now) != false { state = .staleQuota }
        else if !eventsConfigured || sessionIssue != nil { state = .eventsMissing }
        else { state = .ready }
    }
    public var title: String {
        switch state {
        case .unsupportedResponse: return "Формат ответа клиента пока не поддерживается"
        case .unsupportedOperation: return "Операция недоступна в этом клиенте"
        case .clientPathUnavailable: return "Выбранный клиент недоступен"
        case .missingClient: return "Официальный клиент не найден"
        case .signedOut: return "Нужен вход в аккаунт"
        case .authUnknown: return "Клиент не подтвердил состояние входа"
        case .sourceError: return "Источник не передал свежие данные"
        case .waitingForQuota: return "Ждём первые лимиты"
        case .staleQuota: return "Сохранённые лимиты устарели"
        case .eventsMissing: return "Нужно проверить события сессий"
        case .incompleteCatalog: return "Каталог сессий получен не полностью"
        case .ready: return "Подключение работает"
        }
    }
    public var repair: Repair? {
        switch state {
        case .unsupportedResponse, .unsupportedOperation: return .reviewClient
        case .clientPathUnavailable: return .chooseClient
        case .missingClient: return .install
        case .signedOut: return .signIn
        case .authUnknown: return .checkSignIn
        case .eventsMissing: return eventsConfigured ? .refresh : .events
        case .sourceError:
            if let sourceIssue { return sourceIssue.repair }
            if errorCode == "claude_setup_required" { return .reviewUsage }
            if errorCode == "sign_in_required" { return .signIn }
            if errorCode == "events_disabled" { return .events }
            return .refresh
        case .waitingForQuota, .staleQuota, .incompleteCatalog: return .refresh
        case .ready: return nil
        }
    }
    public var guidance: String {
        switch state {
        case .unsupportedResponse, .unsupportedOperation:
            return "Проверьте обновления официального клиента и Lunavect. До поддержки этого формата сохранённые данные остаются на месте; повторный вход не требуется."
        case .clientPathUnavailable:
            return "Проверьте выбранный путь в «Подключениях». Другой клиент не будет подставлен автоматически."
        case .missingClient, .signedOut, .authUnknown: return "Продолжим с нужного шага. Уже выполненную настройку повторять не нужно."
        case .sourceError: return "Проверьте интернет и официальный клиент. Повторная проверка запросит лимиты заново. Сохранённые значения остаются на месте."
        case .waitingForQuota, .staleQuota: return "Повторите проверку. Если данные не появятся, откройте мастер подключения и завершите настройку клиента."
        case .incompleteCatalog: return "Известные сессии сохранены. Обновите каталог, чтобы получить остальные сессии и их свежий статус."
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
