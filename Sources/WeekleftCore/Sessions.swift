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
    /// Retained background waits and completed entries are history without live presence.
    /// Their task phase remains intact; autonomous working tasks can outlive a process.
    public var catalogHistory: Bool?
    /// Codex's internal child/review/compaction agents are part of their parent
    /// task, not independently openable user conversations. Nil supports old records.
    public var isCodexSubagent: Bool?
    /// A Claude runtime launched inside another agent runtime, rather than an independent task.
    /// Explicit false permits a later independent resume; nil retains known origin.
    public var isNestedClaudeSession: Bool?
    public var turnStartedAt: Date?
    /// A live Codex process still owns this unfinished turn's writable log.
    /// Kept separate from event time: polling must not rewrite task history.
    public var runtimeObservedAt: Date?
    /// Task evidence survives SessionEnd even when the initial prompt hook was missed.
    public var hasTaskActivity: Bool?
    /// A conservative local inference from Claude's final response, not an open
    /// permission dialog. Keep only the result; never persist the response text.
    public var responseRequestsInput: Bool?
    /// Only the lifecycle trigger is retained, never compaction instructions or summary.
    public var compactionTrigger: String?
    /// Controlling terminal of a CLI session (for example /dev/ttys003) and its
    /// terminal application, used only to bring the existing tab to the front.
    public var terminalTTY: String?
    public var terminalApp: String?
    public var isUnstartedClaudeLifecycle: Bool {
        provider == .claude && (evidence == .hook || hasTaskActivity == false) && turnStartedAt == nil &&
        hasTaskActivity != true && (phase == .idle || phase == .finished)
    }
    public var activityPath: String?
    public var id: String { provider.rawValue + ":" + sessionID }
    public var project: String { cwd.contains("/scratch-workspaces/") ? L("Без папки") : cwd.isEmpty ? L("Без проекта") : URL(fileURLWithPath: cwd).lastPathComponent }
    /// Source names stay intact. Missing names are localized only for display,
    /// including hook records written by the standalone helper without resources.
    public var displayTitle: String { displayTitle(language: L10n.selection) }
    public func displayTitle(language: String) -> String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if !cwd.isEmpty && !cwd.contains("/scratch-workspaces/") { return project }
        return L10n.text(provider == .claude ? "Сессия Claude" : "Сессия Codex", language: language)
    }
    public var activityTitle: String {
        guard phase == .running else { return phase.title }
        if compactionTrigger != nil { return L("Сжимает контекст") }
        switch tool?.lowercased() {
        case "bash", "shell", "exec_command": return L("Выполняет команду")
        case "read", "readfile": return L("Читает файл")
        case "edit", "write", "apply_patch": return L("Изменяет файлы")
        case nil, "": return L("Думает")
        default: return L("Выполняет {0}", tool!)
        }
    }
    public init(
        provider: ProviderID, sessionID: String, title: String, cwd: String, client: SessionClient = .unknown,
        phase: SessionPhase, updatedAt: Date, observedAt: Date, evidence: SessionEvidence = .catalog,
        tool: String? = nil, resumeID: String? = nil, runtimeConfirmed: Bool? = nil
    ) {
        self.provider = provider; self.sessionID = sessionID; self.title = title; self.cwd = cwd
        self.client = client; self.phase = phase; self.updatedAt = updatedAt; self.observedAt = observedAt
        self.evidence = evidence; self.tool = tool; self.resumeID = resumeID
        self.runtimeConfirmed = runtimeConfirmed
    }
    public func effectivePhase(now: Date = Date()) -> SessionPhase {
        let age = now.timeIntervalSince(observedAt)
        guard runtimeConfirmed != false else { return .unknown }
        if provider == .codex, evidence == .localEvent, phase == .running,
           age >= -60, let runtimeObservedAt {
            let runtimeAge = now.timeIntervalSince(runtimeObservedAt)
            if runtimeAge >= 0 && runtimeAge < 10 { return phase }
        }
        // This is an observation, not a heartbeat or proof a process still exists.
        let lifetime: TimeInterval = evidence == .catalog ? 60 : evidence == .localEvent && phase.isActive ? 120 : 600
        guard age >= -60, age < lifetime else { return .unknown }
        return phase
    }
    public func isCurrent(now: Date = Date()) -> Bool {
        let phase = effectivePhase(now: now)
        return isCodexSubagent != true && isNestedClaudeSession != true && !isUnstartedClaudeLifecycle && catalogHistory != true && phase != .unknown && phase != .finished
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
    static func codexSubagent(source: Any?, parentThreadID: Any? = nil) -> Bool {
        if let parent = parentThreadID as? String, validID(parent) { return true }
        // The app-server protocol uses subAgent; persisted local metadata uses
        // subagent. Classify explicit origin only, never names or shared folders.
        guard let source = source as? [String: Any] else { return false }
        return ["subAgent", "subagent"].contains { key in
            source[key].map { !($0 is NSNull) } ?? false
        }
    }
    /// ASCII letters, digits, `_` and `-`. Called for every record on each poll,
    /// so compare bytes instead of building a CharacterSet per character.
    public static func validID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
        }
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
            var session = AgentSession(
                provider: .codex, sessionID: id, title: codexTitle(row["name"]), cwd: cwd, client: client, phase: phase,
                updatedAt: (row["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
                observedAt: now, runtimeConfirmed: phase != .unknown)
            session.activityPath = row["path"] as? String
            session.isCodexSubagent = codexSubagent(source: row["source"], parentThreadID: row["parentThreadId"]) ? true : nil
            return session
        }
    }
    public static func claude(_ data: Data, now: Date = Date(), nestedRuntime: (Int32) -> Bool? = { _ in nil }) throws -> [AgentSession] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SessionError.invalidResponse }
        return rows.compactMap { row in
            guard let id = (row["sessionId"] ?? row["id"]) as? String, validID(id) else { return nil }
            let cwd = row["cwd"] as? String ?? ""
            let background = row["kind"] as? String == "background"
            let status = row["status"] as? String
            let waiting = row["waitingFor"] as? String
            let waitingPhase: SessionPhase = ["permission prompt", "sandbox request"].contains(waiting) ? .permission : .input
            let phase: SessionPhase
            // Background task state includes autonomous waits between steps. An
            // idle process does not mean that task has finished.
            if background, let state = row["state"] as? String {
                switch state {
                case "working": phase = status == "waiting" ? waitingPhase : .running
                case "blocked": phase = waitingPhase
                case "done": phase = .ready
                case "failed": phase = .failed
                case "stopped": phase = .interrupted
                default: phase = .unknown
                }
            } else {
                switch status {
                case "busy": phase = .running
                case "waiting": phase = waitingPhase
                case "idle": phase = .idle
                default: phase = .unknown
                }
            }
            let activity = (row["updatedAt"] as? Double ?? row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            var session = AgentSession(
                provider: .claude, sessionID: id, title: text(row["name"]), cwd: cwd,
                client: background ? .background : .unknown, phase: phase, updatedAt: activity, observedAt: now,
                resumeID: row["id"] as? String, runtimeConfirmed: phase == .unknown ? false : nil)
            if background {
                // Official detached tasks have attach routes and supervisor processes.
                session.isNestedClaudeSession = false
            } else if let pid = row["pid"] as? Int, pid > 1, let safePID = Int32(exactly: pid) {
                session.isNestedClaudeSession = nestedRuntime(safePID)
            }
            let livePresence = ["busy", "waiting", "idle"].contains(status) || (row["pid"] as? Int ?? 0) > 0
            session.catalogHistory = background && ["blocked", "done", "failed", "stopped"].contains(row["state"] as? String) && !livePresence
            return session
        }
    }
}
public enum SessionList {
    public static func merge(catalog: [AgentSession], events: [AgentSession], now: Date = Date()) -> [AgentSession] {
        var result = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        for event in events.sorted(by: { $0.observedAt < $1.observedAt }) where now.timeIntervalSince(event.observedAt) < 86400 {
            if var row = result[event.id] {
                if event.isCodexSubagent == true { row.isCodexSubagent = true }
                // Only hooks know the terminal a CLI session runs in; catalog rows never carry it.
                if let tty = event.terminalTTY { row.terminalTTY = tty; row.terminalApp = event.terminalApp }
                if row.client == .unknown, event.client != .unknown { row.client = event.client }
                if row.provider == .claude, row.client == .background {
                    row.isNestedClaudeSession = false
                } else if row.isNestedClaudeSession == nil || (event.isNestedClaudeSession != nil && event.observedAt > row.observedAt) {
                    row.isNestedClaudeSession = event.isNestedClaudeSession
                }
                let fresh = event.effectivePhase(now: now) != .unknown
                // Reading a persisted blocked task again does not refresh its
                // runtime presence or supersede an independently fresh hook.
                let dormantClaudeWait = row.provider == .claude && row.catalogHistory == true && [.input, .permission].contains(row.phase)
                // An idle process is expected after a final response asking for
                // a decision. It cannot dismiss that question. Busy/waiting and
                // terminal catalog states still supersede the earlier response.
                let idleAfterQuestion = fresh && row.phase == .idle && event.phase == .input && event.responseRequestsInput == true
                let idleDuringCompaction = fresh && row.phase == .idle && event.compactionTrigger != nil
                let newerClaudeCatalog = row.provider == .claude && !dormantClaudeWait && !idleAfterQuestion && !idleDuringCompaction && row.phase != .unknown && row.observedAt > event.observedAt
                let moreSpecificApproval = !newerClaudeCatalog && row.effectivePhase(now: now) == .input && event.phase == .permission
                if fresh && !newerClaudeCatalog && (idleAfterQuestion || idleDuringCompaction || dormantClaudeWait || row.effectivePhase(now: now) == .unknown || event.observedAt >= row.observedAt || moreSpecificApproval) {
                    row.phase = event.phase; row.observedAt = event.observedAt; row.evidence = event.evidence; row.tool = event.tool
                    row.runtimeConfirmed = event.runtimeConfirmed
                    row.catalogHistory = nil
                    row.turnStartedAt = event.turnStartedAt
                    row.runtimeObservedAt = event.runtimeObservedAt
                    row.hasTaskActivity = event.isUnstartedClaudeLifecycle ? false : event.hasTaskActivity
                    row.responseRequestsInput = event.responseRequestsInput
                    row.compactionTrigger = event.compactionTrigger
                    row.updatedAt = max(row.updatedAt, event.updatedAt)
                } else if newerClaudeCatalog && row.effectivePhase(now: now) != .unknown {
                    // A fresh idle interactive process ends the unfinished hook
                    // turn, but cannot prove successful completion (Esc has no Stop).
                    if row.phase == .idle {
                        if event.phase.isActive { row.phase = .interrupted }
                        else if [.ready, .interrupted, .failed].contains(event.phase) { row.phase = event.phase }
                    }
                    // A newer catalog poll must not turn a startup-only hook
                    // into a user task. This also handles pre-marker hook files.
                    row.hasTaskActivity = event.isUnstartedClaudeLifecycle ? false : event.hasTaskActivity
                    if row.phase == .running && event.phase == .running {
                        row.turnStartedAt = event.turnStartedAt
                        if fresh { row.compactionTrigger = event.compactionTrigger }
                    }
                }
                if fresh && event.client != .unknown && row.client != .background { row.client = event.client }
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
                (query.isEmpty
                    || [session.displayTitle, session.project, session.cwd, session.provider.title].contains {
                        $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                    })
        }
    }
}
public struct SessionRecord: Codable, Sendable {
    public var session: AgentSession
    public var pendingApprovals: Set<String> = []
    public var unidentifiedApproval: Bool?
    public var approvalVersion: Int?
    public static func event(_ data: Data, provider: ProviderID, previous: SessionRecord?, now: Date = Date(), client: SessionClient = .unknown) throws -> SessionRecord {
        guard data.count <= 1_000_000, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = payload["session_id"] as? String, SessionParser.validID(id),
            let name = payload["hook_event_name"] as? String
        else { throw SessionError.invalidResponse }
        let cwd = payload["cwd"] as? String ?? previous?.session.cwd ?? ""
        var record = previous ?? SessionRecord(session: AgentSession(provider: provider, sessionID: id, title: "", cwd: cwd, phase: .unknown, updatedAt: now, observedAt: now, evidence: .hook))
        guard record.session.sessionID == id, record.session.provider == provider else { throw SessionError.invalidResponse }
        if record.session.observedAt > now {
            // Preserve ordering for concurrently delivered hooks, but rebase after
            // a substantial wall-clock correction so Stop is never lost for hours.
            guard record.session.observedAt.timeIntervalSince(now) > 300 else { return record }
            record.session.turnStartedAt = nil
            record.pendingApprovals = []
            record.unidentifiedApproval = nil
        }
        if record.approvalVersion != 2 {
            // Older records mixed IDs and tool names in the same set. Retain
            // their wait conservatively until progress, without guessing which
            // strings are real IDs or leaving a tool-name wait stuck forever.
            if !record.pendingApprovals.isEmpty { record.unidentifiedApproval = true }
            record.pendingApprovals = []
            record.approvalVersion = 2
        }
        let tool = SessionParser.text(payload["tool_name"])
        let toolID = SessionParser.text(payload["tool_use_id"])
        switch name {
        case "SessionStart":
            if provider == .claude, payload["source"] as? String == "compact", let trigger = record.session.compactionTrigger {
                record.session.phase = trigger == "auto" ? .running : .idle
                if trigger == "manual" { record.session.turnStartedAt = nil }
                break
            }
            // Hooks run concurrently: startup may finish after the first prompt/tool event.
            if previous?.session.effectivePhase(now: now).isActive == true { return record }
            record.pendingApprovals = []; record.unidentifiedApproval = nil; record.session.phase = .idle
        case "UserPromptSubmit": record.pendingApprovals = []; record.unidentifiedApproval = nil; record.session.phase = .running; record.session.turnStartedAt = now
        case "PreCompact", "PostCompact":
            guard provider == .claude, let trigger = payload["trigger"] as? String, ["manual", "auto"].contains(trigger) else { throw SessionError.invalidResponse }
            record.pendingApprovals = []; record.unidentifiedApproval = nil
            if name == "PreCompact" {
                record.session.phase = .running
                record.session.compactionTrigger = trigger
                if trigger == "manual" { record.session.turnStartedAt = now }
            } else {
                record.session.phase = trigger == "auto" ? .running : .idle
                if trigger == "manual" { record.session.turnStartedAt = nil }
            }
        case "PermissionRequest":
            if toolID.isEmpty { record.unidentifiedApproval = true }
            else { record.pendingApprovals.insert(toolID) }
            record.session.phase = .permission
        case "Notification":
            guard let type = payload["notification_type"] as? String, ["permission_prompt", "idle_prompt", "elicitation_dialog"].contains(type) else { throw SessionError.invalidResponse }
            if type == "permission_prompt" {
                if record.pendingApprovals.isEmpty { record.unidentifiedApproval = true }
                record.session.phase = .permission
            }
            else if type == "idle_prompt" {
                // Reminder about an already finished response, not a new request.
                // Do not refresh stale work evidence from a delayed notification.
                if previous != nil { return record }
                record.session.phase = .idle
            } else { record.session.phase = .input }
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            if name != "PreToolUse" {
                record.pendingApprovals.remove(toolID)
                // Migrate tool-name/unknown keys written by older versions.
                record.pendingApprovals.remove(tool); record.pendingApprovals.remove("unknown")
                record.unidentifiedApproval = nil
            }
            record.session.phase = record.pendingApprovals.isEmpty && record.unidentifiedApproval != true ? .running : .permission
        case "Stop":
            record.pendingApprovals = []; record.unidentifiedApproval = nil
            let asksForReply = provider == .claude && ClaudeResponseQuestion.requiresReply(payload["last_assistant_message"] as? String)
            record.session.responseRequestsInput = asksForReply ? true : nil
            record.session.phase = asksForReply ? .input : .ready
        case "SessionEnd": record.pendingApprovals = []; record.unidentifiedApproval = nil; record.session.phase = .finished
        case "Interrupt": record.pendingApprovals = []; record.unidentifiedApproval = nil; record.session.phase = .interrupted
        case "StopFailure": record.pendingApprovals = []; record.unidentifiedApproval = nil; record.session.phase = .failed
        default: throw SessionError.invalidResponse
        }
        if name != "Stop" { record.session.responseRequestsInput = nil }
        if name != "PreCompact" { record.session.compactionTrigger = nil }
        if name != "SessionStart" && name != "SessionEnd" {
            record.session.hasTaskActivity = true
        } else if provider == .claude && record.session.hasTaskActivity == nil && record.session.turnStartedAt == nil {
            record.session.hasTaskActivity = false
        }
        record.session.cwd = cwd; record.session.observedAt = now; record.session.updatedAt = now
        record.session.runtimeConfirmed = true
        if record.session.phase == .running && record.session.turnStartedAt == nil { record.session.turnStartedAt = now }
        record.session.tool = name == "PreToolUse" && !tool.isEmpty ? tool : nil
        if client != .unknown { record.session.client = client }
        return record
    }
}

/// Stop means generation ended, even when the assistant explicitly asks the
/// user to choose or approve its next step. This deliberately narrow heuristic
/// examines closing prose, not arbitrary question marks, quotes or code. Unknown
/// wording stays `ready`; structured permission/input events remain authoritative.
enum ClaudeResponseQuestion {
    private static let requests = [
        #"^(?:делаем|делаю|продолжаем|продолжать|начинаем|начинаю|начинать|запускаем|запускаю|запускать|применяем|применить|вносим|внести|отправляем|отправить|публикуем|публиковать|подтверждаете)\b[^?？]*[?？]"#,
        #"^(?:можно\s+(?:мне\s+)?(?:начать|продолжить|запустить|применить|внести|отправить|опубликовать)|какой\s+вариант\s+(?:выбираем|выбираете|выбрать))\b[^?？]*[?？]"#,
        #"^(?:пожалуйста[, ]+)?(?:подтвердите|подтверди|выберите|выбери|уточните|уточни|скажите|скажи)\b"#,
        #"^жду\s+(?:вашего|твоего)\s+(?:ответа|решения|подтверждения|выбора)\b"#,
        #"^(?:shall|should|may|can)\s+(?:i|we)\s+(?:proceed|continue|start|apply|run|send|publish|implement|make|do)\b[^?？]*[?？]"#,
        #"^(?:please\s+)?(?:confirm|choose|select|clarify|let me know which)\b"#,
        #"^which\s+(?:option|version|approach)\s+(?:do you|should we|would you)\b[^?？]*[?？]"#,
        #"^(?:soll|darf)\s+(?:ich|wir)\b[^?？]*[?？]"#,
        #"^(?:bitte\s+)?(?:bestätige|bestätigen sie|wähle|wählen sie)\b"#,
        #"^(?:можно\s+(?:мне\s+)?(?:скачать|установить|обновить|открыть|проверить|сохранить))\b[^?？]*[?？]"#,
        #"^(?:(?:этот|эту|эти|такой|такую|такие)\s+)?(?:хук|ролик|вариант|версию|правки|изменения|план|дизайн|макет)(?:\s+\d+(?:[–—-]\d+)?)?\s+(?:принимаем|оставляем|утверждаем|согласовываем)\s*[?？]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func requiresReply(_ message: String?) -> Bool {
        guard let message, message.utf8.count <= 128_000 else { return false }
        var fence: String?
        var closingLines: [String] = []
        for raw in message.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
                closingLines.append("")
            } else if fence == nil {
                // Preserve boundaries so a trailing example cannot expose an
                // earlier question as if it were the closing request.
                // Inline paths/code are not prose, but surrounding requests still are.
                // Keep the line boundary so examples never become requests.
                closingLines.append(line.hasPrefix(">") || line.hasPrefix("|") ? "" :
                    line.replacingOccurrences(of: #"`+[^`]*`+"#, with: "", options: .regularExpression))
            }
        }
        while closingLines.last == "" { closingLines.removeLast() }
        for raw in closingLines.suffix(6) {
            let line = raw.replacingOccurrences(of: #"^(?:[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if requests.contains(where: { $0.firstMatch(in: line, range: range) != nil }) { return true }
        }
        return false
    }
}
