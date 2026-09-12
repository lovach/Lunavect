import Foundation

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
    /// A new Terminal window resumes this ID; never writes into an existing shell.
    func terminalScript(executable: String) -> String? {
        guard executable.hasPrefix("/"), cwd.hasPrefix("/"), UUID(uuidString: sessionID) != nil else { return nil }
        let arguments: String
        if provider == .claude, client == .background, let resumeID, SessionParser.validID(resumeID) {
            arguments = "attach " + SessionHooks.quote(resumeID)
        } else {
            arguments = (provider == .claude ? "--resume " : "resume ") + SessionHooks.quote(sessionID)
        }
        return "#!/bin/zsh\ncd -- " + SessionHooks.quote(cwd) + " || exit 1\nexec " + SessionHooks.quote(executable) + " " + arguments + "\n"
    }
}

public enum SessionOpeningError: LocalizedError, Equatable {
    case missingCLI(ProviderID), missingProject, missingTerminal, invalidID, missingDesktopLink, missingClient(String), launchFailed(SessionClient)
    public var errorDescription: String? {
        switch self {
        case .missingCLI(let provider): return L("Не найден клиент {0}. Откройте «Подключения» и завершите установку официального клиента.", provider.title)
        case .missingProject: return L("Папка проекта недоступна. Верните её на прежнее место или откройте сессию в официальном приложении. Команду продолжения можно скопировать через «…».")
        case .missingTerminal: return L("Terminal не найден. Откройте другой терминал и вставьте команду продолжения из меню «…».")
        case .invalidID: return L("Не удалось определить ссылку на эту сессию. Откройте её в официальном приложении и обновите список Lunavect.")
        case .missingDesktopLink: return L("Claude не передал ссылку на эту сессию. Откройте её в Claude и обновите список. Для локальной сессии также можно скопировать команду продолжения через «…».")
        case .missingClient(let name): return L("Приложение {0} не найдено. Установите или откройте его, затем повторите переход.", name)
        case .launchFailed(.vscode): return L("VS Code не принял переход. Откройте папку проекта в VS Code, проверьте расширение Claude Code и повторите попытку.")
        case .launchFailed(.terminal), .launchFailed(.background): return L("Не удалось запустить Terminal. Откройте терминал вручную и вставьте команду продолжения из меню «…».")
        case .launchFailed: return L("Приложение не приняло переход. Откройте его вручную и повторите попытку. Команда продолжения доступна в меню «…».")
        }
    }
}
