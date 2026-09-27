import Foundation
import Darwin

/// Reads Claude's own /usage command. Authentication stays inside the unmodified
/// Claude Code executable; no API endpoint, token, model prompt or user chat is used.
public enum ClaudeUsageProbe {
    public static let source = "Claude Code /usage"
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Weekleft/QuotaProbe", isDirectory: true)

    /// Opt-in diagnostics: the plain text of a failed screen is saved here (0600).
    public static let dumpDirectoryVariable = "LUNAVECT_PROBE_DUMP_DIR"

    /// - Parameters:
    ///   - settle: how long a fully drawn but unparsed screen may stay unchanged
    ///     before the probe ends with a typed reason instead of waiting for `timeout`.
    ///   - screen: receives the final plain screen text (diagnostic `--usage-probe`).
    public static func fetch(cliPath: String, timeout: TimeInterval = 25, directory: URL = ClaudeUsageProbe.directory,
                             settle: TimeInterval = 2, screen: (@Sendable (String) -> Void)? = nil) async throws -> UsageSnapshot {
        let dump = getenv(dumpDirectoryVariable).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return try await SessionProcess.detached {
            try read(cliPath: cliPath, timeout: timeout, directory: directory, settle: settle, dumpDirectory: dump, screen: screen)
        }
    }

    private static func read(cliPath: String, timeout: TimeInterval, directory: URL, settle: TimeInterval,
                             dumpDirectory: URL?, screen: (@Sendable (String) -> Void)?) throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw UsageError.claudeCLIUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 80, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw UsageError.claudeUsageUnavailable }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { close(master); try? terminal.close() }
        // Poll a non-blocking PTY so a login prompt or hung CLI cannot stall the app.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--safe-mode", "--ax-screen-reader", "--tools", "", "--strict-mcp-config",
                             "--mcp-config", "{\"mcpServers\":{}}", "--no-chrome", "/usage"]
        process.currentDirectoryURL = directory
        var environment = SessionSources.environment(forExecutable: cliPath)
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        // Documented ephemeral mode covers both transcripts and up-arrow history
        // without relocating, copying or reading the user's credentials.
        environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        process.environment = environment
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        return try SessionProcess.withRunningProcess(process) {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var output = Data(), bytes = [UInt8](repeating: 0, count: 16384)
            var text = "", lastOutput = ProcessInfo.processInfo.systemUptime
            // A screen with a window that has no reset yet is accepted only once
            // it stops changing: a partial render must not look like an inactive window.
            var tentative: UsageSnapshot?
            var settles = false
            func finish(_ error: Error) -> Error {
                screen?(text)
                if !(error is CancellationError) { ClaudeUsageText.dump(text, to: dumpDirectory) }
                return error
            }
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let available = poll(&descriptor, 1, 50)
                if available > 0 {
                    let count = Darwin.read(master, &bytes, bytes.count)
                    if count > 0 {
                        output.append(contentsOf: bytes.prefix(count))
                        guard output.count < 512_000 else { throw finish(UsageError.claudeUsageUnavailable) }
                        text = ClaudeUsageText.plain(String(decoding: output, as: UTF8.self))
                        lastOutput = ProcessInfo.processInfo.systemUptime
                        tentative = nil
                        if let snapshot = try? ClaudeUsageText.parse(text) {
                            guard ClaudeUsageText.awaitsReset(snapshot) else { screen?(text); return snapshot }
                            tentative = snapshot
                        }
                        // Prompts wait for an answer that only the user may give.
                        if let prompt = ClaudeUsageText.blockingPrompt(in: text) { throw finish(prompt) }
                        settles = ClaudeUsageText.isDrawn(text) || ClaudeUsageText.state(in: text) != nil
                    } else if !process.isRunning { break }
                }
                if !process.isRunning { break }
                // The CLI stays open after drawing /usage. Once a complete or
                // conclusive screen stops changing, nothing more will arrive.
                if settles && ProcessInfo.processInfo.systemUptime - lastOutput >= settle { break }
            }
            try Task.checkCancellation()
            if let tentative { screen?(text); return tentative }
            if let failure = ClaudeUsageText.failure(in: text) { throw finish(failure) }
            let completeScreen = ClaudeUsageText.isDrawn(text)
            let cleanOutput = !process.isRunning && process.terminationReason == .exit && process.terminationStatus == 0
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if completeScreen || cleanOutput {
                throw finish(ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse))
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw finish(ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .timedOut))
            }
            throw finish(UsageError.claudeUsageUnavailable)
        }
    }
}

