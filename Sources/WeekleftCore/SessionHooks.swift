import Foundation
import Darwin
import CryptoKit

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
    /// Escape individual unquoted characters: this form is shared by sh, zsh
    /// and fish. Callers omit control-character paths (not shell arguments).
    public static func portableQuote(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/.")
        return text.unicodeScalars.reduce(into: "") { result, scalar in
            if !safe.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
    }
    static func marker(_ provider: ProviderID) -> String { "# lunavect-session-monitor:\(provider.rawValue)" }
    static func events(_ provider: ProviderID) -> [String] {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"] +
        (provider == .claude ? ["Notification", "PostToolUseFailure", "StopFailure", "PreCompact", "PostCompact"] : ["Interrupt"])
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
        guard let data = try? Data(contentsOf: configURL ?? self.configURL(provider)),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["disableAllHooks"] as? Bool != true, let hooks = root["hooks"] as? [String: [[String: Any]]]
        else { return false }
        return events(provider).allSatisfy { event in
            (hooks[event] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == expected && $0["type"] as? String == "command" }
            }
        }
    }
    public static func install(provider: ProviderID, executable: String, configURL: URL? = nil, backupDirectory: URL? = nil,
                               checkpoint: (ClientConnection.LocalStep) throws -> Void = { _ in }) throws {
        try edit(provider: provider, executable: executable, url: configURL ?? self.configURL(provider),
                 backup: backupDirectory ?? directory.appendingPathComponent("backups"), checkpoint: checkpoint)
    }
    public static func remove(provider: ProviderID, configURL: URL? = nil, backupDirectory: URL? = nil,
                              checkpoint: (ClientConnection.LocalStep) throws -> Void = { _ in }) throws {
        try edit(provider: provider, executable: nil, url: configURL ?? self.configURL(provider),
                 backup: backupDirectory ?? directory.appendingPathComponent("backups"), checkpoint: checkpoint)
    }
    static func readConfiguration(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count < 5_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SessionError.invalidResponse }
        return root
    }
    static func validateEdit(provider: ProviderID, executable: String?, url: URL) throws {
        _ = try editedConfiguration(provider: provider, executable: executable, root: readConfiguration(at: url))
    }
    private static func editedConfiguration(provider: ProviderID, executable: String?, root: [String: Any]) throws -> [String: Any] {
        var root = root
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
        return root
    }
    private static func edit(provider: ProviderID, executable: String?, url: URL, backup: URL,
                             checkpoint: (ClientConnection.LocalStep) throws -> Void) throws {
        let old = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        let original: [String: Any]
        if let old {
            guard old.count < 5_000_000,
                  let root = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw SessionError.invalidResponse }
            original = root
        } else { original = [:] }
        let root = try editedConfiguration(provider: provider, executable: executable, root: original)
        if (original as NSDictionary).isEqual(to: root) { return }
        try checkpoint(.hooksBackup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let old { try secureWriteVerified(old, to: backup.appendingPathComponent("\(provider.rawValue)-\(UUID().uuidString).json")) }
        try checkpoint(.hooksWrite)
        let current = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        guard current == old else { throw SessionError.changedConfig }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeConfigurationChange(original: old,
            updated: JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            to: url, restorationURL: restorationURL(for: url, in: backup, prefix: provider.rawValue),
            disconnecting: executable == nil)
        try pruneOwnedBackups(in: backup, prefix: provider.rawValue + "-")
    }
    private struct ConfigurationRestoration: Codable {
        var original: Data?
        var installed: Data
    }
    public static func restorationURL(for config: URL, in directory: URL, prefix: String) -> URL {
        let hash = SHA256.hash(data: Data(config.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(prefix + "-restoration-" + hash + ".json")
    }
    /// Restore exact original bytes only while our installed bytes are untouched.
    /// If another tool edited the configuration, use the caller's semantic merge.
    public static func writeConfigurationChange(original: Data?, updated: Data, to url: URL,
                                                 restorationURL: URL, disconnecting: Bool) throws {
        let previous = (try? Data(contentsOf: restorationURL)).flatMap { try? JSONDecoder().decode(ConfigurationRestoration.self, from: $0) }
        let ownsSnapshot = previous?.installed == original
        if disconnecting {
            if ownsSnapshot, let previous {
                if let bytes = previous.original { try writeConfigurationVerified(bytes, to: url) }
                else { try FileManager.default.removeItem(at: url.resolvingSymlinksInPath()) }
            } else { try writeConfigurationVerified(updated, to: url) }
            if FileManager.default.fileExists(atPath: restorationURL.path) { try FileManager.default.removeItem(at: restorationURL) }
        } else {
            let saved = ConfigurationRestoration(original: ownsSnapshot ? previous?.original : original, installed: updated)
            try secureWriteVerified(JSONEncoder().encode(saved), to: restorationURL)
            try writeConfigurationVerified(updated, to: url)
        }
    }
    /// Client-owned configuration keeps its existing mode. Private monitor data
    /// continues to use secureWriteVerified's 0600 policy.
    public static func writeConfigurationVerified(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        if let mode, mode.intValue & 0o222 == 0 { throw CocoaError(.fileWriteNoPermission) }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".lunavect-" + UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode?.intValue ?? 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard try Data(contentsOf: target) == data else { throw SessionError.changedConfig }
    }
    /// Match only our UUID backup filenames, excluding foreign files, links,
    /// restoration metadata and other providers' backups.
    public static func pruneOwnedBackups(in directory: URL, prefix: String, keeping limit: Int = 8) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        let backups = files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a > b
        }
        for file in backups.dropFirst(max(1, limit)) { try FileManager.default.removeItem(at: file) }
    }
    static func secureWriteVerified(_ data: Data, to url: URL) throws {
        try secureWrite(data, to: url)
        guard try Data(contentsOf: url) == data else { throw SessionError.changedConfig }
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
