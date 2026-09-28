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
        // Removed, replaced by a folder or no longer executable since the last probe.
        var isDirectory: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: cliPath), FileManager.default.fileExists(atPath: cliPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw UsageError.claudeCLIUnavailable }
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
            var text = "", signature = "", lastOutput = ProcessInfo.processInfo.systemUptime
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
                        // Quiet time is measured on the text: cursor, title and spinner
                        // redraws of a finished screen are not new content.
                        let next = ClaudeUsageText.quietSignature(text)
                        if next != signature {
                            signature = next
                            lastOutput = ProcessInfo.processInfo.systemUptime
                            tentative = nil
                            if let snapshot = try? ClaudeUsageText.parse(text) {
                                guard ClaudeUsageText.awaitsReset(snapshot) else { screen?(text); return snapshot }
                                tentative = snapshot
                            }
                            // Prompts wait for an answer that only the user may give.
                            if let prompt = ClaudeUsageText.blockingPrompt(in: text) { throw finish(prompt) }
                            settles = ClaudeUsageText.isDrawn(text) || ClaudeUsageText.state(in: text) != nil
                        }
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
            let section = Array(lines[(start + 1)..<end].prefix { !endsSection($0) })
            let percentPattern = #"(?<![\d.])(\d+(?:\.\d+)?)%\s*used"#
            let regex = try NSRegularExpression(pattern: percentPattern)
            var percentage: Double?
            for line in section {
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 1), in: line) { percentage = Double(line[range]); break }
            }
            guard let used = percentage else { return nil }
            guard let resetLine = section.lazy.compactMap(ClaudeUsageText.resetText).first else {
                // A window that has not started (after a reset, before the first
                // request) is a confirmed 0% without a reset time. A used window
                // without its reset stays unknown.
                return used == 0 ? try QuotaWindow(usedPercent: 0, durationMinutes: minutes, resetsAt: nil) : nil
            }
            guard let shown = ClaudeUsageText.reset(resetLine, now: now, durationMinutes: minutes, timeZone: timeZone)
            else { throw UsageError.claudeUsageUnavailable }
            return try QuotaWindow(usedPercent: used, durationMinutes: minutes, resetsAt: shown.date, resetPrecision: shown.precision)
        }
        // Blocks drawn next to a failed refresh are the CLI's cached values: they
        // were not observed now and must not be stored as a fresh observation.
        if ClaudeUsageText.refreshFailed(text) { throw issue(.usageFetchFailed) }
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
        reset(raw, now: now, durationMinutes: durationMinutes, timeZone: timeZone)?.date
    }
    /// A block ends at the next block. "Extra usage" (overage) has its own
    /// percentage and reset that must not become the account window's.
    static func endsSection(_ line: String) -> Bool {
        line.hasPrefix("Current ") || line.hasPrefix("Usage credits") || line.hasPrefix("Extra usage")
    }
    /// The reset of a block line: "Resets Sep 28 at 11:59pm", also after the
    /// percentage ("40% used · Resets …") and before a trailing note (" · …").
    static func resetText(_ line: String) -> String? {
        let range = line.hasPrefix("Resets ") ? line.range(of: "Resets ") : line.range(of: " Resets ")
        guard let range else { return nil }
        let text = line[range.upperBound...].components(separatedBy: " · ").first ?? ""
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// The reset of a `/usage` block as the CLI prints it after "Resets ": a clock time
/// ("11:59pm", "23:59"), a date with or without a time ("Sep 28 at 11:59 PM",
/// "Sep 28"), "today/tomorrow at ...", or a relative time ("in 2h 15m"), with an
/// optional zone as an IANA identifier or abbreviation ("(Europe/Vienna)", "(CEST)").
///
/// The CLI truncates what it shows: "11:59pm" for a reset at 23:59:59.767. The
/// window has certainly reset only at the end of the shown minute (or day, or
/// relative unit), so that end is stored (Q-05). A window observed now also cannot
/// run past now plus its length, which bounds a date shown without a time.
extension ClaudeUsageText {
    struct ResetCandidate {
        /// The instant the CLI shows.
        let shown: Date
        /// The end of the shown unit: the first moment the reset has certainly happened.
        let end: Date
        let precision: ResetPrecision
    }

    static func reset(_ raw: String, now: Date, durationMinutes: Int, timeZone: TimeZone) -> (date: Date, precision: ResetPrecision)? {
        var text = raw.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = timeZone
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let name = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
            // An unknown zone is never replaced by the device zone: the time would be wrong.
            guard let explicit = explicitZone(name) else { return nil }
            zone = explicit
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.hasPrefix("at ") { text.removeFirst(3) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let groups = relativeReset(text, now: now).map({ [[$0]] }) ?? calendarReset(text, now: now, calendar: calendar) else { return nil }
        let length = Double(durationMinutes) * 60
        // The CLI can still show a reset that has just passed. Keep that elapsed
        // time (an expired window, never shown as current) rather than failing the
        // probe or inventing an extra day or week.
        func justElapsed(_ candidate: ResetCandidate) -> Bool {
            let interval = candidate.end.timeIntervalSince(now)
            return interval <= 0 && interval > -120
        }
        // Never accept a misread past window or a reset beyond the window length.
        func ahead(_ candidate: ResetCandidate) -> Bool {
            candidate.end > now && candidate.shown.timeIntervalSince(now) <= length + 120
        }
        // Within one shown day and time (a repeated daylight-saving hour) the later
        // instant is kept: the earlier one could announce the reset an hour early.
        let choices = groups.compactMap { group in group.last(where: { justElapsed($0) || ahead($0) }) }
        guard let choice = choices.first(where: justElapsed) ?? choices.first(where: ahead) else { return nil }
        let bound = now.addingTimeInterval(length)
        return (max(choice.shown, min(choice.end, bound)), choice.precision)
    }

    /// An IANA identifier ("Europe/Vienna", "GMT+2") or an abbreviation ("CEST",
    /// "EDT", "UTC"). Abbreviations are looked up first: as identifiers some of them
    /// name other places ("BST" would be Dhaka, not London).
    static func explicitZone(_ name: String) -> TimeZone? {
        guard !name.isEmpty else { return nil }
        if name.allSatisfy({ $0.isASCII && $0.isUppercase }), let zone = TimeZone(abbreviation: name) { return zone }
        return TimeZone(identifier: name)
    }

    private static func captures(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// "in 2h 15m", "in 45m", "in 3d", "in 2 hours, 5 minutes": counted from now
    /// (the probe reads the screen as it is drawn) to the end of the smallest unit.
    static func relativeReset(_ text: String, now: Date) -> ResetCandidate? {
        guard text.hasPrefix("in ") else { return nil }
        let body = text.dropFirst(3).replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: " and ", with: " ")
        let unit = #"(\d{1,4}) ?(days?|d|hours?|hrs?|h|minutes?|mins?|m)\b"#
        guard captures("^ *(?:" + unit + " *)+$", in: body) != nil, let regex = try? NSRegularExpression(pattern: unit) else { return nil }
        var seconds: TimeInterval = 0, smallest: (seconds: TimeInterval, precision: ResetPrecision)?
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let valueRange = Range(match.range(at: 1), in: body), let value = Double(body[valueRange]),
                  let nameRange = Range(match.range(at: 2), in: body) else { return nil }
            let name = body[nameRange]
            let step: (seconds: TimeInterval, precision: ResetPrecision) = name.hasPrefix("d") ? (86400, .day)
                : name.hasPrefix("h") ? (3600, .hour) : (60, .minute)
            seconds += value * step.seconds
            if smallest.map({ step.seconds < $0.seconds }) ?? true { smallest = step }
        }
        guard let smallest else { return nil }
        let shown = now.addingTimeInterval(seconds)
        return ResetCandidate(shown: shown, end: shown.addingTimeInterval(smallest.seconds), precision: smallest.precision)
    }

    /// A clock time, a date, or both. Each group holds the instants of one shown day
    /// and time: two for a repeated daylight-saving hour, none for a skipped one.
    static func calendarReset(_ text: String, now: Date, calendar: Calendar) -> [[ResetCandidate]]? {
        var rest = Substring(text)
        var days: [Date] = []
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: today).map { calendar.startOfDay(for: $0) } }
        if let match = captures(#"^(today|tomorrow)(?=$|[ ,])"#, in: text), let word = match[1] {
            days = [day(word == "today" ? 0 : 1)].compactMap { $0 }
            rest = rest.dropFirst(word.count)
        } else if let match = captures(#"^([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?(?=$|[ ,])"#, in: text),
                  let name = match[1], let number = match[2].flatMap({ Int($0) }) {
            let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
            guard let month = months.firstIndex(where: { $0.hasPrefix(name) || (name == "sept" && $0 == "september") }) else { return nil }
            let year = calendar.component(.year, from: now)
            for candidateYear in [year - 1, year, year + 1] {
                // Components are checked back: "Sep 31" must not become Oct 1.
                let parts = DateComponents(year: candidateYear, month: month + 1, day: number)
                guard let date = calendar.date(from: parts), calendar.component(.month, from: date) == month + 1,
                      calendar.component(.day, from: date) == number else { continue }
                days.append(calendar.startOfDay(for: date))
            }
            guard !days.isEmpty else { return nil }
            rest = rest.dropFirst(match[0]?.count ?? 0)
        }
        var clock = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if clock.hasPrefix("at ") { clock.removeFirst(3) }
        guard !clock.isEmpty else {
            // A date without a time: the reset is some moment of that day.
            guard !days.isEmpty else { return nil }
            return days.compactMap { start in
                calendar.date(byAdding: .day, value: 1, to: start).map { [ResetCandidate(shown: start, end: calendar.startOfDay(for: $0), precision: .day)] }
            }
        }
        guard let time = clockTime(clock) else { return nil }
        if days.isEmpty { days = (-1...1).compactMap(day) }
        return days.map { start in
            // A repeated local hour has two possible instants. A skipped hour has
            // none; never normalize it to a different clock time.
            var instants: [Date] = []
            for repetition in [Calendar.RepeatedTimePolicy.first, .last] {
                guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start,
                                               matchingPolicy: .strict, repeatedTimePolicy: repetition),
                      calendar.isDate(date, inSameDayAs: start), !instants.contains(date) else { continue }
                instants.append(date)
            }
            return instants.sorted().map { ResetCandidate(shown: $0, end: $0.addingTimeInterval(60), precision: .minute) }
        }
    }

    /// "11:59pm", "11:59 PM", "11 p.m.", "23:59". A 12-hour hour needs am/pm; a
    /// 24-hour time needs minutes.
    static func clockTime(_ text: String) -> (hour: Int, minute: Int)? {
        guard let match = captures(#"^(\d{1,2})(?::(\d{2}))? ?(am|pm|a\.m\.|p\.m\.)?$"#, in: text),
              let hour = match[1].flatMap({ Int($0) }) else { return nil }
        let minute = match[2].flatMap { Int($0) }
        if let minute, !(0...59).contains(minute) { return nil }
        if let meridiem = match[3] {
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0), minute ?? 0)
        }
        guard let minute, (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }
}

