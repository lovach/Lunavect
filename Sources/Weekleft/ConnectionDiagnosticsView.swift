import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// Owns button/notification tasks for one presented view. A cancelled task must
/// not clear a newer handle when the view is presented again.
@MainActor final class ConnectionViewTasks: ObservableObject {
    private var task: Task<Void, Never>?
    private var generation = 0
    private var active = false
    func activate() { active = true }
    func deactivate() { active = false; cancel() }
    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard active, task == nil else { return }
        generation += 1; let current = generation
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            if self?.generation == current { self?.task = nil }
        }
    }
    func cancel() {
        generation += 1
        task?.cancel(); task = nil
    }
}

@MainActor final class ConnectionDiagnostics: ObservableObject {
    @Published var results: [ConnectionDiagnostic] = []
    @Published var busy = false
    @Published var checkedAt: Date?
    @Published var reportText: String?
    @Published var copied = false
    private var generation = 0
    func cancel() { generation += 1; busy = false }
    func check(store: AppStore, sessions: SessionStore, provider requestedProvider: ProviderID? = nil) async {
        guard !busy, !Task.isCancelled else { return }
        generation += 1; let current = generation
        func acceptsResult() -> Bool { !Task.isCancelled && generation == current }
        busy = true; reportText = nil; copied = false
        defer { if generation == current { busy = false } }
        while store.refreshing {
            guard acceptsResult() else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard acceptsResult() else { return }
        await store.refresh(provider: requestedProvider)
        guard acceptsResult() else { return }
        await sessions.refresh()
        guard acceptsResult() else { return }
        sessions.updateHookConfiguration()
        let providers = store.providers.filter { requestedProvider == nil || $0 == requestedProvider }
        let discoveredCodex = AppStore.discoverCodex()
        let resolver = ClientExecutableResolver(codexPath: store.codexPath, discoverCodex: { discoveredCodex })
        let claude = try? resolver.resolve(.claude), codex = try? resolver.resolve(.codex)
        let codexPathIssue: ClientIntegrationIssue? = !store.codexPath.isEmpty && codex == nil
            ? .init(provider: .codex, capability: .initialization, reason: .clientPathUnavailable) : nil
        async let claudeAuth = auth(.claude, path: providers.contains(.claude) ? claude : nil)
        async let codexAuth = auth(.codex, path: providers.contains(.codex) ? codex : nil)
        let statuses = await [ProviderID.claude: claudeAuth, .codex: codexAuth]
        guard acceptsResult() else { return }
        let checked = providers.map { provider in
            ConnectionDiagnostic(provider: provider, clientFound: (provider == .claude ? claude : codex) != nil,
                signIn: statuses[provider] ?? .unavailable,
                eventsConfigured: sessions.hooksInstalled[provider] == true,
                snapshot: store.snapshots.first { $0.provider == provider }, sessionIssue: sessions.issues[provider],
                sourceIssue: provider == .codex ? codexPathIssue ?? sessions.typedIssues[provider] : sessions.typedIssues[provider])
        }
        results = requestedProvider == nil ? checked : results.filter { $0.provider != requestedProvider } + checked
        checkedAt = Date()
    }
    private func auth(_ provider: ProviderID, path: String?) async -> ClientConnection.SignInState {
        guard let path else { return .unavailable }
        return await ClientConnection.signInState(provider, executable: path)
    }
    func prepareReport() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        reportText = try? ConnectionDiagnosticReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", connections: results).text()
    }
}

