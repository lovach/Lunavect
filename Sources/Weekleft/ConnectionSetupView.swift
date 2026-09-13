import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ConnectionSetupView: View {
    let provider: ProviderID
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var busy = false
    @State private var waitingExternal = false
    @State private var issue: String?
    @State private var localState: ClientConnection.LocalState?
    @State private var editingCodexPath = false
    @StateObject private var actions = ConnectionViewTasks()
    @State private var copied = false
    @State private var externalAction: ClientConnection.Action?
    @State private var externalDeadline: Date?
    private let autoRoute: Bool
    private let repair: ConnectionDiagnostic.Repair?

    init(provider: ProviderID, store: AppStore, sessions: SessionStore, initialStep: Int? = nil,
         repair: ConnectionDiagnostic.Repair? = nil) {
        self.provider = provider; self.store = store; self.sessions = sessions
        self.repair = repair; autoRoute = initialStep == nil
        _step = State(initialValue: initialStep ?? -1)
    }

    private var component: String { provider == .claude ? "Claude Code" : "Codex" }
    private var executable: String? {
        try? ClientExecutableResolver(codexPath: store.codexPath, discoverCodex: AppStore.discoverCodex).resolve(provider)
    }
    private var selectedCodexUnavailable: Bool { provider == .codex && !store.codexPath.isEmpty && executable == nil }
    private var snapshot: UsageSnapshot? { store.snapshots.first { $0.provider == provider } }
    private var freshQuota: Bool { snapshot.map { $0.hasQuota && !$0.isStale() && $0.issue == nil } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step >= 0 { HStack(spacing: 12) {
                ProviderLogo(id: provider).foregroundStyle(provider == .claude ? .orange : .blue).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Подключить {0}", provider.title)).font(.system(size: 21, weight: .semibold))
                    Text(L("Ваш аккаунт остаётся в официальном клиенте.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            HStack(spacing: 12) {
                stepLabel(0, "Приложение")
                InterfaceIcon(.forward).foregroundStyle(.tertiary)
                stepLabel(1, "Вход")
                InterfaceIcon(.forward).foregroundStyle(.tertiary)
                stepLabel(2, "Подключение")
            }.padding(.horizontal, 24).padding(.bottom, 20) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step < 0 {
                        ProgressView(L("Проверяем, что уже настроено…")).frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else if step == 0 { componentStep }
                    else if step == 1 { signInStep }
                    else if step == 2 { accessStep }
                    else { resultStep }
                    if step == 2, let localState { ConnectionLocalStateView(state: localState) }
                    if let issue {
                        InterfaceLabel(L(issue), .info).foregroundStyle(.orange)
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    if waitingExternal {
                        InterfaceLabel(L("Завершите шаг в открывшемся окне. Lunavect проверит результат автоматически."), .external)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider()
                    DisclosureGroup(L("Какие данные использует Lunavect")) { ConnectionPrivacyView().padding(.top, 10) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L(step == 3 ? "Готово" : "Позже")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if step == 0 {
                    Button(L(editingCodexPath || selectedCodexUnavailable ? "Проверить снова" : executable == nil ? "Установить {0}" : "Продолжить", component)) {
                        if editingCodexPath || selectedCodexUnavailable { actions.start { await routeToNeededStep() } }
                        else if executable == nil { actions.start { await launch(.install) } }
                        else { actions.start { await checkSignIn() } }
                    }.buttonStyle(.borderedProminent).disabled(busy || waitingExternal)
                } else if step == 1 {
                    Button(L("Открыть вход в {0}", component)) { actions.start { await launch(.signIn) } }
                        .buttonStyle(.borderedProminent).disabled(busy || waitingExternal)
                } else if step == 2 {
                    Button(L(localState?.hasConfiguration == true ? "Завершить подключение" : "Включить лимиты и сессии")) { actions.start { await enableLocalConnection() } }
                        .buttonStyle(.borderedProminent).disabled(busy)
                } else if step == 3 {
                    Button(L("Проверить снова")) { actions.start { await refreshData() } }.disabled(busy)
                }
            }.padding(20)
        }.frame(width: 600, height: 580).background(Color(nsColor: .windowBackgroundColor))
            .task {
                guard autoRoute else { return }
                await routeToNeededStep()
                if !Task.isCancelled, repair == .signIn, step == 1 { await launch(.signIn) }
                else if !Task.isCancelled, repair == .install, step == 0, !selectedCodexUnavailable { await launch(.install) }
                else if !Task.isCancelled, repair == .events, step == 2 { await enableLocalConnection() }
                else if !Task.isCancelled, repair == .reviewUsage, step == 3 { await launch(.reviewUsage) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard waitingExternal && !busy else { continue }
                    await checkExternalProgress()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if waitingExternal && !busy { actions.start { await checkExternalProgress() } }
            }
            .onAppear { actions.activate() }
            .onDisappear { actions.deactivate(); cancelExternalWait() }
            .accessibilityIdentifier("connection-setup")
    }

    private func stepLabel(_ index: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            if step > index { InterfaceIcon(.checkCircle).foregroundStyle(.green) }
            else { Text(String(index + 1)).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18).background(.quaternary, in: Circle()) }
            Text(L(title)).font(.system(size: 12, weight: step == index ? .semibold : .regular))
        }.foregroundStyle(step == index ? .primary : .secondary)
    }
    private var componentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingCodexPath || selectedCodexUnavailable {
                ConnectionClientPathView(path: $store.codexPath)
            } else {
                Text(L(executable == nil ? "Нужен официальный компонент {0}" : "{0} уже установлен", component)).font(.headline)
                Text(L(provider == .claude
                       ? "Claude Code получает лимиты вашего аккаунта. Его достаточно подключить один раз — запускать задачи в терминале не нужно."
                       : "Lunavect использует официальный клиент Codex для лимитов и сессий. Повторная установка не нужна, если клиент уже найден."))
                if executable == nil {
                    Text(L("По кнопке откроется Terminal и запустит установщик с сайта {0}. Команды вводить не нужно.", ClientConnection.installerURL(provider).host!))
                    Text(L("Устанавливается отдельный официальный клиент, без изменений со стороны Lunavect. Действуют условия провайдера."))
                        .foregroundStyle(.secondary)
                }
            }
            Link(L("Официальная инструкция {0}", component), destination: ClientConnection.documentationURL(provider))
            if waitingExternal { retryExternal }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Войдите в официальном клиенте")).font(.headline)
            Text(L("Кнопка откроет вход {0} в Terminal. Клиент предложит перейти в браузер. Пароль и код подтверждения вводятся только в интерфейсе провайдера.", component))
            Text(L("Lunavect не видит форму входа и не читает её вывод. Проверяем только, подтвердил ли клиент успешный вход."))
                .foregroundStyle(.secondary)
            Link(L("Как устроен вход {0}", component), destination: ClientConnection.authenticationURL(provider))
            Button(L("Я уже вошёл — проверить")) { actions.start { await checkSignIn() } }.disabled(busy)
            if waitingExternal { retryExternal }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            InterfaceLabel(L("Вход подтверждён официальным клиентом"), .checkCircle).foregroundStyle(.green)
            Text(L("Теперь подключим локальные данные")).font(.headline)
            Text(L("Lunavect добавит свои обработчики событий в настройки {0}. Перед изменением создаётся резервная копия; существующие настройки сохраняются.", component))
            if provider == .claude { Text(L("Также подключается строка состояния Claude Code для передачи лимитов. Ваша текущая строка состояния сохраняется.")) }
            Text(L("Обработчики сохраняют на Mac ID, названия, папки проектов и статусы сессий. Они не отправляют команды в ваши чаты."))
            Text(L("События можно отключить в дополнительных настройках подключений."))
                .foregroundStyle(.secondary)
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            InterfaceLabel(L(freshQuota ? "Лимиты получены" : "Локальная настройка сохранена"), .checkCircle)
                .font(.headline).foregroundStyle(freshQuota ? .green : .primary)
            if freshQuota {
                Text(L("Лимиты будут обновляться автоматически. Данные для виджета остаются на этом Mac."))
            } else {
                Text(L("Клиент пока не передал актуальные лимиты. Сохранённые значения не считаются новым успешным подключением."))
                if let message = snapshot?.issue { Text(L(message)).foregroundStyle(.orange) }
                if provider == .claude {
                    Button(L("Завершить настройку Claude Code")) { actions.start { await launch(.reviewUsage) } }.disabled(busy)
                    Text(L("Завершите первый запуск в Claude Code. Lunavect сам проверит данные и вернётся сюда."))
                }
                Button(L("Проверить вход")) { actions.start { await checkSignIn() } }.disabled(busy)
            }
            if sessions.currentSessions.contains(where: { $0.provider == provider }) {
                InterfaceLabel(L("Есть текущие сессии"), .activity).foregroundStyle(.green)
            } else {
                Text(L("Сессии появятся после первого события из приложения."))
            }
            if provider == .codex {
                Text(L("Codex может запросить разрешение обработчиков. Введите /hooks в Codex и разрешите только команды Lunavect. Настройка файла сама по себе не подтверждает получение событий."))
                Button(L(copied ? "Скопировано" : "Скопировать /hooks")) { SessionNavigation.copy("/hooks"); copied = true }
            }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
    private var retryExternal: some View {
        Button(L("Окно закрыто — попробовать снова")) { cancelExternalWait() }
            .buttonStyle(.link).font(.system(size: 12))
    }
    private func checkSignIn(quiet: Bool = false) async {
        guard !busy, !Task.isCancelled else { return }
        let executable: String
        do { executable = try ClientExecutableResolver(codexPath: store.codexPath, discoverCodex: AppStore.discoverCodex).resolve(provider) }
        catch {
            step = 0; issue = error.localizedDescription
            editingCodexPath = selectedCodexUnavailable
            return
        }
        editingCodexPath = false
        busy = true; if !quiet { issue = nil }
        let state = await ClientConnection.signInState(provider, executable: executable)
        busy = false
        guard !Task.isCancelled else { return }
        switch state {
        case .signedIn:
            let wasWaiting = waitingExternal
            step = ConnectionSetupRoute.next(clientFound: true, signIn: state, configured: configured, enabled: store.providers.contains(provider))
            cancelExternalWait(); issue = nil
            if step == 3 { await refreshData() }
            if wasWaiting && !Task.isCancelled { NSApp.activate(ignoringOtherApps: true) }
        case .signedOut:
            step = 1; if !quiet { issue = nil }
            if externalAction == .install { cancelExternalWait(); NSApp.activate(ignoringOtherApps: true) }
        case .unavailable:
            step = 1
            if !quiet { issue = "Не удалось проверить вход. Откройте официальный клиент и повторите проверку." }
            if externalAction == .install { cancelExternalWait(); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    private var configured: Bool {
        ClientConnection.LocalSetup(provider: provider).inspect().connected
    }
    private func routeToNeededStep() async {
        guard !Task.isCancelled else { return }
        localState = ClientConnection.LocalSetup(provider: provider).inspect()
        do { _ = try ClientExecutableResolver(codexPath: store.codexPath, discoverCodex: AppStore.discoverCodex).resolve(provider) }
        catch {
            step = 0; issue = selectedCodexUnavailable ? error.localizedDescription : nil
            editingCodexPath = selectedCodexUnavailable
            return
        }
        editingCodexPath = false
        await checkSignIn()
    }
    private func cancelExternalWait() {
        waitingExternal = false; externalAction = nil; externalDeadline = nil
    }
    private func checkExternalProgress() async {
        guard waitingExternal, !busy else { return }
        guard let deadline = externalDeadline, Date() < deadline else {
            cancelExternalWait(); issue = "Ожидание завершено. Можно продолжить настройку в любое время."; return
        }
        if externalAction == .install, executable != nil { await checkSignIn(quiet: true) }
        else if externalAction == .signIn { await checkSignIn(quiet: true) }
        else if externalAction == .reviewUsage {
            await refreshData()
            if waitingExternal && freshQuota && !Task.isCancelled { cancelExternalWait(); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    private func launch(_ action: ClientConnection.Action) async {
        guard !busy, !Task.isCancelled else { return }; busy = true; issue = nil
        defer { busy = false }
        do {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw SessionError.unavailable }
            if action == .reviewUsage {
                try FileManager.default.createDirectory(at: ClaudeUsageProbe.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let text = try ClientConnection.script(provider: provider, action: action, executable: executable,
                heading: L("Официальный клиент {0}. Данные входа остаются у провайдера; Lunavect не читает вывод этого окна.", component),
                completion: L("Готово. Вернитесь в Lunavect, чтобы продолжить подключение."))
            let file = try ClientConnection.writeLauncher(text, provider: provider, action: action)
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            guard !Task.isCancelled else { return }
            externalAction = action; externalDeadline = Date().addingTimeInterval(600); waitingExternal = true
        } catch {
            guard !Task.isCancelled else { return }
            issue = "Не удалось открыть официальный клиент. Повторите попытку или используйте официальную инструкцию."
        }
    }
    private func enableLocalConnection() async {
        guard !busy, !Task.isCancelled else { return }; busy = true; issue = nil
        defer { busy = false; sessions.updateHookConfiguration() }
        do {
            localState = try ClientConnection.LocalSetup(provider: provider).apply(.connect)
            store.setProvider(provider, enabled: true); sessions.useProviders(store.providers)
            store.importActivityHistory()
            await waitForRefresh()
            guard !Task.isCancelled else { return }
            await store.refresh(provider: provider)
            guard !Task.isCancelled else { return }
            await sessions.refresh()
            guard !Task.isCancelled else { return }
            step = 3
        } catch let failure as ClientConnection.LocalFailure {
            localState = failure.state
            issue = failure.localizedDescription
        } catch { issue = error.localizedDescription }
    }
    private func refreshData() async {
        guard !busy, !Task.isCancelled else { return }; busy = true; issue = nil
        defer { busy = false }
        await waitForRefresh()
        guard !Task.isCancelled else { return }
        await store.refresh(provider: provider)
        guard !Task.isCancelled else { return }
        await sessions.refresh()
    }
    private func waitForRefresh() async {
        while store.refreshing && !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }
}

struct ConnectionPrivacyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InterfaceLabel(L("Подключение на вашем Mac"), .shield).font(.system(size: 13, weight: .semibold))
            Text(L("Lunavect не запрашивает пароль и не читает хранилище токенов. Вход и хранение учётных данных выполняет официальный клиент."))
            Text(L("Локально сохраняются лимиты, названия и ID сессий, папки проектов и статусы. Эти данные не отправляются разработчику Lunavect."))
            Text(L("Для обновления лимитов официальный клиент обращается к своему провайдеру. Lunavect — независимое приложение."))
        }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Only reports verified local configuration; it does not claim client approval or live events.
struct ConnectionLocalStateView: View {
    let state: ClientConnection.LocalState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let statusLine = state.statusLine {
                Text(L("statusLine: {0}", L(statusLine.message)))
            }
            Text(L("События: {0}", L(state.hooks.message)))
            if !state.connected && !state.disconnected {
                Text(L("Повторите действие, чтобы завершить настройку. Остальные настройки клиента сохранятся."))
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

struct ConnectionClientPathView: View {
    @Binding var path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Путь к исполняемому файлу codex")).font(.headline)
            HStack {
                TextField(L("Путь к исполняемому файлу codex"), text: $path).textFieldStyle(.roundedBorder)
                Button(L("Выбрать…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }.accessibilityIdentifier("connection-choose-codex-path")
            }
        }
    }
}
