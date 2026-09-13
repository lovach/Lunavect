import Foundation
import Darwin

/// Starts the vendor's unchanged client. Login output and credentials never pass
/// through Lunavect: Terminal owns that interaction; status checks discard output.
public enum ClientConnection {
    public enum Action: String { case install, signIn, reviewUsage }
    public enum SignInState: Equatable, Sendable { case signedIn, signedOut, unavailable }

    public enum LocalOperation: Sendable { case connect, disconnect }
    /// Checkpoints cover each persistent write and both boundaries between components.
    /// They also allow fixtures to model I/O failures and external edits without a live client.
    public enum LocalStep: CaseIterable, Sendable {
        case prepare, statusLinePrevious, statusLineBackup, statusLineWrite
        case beforeHooks, hooksBackup, hooksWrite, verify
    }
    public enum LocalComponentState: Equatable, Sendable {
        case absent, ready, partial, unavailable
        public var message: String {
            switch self {
            case .absent: return "Не настроено"
            case .ready: return "Настроено"
            case .partial: return "Требуется завершить настройку"
            case .unavailable: return "Не удалось прочитать настройки"
            }
        }
    }
    public struct LocalState: Equatable, Sendable {
        public let statusLine: LocalComponentState?
        public let hooks: LocalComponentState
        public init(statusLine: LocalComponentState?, hooks: LocalComponentState) {
            self.statusLine = statusLine; self.hooks = hooks
        }
        public var connected: Bool { hooks == .ready && (statusLine == nil || statusLine == .ready) }
        public var disconnected: Bool { hooks == .absent && (statusLine == nil || statusLine == .absent) }
        public var hasConfiguration: Bool {
            hooks == .ready || hooks == .partial || statusLine == .ready || statusLine == .partial
        }
    }
    public struct LocalFailure: LocalizedError {
        public let operation: LocalOperation
        public let state: LocalState
        public let cause: Error
        public var errorDescription: String? { cause.localizedDescription }
    }
    /// A recoverable operation, not a rollback of the client's whole configuration.
    /// Every component rereads current settings and touches only Lunavect-owned entries.
    public struct LocalSetup: Sendable {
        public let provider: ProviderID
        public let executable: String?
        public let configURL: URL
        public let bridgeDirectory: URL
        public let backupDirectory: URL
        public init(provider: ProviderID, executable: String? = SessionHooks.monitorExecutable(),
                    configURL: URL? = nil, bridgeDirectory: URL = ClaudeProvider.directory,
                    backupDirectory: URL = SessionHooks.directory.appendingPathComponent("backups")) {
            self.provider = provider; self.executable = executable
            self.configURL = configURL ?? SessionHooks.configURL(provider)
            self.bridgeDirectory = bridgeDirectory; self.backupDirectory = backupDirectory
        }
        public func inspect() -> LocalState {
            let readable = (try? SessionHooks.readConfiguration(at: configURL)) != nil
            guard readable else {
                return LocalState(statusLine: provider == .claude ? .unavailable : nil, hooks: .unavailable)
            }
            let hooks: LocalComponentState
            do {
                try SessionHooks.validateEdit(provider: provider, executable: nil, url: configURL)
                hooks = SessionHooks.installed(provider, configURL: configURL, executable: executable) ? .ready :
                    SessionHooks.configured(provider, configURL: configURL) ? .partial : .absent
            } catch { hooks = .unavailable }
            var status: LocalComponentState?
            if provider == .claude {
                do {
                    try ClaudeProvider.validateStatusLine(settingsURL: configURL, bridgeDirectory: bridgeDirectory, connecting: false)
                    status = ClaudeProvider.statusLineInstalled(settingsURL: configURL, executable: executable) ? .ready :
                        ClaudeProvider.statusLineConfigured(settingsURL: configURL) ? .partial : .absent
                } catch {
                    status = ClaudeProvider.statusLineConfigured(settingsURL: configURL) ? .partial : .unavailable
                }
            }
            return LocalState(statusLine: status, hooks: hooks)
        }
        @discardableResult public func apply(_ operation: LocalOperation,
                                             checkpoint: (LocalStep) throws -> Void = { _ in }) throws -> LocalState {
            do {
                try checkpoint(.prepare)
                let connecting = operation == .connect
                if connecting {
                    guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { throw SessionError.unavailable }
                }
                // Validate both components before the first write. Each edit revalidates
                // fresh bytes, so a user's changes between steps are retained.
                try SessionHooks.validateEdit(provider: provider, executable: connecting ? executable : nil, url: configURL)
                if provider == .claude {
                    try ClaudeProvider.validateStatusLine(settingsURL: configURL, bridgeDirectory: bridgeDirectory, connecting: connecting)
                    if connecting, let executable {
                        try ClaudeProvider.installStatusLine(executable: executable, settingsURL: configURL,
                                                             bridgeDirectory: bridgeDirectory, checkpoint: checkpoint)
                    }
                }
                try checkpoint(.beforeHooks)
                if connecting, let executable {
                    try SessionHooks.install(provider: provider, executable: executable, configURL: configURL,
                                             backupDirectory: backupDirectory, checkpoint: checkpoint)
                } else {
                    try SessionHooks.remove(provider: provider, configURL: configURL, backupDirectory: backupDirectory, checkpoint: checkpoint)
                }
                // Unwind the same settings file in reverse installation order,
                // allowing untouched component snapshots to restore exact bytes.
                if provider == .claude, !connecting {
                    try ClaudeProvider.removeStatusLine(settingsURL: configURL, bridgeDirectory: bridgeDirectory, checkpoint: checkpoint)
                }
                try checkpoint(.verify)
                let state = inspect()
                guard connecting ? state.connected : state.disconnected else { throw SessionError.changedConfig }
                return state
            } catch {
                throw LocalFailure(operation: operation, state: inspect(), cause: error)
            }
        }
    }

