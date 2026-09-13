import Foundation
import Darwin

/// Reads Claude's own /usage command. Authentication stays inside the unmodified
/// Claude Code executable; no API endpoint, token, model prompt or user chat is used.
public enum ClaudeUsageProbe {
    public static let source = "Claude Code /usage"
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Weekleft/QuotaProbe", isDirectory: true)

    public static func fetch(cliPath: String, timeout: TimeInterval = 25, directory: URL = ClaudeUsageProbe.directory) async throws -> UsageSnapshot {
        try await SessionProcess.detached { try read(cliPath: cliPath, timeout: timeout, directory: directory) }
    }

    private static func read(cliPath: String, timeout: TimeInterval, directory: URL) throws -> UsageSnapshot {
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
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let available = poll(&descriptor, 1, 50)
                if available > 0 {
                    let count = Darwin.read(master, &bytes, bytes.count)
                    if count > 0 {
                        output.append(contentsOf: bytes.prefix(count))
                        guard output.count < 512_000 else { throw UsageError.claudeUsageUnavailable }
                        let text = ClaudeUsageText.plain(String(decoding: output, as: UTF8.self))
                        if let snapshot = try? ClaudeUsageText.parse(text) { return snapshot }
                        if text.contains("Enter y/n:") || text.contains("Select login method") || text.contains("Please run /login") || text.contains("Not logged in") {
                            throw UsageError.claudeSignInRequired
                        }
                    } else if !process.isRunning { break }
                }
                if !process.isRunning { break }
            }
            try Task.checkCancellation()
            let finalText = ClaudeUsageText.plain(String(decoding: output, as: UTF8.self))
            let completeScreen = finalText.contains("Esc to cancel") || finalText.contains("Escape to cancel")
            let cleanOutput = !process.isRunning && process.terminationReason == .exit && process.terminationStatus == 0
                && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if completeScreen || cleanOutput {
                throw ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse)
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .timedOut)
            }
            throw UsageError.claudeUsageUnavailable
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
            guard let resetLine = section.first(where: { $0.hasPrefix("Resets ") }) else { return nil }
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
        for format in formats {
            formatter.dateFormat = "yyyy " + format
            for candidateYear in [year, year + 1] {
                if let date = formatter.date(from: "\(candidateYear) " + text), plausible(date, now: now, minutes: durationMinutes) { return date }
            }
        }
        for format in ["h:mma", "ha", "HH:mm"] {
            formatter.dateFormat = format
            guard let clock = formatter.date(from: text) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: clock)
            for day in 0...1 {
                guard let base = calendar.date(byAdding: .day, value: day, to: now),
                      let date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: base)
                else { continue }
                if plausible(date, now: now, minutes: durationMinutes) { return date }
            }
        }
        return nil
    }
    private static func plausible(_ date: Date, now: Date, minutes: Int) -> Bool {
        // The CLI formats to whole minutes. Never invent an extra week/day when
        // the displayed reset has just elapsed, or accept a misread past window.
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= Double(minutes * 60) + 120
    }
}
