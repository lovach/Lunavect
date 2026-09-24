import Darwin
import Foundation

/// One resolution policy for setup, quotas, catalogs and session destinations.
/// An explicit choice is never silently replaced with a different installation.
public struct ClientExecutableResolver: Sendable {
    public let codexPath: String
    private let discoverCodex: @Sendable () -> String?
    private let discoverClaude: @Sendable () -> String?
    private let isExecutable: @Sendable (String) -> Bool

    public init(codexPath: String = "",
                discoverCodex: @escaping @Sendable () -> String? = { CodexProvider.discoverCLI() },
                discoverClaude: @escaping @Sendable () -> String? = { SessionSources.discoverClaude() },
                isExecutable: @escaping @Sendable (String) -> Bool = { ClientExecutableResolver.isExecutableFile($0) }) {
        self.codexPath = codexPath
        self.discoverCodex = discoverCodex
        self.discoverClaude = discoverClaude
        self.isExecutable = isExecutable
    }

    public func resolve(_ provider: ProviderID) throws -> String {
        let explicit = provider == .codex && !codexPath.isEmpty
        let candidate = explicit ? codexPath : (provider == .codex ? discoverCodex() : discoverClaude())
        guard let candidate, candidate.hasPrefix("/"),
              !candidate.contains("\n"), !candidate.contains("\r"), !candidate.contains("\0"),
              isExecutable(candidate) else {
            throw explicit ? SessionOpeningError.unavailableConfiguredCodex : SessionOpeningError.missingCLI(provider)
        }
        return candidate
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

public extension AgentSession {
    var shortProjectPath: String {
        guard !cwd.isEmpty, !cwd.contains("/scratch-workspaces/") else { return project }
        let parts = cwd.split(separator: "/")
        guard !parts.isEmpty else { return "/" }
        return (parts.count > 2 ? "…/" : "/") + parts.suffix(2).joined(separator: "/")
    }
    var vscodeURL: URL? {
        guard provider == .claude, UUID(uuidString: sessionID) != nil else { return nil }
        var url = URLComponents(string: "vscode://anthropic.claude-code/open")!
        url.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return url.url
    }
    func claudeDesktopURL(desktopID: String) -> URL? {
        guard provider == .claude, desktopID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        // The installed desktop client accepts its local-session route directly.
        // code/continue is separately feature-gated and may silently do nothing.
        return URL(string: "claude://claude.ai/epitaxy/" + desktopID)
    }
    /// Only a recorded SessionEnd establishes that a foreground client exited.
    /// Freshness and isCurrent are observations, not process-liveness checks.
    var canLaunchTerminalSession: Bool {
        client == .background && provider == .claude && resumeID.map(SessionParser.validID) == true ||
        client == .terminal && phase == .finished && evidence == .hook
    }
    /// A live CLI session is brought forward in its own terminal tab. A device
    /// recorded by a hook is evidence even when another source names the client.
    var terminalFocusCandidate: Bool {
        !canLaunchTerminalSession && (client == .terminal || terminalTTY.map(TerminalLocation.valid) == true)
    }
    /// Background attach is safe; foreground resume requires recorded exit.
    func terminalScript(resolver: ClientExecutableResolver) throws -> String {
        let executable = try resolver.resolve(provider)
        guard canLaunchTerminalSession else { throw SessionOpeningError.sessionMayBeOpen }
        guard let script = terminalScript(executable: executable) else { throw SessionOpeningError.invalidID }
        return script
    }
    func terminalScript(executable: String) -> String? {
        guard executable.hasPrefix("/"), cwd.hasPrefix("/") else { return nil }
        let arguments: String
        if provider == .claude, client == .background {
            guard let resumeID, SessionParser.validID(resumeID) else { return nil }
            arguments = "attach " + SessionHooks.quote(resumeID)
        } else {
            guard UUID(uuidString: sessionID) != nil, client != .terminal || canLaunchTerminalSession else { return nil }
            arguments = (provider == .claude ? "--resume " : "resume ") + SessionHooks.quote(sessionID)
        }
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return "#!/bin/zsh\nexport PATH=" + SessionHooks.quote(directory) + ":\"$PATH\"\ncd -- " + SessionHooks.quote(cwd) + " || exit 1\nexec " + SessionHooks.quote(executable) + " " + arguments + "\n"
    }
}

public enum SessionOpeningError: LocalizedError, Equatable {
    case unavailableConfiguredCodex, sessionMayBeOpen
    case missingCLI(ProviderID), missingProject, missingTerminal, invalidID, missingDesktopLink, missingClient(String), launchFailed(SessionClient)
    public var errorDescription: String? {
        switch self {
        case .sessionMayBeOpen: return L("Сессия может быть открыта в терминале. Вернитесь в исходное окно. Через «…» можно открыть папку проекта или скопировать ID сессии.")
        case .unavailableConfiguredCodex: return L("Клиент Codex по выбранному пути недоступен. Откройте «Подключения» и выберите исполняемый файл заново.")
        case .missingCLI(let provider): return L("Не найден клиент {0}. Откройте «Подключения» и завершите установку официального клиента.", provider.title)
        case .missingProject: return L("Папка проекта недоступна. Верните её на прежнее место или откройте сессию в официальном приложении. Команду продолжения можно скопировать через «…».")
        case .missingTerminal: return L("Terminal не найден. Откройте другой терминал и вставьте команду продолжения из меню «…».")
        case .invalidID: return L("Не удалось определить ссылку на эту сессию. Откройте её в официальном приложении и обновите список Lunavect.")
        case .missingDesktopLink:
            return L(
                "Claude не передал ссылку на эту сессию. Откройте её в Claude и обновите список. Для локальной сессии также можно скопировать команду продолжения через «…»."
            )
        case .missingClient(let name): return L("Приложение {0} не найдено. Установите или откройте его, затем повторите переход.", name)
        case .launchFailed(.vscode): return L("VS Code не принял переход. Откройте папку проекта в VS Code, проверьте расширение Claude Code и повторите попытку.")
        case .launchFailed(.terminal), .launchFailed(.background): return L("Не удалось запустить Terminal. Откройте терминал вручную и вставьте команду продолжения из меню «…».")
        case .launchFailed: return L("Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…».")
        }
    }
}

/// Brings an existing terminal tab to the front by its controlling device.
/// The device path is validated before it is placed in the script.
public enum TerminalLocation {
    public struct Target: Equatable, Sendable {
        public let tty: String
        public let app: String
        public init(tty: String, app: String) { self.tty = tty; self.app = app }
    }
    /// The recorded device of a live CLI session, or for a terminal session without
    /// one, a running process of the same client in its project folder. Desktop and
    /// editor sessions never search processes: a CLI in the same folder is another task.
    public static func focusTarget(for session: AgentSession,
                                   running: (ProviderID, String) -> Target? = { runningTarget(provider: $0, cwd: $1) }) -> Target? {
        guard session.terminalFocusCandidate else { return nil }
        if let tty = session.terminalTTY, valid(tty) { return Target(tty: tty, app: session.terminalApp ?? "Terminal") }
        guard session.client == .terminal else { return nil }
        return running(session.provider, session.cwd)
    }
    /// Fallback for sessions whose hook did not record a device: the controlling
    /// terminal of a running claude/codex process in the same project folder.
    /// Reads process metadata only (executable path, working directory, device).
    public static func runningTarget(provider: ProviderID, cwd: String) -> Target? {
        guard cwd.hasPrefix("/") else { return nil }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(),
                  info.e_tdev != UInt32.max, let process = SessionProcess.runtimeProcess(pid),
                  SessionProcess.runtimeProvider(ofExecutable: process.executable) == provider else { continue }
            var vnode = proc_vnodepathinfo()
            let vsize = Int32(MemoryLayout.size(ofValue: vnode))
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vsize) == vsize else { continue }
            let dir = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard dir == cwd, let dev = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { continue }
            let tty = "/dev/" + String(cString: dev)
            guard valid(tty) else { continue }
            // The ancestry can stop at Terminal's root-owned login process.
            let app = SessionProcess.terminalLocation(parentPID: pid, termProgram: "")?.app ?? "Terminal"
            return Target(tty: tty, app: app)
        }
        return nil
    }
    public static func bundleIdentifier(forApp app: String) -> String? {
        switch app {
        case "Terminal": return "com.apple.Terminal"
        case "iTerm2": return "com.googlecode.iterm2"
        default: return nil
        }
    }
    /// `\z` rather than `$`: a trailing newline must not reach the script.
    public static func valid(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys[0-9]{1,4}\z"#, options: .regularExpression) != nil
    }
    /// Each Apple event waits at most `focusTimeout` seconds and a timeout ends the
    /// whole search, so a busy or hung terminal cannot hold the caller for the
    /// default two minutes per event. Other per-tab errors only skip that tab.
    public static let focusTimeout = 10
    public static func focusScript(tty: String, app: String) -> String? {
        guard valid(tty) else { return nil }
        switch app {
        case "Terminal":
            return """
            with timeout of \(focusTimeout) seconds
            tell application "Terminal"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            try
                                if tty of t is "\(tty)" then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected of t to true
                                    set index of w to 1
                                    activate
                                    return true
                                end if
                            on error errorMessage number errorNumber
                                if errorNumber is -1712 then error errorMessage number errorNumber
                            end try
                        end repeat
                    on error errorMessage number errorNumber
                        if errorNumber is -1712 then error errorMessage number errorNumber
                    end try
                end repeat
            end tell
            end timeout
            return false
            """
        case "iTerm2":
            return """
            with timeout of \(focusTimeout) seconds
            tell application "iTerm2"
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if tty of s is "\(tty)" then
                                        select w
                                        tell t to select
                                        tell s to select
                                        activate
                                        return true
                                    end if
                                on error errorMessage number errorNumber
                                    if errorNumber is -1712 then error errorMessage number errorNumber
                                end try
                            end repeat
                        end repeat
                    on error errorMessage number errorNumber
                        if errorNumber is -1712 then error errorMessage number errorNumber
                    end try
                end repeat
            end tell
            end timeout
            return false
            """
        default: return nil
        }
    }
}
