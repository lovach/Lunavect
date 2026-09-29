import Foundation

/// What an unattended task may do without asking; nobody is there to answer.
public enum TaskPermission: String, Codable, CaseIterable, Sendable, Identifiable {
    /// File edits in the task's folder and safe commands; anything else is refused.
    case careful
    /// Claude's auto mode (a classifier reviews actions); Codex's workspace sandbox with network.
    case auto
    /// No checks at all. Only when the user chose it for this task.
    case full
    public var id: String { rawValue }
}

/// When a queued task starts.
public enum TaskStart: String, Codable, CaseIterable, Sendable, Identifiable {
    case now, afterFiveHourReset, afterWeeklyReset
    public var id: String { rawValue }
}

public enum TaskState: String, Codable, Sendable {
    case queued, running, wrappingUp, paused, done, failed, needsYou, cancelled
    public var isActive: Bool { self == .running || self == .wrappingUp }
    public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

/// Why a task stopped before it finished.
public enum TaskPause: String, Codable, Sendable {
    /// It used its share of this week.
    case budget
    /// The five-hour window reached the guard.
    case fiveHour
    /// The provider reported the limit reached.
    case limitReached
    /// The user paused it, or Lunavect quit while it ran.
    case user
}

/// A saved state of the task's copy: nothing it did is lost.
public struct TaskCheckpoint: Codable, Equatable, Sendable {
    public var commit: String
    public var date: Date
    public var reason: String
    public init(commit: String, date: Date, reason: String) { self.commit = commit; self.date = date; self.reason = reason }
}

/// One task Lunavect runs for the user within a share of the weekly limit.
public struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: ProviderID
    public var prompt: String
    /// The project folder the user chose.
    public var folder: String
    public var permission: TaskPermission
    /// Percent of the weekly limit the task may use in one week.
    public var weekBudget: Double
    /// Pause when the five-hour window reaches this percent; nil leaves the window alone.
    public var fiveHourGuard: Double?
    public var start: TaskStart
    /// Work in a separate git worktree so the user's folder does not change until they accept.
    public var isolate: Bool
    /// Continue by itself after the limit resets.
    public var autoResume: Bool

    public var state: TaskState = .queued
    public var pause: TaskPause?
    /// Claude session id or Codex thread id; the conversation continues from it.
    public var sessionID: String?
    public var worktree: String?
    public var branch: String?
    public var baseCommit: String?
    public var repository: String?
    public var checkpoints: [TaskCheckpoint] = []
    /// Estimated percent of the weekly limit used in the current week, and when that week ends.
    public var spent: Double = 0
    public var spentWeekEnds: Date?
    /// Price-weighted tokens of the task since it was created.
    public var weight: Double = 0
    public var tokens = TokenCounts()
    /// The agent's last summary: what is done, what is left.
    public var handoff: String?
    public var message: String?
    public var resumeAt: Date?
    public var createdAt: Date
    public var startedAt: Date?
    public var updatedAt: Date

    public init(id: UUID = UUID(), provider: ProviderID, prompt: String, folder: String, permission: TaskPermission = .careful,
                weekBudget: Double = 10, fiveHourGuard: Double? = 90, start: TaskStart = .now, isolate: Bool = true, autoResume: Bool = true,
                now: Date = Date()) {
        self.id = id; self.provider = provider; self.prompt = prompt; self.folder = folder; self.permission = permission
        self.weekBudget = weekBudget; self.fiveHourGuard = fiveHourGuard; self.start = start; self.isolate = isolate; self.autoResume = autoResume
        createdAt = now; updatedAt = now
    }
    /// The first line of the prompt, for lists.
    public var title: String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
    /// Where the agent works: the task's copy, or the folder itself.
    public var workingDirectory: String { worktree ?? folder }
    public var project: String { URL(fileURLWithPath: folder).lastPathComponent }
    /// Spent share of this task's weekly budget, 0...1.
    public var budgetUsed: Double { weekBudget > 0 ? min(1, spent / weekBudget) : 0 }
}

/// What the budget allows next. Pure, so the whole policy is testable.
public enum TaskBudget {
    public enum Decision: Equatable, Sendable { case proceed, wrapUp, stop(TaskPause) }
    /// The agent is asked to wrap up at this share of its budget, then stopped at the budget.
    public static let wrapShare = 0.8

    public static func decide(spent: Double, budget: Double, fiveHourUsed: Double?, fiveHourGuard: Double?,
                              limitReached: Bool, wrappingUp: Bool) -> Decision {
        if limitReached { return .stop(.limitReached) }
        if let guardValue = fiveHourGuard, let used = fiveHourUsed, used >= guardValue { return wrappingUp ? .stop(.fiveHour) : .wrapUp }
        if spent >= budget { return .stop(.budget) }
        if !wrappingUp, spent >= budget * wrapShare { return .wrapUp }
        return .proceed
    }

    /// Percent of the weekly limit per price-weighted token, from this week's used percent
    /// and the tokens the ledger saw in the same week. nil until both are known.
    public static func percentPerWeight(ledger: TokenLedger, provider: ProviderID, week: QuotaWindow?, now: Date) -> Double? {
        guard let week, let resets = week.resetsAt, week.usedPercent > 0 else { return nil }
        let weight = ledger.weight(provider, from: resets.addingTimeInterval(-Double(week.durationMinutes) * 60), to: now)
        return weight > 0 ? week.usedPercent / weight : nil
    }

