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
        ideLocation == nil && client != .vscode && client != .jetbrains &&
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
    case terminalTabUnavailable, terminalAutomationDenied(String), terminalFocusTimedOut(String), terminalFocusFailed(String)
    case terminalProcessEnded, terminalUnsupported(String), terminalAutomationPending(String)
    case ideBridgeMissing(String), ideSessionUnavailable(String), ideUnsupported(String), ideAmbiguous(String), ideTimedOut(String)
    case ideBridgeUnresponsive(String), ideCompanionIncompatible(String), ideActivationFailed(String)
    case missingCLI(ProviderID), missingProject, missingTerminal, invalidID, missingDesktopLink, missingClient(String), launchFailed(SessionClient)
    public var errorDescription: String? {
        switch self {
        case .sessionMayBeOpen: return L("Сессия может быть открыта в терминале. Вернитесь в исходное окно. Через «…» можно открыть папку проекта или скопировать ID сессии.")
        case .terminalTabUnavailable: return L("Не удалось найти исходную вкладку этой сессии. Убедитесь, что она открыта в Terminal или iTerm2, и повторите переход.")
        case .terminalAutomationDenied(let app): return L("Разрешите Lunavect управлять {0}: Системные настройки → Конфиденциальность и безопасность → Автоматизация. Затем повторите переход.", app)
        case .terminalFocusTimedOut(let app): return L("{0} не ответил на запрос перехода. Закройте открытые диалоги в терминале и повторите попытку.", app)
        case .terminalFocusFailed(let app): return L("Не удалось переключить вкладку в {0}. Откройте терминал и повторите переход.", app)
        case .terminalProcessEnded:
            return L("Клиент этой сессии больше не работает в своей вкладке терминала. Продолжите сессию командой из меню «…» → «Копировать команду продолжения».")
        case .terminalUnsupported(let app):
            return L("Переход к вкладке в {0} пока не поддерживается. Вернитесь в окно терминала вручную. Через «…» можно открыть папку проекта или скопировать команду продолжения.", app)
        case .terminalAutomationPending(let app):
            return L("macOS ждёт вашего ответа на запрос об управлении {0}. Ответьте на системный запрос и повторите переход.", app)
        case .ideBridgeMissing(let app): return L("Подключите {0} в настройках Lunavect, чтобы переходить к сессиям в редакторе.", app)
        case .ideSessionUnavailable(let app): return L("Не удалось найти эту сессию в {0}. Проверьте, что её проект и вкладка открыты, затем обновите список.", app)
        case .ideUnsupported(let app): return L("Этот способ запуска сессии в {0} пока не поддерживается. Поддерживаемые варианты указаны в настройках подключения редакторов.", app)
        case .ideAmbiguous(let app): return L("В {0} найдено несколько подходящих окон. Оставьте проект открытым в одном окне и повторите переход.", app)
        case .ideTimedOut(let app): return L("{0} не подтвердил переход к сессии. Проверьте запросы разрешений в редакторе и повторите попытку.", app)
        case .ideBridgeUnresponsive(let app):
            return L("Модуль Lunavect в {0} установлен, но не отвечает. Подождите полминуты или перезапустите окно редактора, затем повторите переход.", app)
        case .ideCompanionIncompatible(let app):
            return L("Версия модуля Lunavect в {0} не подходит к этой версии Lunavect. Переустановите модуль: Настройки → Подключения → Сессии в редакторах.", app)
        case .ideActivationFailed(let app): return L("Не удалось вывести {0} на передний план. Откройте окно редактора и повторите переход.", app)
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

/// Everything terminal navigation asks of the system. The policy in
/// `TerminalLocation.focusSession` is tested with fixtures; only the live
/// environment inspects processes or scripts another application.
public struct TerminalFocusEnvironment: Sendable {
    /// Whether an application with this bundle identifier is running. Supplied by the app target.
    public var isRunning: @Sendable (String) async -> Bool
    /// What runs on a terminal device, for the session's provider.
    public var occupancy: @Sendable (String, ProviderID) -> TerminalLocation.DeviceOccupancy
    /// Apple event permission for a bundle identifier; `true` may show the macOS consent prompt.
    public var permission: @Sendable (String, Bool) async throws -> Int32
    /// Runs the focus script for (device, app) within the given number of seconds.
    public var runScript: @Sendable (String, String, TimeInterval) async throws -> Bool
    public var runningTarget: @Sendable (ProviderID, String) -> TerminalLocation.Target?
    public var uptime: @Sendable () -> TimeInterval

    public init(isRunning: @escaping @Sendable (String) async -> Bool,
                occupancy: @escaping @Sendable (String, ProviderID) -> TerminalLocation.DeviceOccupancy = { _, _ in .unknown },
                permission: @escaping @Sendable (String, Bool) async throws -> Int32 = { _, _ in 0 },
                runScript: @escaping @Sendable (String, String, TimeInterval) async throws -> Bool = {
                    try await TerminalLocation.focus(tty: $0, app: $1, timeout: $2)
                },
                runningTarget: @escaping @Sendable (ProviderID, String) -> TerminalLocation.Target? = {
                    TerminalLocation.runningTarget(provider: $0, cwd: $1)
                },
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isRunning = isRunning; self.occupancy = occupancy; self.permission = permission
        self.runScript = runScript; self.runningTarget = runningTarget; self.uptime = uptime
    }
}

/// Brings an existing terminal tab to the front by its controlling device.
/// The device path is validated before it is placed in the script.
public enum TerminalLocation {
    /// Run automation in an owned helper process, so a stuck Apple event cannot
    /// block the app's main thread. Only validated device/app names enter the script.
    public static func focus(tty: String, app: String, timeout: TimeInterval = Double(focusTimeout)) async throws -> Bool {
        try Task.checkCancellation()
        guard let source = focusScript(tty: tty, app: app) else { throw SessionOpeningError.terminalFocusFailed(app) }
        return try await executeFocusScript(source, app: app, timeout: timeout)
    }

    static func executeFocusScript(_ source: String, app: String, timeout: TimeInterval,
                                   run: @escaping @Sendable (String, TimeInterval) throws -> Data = {
                                       try SessionProcess.run(path: "/usr/bin/osascript", arguments: ["-e", $0], timeout: $1)
                                   }) async throws -> Bool {
        // Numeric errors survive localization; stderr may contain script details
        // and is deliberately discarded by the process runner.
        let script = "try\n" + source + "\non error errorMessage number errorNumber\nreturn \"error:\" & errorNumber\nend try"
        do {
            guard timeout.isFinite, timeout > 0 else { throw SessionError.timeout }
            let data = try await SessionProcess.detached { try run(script, timeout) }
            let reply = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply == "true" { return true }
            if reply == "false" { return false }
            if let reply, reply.hasPrefix("error:"), let code = Int(reply.dropFirst(6)) {
                throw focusError(code: code, app: app)
            }
            throw SessionOpeningError.terminalFocusFailed(app)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || error is SessionOpeningError { throw error }
            if error as? SessionError == .timeout { throw SessionOpeningError.terminalFocusTimedOut(app) }
            throw SessionOpeningError.terminalFocusFailed(app)
        }
    }

    public static func focusError(code: Int?, app: String) -> SessionOpeningError {
        switch code {
        case -1743: return .terminalAutomationDenied(app)
        case -1712: return .terminalFocusTimedOut(app)
        default: return .terminalFocusFailed(app)
        }
    }
    /// What a terminal device currently runs, as far as the session's provider is concerned.
    public enum DeviceOccupancy: Equatable, Sendable {
        /// A runtime of the session's provider runs on the device.
        case provider
        /// No provider runtime, but an interpreter that may run an npm-installed CLI.
        case interpreter
        /// Neither: the recorded tab no longer runs this kind of session.
        case vacant
        /// The process table could not be read.
        case unknown
    }

    /// A live CLI session stays where it runs: bring its own tab to the front.
    /// Never launches a terminal application that is not running.
    public static func focusSession(_ session: AgentSession, environment: TerminalFocusEnvironment) async throws -> Bool {
        try Task.checkCancellation()
        guard let target = focusTarget(for: session, running: environment.runningTarget) else {
            throw SessionOpeningError.terminalTabUnavailable
        }
        // A root-owned login may hide the host's name. Match the exact device
        // against running supported terminals; never launch an empty terminal.
        let apps = target.app.isEmpty ? ["Terminal", "iTerm2"] : [target.app]
        var failure: SessionOpeningError?
        let deadline = environment.uptime() + Double(focusTimeout)
        for app in apps {
            try Task.checkCancellation()
            guard let bundle = bundleIdentifier(forApp: app), await environment.isRunning(bundle) else { continue }
            do {
                if try await environment.runScript(target.tty, app, deadline - environment.uptime()) { return true }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                failure = failure ?? (error as? SessionOpeningError) ?? .terminalFocusFailed(app)
            }
        }
        throw failure ?? SessionOpeningError.terminalTabUnavailable
    }

    public struct Target: Hashable, Sendable {
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
        let canonicalDirectory = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var targets = Set<Target>()
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
            guard URL(fileURLWithPath: dir).resolvingSymlinksInPath().path == canonicalDirectory,
                  let dev = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { continue }
            let tty = "/dev/" + String(cString: dev)
            guard valid(tty) else { continue }
            // The ancestry can stop at Terminal's root-owned login process.
            let app = SessionProcess.terminalLocation(parentPID: pid, termProgram: "")?.app ?? "Terminal"
            targets.insert(Target(tty: tty, app: app))
        }
        // Several tasks may share one project. Never jump to an arbitrary task.
        return targets.count == 1 ? targets.first : nil
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
                                if tty of t is "\(tty)" and (count of processes of t) > 0 then
                                    if miniaturized of w then set miniaturized of w to false
                                    set selected of t to true
                                    set index of w to 1
                                    activate
                                    return true
                                end if
                            on error errorMessage number errorNumber
                                if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber
                            end try
                        end repeat
                    on error errorMessage number errorNumber
                        if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber
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
                                    if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber
                                end try
                            end repeat
                        end repeat
                    on error errorMessage number errorNumber
                        if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber
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
