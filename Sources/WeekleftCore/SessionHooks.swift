import Foundation
import Darwin

public enum SessionHooks {
    public static func monitorExecutable(bundle: URL = Bundle.main.bundleURL, fallback: String? = Bundle.main.executablePath) -> String? {
        let helper = bundle.appendingPathComponent("Contents/Helpers/LunavectHook").path
        if FileManager.default.isExecutableFile(atPath: helper) { return helper }
        // Command-line development builds and old installations retain support.
        return fallback
    }
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Weekleft/Sessions", isDirectory: true)
    }
    public static func configURL(_ provider: ProviderID) -> URL {
        let env = ProcessInfo.processInfo.environment
        let base = env[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(provider == .codex ? ".codex" : ".claude")
        return base.appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func marker(_ provider: ProviderID) -> String { "# lunavect-session-monitor:\(provider.rawValue)" }
    static func events(_ provider: ProviderID) -> [String] {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"] +
        (provider == .claude ? ["Notification", "PostToolUseFailure", "StopFailure"] : ["Interrupt"])
    }
    public static func configured(_ provider: ProviderID, configURL: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: configURL ?? self.configURL(provider)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: [[String: Any]]] else { return false }
        return hooks.values.flatMap { $0 }.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasSuffix(marker(provider)) == true }
        }
    }
    public static func installed(_ provider: ProviderID, configURL: URL? = nil, executable: String? = SessionHooks.monitorExecutable()) -> Bool {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let expected = "\(quote(executable)) --session-hook \(provider.rawValue) \(marker(provider))"
        guard let data = try? Data(contentsOf: configURL ?? self.configURL(provider)), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["disableAllHooks"] as? Bool != true, let hooks = root["hooks"] as? [String: [[String: Any]]] else { return false }
        return events(provider).allSatisfy { event in
            (hooks[event] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == expected && $0["type"] as? String == "command" }
            }
        }
    }
    public static func install(provider: ProviderID, executable: String, configURL: URL? = nil, backupDirectory: URL? = nil) throws {
        try edit(provider: provider, executable: executable, url: configURL ?? self.configURL(provider), backup: backupDirectory ?? directory.appendingPathComponent("backups"))
    }
    public static func remove(provider: ProviderID, configURL: URL? = nil, backupDirectory: URL? = nil) throws {
        try edit(provider: provider, executable: nil, url: configURL ?? self.configURL(provider), backup: backupDirectory ?? directory.appendingPathComponent("backups"))
    }
    private static func edit(provider: ProviderID, executable: String?, url: URL, backup: URL) throws {
        let old = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        var root: [String: Any] = [:]
        if let old {
            guard old.count < 5_000_000, let parsed = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw SessionError.invalidResponse }
            root = parsed
        }
        let original = root as NSDictionary
        if executable != nil, root["disableAllHooks"] as? Bool == true { throw SessionError.disabled }
        guard root["hooks"] == nil || root["hooks"] is [String: [[String: Any]]] else { throw SessionError.invalidResponse }
        var hooks = root["hooks"] as? [String: [[String: Any]]] ?? [:]
        for (event, groups) in hooks {
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw SessionError.invalidResponse }
                let filtered = handlers.filter { ($0["command"] as? String)?.hasSuffix(marker(provider)) != true }
                if !filtered.isEmpty || handlers.isEmpty { group["hooks"] = filtered; kept.append(group) }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if let executable {
            let command = "\(quote(executable)) --session-hook \(provider.rawValue) \(marker(provider))"
            for event in events(provider) {
                hooks[event, default: []].append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if original.isEqual(to: root) { return }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let old { try secureWrite(old, to: backup.appendingPathComponent("\(provider.rawValue)-\(UUID().uuidString).json")) }
        let current = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        guard current == old else { throw SessionError.changedConfig }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try secureWrite(JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: url)
    }
    public static func secureWrite(_ data: Data, to url: URL) throws {
        try LocalStateRecovery.write(data, to: url)
    }
    public static func capture(_ data: Data, provider: ProviderID, at directory: URL = directory, client: SessionClient = .unknown) throws {
        let now = Date()
        let initial = try SessionRecord.event(data, provider: provider, previous: nil, now: now, client: client)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(provider.rawValue)-\(initial.session.sessionID).json")
        let lock = open(directory.appendingPathComponent(".capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SessionError.unavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw SessionError.unavailable }
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
        let record = try SessionRecord.event(data, provider: provider, previous: previous, now: now, client: client)
        try secureWrite(JSONEncoder().encode(record), to: file)
    }
    public static func load(at directory: URL = directory) -> [AgentSession] {
        _ = try? prune(at: directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true, (values.fileSize ?? 0) < 65536,
                  let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(SessionRecord.self, from: data), SessionParser.validID(record.session.sessionID) else { return nil }
            return record.session
        }
    }
    /// Lifecycle observations expire after a day. Clean only this monitor's
    /// records, under the same lock as capture; never touch provider transcripts.
    @discardableResult public static func prune(at directory: URL = directory, now: Date = Date()) throws -> Int {
        let stamp = directory.appendingPathComponent(".last-prune")
        if let modified = try? stamp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           now.timeIntervalSince(modified) >= 0, now.timeIntervalSince(modified) < 3600 { return 0 }
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let lock = open(directory.appendingPathComponent(".capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SessionError.unavailable }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        defer { flock(lock, LOCK_UN) }
        let cutoff = now.addingTimeInterval(-86400)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        func owned(_ url: URL) -> Bool {
            let name = url.deletingPathExtension().lastPathComponent
            return ProviderID.allCases.contains { provider in
                name.hasPrefix(provider.rawValue + "-") && SessionParser.validID(String(name.dropFirst(provider.rawValue.count + 1)))
            }
        }
        var removed = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let modified = values.contentModificationDate, modified < cutoff else { continue }
            if file.pathExtension == "json", owned(file), (values.fileSize ?? 0) < 65536,
               let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
               file.lastPathComponent == "\(record.session.provider.rawValue)-\(record.session.sessionID).json",
               record.session.observedAt < cutoff {
                try FileManager.default.removeItem(at: file); removed += 1
            }
        }
        // Old releases used one lock per session. Remove abandoned locks only;
        // a lock corresponding to a surviving record remains during migration.
        for file in files where file.pathExtension == "lock" && file.deletingPathExtension().pathExtension == "json" {
            let record = file.deletingPathExtension()
            guard owned(record), !FileManager.default.fileExists(atPath: record.path),
                  let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            let fd = open(file.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: file)
                flock(fd, LOCK_UN)
            }
            close(fd)
        }
        try secureWrite(Data(), to: stamp)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
        return removed
    }
}
