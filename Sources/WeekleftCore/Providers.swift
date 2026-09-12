import Foundation


public enum CodexProvider {
    public static func discoverCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", home + "/Applications/Codex.app/Contents/Resources/codex", home + "/Desktop/ChatGPT.app/Contents/Resources/codex"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func fetch(cliPath: String) async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) { try read(cliPath: cliPath) }.value
    }
    static func read(cliPath: String, timeout: TimeInterval = 25) throws -> UsageSnapshot {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw UsageError.missingCLI }
        do {
            return try SessionProcess.withProcess(path: cliPath, arguments: ["app-server", "--stdio"], timeout: timeout) { _, input, output, deadline in
                // No conversation is started. Only initialize and account/rateLimits/read are sent.
                func send(_ object: [String: Any]) throws {
                    var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
                try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "weekleft", "version": "0.1.0"]]])
                var buffer = Data(), total = 0
                while true {
                    let data = try SessionProcess.readChunk(output.fileHandleForReading, until: deadline)
                    if data.isEmpty { throw UsageError.timeout }
                    total += data.count
                    guard total < 2_000_000 else { throw UsageError.invalidResponse }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] as? Int else { continue }
                        if id == 1 {
                            guard message["error"] == nil else { throw UsageError.invalidResponse }
                            try send(["method": "initialized"])
                            try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                        } else if id == 2 {
                            guard let result = message["result"] as? [String: Any] else { throw UsageError.notSignedIn }
                            return try UsageParser.codex(result)
                        }
                    }
                }
            }
        } catch SessionError.timeout { throw UsageError.timeout }
        catch SessionError.invalidResponse { throw UsageError.invalidResponse }
        catch is SessionError { throw UsageError.missingCLI }
    }
}