struct ConnectionDiagnosticSummary: View {
    let result: ConnectionDiagnostic
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.provider.title).font(.headline)
                Spacer()
                InterfaceIcon(result.state == .ready ? .checkCircle : .info).foregroundStyle(result.state == .ready ? .green : .orange)
            }
            Text(L(result.title)).font(.system(size: 13, weight: .semibold))
            Text(L(result.guidance)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let age = result.quotaAgeMinutes {
                Text(L("Лимиты получены {0} мин назад", String(age))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConnectionDiagnosticsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    @StateObject var diagnostics = ConnectionDiagnostics()
    var onConnect: (ProviderID, ConnectionDiagnostic.Repair) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailed = false
    @StateObject private var actions = ConnectionViewTasks()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Диагностика подключений")).font(.system(size: 21, weight: .semibold))
                    Text(L("Проверка ничего не меняет в настройках клиентов.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NetworkStatusView(network: store.network)
                    if diagnostics.results.isEmpty {
                        InterfaceIcon(.link, size: 34).foregroundStyle(.blue)
                        Text(L("Проверим клиент, вход, свежесть лимитов и локальные события. Пароли и токены не читаются."))
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(diagnostics.results) { result in
                        VStack(alignment: .leading, spacing: 10) {
                            ConnectionDiagnosticSummary(result: result)
                            if let repair = result.repair {
                                Button(L(repair.title)) {
                                    if repair == .refresh || repair == .checkSignIn {
                                        actions.start { await diagnostics.check(store: store, sessions: sessions, provider: result.provider) }
                                    } else if repair == .reviewClient {
                                        NSWorkspace.shared.open(ClientConnection.documentationURL(result.provider))
                                    } else { dismiss(); onConnect(result.provider, repair) }
                                }.disabled(diagnostics.busy).accessibilityIdentifier("repair-" + result.provider.rawValue)
                                if result.provider == .claude && repair == .refresh {
                                    Button(L("Открыть официальный клиент")) { dismiss(); onConnect(result.provider, .reviewUsage) }
                                        .buttonStyle(.link)
                                }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !diagnostics.results.isEmpty {
                        Divider()
                        Text(
                            L(
                                "Отчёт содержит только версии Lunavect и macOS, состояние подключений и коды ошибок. Без переписки, названий сессий, путей и токенов. Ничего не отправляется автоматически."
                            )
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("Посмотреть отчёт")) { diagnostics.prepareReport() }.disabled(diagnostics.busy)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
                if let date = diagnostics.checkedAt { Text(L("Проверено {0}", date.formatted(.dateTime.hour().minute().locale(L10n.locale)))).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                if diagnostics.busy { ProgressView().controlSize(.small) }
                Button(L(diagnostics.results.isEmpty ? "Проверить подключение" : "Проверить снова")) { actions.start { await diagnostics.check(store: store, sessions: sessions) } }
                    .buttonStyle(.borderedProminent).disabled(diagnostics.busy)
            }.padding(20)
        }.frame(width: 620, height: 640).background(Color(nsColor: .windowBackgroundColor))
            .task { if diagnostics.results.isEmpty { await diagnostics.check(store: store, sessions: sessions) } }
            .onAppear { actions.activate() }
            .onDisappear { actions.deactivate(); diagnostics.cancel() }
            .sheet(isPresented: Binding(get: { diagnostics.reportText != nil }, set: { if !$0 { diagnostics.reportText = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Предпросмотр отчёта")).font(.title2.bold())
                    Text(L("Проверьте содержимое перед копированием или сохранением.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    ScrollView { Text(diagnostics.reportText ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if saveFailed { Text(L("Не удалось сохранить отчёт.")).foregroundStyle(.orange) }
                    HStack {
                        Button(L("Закрыть")) { diagnostics.reportText = nil }
                        Spacer()
                        Button(L(diagnostics.copied ? "Скопировано" : "Копировать")) { SessionNavigation.copy(diagnostics.reportText ?? ""); diagnostics.copied = true }
                        Button(L("Сохранить…")) { saveReport() }
                    }
                }.padding(24).frame(width: 580, height: 540)
            }
    }
    private func saveReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Lunavect-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url, let report = diagnostics.reportText else { return }
        do { try SessionHooks.secureWrite(Data(report.utf8), to: url); saveFailed = false } catch { saveFailed = true }
    }
}
