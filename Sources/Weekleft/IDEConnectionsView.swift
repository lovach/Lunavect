import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct IDEConnectionsView: View {
    @State private var connected = Set<SessionIDE>()

    var body: some View {
        DisclosureGroup(L("Сессии в редакторах")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Установите модуль Lunavect в редактор, чтобы переходить к нужной вкладке Claude или Codex."))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach([SessionIDE.vscode, .jetbrains], id: \.rawValue) { editor in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(editor.client.title).fontWeight(.medium)
                            Text(L(connected.contains(editor) ? "Модуль работает" : "Модуль не подключён"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let package = Self.package(editor) {
                            Button(L("Показать модуль")) { NSWorkspace.shared.activateFileViewerSelecting([package]) }
                        }
                    }
                }
                Text(L("VS Code: Extensions → Install from VSIX. JetBrains: Settings → Plugins → Install Plugin from Disk. После установки откройте проект и обновите подключение."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("Поддерживаются локальные терминалы VS Code и JetBrains 2026.2, а также панели Claude Code и Codex в VS Code. AI Chat JetBrains и удалённые рабочие среды пока не поддерживаются."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Обновить подключение")) { Task { await refresh() } }
            }.font(.system(size: 12)).padding(.top, 8)
        }.task { await refresh() }
    }

    private func refresh() async {
        connected = await Task.detached { Set(IDEBridge.descriptors().map(\.editor)) }.value
    }

    static func package(_ editor: SessionIDE) -> URL? {
        #if SWIFT_PACKAGE
        let root = Bundle.module.resourceURL?.appendingPathComponent("Resources/IDEConnectors")
        #else
        let root = Bundle.main.resourceURL?.appendingPathComponent("IDEConnectors")
        #endif
        let url = root?.appendingPathComponent(editor == .vscode ? "lunavect-vscode.vsix" : "lunavect-jetbrains.zip")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}
