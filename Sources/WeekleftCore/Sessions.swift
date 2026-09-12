import Foundation

public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    case running, permission, input, idle, ready, finished, interrupted, failed, unknown
    public var title: String {
        switch self {
        case .running: return L("Работает")
        case .permission: return L("Нужно разрешение")
        case .input: return L("Ждёт ответа")
        case .idle: return L("Готова к работе")
        case .ready: return L("Ответ готов")
        case .finished: return L("Завершена")
        case .interrupted: return L("Остановлена")
        case .failed: return L("Ошибка")
        case .unknown: return L("Нет свежего статуса")
        }
    }
    public var isActive: Bool { [.running, .permission, .input].contains(self) }
    public var priority: Int {
        switch self {
        case .permission, .input: return 0
        case .running: return 1
        case .failed: return 2
        case .idle, .ready, .interrupted: return 3
        case .unknown: return 4
        case .finished: return 5
        }
    }
}
public enum SessionClient: String, Codable, Sendable {
    case desktop, terminal, vscode, background, unknown
    public var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .background: return L("Фоновая сессия")
        case .unknown: return L("Клиент не указан")
        }
    }
    public var symbol: String {
        switch self {
        case .desktop: return "macwindow"
        case .terminal: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .background: return "arrow.triangle.2.circlepath"
        case .unknown: return "desktopcomputer"
        }
    }
}
public enum SessionEvidence: String, Codable, Sendable { case catalog, hook, legacy, localEvent }

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var client: SessionClient
    public var phase: SessionPhase
    public var updatedAt: Date
    public var observedAt: Date
    public var evidence: SessionEvidence
    public var tool: String?
    public var resumeID: String?
    // A catalog entry alone is not proof that a session is still open.
    public var runtimeConfirmed: Bool?
    public var turnStartedAt: Date?
    /// Task evidence survives SessionEnd even when the initial prompt hook was missed.
    public var hasTaskActivity: Bool?
    public var isUnstartedClaudeLifecycle: Bool {
        provider == .claude && evidence == .hook && turnStartedAt == nil &&
        hasTaskActivity != true && (phase == .idle || phase == .finished)
    }
    public var activityPath: String?
    public var id: String { provider.rawValue + ":" + sessionID }
    public var project: String { cwd.contains("/scratch-workspaces/") ? L("Без папки") : cwd.isEmpty ? L("Без проекта") : URL(fileURLWithPath: cwd).lastPathComponent }
    public var activityTitle: String {
        guard phase == .running else { return phase.title }
        switch tool?.lowercased() {
        case "bash", "shell", "exec_command": return L("Выполняет команду")
        case "read", "readfile": return L("Читает файл")
        case "edit", "write", "apply_patch": return L("Изменяет файлы")
        case nil, "": return L("Думает")
        default: return L("Выполняет {0}", tool!)
        }
    }
    public init(provider: ProviderID, sessionID: String, title: String, cwd: String, client: SessionClient = .unknown, phase: SessionPhase, updatedAt: Date, observedAt: Date, evidence: SessionEvidence = .catalog, tool: String? = nil, resumeID: String? = nil, runtimeConfirmed: Bool? = nil) {
        self.provider = provider; self.sessionID = sessionID; self.title = title; self.cwd = cwd
        self.client = client; self.phase = phase; self.updatedAt = updatedAt; self.observedAt = observedAt
        self.evidence = evidence; self.tool = tool; self.resumeID = resumeID
        self.runtimeConfirmed = runtimeConfirmed
    }
    public func effectivePhase(now: Date = Date()) -> SessionPhase {
        let age = now.timeIntervalSince(observedAt)
        guard runtimeConfirmed != false else { return .unknown }
        // This is an observation, not a heartbeat or proof a process still exists.
        let lifetime: TimeInterval = evidence == .catalog ? 60 : evidence == .localEvent && phase.isActive ? 120 : 600
        guard age >= -60, age < lifetime else { return .unknown }
        return phase
    }
    public func isCurrent(now: Date = Date()) -> Bool {
        let phase = effectivePhase(now: now)
        return phase != .unknown && phase != .finished
    }
}
public enum SessionError: LocalizedError {
    case invalidResponse, timeout, unavailable, disabled, changedConfig
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Источник вернул неизвестный формат данных."
        case .timeout: return "Источник не ответил вовремя."
        case .unavailable: return "Не найден подходящий CLI. Проверьте установку приложения."
        case .disabled: return "Обработчики событий выключены в настройках источника."
        case .changedConfig: return "Настройки изменились во время подключения. Повторите действие."
        }
    }
}
public enum SessionParser {
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }
    static func text(_ value: Any?, fallback: String = "") -> String {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return String(text.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(240))
    }
    static func codexTitle(_ value: Any?, fallback: String = "") -> String {
        guard var title = value as? String else { return fallback }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("# Files mentioned by the user:") {
            // Extract before the display length limit: file metadata can be long.
            // A previously truncated envelope has no usable task name.
            guard let request = title.range(of: "\n## My request:\n") else { return fallback }
            title = String(title[request.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text(title, fallback: fallback)
    }
    public static func codex(_ data: Data, now: Date = Date()) throws -> [AgentSession] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = root["data"] as? [[String: Any]] else { throw SessionError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, validID(id) else { return nil }
            let cwd = row["cwd"] as? String ?? ""
            let status = row["status"] as? [String: Any] ?? [:], flags = status["activeFlags"] as? [String] ?? []
            let phase: SessionPhase
            switch status["type"] as? String {
            case "active": phase = flags.contains("waitingOnApproval") ? .permission : flags.contains("waitingOnUserInput") ? .input : .running
            case "idle": phase = .idle
            case "systemError": phase = .failed
            default: phase = .unknown
            }
            // Desktop versions also persist "vscode"; that field alone cannot identify the host.
            let client: SessionClient = row["source"] as? String == "cli" ? .terminal : .unknown
            var session = AgentSession(provider: .codex, sessionID: id, title: codexTitle(row["name"], fallback: cwd.isEmpty ? L("Сессия Codex") : URL(fileURLWithPath: cwd).lastPathComponent), cwd: cwd, client: client, phase: phase, updatedAt: (row["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast, observedAt: now, runtimeConfirmed: phase != .unknown)
            session.activityPath = row["path"] as? String
            return session
        }
    }
    public static func claude(_ data: Data, now: Date = Date()) throws -> [AgentSession] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SessionError.invalidResponse }
        return rows.compactMap { row in
            guard let id = (row["sessionId"] ?? row["id"]) as? String, validID(id) else { return nil }
            let cwd = row["cwd"] as? String ?? ""
            let phase: SessionPhase
            switch row["state"] as? String {
            case "running", "working", "busy": phase = .running
            case "blocked": phase = .input
            case "idle", "waiting": phase = .idle
            case "completed", "exited": phase = .finished
            case "errored", "failed": phase = .failed
            default: phase = .unknown
            }
            // Background rows can survive for months with state=blocked and no worker.
            // Only interactive discovery or our live lifecycle events establish presence.
            let activity = (row["updatedAt"] as? Double ?? row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            return AgentSession(provider: .claude, sessionID: id, title: text(row["name"], fallback: cwd.isEmpty ? L("Сессия Claude") : URL(fileURLWithPath: cwd).lastPathComponent), cwd: cwd, client: row["kind"] as? String == "background" ? .background : .unknown, phase: phase, updatedAt: activity, observedAt: now, resumeID: row["id"] as? String, runtimeConfirmed: row["kind"] as? String == "interactive")
        }
    }
}
public enum SessionList {
    public static func merge(catalog: [AgentSession], events: [AgentSession], now: Date = Date()) -> [AgentSession] {
        var result = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        for event in events.sorted(by: { $0.observedAt < $1.observedAt }) where now.timeIntervalSince(event.observedAt) < 86400 {
            if var row = result[event.id] {
                let fresh = event.effectivePhase(now: now) != .unknown
                let moreSpecificApproval = row.effectivePhase(now: now) == .input && event.phase == .permission
                if fresh && (row.effectivePhase(now: now) == .unknown || event.observedAt >= row.observedAt || moreSpecificApproval) {
                    row.phase = event.phase; row.observedAt = event.observedAt; row.evidence = event.evidence; row.tool = event.tool
                    row.runtimeConfirmed = event.runtimeConfirmed
                    row.turnStartedAt = event.turnStartedAt
                    row.hasTaskActivity = event.hasTaskActivity
                    row.updatedAt = max(row.updatedAt, event.updatedAt)
                }
                if fresh && event.client != .unknown { row.client = event.client }
                result[event.id] = row
            } else { result[event.id] = event }
        }
        return result.values.sorted {
            let a = $0.effectivePhase(now: now).priority, b = $1.effectivePhase(now: now).priority
            if a != b { return a < b }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
    public static func filter(_ sessions: [AgentSession], query: String, provider: ProviderID?, activeOnly: Bool, now: Date = Date(), includeHistory: Bool = false) -> [AgentSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            (includeHistory || session.isCurrent(now: now)) &&
            (provider == nil || session.provider == provider) &&
            (!activeOnly || session.effectivePhase(now: now).isActive) &&
            (query.isEmpty || [session.title, session.project, session.cwd, session.provider.title].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
}
public struct SessionRecord: Codable, Sendable {
    public var session: AgentSession
    public var pendingApprovals: Set<String> = []
    public static func event(_ data: Data, provider: ProviderID, previous: SessionRecord?, now: Date = Date(), client: SessionClient = .unknown) throws -> SessionRecord {
        guard data.count <= 1_000_000, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = payload["session_id"] as? String, SessionParser.validID(id), let name = payload["hook_event_name"] as? String else { throw SessionError.invalidResponse }
        let cwd = payload["cwd"] as? String ?? previous?.session.cwd ?? ""
        var record = previous ?? SessionRecord(session: AgentSession(provider: provider, sessionID: id, title: cwd.isEmpty ? L(provider == .claude ? "Сессия Claude" : "Сессия Codex") : URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd, phase: .unknown, updatedAt: now, observedAt: now, evidence: .hook))
        guard record.session.sessionID == id, record.session.provider == provider else { throw SessionError.invalidResponse }
        if record.session.observedAt > now { return record }
        let tool = SessionParser.text(payload["tool_name"])
        let toolID = SessionParser.text(payload["tool_use_id"], fallback: tool.isEmpty ? "unknown" : tool)
        switch name {
        case "SessionStart":
            // Hooks run concurrently: startup may finish after the first prompt/tool event.
            if previous?.session.effectivePhase(now: now).isActive == true { return record }
            record.pendingApprovals = []; record.session.phase = .idle
        case "UserPromptSubmit": record.pendingApprovals = []; record.session.phase = .running; record.session.turnStartedAt = now
        case "PermissionRequest": record.pendingApprovals.insert(toolID); record.session.phase = .permission
        case "Notification":
            guard let type = payload["notification_type"] as? String, ["permission_prompt", "idle_prompt", "elicitation_dialog"].contains(type) else { throw SessionError.invalidResponse }
            if type == "permission_prompt" {
                if record.pendingApprovals.isEmpty { record.pendingApprovals.insert(toolID) }
                record.session.phase = .permission
            }
            else { record.session.phase = .input }
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            if name != "PreToolUse" { record.pendingApprovals.remove(toolID); record.pendingApprovals.remove(tool) }
            record.session.phase = record.pendingApprovals.isEmpty ? .running : .permission
        case "Stop": record.pendingApprovals = []; record.session.phase = .ready
        case "SessionEnd": record.pendingApprovals = []; record.session.phase = .finished
        case "Interrupt": record.pendingApprovals = []; record.session.phase = .interrupted
        case "StopFailure": record.pendingApprovals = []; record.session.phase = .failed
        default: throw SessionError.invalidResponse
        }
        if name != "SessionStart" && name != "SessionEnd" {
            record.session.hasTaskActivity = true
        }
        record.session.cwd = cwd; record.session.observedAt = now; record.session.updatedAt = now
        record.session.runtimeConfirmed = true
        if record.session.phase == .running && record.session.turnStartedAt == nil { record.session.turnStartedAt = now }
        record.session.tool = name == "PreToolUse" && !tool.isEmpty ? tool : nil
        if client != .unknown { record.session.client = client }
        return record
    }
}
