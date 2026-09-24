import Foundation
import CryptoKit
import Darwin


public enum CodexProvider {
    public static func discoverCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home + "/Applications/Codex.app/Contents/Resources/codex",
            home + "/Desktop/ChatGPT.app/Contents/Resources/codex",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func fetch(resolver: ClientExecutableResolver) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        return try await fetch(cliPath: resolver.resolve(.codex))
    }
    public static func fetch(cliPath: String) async throws -> UsageSnapshot {
        try await SessionProcess.detached { try read(cliPath: cliPath) }
    }
    static func read(cliPath: String, timeout: TimeInterval = 25) throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw UsageError.missingCLI }
        do {
            return try SessionProcess.withProcess(path: cliPath, arguments: ["app-server", "--stdio"], timeout: timeout) { _, input, output, deadline in
                // No conversation is started. Only initialize and account/rateLimits/read are sent.
                func send(_ object: [String: Any]) throws {
                    var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
                    try SessionProcess.writeCodexInput(data, to: input.fileHandleForWriting, until: deadline)
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
                        try Task.checkCancellation()
                        let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] as? Int else { continue }
                        if id == 1 {
                            _ = try ClientResponseContract.codexResult(message, capability: .initialization)
                            try send(["method": "initialized"])
                            try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                        } else if id == 2 {
                            let result = try ClientResponseContract.codexResult(message, capability: .rateLimits)
                            try ClientResponseContract.validateCodexRateLimits(result)
                            do { return try UsageParser.codex(result) }
                            catch { throw ClientIntegrationIssue.classify(error, provider: .codex, capability: .rateLimits) ?? error }
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
        try Task.checkCancellation()
        guard let data = try? Data(contentsOf: url) else { throw UsageError.waitingForClaude }
        var snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        guard snapshot.provider == .claude, snapshot.source == "Claude Code statusLine", snapshot.fetchedAt != nil,
            [snapshot.weekly, snapshot.fiveHour].compactMap({ $0 }).allSatisfy({
                $0.resetsAt != nil && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
            })
        else { throw UsageError.invalidResponse }
        if snapshot.isStale(now: now) { snapshot.issue = UsageError.claudeQuotaStale.errorDescription }
        try Task.checkCancellation()
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
        guard var snapshot = preferredObservation(observations, now: now) else { throw UsageError.waitingForClaude }
        // statusLine does not carry model buckets. Keep their own timestamps;
        // a newer statusLine must neither erase them nor make them appear fresh.
        if snapshot.source == "Claude Code statusLine", snapshot.modelQuotas == nil {
            snapshot.modelQuotas = observations.first(where: { $0.source == ClaudeUsageProbe.source })?.modelQuotas
        }
        if snapshot.isStale(now: now) { snapshot.issue = UsageError.claudeQuotaStale.errorDescription }
        return snapshot
    }
    public static func preferredObservation(_ observations: [UsageSnapshot], now: Date) -> UsageSnapshot? {
        let current = observations.filter { $0.freshnessVerified && !$0.isStale(now: now) }
        return (current.isEmpty ? observations : current).max {
            ($0.fetchedAt ?? .distantPast) < ($1.fetchedAt ?? .distantPast)
        }
    }
    static func cacheIsCurrent(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard !snapshot.isStale(now: now), let fetchedAt = snapshot.fetchedAt,
              now.timeIntervalSince(fetchedAt) >= 0, now.timeIntervalSince(fetchedAt) < 300,
              let weekly = snapshot.weekly, weekly.resetsAt.map({ $0 > now }) ?? false else { return false }
        if let fiveHour = snapshot.fiveHour, fiveHour.resetsAt.map({ $0 <= now }) ?? true { return false }
        return (snapshot.modelQuotas ?? []).allSatisfy { !$0.isStale(now: now) }
    }
    public static func refresh(force: Bool = true) async throws -> UsageSnapshot {
        try await refresh(force: force, cached: { try latest() }, probe: {
            try Task.checkCancellation()
            guard let path = SessionSources.discoverClaude() else { throw UsageError.claudeCLIUnavailable }
            return try await ClaudeUsageProbe.fetch(cliPath: path)
        }, save: { try saveUsage($0) })
    }
    static func refresh(force: Bool, now: Date = Date(), cached: () throws -> UsageSnapshot,
                        probe: () async throws -> UsageSnapshot, save: (UsageSnapshot) throws -> Void) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        if !force, let snapshot = try? cached(), cacheIsCurrent(snapshot, now: now) {
            try Task.checkCancellation()
            return snapshot
        }
        do {
            try Task.checkCancellation()
            let snapshot = try await probe()
            try Task.checkCancellation()
            try save(snapshot)
            try Task.checkCancellation()
            return snapshot
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            // An offline/login failure keeps the last real observation and its
            // timestamp. It must not reset usage or make old data fresh.
            guard var snapshot = try? cached() else { throw error }
            try Task.checkCancellation()
            snapshot.issue = (error as? ClientIntegrationIssue)?.message ?? (error as? UsageError)?.errorDescription ?? UsageError.claudeUsageUnavailable.errorDescription
            return snapshot
        }
    }
    public static func saveUsage(_ snapshot: UsageSnapshot, destination: URL = usageCacheURL) throws {
        try Task.checkCancellation()
        guard isTrustedSnapshot(snapshot), snapshot.source == ClaudeUsageProbe.source else { throw UsageError.invalidResponse }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        try LocalStateRecovery.write(JSONEncoder().encode(snapshot), to: destination)
    }
    public static func capture(_ data: Data, destination: URL = cacheURL, now: Date = Date()) throws {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        // An absent field carries no fresh quota information; retain the last observation.
        guard let limits = try ClientResponseContract.claudeRateLimits(root) else { return }
        let snapshot: UsageSnapshot
        do { snapshot = try UsageParser.claude(limits, now: now) }
        catch { throw ClientIntegrationIssue.classify(error, provider: .claude, capability: .statusLine) ?? error }
        guard snapshot.weekly != nil || snapshot.fiveHour != nil else { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Quota values alone do not identify a replay: a later API response may
        // legitimately contain identical (or lower) values. Include documented
        // response progress, but never the wall duration that changes on redraw.
        var identity: [String: Any] = ["rate_limits": limits]
        identity["session_id"] = root["session_id"]
        identity["api_duration"] = (root["cost"] as? [String: Any])?["total_api_duration_ms"]
        if let context = root["context_window"] as? [String: Any] {
            identity["input"] = context["total_input_tokens"]
            identity["output"] = context["total_output_tokens"]
            identity["usage"] = context["current_usage"]
        }
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: identity, options: .sortedKeys))
            .map { String(format: "%02x", $0) }.joined()
        let target = destination.resolvingSymlinksInPath()
        let lock = open(target.appendingPathExtension("capture.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let previous = try LocalStateRecovery.load(from: target, empty: (snapshot: UsageSnapshot?.none, fields: [String: Any]())) { url in
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let stored = try JSONDecoder().decode(UsageSnapshot.self, from: bytes)
            return (stored, try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:])
        }
        var seen = previous.value.fields["captureFingerprints"] as? [String: Double] ?? [:]
        guard seen[digest] == nil else { return }
        // Bounded hashes contain no raw session identity, transcript or account data.
        let writer = (root["session_id"] as? String).map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        // Usage within one window never decreases. Claude re-runs every session's
        // status line (a window reset, refreshInterval), so an idle session re-sends
        // its own older response; a lower value for the same window from another
        // session is that older response and must neither replace nor re-stamp
        // the newer observation. The last writer's own lower value is accepted.
        if let stored = previous.value.snapshot, writer == nil || previous.value.fields["captureSession"] as? String != writer,
           zip([stored.weekly, stored.fiveHour], [snapshot.weekly, snapshot.fiveHour]).contains(where: { old, new in
               guard let old, let new, old.resetsAt != nil, old.resetsAt == new.resetsAt else { return false }
               return new.usedPercent < old.usedPercent
           }) { return }
        seen[digest] = now.timeIntervalSince1970
        seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) })
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        encoded["captureFingerprints"] = seen
        encoded["captureSession"] = writer
        try LocalStateRecovery.write(JSONSerialization.data(withJSONObject: encoded, options: .sortedKeys), to: target)
        // Claude cancels an in-flight status line when the next update starts.
        // Best-effort cleanup; the capture above has already succeeded.
        _ = try? LocalStateRecovery.removeAbandonedTemporaries(in: target.deletingLastPathComponent(), now: now)
    }
    private static func statusLineCommand(_ executable: String) -> String { SessionHooks.quote(executable) + " --claude-statusline" }
    private static func ownsStatusLine(_ command: String) -> Bool {
        command.range(of: #"^'(?:[^']|'"'"')+' --claude-statusline$"#, options: .regularExpression) != nil
    }
    public static func statusLineConfigured(settingsURL: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL ?? SessionHooks.configURL(.claude)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["statusLine"] as? [String: Any], let command = status["command"] as? String else { return false }
        return ownsStatusLine(command)
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
    static func validateStatusLine(settingsURL: URL, bridgeDirectory: URL, connecting: Bool) throws {
        let root = try SessionHooks.readConfiguration(at: settingsURL)
        if connecting, root["disableAllHooks"] as? Bool == true { throw UsageError.statusLineDisabled }
        guard root["statusLine"] == nil || root["statusLine"] is [String: Any] else { throw UsageError.invalidResponse }
        if let status = root["statusLine"] as? [String: Any],
           let command = status["command"] as? String, ownsStatusLine(command) {
            _ = try previousStatusLine(in: bridgeDirectory)
        }
    }
    private static func previousStatusLine(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("previous-statusline.json"))
        guard data.count < 5_000_000, let prior = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (prior["command"] as? String).map({ !ownsStatusLine($0) }) ?? true else { throw UsageError.invalidResponse }
        return prior
    }
    public static func installStatusLine(executable: String, settingsURL: URL? = nil, bridgeDirectory: URL = directory,
                                         checkpoint: (ClientConnection.LocalStep) throws -> Void = { _ in }) throws {
        let settings = settingsURL ?? SessionHooks.configURL(.claude)
        try validateStatusLine(settingsURL: settings, bridgeDirectory: bridgeDirectory, connecting: true)
        let oldData = try FileManager.default.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
        var root: [String: Any] = [:]
        if let oldData {
            guard oldData.count < 5_000_000, let object = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw UsageError.invalidResponse }
            root = object
        }
        guard root["disableAllHooks"] as? Bool != true else { throw UsageError.statusLineDisabled }
        guard root["statusLine"] == nil || root["statusLine"] is [String: Any] else { throw UsageError.invalidResponse }
        var status = root["statusLine"] as? [String: Any] ?? [:]
        let command = statusLineCommand(executable)
        let migrating = (status["command"] as? String).map(ownsStatusLine) ?? false
        if migrating { _ = try previousStatusLine(in: bridgeDirectory) }
        if status["command"] as? String == command && status["type"] as? String == "command" { return }
        if !migrating {
            try checkpoint(.statusLinePrevious)
            try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let prior = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            try SessionHooks.secureWriteVerified(prior, to: bridgeDirectory.appendingPathComponent("previous-statusline.json"))
        }
        try checkpoint(.statusLineBackup)
        try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let oldData { try SessionHooks.secureWriteVerified(oldData, to: bridgeDirectory.appendingPathComponent("settings-backup-" + UUID().uuidString + ".json")) }
        status["type"] = "command"; status["command"] = command; root["statusLine"] = status
        try checkpoint(.statusLineWrite)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = try FileManager.default.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
        guard current == oldData else { throw SessionError.changedConfig }
        try SessionHooks.writeConfigurationChange(original: oldData,
            updated: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: settings, restorationURL: SessionHooks.restorationURL(for: settings, in: bridgeDirectory, prefix: "statusline"),
            disconnecting: false)
        try SessionHooks.pruneOwnedBackups(in: bridgeDirectory, prefix: "settings-backup-")
    }
    public static func removeStatusLine(settingsURL: URL? = nil, bridgeDirectory: URL = directory,
                                        checkpoint: (ClientConnection.LocalStep) throws -> Void = { _ in }) throws {
        let settings = settingsURL ?? SessionHooks.configURL(.claude)
        try validateStatusLine(settingsURL: settings, bridgeDirectory: bridgeDirectory, connecting: false)
        guard FileManager.default.fileExists(atPath: settings.path) else { return }
        let oldData = try Data(contentsOf: settings)
        guard var root = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw UsageError.invalidResponse }
        guard let status = root["statusLine"] as? [String: Any], let command = status["command"] as? String, ownsStatusLine(command) else { return }
        // Restore only the two fields owned by the bridge. Metadata edited by the
        // client since installation (padding, refreshInterval, etc.) stays current.
        let prior = try previousStatusLine(in: bridgeDirectory)
        var restored = status
        restored["type"] = prior["type"]; restored["command"] = prior["command"]
        if restored.isEmpty { root.removeValue(forKey: "statusLine") } else { root["statusLine"] = restored }
        try checkpoint(.statusLineBackup)
        try SessionHooks.secureWriteVerified(oldData, to: bridgeDirectory.appendingPathComponent("settings-backup-" + UUID().uuidString + ".json"))
        try checkpoint(.statusLineWrite)
        guard try Data(contentsOf: settings) == oldData else { throw SessionError.changedConfig }
        try SessionHooks.writeConfigurationChange(original: oldData,
            updated: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: settings, restorationURL: SessionHooks.restorationURL(for: settings, in: bridgeDirectory, prefix: "statusline"),
            disconnecting: true)
        try SessionHooks.pruneOwnedBackups(in: bridgeDirectory, prefix: "settings-backup-")
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
