import Foundation

/// What the user asked Lunavect to do with one running session (owner decisions 30.09):
/// stop it when the week reaches a level, rest it before the 5-hour window runs out,
/// and continue it later with a message.
public struct SessionControl: Codable, Equatable, Identifiable, Sendable {
    public enum Resume: String, Codable, CaseIterable, Sendable, Identifiable {
        /// After the weekly reset: the week's level only falls then.
        case afterWeeklyReset
        case afterFiveHourReset
        /// At a time the user chose.
        case at
        /// After the window that cut the session off resets.
        case afterLimitReset
        public var id: String { rawValue }
    }
    public enum State: String, Codable, Sendable {
        /// Under the limit, or waiting for its time.
        case watching
        /// Close to the limit: the agent was asked to finish its step.
        case wrappingUp
        /// At the week's limit: new actions are refused.
        case stopped
        /// The 5-hour window is nearly used up: new actions are refused until it resets,
        /// then the session continues by itself.
        case resting
        /// The provider's limit cut the session off; the user is asked whether to continue it after the reset.
        case offered
        /// The message was delivered; nothing left to do.
        case continued
        /// The message could not be typed into the session; the user was told.
        case needsYou
    }
    /// Which limit a wrap-up or stop belongs to.
    public enum Reason: String, Codable, Sendable { case week, fiveHour }

    public var id: String { TokenLedger.sessionKey(provider, sessionID) }
    public var provider: ProviderID
    public var sessionID: String
    public var title: String
    public var cwd: String
    /// Stop when the weekly limit reaches this percent; nil only continues later.
    public var stopAtWeek: Double?
    /// The week's level when the limit was set, to ask for a wrap-up in proportion.
    public var startLevel: Double?
    /// Continue after the weekly reset when the week stopped the session.
    public var continueAfterWeek: Bool?
    /// Wrap up before the 5-hour window runs out and continue after its reset.
    public var fiveHourGuard: Bool?
    /// The 5-hour guard waits until this date: the user continued a resting session.
    public var guardOffUntil: Date?
    /// What to type when continuing; nil types `defaultMessage`.
    public var message: String?
    public var resume: Resume?
    /// A continuation is due at this time.
    public var resumeAt: Date?
    public var reason: Reason?
    public var state: State = .watching
    public var note: String?
    /// The agent's last reply after it stopped: what it did and what is left.
    public var summary: String?
    public var summaryAt: Date?
    /// Where the session ran, to continue it when its row is gone.
    public var client: SessionClient?
    public var terminalApp: String?
    /// The limit failure this control answers: the session's time then.
    public var cutOffAt: Date?
    /// Claude Code waits for Enter after the reset (the Mac slept through it): continuing presses Enter only.
    public var pressEnter: Bool?
    /// Claude Code itself continues after the limit that cut the resting session off: nothing to type.
    public var nativeContinue: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(provider: ProviderID, sessionID: String, title: String, cwd: String, stopAtWeek: Double? = nil, startLevel: Double? = nil,
                message: String? = nil, resume: Resume? = nil, resumeAt: Date? = nil, now: Date = Date()) {
        self.provider = provider; self.sessionID = sessionID; self.title = title; self.cwd = cwd
        self.stopAtWeek = stopAtWeek; self.startLevel = startLevel; self.message = message; self.resume = resume; self.resumeAt = resumeAt
        createdAt = now; updatedAt = now
    }

    /// The message Lunavect types when the user left the field empty.
    public static var defaultMessage: String { L("Продолжай с того места, где остановился.") }
    public var text: String { pressEnter == true ? "" : message ?? Self.defaultMessage }
    /// The 5-hour window's level for a wrap-up and for the rest: the provider cuts off at 100 %,
    /// and the estimate between readings needs a margin.
    public static let fiveHourWrap = 88.0, fiveHourRest = 96.0

    /// Where the week stands on the way to this limit: proceed, wrap up or stop.
    /// The wrap-up comes at 80 % of the distance from where the limit was set, at least one point before it.
    public func decide(weekLevel: Double) -> State { decide(weekLevel: weekLevel, fiveHourLevel: nil, now: .distantPast).state }