public enum ClaudeProvider {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/ClaudeStatusLine")
    public static var cacheURL: URL { directory.appendingPathComponent("quota.json") }
    public static func fetch(from url: URL = cacheURL, now: Date = Date()) async throws -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url) else { throw UsageError.waitingForClaude }
        var snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        guard snapshot.provider == .claude, snapshot.source == "Claude Code statusLine", snapshot.fetchedAt != nil, [snapshot.weekly, snapshot.fiveHour].compactMap({ $0 }).allSatisfy({ $0.resetsAt != nil && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }) else { throw UsageError.invalidResponse }
        if snapshot.isStale(now: now) { snapshot.issue = UsageError.claudeQuotaStale.errorDescription }
        return snapshot
    }
    public static var usageCacheURL: URL { directory.appendingPathComponent("usage.json") }
    public static func isTrustedSnapshot(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.provider == .claude && ["Claude Code statusLine", ClaudeUsageProbe.source].contains(snapshot.source)
            && snapshot.fetchedAt != nil && snapshot.hasQuota
            && [snapshot.weekly, snapshot.fiveHour].compactMap({ $0 }).allSatisfy {
                $0.resetsAt != nil && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
            }
            && (snapshot.modelQuotas ?? []).count <= 20
            && (snapshot.modelQuotas ?? []).allSatisfy {
                !$0.name.isEmpty && $0.name.count <= 60 && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && $0.window.durationMinutes == 10080 && $0.window.resetsAt != nil
                    && $0.window.usedPercent.isFinite && (0...100).contains($0.window.usedPercent)
            }
    }
    public static func latest(statusLineURL: URL = cacheURL, usageURL: URL = usageCacheURL, now: Date = Date()) throws -> UsageSnapshot {
        let observations = [statusLineURL, usageURL].compactMap { url -> UsageSnapshot? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
                  isTrustedSnapshot(snapshot) else { return nil }
            return snapshot
        }
        guard var snapshot = observations.max(by: { ($0.fetchedAt ?? .distantPast) < ($1.fetchedAt ?? .distantPast) }) else { throw UsageError.waitingForClaude }
        // statusLine does not carry model buckets. Keep their own timestamps;
        // a newer statusLine must neither erase them nor make them appear fresh.
        if snapshot.source == "Claude Code statusLine", snapshot.modelQuotas == nil {
            snapshot.modelQuotas = observations.first(where: { $0.source == ClaudeUsageProbe.source })?.modelQuotas
        }
        if snapshot.isStale(now: now) { snapshot.issue = UsageError.claudeQuotaStale.errorDescription }
        return snapshot
    }
    static func cacheIsCurrent(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.issue == nil, let fetchedAt = snapshot.fetchedAt,
              now.timeIntervalSince(fetchedAt) >= 0, now.timeIntervalSince(fetchedAt) < 300,
              let weekly = snapshot.weekly, weekly.resetsAt.map({ $0 > now }) ?? false else { return false }
        if let fiveHour = snapshot.fiveHour, fiveHour.resetsAt.map({ $0 <= now }) ?? true { return false }
        return (snapshot.modelQuotas ?? []).allSatisfy { !$0.isStale(now: now) }
    }
    public static func refresh(force: Bool = true) async throws -> UsageSnapshot {
        if !force, let cached = try? latest(), cacheIsCurrent(cached) { return cached }
        do {
            guard let path = SessionSources.discoverClaude() else { throw UsageError.claudeCLIUnavailable }
            let snapshot = try await ClaudeUsageProbe.fetch(cliPath: path)
            try saveUsage(snapshot)
            return snapshot
        } catch {
            // An offline/login failure keeps the last real observation and its
            // timestamp. It must not reset usage or make old data fresh.
            guard var cached = try? latest() else { throw error }
            cached.issue = (error as? UsageError)?.errorDescription ?? UsageError.claudeUsageUnavailable.errorDescription
            return cached
        }
    }
    public static func saveUsage(_ snapshot: UsageSnapshot, destination: URL = usageCacheURL) throws {
        guard isTrustedSnapshot(snapshot), snapshot.source == ClaudeUsageProbe.source else { throw UsageError.invalidResponse }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    public static func capture(_ data: Data, destination: URL = cacheURL) throws {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        // An absent field carries no fresh quota information; retain the last observation.
        guard let limits = root["rate_limits"] as? [String: Any], !limits.isEmpty else { return }
        let snapshot = try UsageParser.claude(limits)
        guard snapshot.weekly != nil || snapshot.fiveHour != nil else { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    private static func statusLineCommand(_ executable: String) -> String { SessionHooks.quote(executable) + " --claude-statusline" }
    private static func ownsStatusLine(_ command: String) -> Bool {
        command.range(of: #"^'(?:[^']|'"'"')+' --claude-statusline$"#, options: .regularExpression) != nil
    }
    public static func statusLineConfigured(settingsURL: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL ?? SessionHooks.configURL(.claude)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["statusLine"] as? [String: Any], let command = status["command"] as? String else { return false }
        return ownsStatusLine(command) && status["type"] as? String == "command"
    }
    public static func statusLineInstalled(settingsURL: URL? = nil, executable: String? = SessionHooks.monitorExecutable()) -> Bool {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let config = settingsURL ?? SessionHooks.configURL(.claude)
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["disableAllHooks"] as? Bool != true,
              let status = root["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return command == statusLineCommand(executable) && status["type"] as? String == "command"
    }
    public static func installStatusLine(executable: String, settingsURL: URL? = nil, bridgeDirectory: URL = directory) throws {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settings = settingsURL ?? config.appendingPathComponent("settings.json")
        let oldData = try FileManager.default.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
        var root: [String: Any] = [:]
        if let oldData {
            guard let object = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw UsageError.invalidResponse }
            root = object
        }
        guard root["disableAllHooks"] as? Bool != true else { throw UsageError.statusLineDisabled }
        guard root["statusLine"] == nil || root["statusLine"] is [String: Any] else { throw UsageError.invalidResponse }
        var status = root["statusLine"] as? [String: Any] ?? [:]
        let command = statusLineCommand(executable)
        if status["command"] as? String == command { return }
        let migrating = (status["command"] as? String).map(ownsStatusLine) ?? false
        try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !migrating {
            let prior = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            try SessionHooks.secureWrite(prior, to: bridgeDirectory.appendingPathComponent("previous-statusline.json"))
        }
        if let oldData { try SessionHooks.secureWrite(oldData, to: bridgeDirectory.appendingPathComponent("settings-backup-" + UUID().uuidString + ".json")) }
        status["type"] = "command"; status["command"] = command; root["statusLine"] = status
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = try FileManager.default.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
        guard current == oldData else { throw SessionError.changedConfig }
        try SessionHooks.secureWrite(JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: settings)
    }
    public static func removeStatusLine(settingsURL: URL? = nil, bridgeDirectory: URL = directory) throws {
        let settings = settingsURL ?? SessionHooks.configURL(.claude)
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        let oldData = try Data(contentsOf: settings)
        guard var root = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw UsageError.invalidResponse }
        guard let status = root["statusLine"] as? [String: Any], let command = status["command"] as? String, ownsStatusLine(command) else { return }
        let priorURL = bridgeDirectory.appendingPathComponent("previous-statusline.json")
        // Missing/unreadable backup is an error, never a reason to erase a user's HUD.
        guard let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: priorURL)) as? [String: Any],
              (prior["command"] as? String).map({ !ownsStatusLine($0) }) ?? true else { throw UsageError.invalidResponse }
        if prior.isEmpty { root.removeValue(forKey: "statusLine") } else { root["statusLine"] = prior }
        try SessionHooks.secureWrite(oldData, to: bridgeDirectory.appendingPathComponent("settings-backup-" + UUID().uuidString + ".json"))
        guard try Data(contentsOf: settings) == oldData else { throw SessionError.changedConfig }
        try SessionHooks.secureWrite(JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: settings)
    }
    public static func runStatusLine() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        do { try capture(data) } catch { fputs("Lunavect: quota data could not be saved.\n", stderr) }
        // Preserve the user's existing HUD, including stdin, stdout, environment and cwd.
        guard let prior = try? Data(contentsOf: directory.appendingPathComponent("previous-statusline.json")),
              let object = (try? JSONSerialization.jsonObject(with: prior)) as? [String: Any],
              let command = object["command"] as? String, !command.isEmpty, !command.contains("--claude-statusline") else { return }
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardInput = input; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        do {
            try process.run()
            DispatchQueue.global().async { try? input.fileHandleForWriting.write(contentsOf: data); try? input.fileHandleForWriting.close() }
            process.waitUntilExit()
        } catch { fputs("Lunavect: previous status line could not be started.\n", stderr) }
    }
}