/// Lunavect's own `/usage` probe is not a user session. Its catalog row (and any
/// hook a future `--safe-mode` might run) is dropped at the source. The name
/// Claude generates for it ("quotaprobe-NN") is deliberately not used.
public extension ClaudeUsageProbe {
    /// The probe folder as the file system names it: symlinks resolved, `/var`
    /// and `/private/var` unified, no trailing slash.
    static let canonicalDirectory = canonicalPath(directory.path)

    static func isProbeSession(cwd: String, pid: Int32?) -> Bool {
        isProbeSession(cwd: cwd, pid: pid, canonicalDirectory: canonicalDirectory)
    }
}

extension ClaudeUsageProbe {
    /// `canonicalDirectory` must already be canonical. The probe is started by
    /// `Process` without a shell, so the catalog PID is a direct child of this app.
    static func isProbeSession(cwd: String, pid: Int32?, canonicalDirectory: String,
                               parentPID: (Int32) -> Int32? = { SessionProcess.runtimeProcess($0)?.parentPID },
                               ownPID: Int32 = getpid()) -> Bool {
        if !canonicalDirectory.isEmpty {
            let path = canonicalPath(cwd)
            if !path.isEmpty, path == canonicalDirectory || path.hasPrefix(canonicalDirectory + "/") { return true }
        }
        guard let pid, pid > 1 else { return false }
        return parentPID(pid) == ownPID
    }
    /// A lexical `.`/`..`/slash cleanup, then realpath(3) of the deepest existing
    /// ancestor. realpath keeps `/private`, so both spellings of a temporary or
    /// `/var` path compare equal; a folder that does not exist yet still matches
    /// the name it will have once created.
    static func canonicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return "" }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        var suffix: [String] = []
        while true {
            let candidate = "/" + parts.joined(separator: "/")
            if let resolved = realpath(candidate, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                guard !suffix.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + suffix.reversed().joined(separator: "/")
            }
            guard let last = parts.popLast() else { return candidate }
            suffix.append(last)
        }
    }
}