    /// The week's stop comes first, then the 5-hour rest, then a wrap-up for either.
    public func decide(weekLevel: Double?, fiveHourLevel: Double?, now: Date) -> (state: State, reason: Reason?) {
        var week = State.watching
        if let stop = stopAtWeek, let weekLevel {
            let start = min(startLevel ?? weekLevel, stop)
            let wrapAt = min(stop - 1, start + (stop - start) * 0.8)
            week = weekLevel >= stop ? .stopped : weekLevel >= wrapAt ? .wrappingUp : .watching
        }
        var five = State.watching
        if fiveHourGuard == true, (guardOffUntil ?? .distantPast) <= now, let fiveHourLevel {
            five = fiveHourLevel >= Self.fiveHourRest ? .resting : fiveHourLevel >= Self.fiveHourWrap ? .wrappingUp : .watching
        }
        if week == .stopped { return (.stopped, .week) }
        if five == .resting { return (.resting, .fiveHour) }
        if week == .wrappingUp { return (.wrappingUp, .week) }
        if five == .wrappingUp { return (.wrappingUp, .fiveHour) }
        return (.watching, nil)
    }

    /// The level that spreads the rest of the week evenly over the days left: today's share.
    public static func suggestedStop(level: Double, resetsAt: Date?, now: Date) -> Double {
        guard let resetsAt, resetsAt > now else { return min(100, (level + 10).rounded()) }
        let days = max(1, (resetsAt.timeIntervalSince(now) / 86400).rounded(.up))
        return min(100, max(level + 1, level + (100 - level) / days).rounded(.up))
    }

