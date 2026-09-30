import Foundation
import Darwin
import CryptoKit

/// Where Claude Code and Codex find Lunavect's hook helper (owner decision 18).
/// Commands name a stable symbolic link in Lunavect's support folder; every launch
/// points it at the running copy's helper, so moving, renaming or updating the app
/// never requires rewriting client configuration. A copy that macOS runs from App
/// Translocation is temporary: it neither retargets the link nor installs commands.
public struct HookHelperLocation: Sendable, Equatable {
    public static var defaultLink: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Weekleft/bin/LunavectHook")
    }
    public let link: URL
    public let bundle: URL
    /// Command-line development builds have no embedded helper.
    public let fallback: String?
    public init(link: URL = HookHelperLocation.defaultLink, bundle: URL = Bundle.main.bundleURL,
                fallback: String? = Bundle.main.executablePath) {
        self.link = link; self.bundle = bundle; self.fallback = fallback
    }
    public static func isTranslocated(_ bundle: URL) -> Bool { bundle.path.contains("/AppTranslocation/") }
    public var isTranslocated: Bool { Self.isTranslocated(bundle) }
    /// The running copy's helper, or the development fallback.
    public var bundledHelper: String? { SessionHooks.monitorExecutable(bundle: bundle, fallback: fallback) }
    /// A symbolic link (never a file placed there) that leads to an executable.
    public var linkIsUsable: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
            && FileManager.default.isExecutableFile(atPath: link.path)
    }
    /// The executable new or repaired commands name; nil from a translocated copy.
    public var commandExecutable: String? {
        guard !isTranslocated else { return nil }
        return linkIsUsable ? link.path : bundledHelper
    }
    /// Executables whose commands count as a working connection: the link and,
    /// for installations made before it existed, the running copy's own helper.
    public var acceptedExecutables: [String] {
        var result: [String] = []
        if linkIsUsable { result.append(link.path) }
        if !isTranslocated, let helper = bundledHelper, FileManager.default.isExecutableFile(atPath: helper) { result.append(helper) }
        return result
    }
    public enum LinkUpdate: Equatable, Sendable { case unchanged, updated, translocated, missingHelper }
    /// Points the link at this copy's helper, atomically. Only a symbolic link is
    /// ever replaced; any other file at that path is left untouched and reported.
    @discardableResult public func refreshLink() throws -> LinkUpdate {
        guard !isTranslocated else { return .translocated }
        guard let target = bundledHelper, FileManager.default.isExecutableFile(atPath: target) else { return .missingHelper }
        try LiveWriteGuard.check(link)
        let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        if current == target { return .unchanged }
        var info = stat()
        if current == nil, lstat(link.path, &info) == 0 { throw CocoaError(.fileWriteFileExists) }
        let directory = link.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".LunavectHook-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        guard rename(temporary.path, link.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return .updated
    }
}

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
        (provider == .claude ? ["Notification", "PostToolUseFailure", "StopFailure", "PreCompact", "PostCompact", "SubagentStop"] : ["Interrupt"])
    }
    public static func configured(_ provider: ProviderID, configURL: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: configURL ?? self.configURL(provider)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: [[String: Any]]] else { return false }
        return hooks.values.flatMap { $0 }.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.hasSuffix(marker(provider)) == true }
        }
    }
    /// The exact command Lunavect installs for one provider's lifecycle events.
    /// Claude Code and Codex run it with /bin/sh; the path is single-quoted.
    public static func command(_ provider: ProviderID, executable: String) -> String {
        "\(quote(executable)) --session-hook \(provider.rawValue) \(marker(provider))"
    }
    public static func installed(_ provider: ProviderID, configURL: URL? = nil, executable: String?) -> Bool {
        installed(provider, configURL: configURL, accepting: executable.map { [$0] } ?? [])
    }
    /// Every event has a Lunavect handler naming one of `executables`: the stable
    /// link or, for older installations, the running copy's own helper path.
    public static func installed(_ provider: ProviderID, configURL: URL? = nil,
                                 accepting executables: [String] = HookHelperLocation().acceptedExecutables) -> Bool {
        let expected = Set(executables.filter { FileManager.default.isExecutableFile(atPath: $0) }.map { command(provider, executable: $0) })
        guard !expected.isEmpty,
              let data = try? Data(contentsOf: configURL ?? self.configURL(provider)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["disableAllHooks"] as? Bool != true, let hooks = root["hooks"] as? [String: [[String: Any]]]
        else { return false }
        return events(provider).allSatisfy { event in
            (hooks[event] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String).map(expected.contains) == true && $0["type"] as? String == "command"
                }
            }
        }
    }
    /// The path a Lunavect command names, from its leading single-quoted word.
    static func quotedExecutable(_ command: String) -> String? {
        guard command.hasPrefix("'") else { return nil }
        var result = "", rest = command.dropFirst()
        while let close = rest.firstIndex(of: "'") {
            result += rest[..<close]
            rest = rest[rest.index(after: close)...]
            guard rest.hasPrefix("\"'\"'") else { return result }
            result += "'"; rest = rest.dropFirst(4)
        }
        return nil
    }
    /// The first path named by Lunavect's own handlers that no longer leads to an
    /// executable, for example after the app was moved or ran from a temporary copy.
    public static func missingCommandExecutable(_ provider: ProviderID, configURL: URL? = nil) -> String? {
        guard let root = try? readConfiguration(at: configURL ?? self.configURL(provider)),
              let hooks = root["hooks"] as? [String: [[String: Any]]] else { return nil }
        for event in events(provider) {
            for handler in (hooks[event] ?? []).flatMap({ $0["hooks"] as? [[String: Any]] ?? [] }) {
                guard let command = handler["command"] as? String, command.hasSuffix(marker(provider)),
                      let path = quotedExecutable(command) else { continue }
                if !FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        if provider == .claude, let command = (root["statusLine"] as? [String: Any])?["command"] as? String,
           command.hasSuffix(" --claude-statusline"), let path = quotedExecutable(command),
           !FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
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
        return try strictObject(Data(contentsOf: url))
    }
    /// Foundation's parser also accepts comments and trailing commas, which a
    /// rewrite would silently drop. Such settings are unreadable for Lunavect: it
    /// never rewrites or backs them up (audit 05 §5 item 3).
    public static func strictObject(_ data: Data) throws -> [String: Any] {
        guard data.count < 5_000_000, !isLenientJSON(data),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SessionError.invalidResponse }
        return root
    }
    /// A comment or a comma before a closing bracket, outside string literals.
    static func isLenientJSON(_ data: Data) -> Bool {
        var inString = false, escaped = false, previous: UInt8 = 0
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true; previous = 0; continue
            case 0x20, 0x09, 0x0A, 0x0D: continue  // whitespace keeps the previous token
            case 0x2F where previous == 0x2F, 0x2A where previous == 0x2F: return true
            case 0x7D where previous == 0x2C, 0x5D where previous == 0x2C: return true
            default: break
            }
            previous = byte
        }
        return false
    }
    /// Pretty, key-sorted JSON with a final newline (owner decision 19). Sorting
    /// keeps the bytes deterministic so an untouched connection can be undone exactly.
    public static func serialized(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
    /// The file a write through `url` replaces, following links even when the
    /// final target does not exist yet (a dotfile link to a missing file).
    static func writeTarget(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return current }
            current = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
        }
        return current
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
    /// Launch repair (owner decision 17): each Lunavect handler that names another
    /// path is rewritten in place to `executable`. Events without a Lunavect handler
    /// stay without one, foreign handlers and their order are untouched, and a
    /// duplicate Lunavect handler within one event is dropped.
    /// - Returns: whether the configuration changed.
    @discardableResult public static func retarget(provider: ProviderID, executable: String, configURL: URL? = nil,
                                                   backupDirectory: URL? = nil) throws -> Bool {
        let url = configURL ?? self.configURL(provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let desired = command(provider, executable: executable)
        return try edit(provider: provider, url: url, backup: backupDirectory ?? directory.appendingPathComponent("backups"),
                        disconnecting: false, checkpoint: { _ in }) { original in
            var root = original
            if root["disableAllHooks"] as? Bool == true { throw SessionError.disabled }
            guard root["hooks"] == nil || root["hooks"] is [String: [[String: Any]]] else { throw SessionError.invalidResponse }
            var hooks = root["hooks"] as? [String: [[String: Any]]] ?? [:]
            for (event, groups) in hooks {
                var seen = false, kept: [[String: Any]] = []
                for var group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw SessionError.invalidResponse }
                    var updated: [[String: Any]] = []
                    for var handler in handlers {
                        guard (handler["command"] as? String)?.hasSuffix(marker(provider)) == true else { updated.append(handler); continue }
                        guard !seen else { continue }
                        seen = true
                        handler["command"] = desired; handler["type"] = "command"
                        updated.append(handler)
                    }
                    if !updated.isEmpty || handlers.isEmpty { group["hooks"] = updated; kept.append(group) }
                }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if !hooks.isEmpty { root["hooks"] = hooks }
            return root
        }
    }
    private static func edit(provider: ProviderID, executable: String?, url: URL, backup: URL,
                             checkpoint: (ClientConnection.LocalStep) throws -> Void) throws {
        try edit(provider: provider, url: url, backup: backup, disconnecting: executable == nil, checkpoint: checkpoint) {
            try editedConfiguration(provider: provider, executable: executable, root: $0)
        }
    }
    @discardableResult private static func edit(provider: ProviderID, url: URL, backup: URL, disconnecting: Bool,
                                                checkpoint: (ClientConnection.LocalStep) throws -> Void,
                                                change: ([String: Any]) throws -> [String: Any]) throws -> Bool {
        try LiveWriteGuard.check(url, backup)
        let old = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        let original: [String: Any]
        if let old { original = try strictObject(old) } else { original = [:] }
        let root = try change(original)
        if (original as NSDictionary).isEqual(to: root) { return false }
        try checkpoint(.hooksBackup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let old { try secureWriteVerified(old, to: backup.appendingPathComponent("\(provider.rawValue)-\(UUID().uuidString).json")) }
        try checkpoint(.hooksWrite)
        let current = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        guard current == old else { throw SessionError.changedConfig }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeConfigurationChange(original: old, updated: serialized(root),
            to: url, restorationURL: restorationURL(for: url, in: backup, prefix: provider.rawValue),
            disconnecting: disconnecting)
        try pruneOwnedBackups(in: backup, prefix: provider.rawValue + "-")
        return true
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
        try LiveWriteGuard.check(url, restorationURL)
        let previous = (try? Data(contentsOf: restorationURL)).flatMap { try? JSONDecoder().decode(ConfigurationRestoration.self, from: $0) }
        let ownsSnapshot = previous?.installed == original
        if disconnecting {
            // A file that did not exist before connecting stays, without Lunavect's
            // entries: tools that created it meanwhile keep a valid file (H-08).
            try writeConfigurationVerified(ownsSnapshot ? previous?.original ?? updated : updated, to: url)
            if FileManager.default.fileExists(atPath: restorationURL.path) { try FileManager.default.removeItem(at: restorationURL) }
        } else if !ownsSnapshot, containsOwnedEntries(original) {
            // These bytes already hold Lunavect's own (older) handlers, e.g. after an app
            // move or new hook events; they are not a pre-connection original. Without a
            // snapshot, disconnecting removes only Lunavect's entries and keeps the rest.
            if FileManager.default.fileExists(atPath: restorationURL.path) { try FileManager.default.removeItem(at: restorationURL) }
            try writeConfigurationVerified(updated, to: url)
        } else {
            let saved = ConfigurationRestoration(original: ownsSnapshot ? previous?.original : original, installed: updated)
            try secureWriteVerified(JSONEncoder().encode(saved), to: restorationURL)
            try writeConfigurationVerified(updated, to: url)
        }
    }
    static func containsOwnedEntries(_ data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("# lunavect-session-monitor:") || text.contains(" --claude-statusline")
    }
    /// Client-owned configuration keeps its existing mode. Private monitor data
    /// continues to use secureWriteVerified's 0600 policy.
    /// Write, flush, then rename (H-07): a power loss leaves either the old or the
    /// new complete file. A link is kept and its target replaced.
    public static func writeConfigurationVerified(_ data: Data, to url: URL,
                                                  synchronize: (Int32) throws -> Void = flush) throws {
        let target = writeTarget(url)
        try LiveWriteGuard.check(url, target)
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        if let mode, mode.intValue & 0o222 == 0 { throw CocoaError(.fileWriteNoPermission) }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".lunavect-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode?.intValue ?? 0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            // open() applies the umask; restore the client file's own mode.
            guard fchmod(descriptor, mode_t(mode?.intValue ?? 0o600)) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try synchronize(descriptor)
        } catch { close(descriptor); throw error }
        guard close(descriptor) == 0, rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let folder = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if folder >= 0 { _ = fsync(folder); close(folder) }
        guard try Data(contentsOf: target) == data else { throw SessionError.changedConfig }
    }
    /// F_FULLFSYNC reaches the storage medium; plain fsync is the fallback.
    public static func flush(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    /// Older releases created saved settings copies with mode 0644 (audit H-12).
    /// Restrict Lunavect's own backup names to 0600: regular files of this user
    /// only, never a link or a foreign file. Returns how many were changed.
    @discardableResult public static func restrictOwnBackups(bridgeDirectory: URL, backupDirectory: URL) throws -> Int {
        func uuid(_ name: String, after prefix: String) -> Bool {
            name.hasPrefix(prefix) && name.hasSuffix(".json")
                && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(5))) != nil
        }
        let rules: [(URL, (String) -> Bool)] = [
            (bridgeDirectory, { $0 == "previous-statusline.json" || uuid($0, after: "settings-backup-") || $0.hasPrefix("statusline-restoration-") && $0.hasSuffix(".json") }),
            (backupDirectory, { name in ProviderID.allCases.contains { uuid(name, after: $0.rawValue + "-") || name.hasPrefix($0.rawValue + "-restoration-") && name.hasSuffix(".json") } }),
        ]
        var changed = 0
        for (directory, owned) in rules {
            try LiveWriteGuard.check(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where owned(name) {
                let descriptor = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                      info.st_mode & 0o077 != 0 else { continue }
                if fchmod(descriptor, 0o600) == 0 { changed += 1 }
            }
        }
        return changed
    }
    /// Match only our UUID backup filenames, excluding foreign files, links,
    /// restoration metadata and other providers' backups.
    public static func pruneOwnedBackups(in directory: URL, prefix: String, keeping limit: Int = 8) throws {
        try LiveWriteGuard.check(directory)
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
    /// `isInternal` identifies Lunavect's own quota probe by its folder. `--safe-mode`
    /// currently disables hooks there; this keeps a future client from recording it.
    /// `now` is the event's time: the hook helper passes the moment it started.
    public static func capture(_ data: Data, provider: ProviderID, at directory: URL = directory, now: Date = Date(), client: SessionClient = .unknown, nestedClaudeRuntime: Bool? = nil, terminal: (tty: String, app: String)? = nil, ide: IDESessionLocation? = nil,
                               runtimePID: Int32? = nil, backgroundRun: Bool = false,
                               isInternal: (String) -> Bool = { ClaudeUsageProbe.isProbeSession(cwd: $0, pid: nil) },
                               isAlive: (Int32) -> Bool = SessionSources.isProcessAlive) throws {
        try LiveWriteGuard.check(directory)
        let initial = try SessionRecord.event(data, provider: provider, previous: nil, now: now, client: client)
        if provider == .claude, isInternal(initial.session.cwd) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(provider.rawValue)-\(initial.session.sessionID).json")
        let lock = open(directory.appendingPathComponent(".capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SessionError.unavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw SessionError.unavailable }
        let existing = try? Data(contentsOf: file)
        // A turn whose recorded runtime is gone ended with it (R2-03, for example resume after kill).
        let previous = existing.flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
            .map { provider == .claude ? SessionRecord.endingReplacedRuntime($0, runtimePID: runtimePID, isAlive: isAlive) : $0 }
        // A record that no longer decodes loses its turn start and pending
        // approvals. Keep its bytes aside for diagnosis and say so (S-09).
        let unreadable = existing != nil && previous == nil
        if unreadable {
            try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent + Self.corruptMarker + UUID().uuidString))
        }
        // A print-mode run on a session that still runs interactively elsewhere (`claude -p --resume` or `--continue`
        // from a script): it shares the session id, not the session's tab, runtime or client, and its end is not the
        // session's end (docs: two processes on one session interleave one transcript).
        let secondary = provider == .claude && backgroundRun && previous.map { old in
            old.session.isBackgroundRun != true && (old.session.runtimePID.map { $0 != runtimePID && isAlive($0) } ?? false)
        } == true
        if secondary, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hook_event_name"] as? String == "SessionEnd" { return }
        var record = try SessionRecord.event(data, provider: provider, previous: previous, now: now, client: client)
        if unreadable { record.session.hookDiagnostic = HookDiagnostic(kind: .unreadableRecord, at: now) }
        // An ignored notice for a session without a record carries no lifecycle.
        if previous == nil, record.session.phase == .unknown { return }
        if provider == .claude, let nestedClaudeRuntime { record.session.isNestedClaudeSession = nestedClaudeRuntime }
        if secondary, let old = previous?.session {
            record.session.runtimePID = old.runtimePID; record.session.client = old.client
            record.session.terminalTTY = old.terminalTTY; record.session.terminalApp = old.terminalApp; record.session.ideLocation = old.ideLocation
            try secureWrite(JSONEncoder().encode(record), to: file)
            return
        }
        // Replaced on every event: a resumed session runs in a new process.
        if provider == .claude { record.session.runtimePID = runtimePID }
        // The latest runtime decides: an interactive process reporting again ends an earlier print-mode run's mark.
        if provider == .claude, backgroundRun { record.session.isBackgroundRun = true }
        else if provider == .claude, runtimePID != nil { record.session.isBackgroundRun = nil }
        if let terminal { record.session.terminalTTY = terminal.tty; record.session.terminalApp = terminal.app }
        if let ide {
            record.session.ideLocation = ide; record.session.client = ide.editor.client
            record.session.terminalTTY = nil; record.session.terminalApp = nil
        } else if terminal != nil || [.terminal, .desktop, .background].contains(client) {
            record.session.ideLocation = nil
            if client == .desktop || client == .background {
                record.session.terminalTTY = nil; record.session.terminalApp = nil
            }
        }
        try secureWrite(JSONEncoder().encode(record), to: file)
    }
    public static func load(at directory: URL = directory) -> [AgentSession] {
        _ = try? prune(at: directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        let records = files.filter { $0.pathExtension == "json" }
        // Polled every one to five seconds. Captures replace a record by rename,
        // so an unchanged identity/size/time means the decoded record is unchanged.
        loadedRecords.retain(records.map(\.path))
        return records.compactMap { url in
            guard let identity = LocalFileIdentity(path: url.path), identity.size < 65536 else { return nil }
            return loadedRecords.value(for: url.path, identity: identity) {
                guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
                      SessionParser.validID(record.session.sessionID) else { return nil }
                return record.session
            }
        }
    }
    private static let loadedRecords = LocalFileCache<AgentSession>()
    static let corruptMarker = ".corrupt-"
    /// Lifecycle observations expire after a day. Clean only this monitor's
    /// records, under the same lock as capture; never touch provider transcripts.
    @discardableResult public static func prune(at directory: URL = directory, now: Date = Date()) throws -> Int {
        try LiveWriteGuard.check(directory)
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
        /// `<provider>-<id>.json.corrupt-<uuid>`, set aside by capture.
        func setAside(_ url: URL) -> Bool {
            let name = url.lastPathComponent
            guard let marker = name.range(of: ".json" + corruptMarker) else { return false }
            return owned(URL(fileURLWithPath: String(name[..<marker.lowerBound]) + ".json")) && UUID(uuidString: String(name[marker.upperBound...])) != nil
        }
        var removed = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let modified = values.contentModificationDate, modified < cutoff else { continue }
            if file.pathExtension == "json", owned(file) {
                let loadable = (values.fileSize ?? 0) < 65536
                let data = loadable ? try? Data(contentsOf: file) : nil
                if let data, let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
                    guard file.lastPathComponent == "\(record.session.provider.rawValue)-\(record.session.sessionID).json",
                          record.session.observedAt < cutoff else { continue }
                } else if loadable && data == nil {
                    continue // Not readable right now (for example permissions): not proof of damage.
                }
                // Expired, or never loadable again (damaged, oversized or rejected
                // by a stricter decoder): it would be decoded on every poll forever.
                try FileManager.default.removeItem(at: file); removed += 1
            } else if setAside(file) {
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
        try LocalStateRecovery.removeAbandonedTemporaries(in: directory, now: now)
        try secureWrite(Data(), to: stamp)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
        return removed
    }
    /// Terminal runs a launcher once and `exec`s the client, so it is only needed
    /// until Terminal starts it. Remove only Lunavect's own launchers after a day.
    @discardableResult public static func pruneOpeners(in directory: URL, now: Date = Date()) throws -> Int {
        try LiveWriteGuard.check(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var removed = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) where file.pathExtension == "command" {
            let name = file.deletingPathExtension().lastPathComponent
            guard ProviderID.allCases.contains(where: { name.hasPrefix($0.rawValue + "-") && SessionParser.validID(String(name.dropFirst($0.rawValue.count + 1))) }),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > 86400 else { continue }
            try FileManager.default.removeItem(at: file); removed += 1
        }
        return removed
    }
}