/// Screens that are not a subscription quota. Each is conclusive on its own, so the
/// probe ends shortly after it is drawn instead of holding the client until the deadline.
extension ClaudeUsageText {
    private static func issue(_ reason: ClientIntegrationIssue.Reason) -> ClientIntegrationIssue {
        ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: reason)
    }
    /// What the early exit compares to decide that the screen stopped changing: the
    /// plain text without whitespace and spinner glyphs (Braille dots, Claude's
    /// asterisk-like frames, quarter circles). Escape sequences are already gone.
    static func quietSignature(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) && !isSpinner(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
    private static func isSpinner(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value) || "·✢✳✶✻✽*◐◓◑◒".unicodeScalars.contains(scalar)
    }
    /// The CLI could not load or refresh its usage data; blocks on such a screen are cached.
    static func refreshFailed(_ text: String) -> Bool {
        text.contains("Failed to load usage data") || text.contains("Could not refresh usage data")
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
        if refreshFailed(text) || text.contains("No model usage data available") { return .usageFetchFailed }
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
        // An empty block means "not started" only on a finished screen. A block that
        // is still loading (or cut off) when the deadline passes is a timeout.
        guard isDrawn(text) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let start = lines.lastIndex(of: "Current week (all models)") {
            let section = lines[(start + 1)..<min(lines.count, start + 6)].prefix { !endsSection($0) }
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
