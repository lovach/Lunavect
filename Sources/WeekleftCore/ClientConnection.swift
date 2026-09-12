import Foundation
import Darwin

/// Starts the vendor's unchanged client. Login output and credentials never pass
/// through Lunavect: Terminal owns that interaction; status checks discard output.
public enum ClientConnection {
    public enum Action: String { case install, signIn, reviewUsage }
    public enum SignInState: Equatable { case signedIn, signedOut, unavailable }

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
        await Task.detached(priority: .utility) {
            readSignInState(provider, executable: executable, timeout: timeout)
        }.value
    }
    private static func readSignInState(_ provider: ProviderID, executable: String, timeout: TimeInterval) -> SignInState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = provider == .claude ? ["auth", "status"] : ["login", "status"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let end = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return .unavailable
        }
        guard process.terminationReason == .exit else { return .unavailable }
        switch process.terminationStatus {
        case 0: return .signedIn
        case 1: return .signedOut
        default: return .unavailable
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