    /// When a paused task may continue: its budget comes back with the next week, the window after five hours.
    public static func resumeDate(for pause: TaskPause, week: QuotaWindow?, fiveHour: QuotaWindow?) -> Date? {
        switch pause {
        case .budget: return week?.resetsAt
        case .fiveHour: return fiveHour?.resetsAt
        case .limitReached: return [fiveHour, week].compactMap { $0 }.filter { $0.isUsedUp }.compactMap(\.resetsAt).max() ?? fiveHour?.resetsAt
        case .user: return nil
        }
    }
}

/// What Lunavect says to the agent. The agent reads English best and answers in the task's language.
public enum TaskMessages {
    public static func wrapUp(_ reason: TaskPause) -> String {
        let why = reason == .fiveHour ? "The five-hour usage window is almost used up." : "This task's usage budget is almost used up."
        return why + " Finish the step you are on, do not start new work, and stop. In your final reply, summarise in a few lines: what is done, what is left, and where to continue. Your work and this conversation are saved and will be continued later."
    }
    public static let resume = "Continue the task from where you stopped. Your earlier work is saved in this folder and in this conversation."
}

/// Command lines and requests that start, continue and steer a task.
public enum TaskCommands {
    /// `claude -p` with streamed JSON both ways: the prompt and later messages go in on stdin.
    public static func claudeArguments(_ task: AgentTask, sessionID: String, resume: Bool) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         resume ? "--resume" : "--session-id", sessionID, "--permission-prompts", "none"]
        switch task.permission {
        case .careful: arguments += ["--permission-mode", "acceptEdits"]
        case .auto: arguments += ["--permission-mode", "auto"]
        case .full: arguments += ["--permission-mode", "bypassPermissions"]
        }
        return arguments
    }
    public static func claudeUserMessage(_ text: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text]]
    }
    public static let claudeInterrupt: [String: Any] = ["type": "control_request", "request_id": "lunavect-interrupt", "request": ["subtype": "interrupt"]]

    /// Codex app-server `thread/start` or `thread/resume` parameters.
    public static func codexThreadParameters(_ task: AgentTask, resume: String?) -> [String: Any] {
        var parameters: [String: Any] = ["cwd": task.workingDirectory, "approvalPolicy": "never"]
        switch task.permission {
        case .careful: parameters["sandbox"] = "workspace-write"
        case .auto:
            parameters["sandbox"] = "workspace-write"
            parameters["config"] = ["sandbox_workspace_write.network_access": true]
        case .full: parameters["sandbox"] = "danger-full-access"
        }
        if let resume { parameters["threadId"] = resume }
        return parameters
    }
    public static func codexInput(_ text: String) -> [[String: Any]] { [["type": "text", "text": text]] }
}

/// The tasks and where they are saved.
public struct AgentTaskList: Codable, Equatable, Sendable {
    public var tasks: [AgentTask] = []
    public init() {}
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/tasks.json")
    }
    /// Copies of projects for tasks live here, outside the user's folders.
    public static var worktreesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/Worktrees")
    }
    public static func load(from url: URL = fileURL) throws -> AgentTaskList {
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentTaskList() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: LocalStateRecovery.read(from: url, maximumBytes: 8_000_000))
    }
    public func save(to url: URL = fileURL) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalStateRecovery.write(encoder.encode(self), to: url, synchronize: false)
    }
}

/// Git steps of a task's copy, as argument lists for `/usr/bin/git`.
public enum TaskGit {
    public static func branch(for task: AgentTask) -> String {
        let slug = task.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { result, character in
            if character != "-" || result.last != "-" { result.append(character) }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "lunavect/" + String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "-" + task.id.uuidString.prefix(6).lowercased()
    }
    /// A copy of the repository at its current commit; the folder keeps the project's name for statistics.
    public static func worktreePath(for task: AgentTask, repository: String, root: URL = AgentTaskList.worktreesURL) -> String {
        root.appendingPathComponent(String(task.id.uuidString.prefix(8)).lowercased()).appendingPathComponent(URL(fileURLWithPath: repository).lastPathComponent).path
    }
    public static func addWorktree(repository: String, path: String, branch: String) -> [String] {
        ["-C", repository, "worktree", "add", "-b", branch, path, "HEAD"]
    }
    /// Used only when the repository has no author of its own; the user's identity otherwise.
    static let fallbackIdentity = ["-c", "user.name=Lunavect", "-c", "user.email=tasks@lunavect.local"]
    /// Saves everything the agent changed as one commit on the task's branch, never elsewhere.
    public static func checkpoint(worktree: String, message: String, hasIdentity: Bool) -> [[String]] {
        [["-C", worktree, "add", "-A"],
         ["-C", worktree] + (hasIdentity ? [] : fallbackIdentity) + ["commit", "--no-verify", "-q", "-m", message]]
    }
    public static func merge(repository: String, branch: String, title: String, hasIdentity: Bool) -> [String] {
        ["-C", repository] + (hasIdentity ? [] : fallbackIdentity) + ["merge", "--no-ff", "-m", "Lunavect: " + title, branch]
    }
    public static func removeWorktree(repository: String, path: String) -> [[String]] {
        [["-C", repository, "worktree", "remove", "--force", path]]
    }
}