    /// "Done: …" and "Left: …" from the agent's reply when it followed the wrap-up request.
    public static func summaryParts(_ text: String) -> (done: String, left: String)? {
        let done = L("Сделано:"), left = L("Осталось:")
        guard let doneRange = text.range(of: done), let leftRange = text.range(of: left, range: doneRange.upperBound..<text.endIndex) else { return nil }
        let first = text[doneRange.upperBound..<leftRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let second = text[leftRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty || second.isEmpty ? nil : (first, second)
    }
}

/// A limit window's level now: the last reading plus what the ledger saw since, in its percent per weighted token.
public enum WeekLevel {
    public static func estimate(snapshot: UsageSnapshot?, ledger: TokenLedger, now: Date) -> Double? {
        estimate(snapshot: snapshot, window: snapshot?.weekly, ledger: ledger, now: now)
    }
    public static func estimate(snapshot: UsageSnapshot?, window: QuotaWindow?, ledger: TokenLedger, now: Date) -> Double? {
        guard let snapshot, let window else { return nil }
        // The window has reset since the reading: the new one starts near zero until the next reading.
        if let resets = window.resetsAt, resets <= now { return 0 }
        // Until the ledger has read every log once, its share of the window is partial and the ratio too high.
        guard ledger.caughtUp == true, let fetched = snapshot.fetchedAt, fetched < now,
              let ratio = percentPerWeight(ledger: ledger, provider: snapshot.provider, week: window, now: fetched) else { return window.usedPercent }
        let since = ledger.weight(snapshot.provider, from: fetched, to: now)
        return min(100, window.usedPercent + since * ratio)
    }
    /// Percent of a limit window per price-weighted token, from its used percent and the tokens
    /// the ledger saw in the same window up to `now` (the reading's time). nil until both are known.
    public static func percentPerWeight(ledger: TokenLedger, provider: ProviderID, week: QuotaWindow?, now: Date) -> Double? {
        guard let week, let resets = week.resetsAt, week.usedPercent > 0 else { return nil }
        let weight = ledger.weight(provider, from: resets.addingTimeInterval(-Double(week.durationMinutes) * 60), to: now)
        return weight > 0 ? week.usedPercent / weight : nil
    }
    /// When a used-up limit of the provider resets: the latest of its used-up windows.
    public static func limitReset(_ snapshot: UsageSnapshot?, now: Date) -> Date? {
        guard let snapshot else { return nil }
        let windows = [snapshot.fiveHour, snapshot.weekly].compactMap { $0 } + (snapshot.modelQuotas ?? []).map(\.window)
        return windows.filter(\.isUsedUp).compactMap(\.resetsAt).filter { $0 > now }.max()
    }
}

/// Claude Code's `autoContinueAtUsageLimit` (on by default since 2.1.234): after a claude.ai usage
/// limit it waits in the open session and continues by itself. Managed settings first, then the user's.
public enum ClaudeAutoContinue {
    public static func enabled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               managed: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")) -> Bool {
        for file in [managed, home.appendingPathComponent(".claude/settings.json")] {
            guard let data = try? Data(contentsOf: file), data.count < 5_000_000,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["autoContinueAtUsageLimit"] as? Bool else { continue }
            return value
        }
        return true
    }
}

/// The part hooks read: only sessions that need an answer, keyed by provider and session id.
public struct SessionLimitFile: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var state: SessionControl.State
        /// What the agent reads with its refused or reminded action.
        public var agent: String
        /// What the agent reads with the user's own message to a stopped session, which lifts the stop.
        public var continued: String?
        /// The entry lapses then (the window's reset): a stop never outlives its limit when Lunavect is not running.
        public var until: Date?
        public init(state: SessionControl.State, agent: String, continued: String? = nil, until: Date? = nil) {
            self.state = state; self.agent = agent; self.continued = continued; self.until = until
        }
    }
    public var entries: [String: Entry] = [:]
    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public static var fileURL: URL { SessionHooks.directory.appendingPathComponent("limits.json") }
    public static func load(from url: URL = fileURL) -> SessionLimitFile {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 1_000_000 else { return SessionLimitFile() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? SessionLimitFile()
    }
    public func save(to url: URL = fileURL) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The hook's reply for one event: `{}` for every session the user did not limit.
    /// Claude Code and Codex read the same shapes: PreToolUse denies with a reason the
    /// agent sees or adds context. The user's own message (UserPromptSubmit) is never
    /// blocked: in a stopped session it lifts the stop (owner 30.09), noted in `overridden`
    /// until Lunavect removes the entry. Claude Code's own continuation after a usage limit
    /// (`automatic`) is not the user's decision: a week's stop holds it back, a rest lets it go.
    public func reply(payload: Data, now: Date = Date(), overridden: Set<String> = [], automatic: Bool = false) -> String {
        guard !entries.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object["hook_event_name"] as? String, let session = object["session_id"] as? String else { return "{}" }
        let provider: ProviderID? = entries[TokenLedger.sessionKey(.claude, session)] != nil ? .claude
            : entries[TokenLedger.sessionKey(.codex, session)] != nil ? .codex : nil
        guard let provider, let entry = entries[TokenLedger.sessionKey(provider, session)],
              entry.until.map({ $0 > now }) ?? true else { return "{}" }
        let lifted = overridden.contains(TokenLedger.sessionKey(provider, session))
        let reply: [String: Any]?
        switch (event, entry.state) {
        case ("PreToolUse", .stopped), ("PreToolUse", .resting):
            reply = lifted ? nil : ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": entry.agent]]
        case ("PreToolUse", .wrappingUp):
            reply = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "additionalContext": entry.agent]]
        case ("UserPromptSubmit", .stopped) where automatic:
            reply = ["decision": "block", "reason": entry.agent]
        case ("UserPromptSubmit", .resting) where automatic:
            reply = nil
        case ("UserPromptSubmit", .stopped), ("UserPromptSubmit", .resting):
            reply = entry.continued.map { ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": $0]] }
        case ("UserPromptSubmit", .wrappingUp):
            reply = ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": entry.agent]]
        default: reply = nil
        }
        guard let reply, let data = try? JSONSerialization.data(withJSONObject: reply) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension SessionLimitFile {
    /// The hook's side of a limit: the reply, and a note when the user's message lifts a stop.
    /// `limitWait` reads the session's own record: Claude Code's last wait for a usage limit and when it ended.
    static func answer(payload: Data, limits: URL = fileURL, overrides: URL = SessionLimitOverrides.fileURL, now: Date = Date(),
                       limitWait: (String) -> (kind: String, at: Date)? = SessionLimitFile.recordedLimitWait) -> String {
        let file = load(from: limits)
        guard !file.entries.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object["hook_event_name"] as? String, let session = object["session_id"] as? String,
              let key = [TokenLedger.sessionKey(.claude, session), TokenLedger.sessionKey(.codex, session)].first(where: { file.entries[$0] != nil }),
              let entry = file.entries[key], [.stopped, .resting].contains(entry.state) else { return file.reply(payload: payload, now: now) }
        let automatic = event == "UserPromptSubmit" && key.hasPrefix(ProviderID.claude.rawValue + ":")
            && isAutomaticContinuation(object["prompt"] as? String, wait: limitWait(session), now: now)
        var noted = SessionLimitOverrides.load(from: overrides)
        if event == "UserPromptSubmit", !automatic, entry.until.map({ $0 > now }) ?? true {
            noted.sessions[key] = now
            try? noted.save(to: overrides)
        }
        return file.reply(payload: payload, now: now, overridden: Set(noted.sessions.keys), automatic: automatic)
    }
    /// Claude Code's own continuation after a usage limit: it sends a fixed prompt through UserPromptSubmit, with
    /// no field saying so (docs: interactive mode, "Wait for a usage limit to reset"; the texts are 2.1.283's).
    /// Also any prompt within two minutes after Claude Code reported that wait ending (`quota_auto_resume_fired`
    /// or `_stale`, recorded by the Notification hook).
    static func isAutomaticContinuation(_ prompt: String?, wait: (kind: String, at: Date)?, now: Date) -> Bool {
        let text = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Your claude.ai usage limit has reset.") || text.hasPrefix("Your claude.ai usage is available again") { return true }
        guard let wait, ["fired", "stale"].contains(wait.kind) else { return false }
        let since = now.timeIntervalSince(wait.at)
        return since >= 0 && since < 120
    }
    static func recordedLimitWait(_ session: String) -> (kind: String, at: Date)? {
        let url = SessionHooks.directory.appendingPathComponent("claude-\(session).json")
        guard SessionParser.validID(session), let data = try? Data(contentsOf: url), data.count < 65536,
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              let kind = record.session.limitWait, let at = record.session.limitWaitAt else { return nil }
        return (kind, at)
    }
}

/// Stopped sessions the user wrote to: the hook lets the message and the agent's next
/// actions through, and Lunavect lifts the stop on its next pass and removes the note.
public struct SessionLimitOverrides: Codable, Equatable, Sendable {
    public var sessions: [String: Date] = [:]
    public init(sessions: [String: Date] = [:]) { self.sessions = sessions }
    public static var fileURL: URL { SessionHooks.directory.appendingPathComponent("limit-overrides.json") }
    public static func load(from url: URL = fileURL) -> SessionLimitOverrides {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 1_000_000 else { return SessionLimitOverrides() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? SessionLimitOverrides()
    }
    public func save(to url: URL = fileURL) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The saved controls, and the cut-offs the user declined.
public struct SessionControlList: Codable, Equatable, Sendable {
    public var controls: [SessionControl] = []
    /// Session id → the cut-off time the user said no to, so it is not offered again.
    public var declined: [String: Date]?
    public init() {}
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/session-controls.json")
    }
    public static func load(from url: URL = fileURL) throws -> SessionControlList {
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionControlList() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: LocalStateRecovery.read(from: url, maximumBytes: 4_000_000))
    }
    public func save(to url: URL = fileURL) throws {
        try LiveWriteGuard.check(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalStateRecovery.write(encoder.encode(self), to: url, synchronize: false)
    }
}

/// The agent's last reply in its own log: the end of a Claude transcript or a Codex rollout.
public enum SessionReply {
    /// Reads at most the last 512 KB; an API error line (a limit message) is not a reply.
    public static func last(in url: URL, provider: ProviderID) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > 524_288 ? size - 524_288 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            // The end of a long reply: the agent's "Done/Left" lines close it.
            if let text = reply(object, provider: provider) { return text.count > 1200 ? "…" + String(text.suffix(1200)) : text }
        }
        return nil
    }
    static func reply(_ object: [String: Any], provider: ProviderID) -> String? {
        switch provider {
        case .claude:
            guard object["type"] as? String == "assistant", object["isApiErrorMessage"] as? Bool != true, object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return nil }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case .codex:
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            let text: String?
            switch (object["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "agent_message"): text = payload["message"] as? String
            // Codex 0.159 writes no agent_message events: the turn's end and the assistant's message carry the reply.
            case ("event_msg", "task_complete"): text = payload["last_agent_message"] as? String
            case ("response_item", "message") where payload["role"] as? String == "assistant":
                text = (payload["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            default: text = nil
            }
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return nil
        }
    }
}

/// Continuing a session in Terminal or iTerm2: in its own tab while the agent is there,
/// with the client's resume command when the tab went back to the shell or is gone.
public extension TerminalLocation {
    /// One line of the message, at most 500 characters, quoted for AppleScript.
    static func typedText(_ text: String) -> String { scriptLine(String(text.prefix(500))) }
    /// One line quoted for AppleScript, whole: a command is never cut inside its quotes.
    static func scriptLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    /// A string for the shell, in single quotes.
    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// `claude --resume <id> '<text>'` or `codex resume <id> '<text>'`, from the session's folder when given.
    static func resumeCommand(provider: ProviderID, sessionID: String, text: String, cwd: String? = nil) -> String? {
        guard sessionID.range(of: #"^[A-Za-z0-9-]{8,80}\z"#, options: .regularExpression) != nil else { return nil }
        var line = String(text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(500))
        // A message starting with "-" would be read as an option.
        if line.hasPrefix("-") { line = " " + line }
        let command: String
        switch provider {
        case .claude: command = "claude --resume " + sessionID + " " + shellQuoted(line)
        case .codex: command = "codex resume " + sessionID + " " + shellQuoted(line)
        default: return nil
        }
        guard let cwd, cwd.hasPrefix("/"), !cwd.contains("\n"), !cwd.contains("\r") else { return command }
        return "cd " + shellQuoted(cwd) + " && " + command
    }
    /// Programs that mean the agent still runs in the tab, and shells that mean it exited. The native
    /// Claude installer runs a binary named by its version ("2.1.283"): a name starting with a digit counts too.
    static let agentProcesses = ["claude", "claude.exe", "codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin", "node", "bun"]
    static let shellProcesses = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "login"]

    /// Finds the tab by its tty: types `text` while the agent runs there, `command` at a shell prompt.
    /// `false` when the tab is gone or runs something else.
    /// Codex reads fast input as a paste, where Return is a new line (live check 30.09): `submitAgain`
    /// presses Return once more after a pause so the message is sent. Terminal ends `do script` with a
    /// line feed, which Claude Code's fullscreen interface takes as a new line (live check 30.09): `carriageReturn`
    /// ends the text with the carriage return a real Enter sends.
    /// `agentAllowed` false: the session's agent is gone from the device, so a program there is someone else's.
    /// A closed terminal app has no tab to type into: the script does not launch it, since a launched Terminal
    /// opens a new window that can get the old tab's device; the new-window path opens it with the command instead.
    /// `titleContains`: the tab was found only by the session's folder, so it must also carry the session's
    /// name in its title (Codex titles its tab "<thread name> | <folder>").
    static func typeScript(tty: String, app: String, text: String, command: String? = nil, agent: String? = nil, submitAgain: Bool = false,
                           carriageReturn: Bool = false, agentAllowed: Bool = true, titleContains: String? = nil) -> String? {
        guard valid(tty) else { return nil }
        let terminalTitle = titleContains.map { " and ((custom title of t) contains \"\(scriptLine($0))\")" } ?? ""
        let itermTitle = titleContains.map { " and ((name of s) contains \"\(scriptLine($0))\")" } ?? ""
        let typed = typedText(text), resume = command.map(scriptLine)
        let names = agentAllowed ? agentProcesses + (agent.map { [scriptLine($0)] } ?? []) : []
        let agents = names.map { "\"\($0)\"" }.joined(separator: ", "), shells = shellProcesses.map { "\"\($0)\"" }.joined(separator: ", ")
        let versioned = agentAllowed ? "(count of pn) > 0 and \"0123456789\" contains (character 1 of pn)" : "false"
        let versionedJob = agentAllowed ? "((count of job) > 0 and \"0123456789\" contains (character 1 of job))" : "false"
        let terminalShell = resume.map { "if {\(shells)} contains ((last item of names) as text) then\ndo script \"\($0)\" in t\nreturn true\nend if" } ?? ""
        let itermShell = resume.map { "if {\(shells)} contains job then\ntell s to write text \"\($0)\"\nreturn true\nend if" } ?? ""
        switch app {
        case "Terminal":
            return """
            if application "Terminal" is not running then return false
            with timeout of \(focusTimeout) seconds
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)"\(terminalTitle) and (count of processes of t) > 0 then
                            set names to processes of t
                            set agentRuns to false
                            repeat with p in names
                                set pn to p as text
                                if {\(agents)} contains pn then set agentRuns to true
                                if \(versioned) then set agentRuns to true
                            end repeat
                            if agentRuns then
                                do script \(carriageReturn ? "(\"\(typed)\" & return)" : "\"\(typed)\"") in t
                                \(submitAgain ? "delay 0.6\ndo script \"\" in t" : "")
                                return true
                            end if
                            \(terminalShell)
                            return false
                        end if
                    end repeat
                end repeat
            end tell
            end timeout
            return false
            """
        case "iTerm2":
            return """
            if application "iTerm2" is not running then return false
            with timeout of \(focusTimeout) seconds
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)"\(itermTitle) then
                                set job to ""
                                try
                                    tell s to set job to (variable named "jobName")
                                end try
                                if {\(agents)} contains job or \(versionedJob) then
                                    tell s to write text \(carriageReturn ? "(\"\(typed)\" & return) newline no" : "\"\(typed)\"")
                                    \(submitAgain ? "delay 0.6\ntell s to write text \"\"" : "")
                                    return true
                                end if
                                \(itermShell)
                                return false
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            end timeout
            return false
            """
        default: return nil
        }
    }
    /// A new window of `app` (Terminal when unknown) running `command` in a login shell.
    static func openScript(app: String, command: String) -> String {
        let typed = scriptLine(command)
        if app == "iTerm2" {
            return """
            with timeout of \(focusTimeout) seconds
            tell application "iTerm2"
                set w to (create window with default profile)
                tell current session of w to write text "\(typed)"
            end tell
            end timeout
            return true
            """
        }
        return """
        with timeout of \(focusTimeout) seconds
        tell application "Terminal" to do script "\(typed)"
        end timeout
        return true
        """
    }
    /// Types `text` and Return into the tab; false when the tab is gone.
    static func type(_ text: String, tty: String, app: String, command: String? = nil, agentPID: Int32? = nil, provider: ProviderID,
                     titleContains: String? = nil, timeout: TimeInterval = Double(focusTimeout)) async throws -> Bool {
        // The session's own runtime names its process exactly, whatever the installer called the binary.
        let agent = agentPID.flatMap(SessionProcess.runtimeProcess).map { URL(fileURLWithPath: $0.executable).lastPathComponent }
        // macOS gives a closed tab's device to the next tab, and the user may have started another agent or
        // program there: type the message only while this session's runtime (its recorded process when known)
        // runs on the device. An interpreter alone counts only for Claude, whose npm install runs under node.
        let occupancy = occupancy(of: tty, provider: provider, runtimePID: agentPID)
        let agentAllowed = occupancy == .provider || occupancy == .unknown || (occupancy == .interpreter && provider == .claude)
        guard let source = typeScript(tty: tty, app: app, text: text, command: command, agent: agent, submitAgain: provider == .codex,
                                      carriageReturn: provider == .claude, agentAllowed: agentAllowed, titleContains: titleContains) else {
            throw SessionOpeningError.terminalFocusFailed(app)
        }
        return try await executeFocusScript(source, app: app, timeout: timeout)
    }
    static func open(_ command: String, app: String, timeout: TimeInterval = Double(focusTimeout)) async throws -> Bool {
        let target = app == "iTerm2" ? "iTerm2" : "Terminal"
        return try await executeFocusScript(openScript(app: target, command: command), app: target, timeout: timeout)
    }
}