    public static func installerURL(_ provider: ProviderID) -> URL {
        URL(string: provider == .claude ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh")!
    }
    public static func documentationURL(_ provider: ProviderID) -> URL {
        URL(string: provider == .claude ? "https://code.claude.com/docs/en/setup" : "https://learn.chatgpt.com/docs/cli")!
    }
    public static func authenticationURL(_ provider: ProviderID) -> URL {
        URL(string: provider == .claude ? "https://code.claude.com/docs/en/authentication" : "https://learn.chatgpt.com/docs/auth")!
    }

    public static func signInState(_ provider: ProviderID, executable: String, timeout: TimeInterval = 10) async -> SignInState {
        do {
            return try await SessionProcess.detached {
                try readSignInState(provider, executable: executable, timeout: timeout)
            }
        } catch { return .unavailable }
    }
    private static func readSignInState(_ provider: ProviderID, executable: String, timeout: TimeInterval) throws -> SignInState {
        guard timeout.isFinite, timeout > 0 else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = SessionSources.environment(forExecutable: executable)
        process.arguments = provider == .claude ? ["auth", "status"] : ["login", "status"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try SessionProcess.withRunningProcess(process) {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
                Thread.sleep(forTimeInterval: 0.02)
            }
            try Task.checkCancellation()
            guard process.terminationReason == .exit else { return .unavailable }
            switch process.terminationStatus {
            case 0: return .signedIn
            case 1: return .signedOut
            default: return .unavailable
            }
        }
    }

    public static func script(provider: ProviderID, action: Action, executable: String?,
                              heading: String, completion: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        var lines = ["#!/bin/bash", "set -euo pipefail", "umask 077",
                     "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"",
                     "printf '%s\\n\\n' \(SessionHooks.quote(heading))"]
        // Match custom configuration directories, but never copy credential variables.
        let key = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        if let directory = environment[key], !directory.isEmpty {
            lines.append("export \(key)=\(SessionHooks.quote(directory))")
        }
        if action == .install {
            lines += [
                "lunavect_installer=$(/usr/bin/mktemp -t lunavect-install)",
                "trap '/bin/rm -f \"$lunavect_installer\"' EXIT",
                "/usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --show-error --location --max-time 90 \(SessionHooks.quote(installerURL(provider).absoluteString)) -o \"$lunavect_installer\"",
                (provider == .claude ? "/bin/bash" : "/bin/sh") + " \"$lunavect_installer\""
            ]
        } else {
            guard let executable, executable.hasPrefix("/"), !executable.contains("\n") else { throw SessionError.unavailable }
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            lines.append("export PATH=" + SessionHooks.quote(directory) + ":\"$PATH\"")
            if action == .reviewUsage && provider == .claude {
                lines += ["cd \(SessionHooks.quote(ClaudeUsageProbe.directory.path))",
                          "\(SessionHooks.quote(executable)) --safe-mode --tools '' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --no-chrome /usage"]
            } else {
                lines.append(SessionHooks.quote(executable) + (provider == .claude ? " auth login" : " login"))
            }
        }
        lines.append("printf '\\n%s\\n' \(SessionHooks.quote(completion))")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func writeLauncher(_ script: String, provider: ProviderID, action: Action, directory: URL? = nil) throws -> URL {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Weekleft/ConnectionSetup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(provider.rawValue + "-" + action.rawValue + ".command")
        try SessionHooks.secureWrite(Data(script.utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
