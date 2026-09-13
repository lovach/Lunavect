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