/// Screen-reader output is deliberately parsed by labelled sections, never by
/// percent order: model-specific weekly limits must not replace all-model usage.
public enum ClaudeUsageText {
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][0-2A-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}.", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> UsageSnapshot {
        let lines = plain(text).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func window(label: String, minutes: Int) throws -> QuotaWindow? {
            guard let start = lines.lastIndex(of: label) else { return nil }
            let end = min(lines.count, start + 6)
            let section = Array(lines[(start + 1)..<end].prefix { !$0.hasPrefix("Current ") && !$0.hasPrefix("Usage credits") })
            let percentPattern = #"(?<![\d.])(\d+(?:\.\d+)?)%\s*used"#
            let regex = try NSRegularExpression(pattern: percentPattern)
            var percentage: Double?
            for line in section {
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 1), in: line) { percentage = Double(line[range]); break }
            }
            guard let used = percentage else { return nil }
            guard let resetLine = section.first(where: { $0.hasPrefix("Resets ") }) else {
                // A window that has not started (after a reset, before the first
                // request) is a confirmed 0% without a reset time. A used window
                // without its reset stays unknown.
                return used == 0 ? try QuotaWindow(usedPercent: 0, durationMinutes: minutes, resetsAt: nil) : nil
            }
            guard let reset = resetDate(String(resetLine.dropFirst(7)), now: now, durationMinutes: minutes, timeZone: timeZone)
            else { throw UsageError.claudeUsageUnavailable }
            return try QuotaWindow(usedPercent: used, durationMinutes: minutes, resetsAt: reset)
        }
        guard let weekly = try window(label: "Current week (all models)", minutes: 10080) else { throw UsageError.claudeUsageUnavailable }
        let fiveHour = try window(label: "Current session", minutes: 300)
        // Wait for the complete command, not a partially rendered weekly block.
        guard lines.contains(where: { $0.contains("Esc to cancel") || $0.contains("Escape to cancel") }) else { throw UsageError.claudeUsageUnavailable }
        var modelQuotas: [ModelQuota] = []
        for label in lines where label.hasPrefix("Current week (") && label.hasSuffix(")") && label != "Current week (all models)" {
            let name = String(label.dropFirst("Current week (".count).dropLast())
            guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !modelQuotas.contains(where: { $0.name == name }) else { continue }
            // A malformed optional model block must not suppress valid account quotas.
            if let quota = try? window(label: label, minutes: 10080) {
                modelQuotas.append(ModelQuota(name: name, window: quota, fetchedAt: now))
            }
        }
        return UsageSnapshot(provider: .claude, weekly: weekly, fiveHour: fiveHour, fetchedAt: now, source: ClaudeUsageProbe.source, modelQuotas: modelQuotas)
    }

    static func resetDate(_ raw: String, now: Date, durationMinutes: Int, timeZone: TimeZone) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = timeZone
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            guard let explicitZone = TimeZone(identifier: name) else { return nil }
            zone = explicitZone
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = zone; formatter.isLenient = false
        let formats = ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d 'at' HH:mm", "MMM d, h:mma", "MMM d, ha"]
        var candidates: [Date] = []
        for format in formats {
            formatter.dateFormat = "yyyy " + format
            for candidateYear in [year - 1, year, year + 1] {
                if let date = formatter.date(from: "\(candidateYear) " + text) { candidates.append(date) }
            }
        }
        for format in ["h:mma", "ha", "HH:mm"] {
            formatter.dateFormat = format
            guard let clock = formatter.date(from: text) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: clock)
            for day in -1...1 {
                guard let base = calendar.date(byAdding: .day, value: day, to: now) else { continue }
                // A repeated local hour has two possible instants. A skipped
                // hour has none; never normalize it to a different clock time.
                for repetition in [Calendar.RepeatedTimePolicy.first, .last] {
                    guard let date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0,
                                                   second: 0, of: base, matchingPolicy: .strict, repeatedTimePolicy: repetition),
                          calendar.isDate(date, inSameDayAs: base) else { continue }
                    candidates.append(date)
                }
            }
        }
        // The CLI formats to whole minutes and can still show a reset that has
        // just passed. Keep that elapsed time (an expired window, never shown as
        // current) rather than failing the probe or inventing an extra day/week.
        return candidates.first { justElapsed($0, now: now) }
            ?? candidates.first { plausible($0, now: now, minutes: durationMinutes) }
    }
    private static func plausible(_ date: Date, now: Date, minutes: Int) -> Bool {
        // Never accept a misread past window or a reset beyond the window length.
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= Double(minutes * 60) + 120
    }
    private static func justElapsed(_ date: Date, now: Date) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval <= 0 && interval > -120
    }
}

