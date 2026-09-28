import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct IDEConnectionsView: View {
    @State private var endpoints: [IDEBridge.Endpoint] = []
    private let bundled = IDEConnectionsView.bundledVersions()

    var body: some View {
        DisclosureGroup(L("Сессии в редакторах")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Установите модуль Lunavect в редактор, чтобы переходить к нужной вкладке Claude или Codex."))
                    .fixedSize(horizontal: false, vertical: true)
                IDEConnectionStatusList(endpoints: endpoints, bundled: bundled, package: Self.package)
                Text(L("VS Code, Cursor и другие редакторы на основе VS Code: Extensions → Install from VSIX. JetBrains: Settings → Plugins → Install Plugin from Disk. После установки откройте проект и обновите подключение."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("Поддерживаются локальные терминалы VS Code, Cursor и других редакторов на основе VS Code и JetBrains 2026.2, а также панели Claude Code и Codex в редакторах на основе VS Code. AI Chat JetBrains и удалённые рабочие среды пока не поддерживаются."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Обновить подключение")) { Task { await refresh() } }
            }.font(.system(size: 12)).padding(.top, 8)
        }.task { await refresh() }
    }

    private func refresh() async {
        endpoints = await Task.detached { IDEBridge.scan() }.value
    }

    static func resources() -> URL? {
        #if SWIFT_PACKAGE
        // `.copy("Resources")` keeps the folder; resourceURL already points inside it.
        return Bundle.module.bundleURL.appendingPathComponent("Resources/IDEConnectors")
        #else
        return Bundle.main.resourceURL?.appendingPathComponent("IDEConnectors")
        #endif
    }

    static func package(_ editor: SessionIDE) -> URL? {
        let url = resources()?.appendingPathComponent(editor == .vscode ? "lunavect-vscode.vsix" : "lunavect-jetbrains.zip")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static func bundledVersions() -> [SessionIDE: String] {
        guard let url = resources()?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: url) else { return [:] }
        return IDEBridge.bundledCompanionVersions(manifest: data)
    }

    /// One line per editor: connected, an update to install, not answering,
    /// incompatible or not connected. Several windows each publish an endpoint.
    static func status(_ editor: SessionIDE, endpoints: [IDEBridge.Endpoint], bundled: String?) -> String {
        let own = endpoints.filter { $0.editor == editor }
        let reachable = own.filter { $0.state == .live || $0.state == .stale }
        if !reachable.isEmpty {
            for endpoint in reachable {
                if case .available(let installed, let available) = IDEBridge.companionUpdate(installed: endpoint.companion, bundled: bundled) {
                    return L("Установлен {0}, доступен {1}: переустановите модуль", installed ?? L("0.1.1 или раньше"), available)
                }
            }
            return L("Модуль работает")
        }
        if own.contains(where: { $0.state == .incompatible }) { return L("Версия модуля не подходит: переустановите модуль") }
        if own.contains(where: { $0.state == .unreachable }) { return L("Модуль не отвечает: перезапустите окно редактора") }
        return L("Модуль не подключён")
    }
}

/// The per-editor rows, separate from discovery so they can be rendered from fixtures.
struct IDEConnectionStatusList: View {
    let endpoints: [IDEBridge.Endpoint]
    let bundled: [SessionIDE: String]
    let package: (SessionIDE) -> URL?

    var body: some View {
        ForEach([SessionIDE.vscode, .jetbrains], id: \.rawValue) { editor in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(editor == .vscode ? L("VS Code, Cursor и другие") : editor.client.title).fontWeight(.medium)
                    Text(IDEConnectionsView.status(editor, endpoints: endpoints, bundled: bundled[editor]))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let package = package(editor) {
                    Button(L("Показать модуль")) { NSWorkspace.shared.activateFileViewerSelecting([package]) }
                }
            }
        }
    }
}
