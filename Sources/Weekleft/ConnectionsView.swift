import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ConnectionsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    @State private var selectedProvider: ProviderID?
    @State private var showingDiagnostics = false
    @State private var repairProvider: ProviderID?
    @State private var selectedRepair: ConnectionDiagnostic.Repair?
    @State private var claudeBridge = ClaudeProvider.statusLineInstalled()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Достаточно одного подключения. Второе можно добавить в любое время."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(store.providers) { id in providerCard(id) }
                ForEach(ProviderID.allCases.filter { !store.providers.contains($0) }) { id in optionalProviderCard(id) }
                DisclosureGroup(L("Подключение на вашем Mac")) { ConnectionPrivacyView().padding(.top, 8) }
                Button { showingDiagnostics = true } label: { InterfaceLabel(L("Проверить подключение"), .activity) }
                    .accessibilityIdentifier("connection-diagnostics")
                DisclosureGroup(L("Дополнительные настройки")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.providers.contains(.codex) { HStack {
                            Text("Codex CLI")
                            TextField(L("Путь к исполняемому файлу codex"), text: $store.codexPath).textFieldStyle(.roundedBorder)
                            Button(L("Выбрать…")) {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url { store.codexPath = url.path; Task { await store.refresh(); await sessions.refresh() } }
                            }
                        } }
                        ForEach(store.providers) { id in
                            Button(L("Отключить {0} в Lunavect", id.title)) {
                                if sessions.disconnect(id) { store.setProvider(id, enabled: false); sessions.useProviders(store.providers) }
                            }
                            if sessions.hooksInstalled[id] == true {
                                Button(L("Отключить события {0}", id.title)) { sessions.toggleHooks(id) }
                            }
                        }
                        Text(L("Отключение останавливает опрос, удаляет обработчики Lunavect и восстанавливает прежнюю строку состояния Claude. Сохранённые данные остаются."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let message = sessions.connectionMessage { Text(L(message)).foregroundStyle(.secondary) }
                    }.font(.system(size: 11)).padding(.top, 8)
                }

            }.padding(8).fixedSize(horizontal: false, vertical: true)
        }.onAppear { sessions.updateHookConfiguration() }
            .sheet(item: $selectedProvider, onDismiss: {
                claudeBridge = ClaudeProvider.statusLineInstalled(); sessions.updateHookConfiguration()
            }) { id in
                ConnectionSetupView(provider: id, store: store, sessions: sessions, repair: selectedRepair)
            }
            .sheet(isPresented: $showingDiagnostics, onDismiss: {
                selectedProvider = repairProvider; repairProvider = nil
            }) {
                ConnectionDiagnosticsView(store: store, sessions: sessions) { provider, repair in
                    repairProvider = provider; selectedRepair = repair
                }
            }
    }
    private func optionalProviderCard(_ id: ProviderID) -> some View {
        HStack(spacing: 12) {
            ProviderLogo(id: id).foregroundStyle(id == .claude ? Color.orange : Color.blue).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(id.title).font(.system(size: 14, weight: .semibold))
                Text(L("Не подключён · по желанию")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Подключить {0}", id.title)) { selectedRepair = nil; selectedProvider = id }
                .accessibilityIdentifier("connect-" + id.rawValue)
        }.padding(14).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
    private func providerCard(_ id: ProviderID) -> some View {
        let snapshot = store.snapshots.first { $0.provider == id }
        let found = id == .claude ? SessionSources.discoverClaude() != nil : FileManager.default.isExecutableFile(atPath: store.codexPath)
        let configured = sessions.hooksInstalled[id] == true && (id == .codex || claudeBridge)
        let needsSetup = !found || !configured
        let hasQuota = snapshot?.hasQuota == true
        let freshQuota = snapshot.map { !$0.isStale() && $0.issue == nil && $0.hasQuota } ?? false
        let receivedEvents = sessions.currentSessions.contains { $0.provider == id && [.hook, .localEvent].contains($0.evidence) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProviderLogo(id: id).foregroundStyle(activityAccent(id)).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(id == .claude ? "Claude Code" : "Codex").font(.system(size: 15, weight: .semibold))
                    Text(L(!found ? "Нужно установить приложение" : snapshot?.connectionQuotaTitle() ?? "Ждём лимиты"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L(needsSetup ? "Завершить настройку" : "Проверить данные")) {
                    if needsSetup { selectedRepair = nil; selectedProvider = id }
                    else { Task { await store.refresh(provider: id); await sessions.refresh() } }
                }.disabled(store.refreshing || sessions.refreshing)
                    .accessibilityIdentifier("connect-" + id.rawValue)
            }
            if store.refreshing { ProgressView().controlSize(.small) }
            if let date = snapshot?.fetchedAt {
                Text(L("Последние данные: {0}", date.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if hasQuota && !freshQuota {
                Text(L("Показаны последние полученные лимиты. Они обновятся, когда источник передаст новые данные."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let issue = snapshot?.issue, !(id == .claude && issue == UsageError.waitingForClaude.errorDescription) {
                if store.network.isOffline {
                    Text(L("Ждём соединение. Данные обновятся автоматически.")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(L(issue)).font(.system(size: 12)).foregroundStyle(.orange)
                    let needsLogin = issue == UsageError.notSignedIn.errorDescription
                    let needsUsage = issue == UsageError.claudeSignInRequired.errorDescription
                    if needsLogin || needsUsage {
                        Button(L(needsLogin ? "Войти снова" : "Завершить настройку Claude Code")) {
                            selectedRepair = needsLogin ? .signIn : .reviewUsage; selectedProvider = id
                        }.buttonStyle(.link)
                    }
                }
            }
            DisclosureGroup(L("Подробности подключения")) {
                VStack(alignment: .leading, spacing: 10) {
                    connectionStep(1, title: L("Приложение найдено"), complete: found)
                    connectionStep(2, title: L("Локальные события настроены"), complete: configured)
                    Text(L(receivedEvents ? "Получены события текущей сессии" : "Нет подтверждённых событий текущей сессии"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Настроить")) { selectedRepair = nil; selectedProvider = id }
                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex") {
                            Button(L("Открыть {0}", id.title)) { NSWorkspace.shared.open(appURL) }
                        }
                    }
                    if id == .claude {
                        Text(L("Лимиты обновляются автоматически каждые 5 минут и после пробуждения Mac. Claude Code запрашивает квоты аккаунта, включая работу в Desktop. Запускать задачу в терминале не нужно."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func connectionStep(_ number: Int, title: String, complete: Bool, stale: Bool = false) -> some View {
        HStack(spacing: 8) {
            if complete {
                InterfaceIcon(stale ? .history : .checkCircle, size: 13)
                    .foregroundStyle(stale ? Color.secondary : Color.green).frame(width: 16)
            } else {
                Text(String(number)).font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16).background(.primary.opacity(0.08), in: Circle())
            }
            Text(title).foregroundStyle(complete && !stale ? Color.primary : .secondary)
        }.font(.system(size: 11))
    }
}