/// Screens that are not a subscription quota. Each is conclusive on its own, so the
/// probe ends shortly after it is drawn instead of holding the client until the deadline.
extension ClaudeUsageText {
    private static func issue(_ reason: ClientIntegrationIssue.Reason) -> ClientIntegrationIssue {
        ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: reason)
    }
    /// The footer is drawn last; a loading indicator means more is coming.
    static func isDrawn(_ text: String) -> Bool {
        guard text.contains("Esc to cancel") || text.contains("Escape to cancel") else { return false }
        return !text.components(separatedBy: .newlines).suffix(6).contains { $0.contains("Loading") }
    }
    static func awaitsReset(_ snapshot: UsageSnapshot) -> Bool {
        [snapshot.weekly, snapshot.fiveHour].contains { $0 != nil && $0?.resetsAt == nil }
            || (snapshot.modelQuotas ?? []).contains { $0.window.resetsAt == nil }
    }
    /// Questions Claude Code asks before it runs `/usage`. Lunavect never answers them.
    static func blockingPrompt(in text: String) -> Error? {
        if ["Quick safety check", "trust this folder", "Accessing workspace"].contains(where: { text.contains($0) }) {
            return issue(.workspaceTrustRequired)
        }
        if text.contains("Enter y/n:") || text.contains("Select login method") || text.contains("Please run /login") || text.contains("Not logged in") {
            return UsageError.claudeSignInRequired
        }
        return nil
    }
    /// Known states of a drawn `/usage` screen that carry no subscription quota.
    static func state(in text: String) -> ClientIntegrationIssue.Reason? {
        if text.contains("Failed to load usage data") || text.contains("Could not refresh usage data") { return .usageFetchFailed }
        if text.contains("Usage limit reached") || text.contains("You've hit your") || text.contains("You\u{2019}ve hit your") { return .limitReached }
        // Header of a CLI without a subscription sign-in or with API-key billing:
        // `/usage` then shows only the session cost panel.
        if text.contains("API Usage Billing") { return .subscriptionUnavailable }
        return nil
    }
    /// Why a finished screen produced no quota; nil when nothing on it is recognized.
    static func failure(in text: String) -> Error? {
        if let prompt = blockingPrompt(in: text) { return prompt }
        if let reason = state(in: text) { return issue(reason) }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let start = lines.lastIndex(of: "Current week (all models)") {
            let section = lines[(start + 1)..<min(lines.count, start + 6)].prefix { !$0.hasPrefix("Current ") && !$0.hasPrefix("Usage credits") }
            let empty = !section.contains { $0.range(of: #"\d%\s*used"#, options: .regularExpression) != nil || $0.hasPrefix("Resets") }
            if empty { return issue(.windowInactive) }
        }
        return nil
    }
    /// Saves the plain screen of a failed probe for diagnosis, only when the user
    /// opted in with `LUNAVECT_PROBE_DUMP_DIR`. The file is private to the user.
    static func dump(_ text: String, to directory: URL?, now: Date = Date()) {
        guard let directory, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = Int(now.timeIntervalSince1970)
            let file = directory.appendingPathComponent("usage-probe-\(stamp)-\(UUID().uuidString.prefix(8)).txt")
            try LocalStateRecovery.write(Data(text.utf8), to: file)
        } catch {
            // Diagnostics must never change the probe's result.
        }
    }
}
