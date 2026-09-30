import Foundation

/// What the user asked Lunavect to do with one running session (owner decisions 30.09):
/// stop it when the week reaches a level, and continue it later with a message.
public struct SessionControl: Codable, Equatable, Identifiable, Sendable {
    public enum Resume: String, Codable, CaseIterable, Sendable, Identifiable {
        /// After the weekly reset: the week's level only falls then.
        case afterWeeklyReset
        case afterFiveHourReset
        /// At a time the user chose.
        case at
        public var id: String { rawValue }
    }
    public enum State: String, Codable, Sendable {
        /// Under the limit, or waiting for its time.
        case watching
        /// Close to the limit: the agent was asked to finish its step.
        case wrappingUp
        /// At the limit: new actions are refused.
        case stopped
        /// The message was delivered; nothing left to do.
        case continued
        /// The message could not be typed into the session; the user was told.
        case needsYou
    }
    public var id: String { TokenLedger.sessionKey(provider, sessionID) }
    public var provider: ProviderID
    public var sessionID: String
    public var title: String
    public var cwd: String
    /// Stop when the weekly limit reaches this percent; nil only continues later.
    public var stopAtWeek: Double?
    /// The week's level when the limit was set, to ask for a wrap-up in proportion.
    public var startLevel: Double?
    /// Continue the session with this message; nil only stops it.
    public var message: String?
    public var resume: Resume?
    public var resumeAt: Date?
    public var state: State = .watching
    public var note: String?
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

    /// Where the week stands on the way to this limit: proceed, wrap up or stop.
    /// The wrap-up comes at 80 % of the distance from where the limit was set, at least one point before it.
    public func decide(weekLevel: Double) -> State {
        guard let stop = stopAtWeek else { return .watching }
        if weekLevel >= stop { return .stopped }
        let start = min(startLevel ?? weekLevel, stop)
        let wrapAt = min(stop - 1, start + (stop - start) * 0.8)
        return weekLevel >= wrapAt ? .wrappingUp : .watching
    }
}

/// The week's level now: the last reading plus what the ledger saw since, in its percent per weighted token.
public enum WeekLevel {
    public static func estimate(snapshot: UsageSnapshot?, ledger: TokenLedger, now: Date) -> Double? {
        guard let snapshot, let week = snapshot.weekly else { return nil }
        // The week has reset since the reading: the new week starts near zero until the next reading.
        if let resets = week.resetsAt, resets <= now { return 0 }
        guard let fetched = snapshot.fetchedAt, fetched < now,
              let ratio = percentPerWeight(ledger: ledger, provider: snapshot.provider, week: week, now: now) else { return week.usedPercent }
        let since = ledger.weight(snapshot.provider, from: fetched, to: now)
        return min(100, week.usedPercent + since * ratio)
    }
    /// Percent of the weekly limit per price-weighted token, from this week's used percent
    /// and the tokens the ledger saw in the same week. nil until both are known.
    public static func percentPerWeight(ledger: TokenLedger, provider: ProviderID, week: QuotaWindow?, now: Date) -> Double? {
        guard let week, let resets = week.resetsAt, week.usedPercent > 0 else { return nil }
        let weight = ledger.weight(provider, from: resets.addingTimeInterval(-Double(week.durationMinutes) * 60), to: now)
        return weight > 0 ? week.usedPercent / weight : nil
    }
}

/// The part hooks read: only sessions that need an answer, keyed by provider and session id.
public struct SessionLimitFile: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var state: SessionControl.State
        /// What the agent reads with its refused or reminded action.
        public var agent: String
        /// What the user reads when a prompt to a stopped session is blocked.
        public var user: String
        public init(state: SessionControl.State, agent: String, user: String) { self.state = state; self.agent = agent; self.user = user }
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
    /// agent sees or adds context; UserPromptSubmit blocks with a reason the user sees.
    public func reply(payload: Data) -> String {
        guard !entries.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object["hook_event_name"] as? String, let session = object["session_id"] as? String else { return "{}" }
        let provider: ProviderID? = entries[TokenLedger.sessionKey(.claude, session)] != nil ? .claude
            : entries[TokenLedger.sessionKey(.codex, session)] != nil ? .codex : nil
        guard let provider, let entry = entries[TokenLedger.sessionKey(provider, session)] else { return "{}" }
        let reply: [String: Any]?
        switch (event, entry.state) {
        case ("PreToolUse", .stopped):
            reply = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": entry.agent]]
        case ("PreToolUse", .wrappingUp):
            reply = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "additionalContext": entry.agent]]
        case ("UserPromptSubmit", .stopped):
            reply = ["decision": "block", "reason": entry.user]
        case ("UserPromptSubmit", .wrappingUp):
            reply = ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": entry.agent]]
        default: reply = nil
        }
        guard let reply, let data = try? JSONSerialization.data(withJSONObject: reply) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The saved controls.
public struct SessionControlList: Codable, Equatable, Sendable {
    public var controls: [SessionControl] = []
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

/// Typing the continuation into the session's own Terminal or iTerm2 tab.
public extension TerminalLocation {
    /// One line of plain text, quoted for AppleScript.
    static func typedText(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(line.prefix(500)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    static func typeScript(tty: String, app: String, text: String) -> String? {
        guard valid(tty) else { return nil }
        let typed = typedText(text)
        switch app {
        case "Terminal":
            return """
            with timeout of \(focusTimeout) seconds
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" and (count of processes of t) > 0 then
                            do script "\(typed)" in t
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            end timeout
            return false
            """
        case "iTerm2":
            return """
            with timeout of \(focusTimeout) seconds
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to write text "\(typed)"
                                return true
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
    /// Types `text` and Return into the tab; false when the tab is gone.
    static func type(_ text: String, tty: String, app: String, timeout: TimeInterval = Double(focusTimeout)) async throws -> Bool {
        guard let source = typeScript(tty: tty, app: app, text: text) else { throw SessionOpeningError.terminalFocusFailed(app) }
        return try await executeFocusScript(source, app: app, timeout: timeout)
    }
}
