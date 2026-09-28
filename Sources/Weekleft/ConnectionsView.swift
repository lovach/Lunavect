import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// The card uses the same strict executable resolution as fetching and setup.
/// An empty saved path selects discovery; it does not mean the client is absent.
struct ConnectionCardState {
    enum Action: Equatable { case setup, refresh, enableEvents }
    let clientFound: Bool
    let needsSetup: Bool
    let statusTitle: String
    let action: Action
    var actionTitle: String {
        switch action {
        case .setup: return "Завершить настройку"
        case .refresh: return "Проверить данные"
        case .enableEvents: return "Включить события"
        }
    }

    /// - Parameters:
    ///   - local: the provider's local configuration, when known.
    ///   - eventsDisabled: the user turned events off here on purpose (H-05).
    init(provider: ProviderID, resolver: ClientExecutableResolver, configured: Bool, snapshot: UsageSnapshot?,
         local: ClientConnection.LocalState? = nil, eventsDisabled: Bool = false) {
        let issue: ClientIntegrationIssue?
        do {
            _ = try resolver.resolve(provider)
            issue = nil
        } catch {
            issue = ClientIntegrationIssue.classify(error, provider: provider, capability: .initialization)
        }
        clientFound = issue == nil
        if let issue {
            statusTitle = issue.reason == .missingClient ? "Нужно установить приложение" : issue.message
            needsSetup = true; action = .setup
        } else if local?.paused == true {
            // disableAllHooks is the client's own switch; Lunavect never overrides it.
            statusTitle = "События приостановлены: в настройках клиента включено disableAllHooks"
            needsSetup = false; action = .refresh
        } else if eventsDisabled && !configured {
            statusTitle = "События отключены"
            needsSetup = false; action = .enableEvents
        } else if !configured, local?.missingExecutable != nil {
            statusTitle = "Команда Lunavect указывает на удалённый файл. Завершите настройку, чтобы обновить её."
            needsSetup = true; action = .setup
        } else {
            statusTitle = snapshot?.connectionQuotaTitle() ?? "Ждём лимиты"
            needsSetup = !configured; action = configured ? .refresh : .setup
        }
    }

    /// The sentence under limits that are shown but not fresh. A client answer in a
    /// format Lunavect cannot read never updates them by itself, so it gets no promise.
    static func savedQuotaNote(provider: ProviderID, snapshot: UsageSnapshot?, now: Date = Date()) -> String? {
        guard let snapshot, snapshot.hasQuota else { return nil }
        guard snapshot.isStale(now: now) || snapshot.issue != nil else { return nil }
        guard issueGuidance(provider: provider, issue: snapshot.issue) == nil else { return nil }
        return "Показаны последние полученные лимиты. Они обновятся, когда источник передаст новые данные."
    }
    /// What to do about the source issue shown on the card, when the card offers no
    /// button for it: the same advice as the diagnostics for an unsupported format.
    static func issueGuidance(provider: ProviderID, issue: String?) -> String? {
        let reason = ClientIntegrationIssue.legacy(issue, provider: provider, capability: provider == .codex ? .rateLimits : .usageProbe)?.reason
        guard reason == .unsupportedResponse || reason == .unsupportedOperation else { return nil }
        return "Проверьте обновления официального клиента и Lunavect. До поддержки этого формата сохранённые данные остаются на месте; повторный вход не требуется."
    }
}

/// Whether the quota check controls can ask the provider now. A disabled control
/// always carries its reason (owner report 28.09: «Проверить данные» and «Обновить»
/// looked inactive without one while a background probe ran). Offline,
/// `AppStore.refresh` returns without asking, so the controls say so instead.
enum QuotaCheckAvailability: Equatable {
    case available, refreshing, offline
    init(refreshing: Bool, offline: Bool) {
        self = offline ? .offline : refreshing ? .refreshing : .available
    }
    var allowsCheck: Bool { self == .available }
    /// Shown beside disabled controls; nil when they are available.
    var reason: String? {
        switch self {
        case .available: return nil
        case .refreshing: return "Идёт обновление лимитов. Проверка станет доступна, когда оно закончится."
        case .offline: return "Ждём соединение. Данные обновятся автоматически."
        }
    }
    /// What an explicit check reports when it did not ask the provider again:
    /// the 30 s limit between checks is stated, not silent (R2-U-03).
    static func note(for outcome: AppStore.RefreshOutcome, now: Date) -> String? {
        guard case .tooSoon(let until) = outcome else { return nil }
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        return L("Данные только что проверены. Повторить проверку можно через {0} с.", "\(seconds)")
    }
}

/// One step of a card's connection details.
struct ConnectionStepRow: View {
    let number: Int
    let title: String
    let complete: Bool
    var stale = false
    var body: some View {
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
            // The check mark and the number are drawing; VoiceOver hears the title and its state.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(L(complete ? "Готово" : "Не выполнено"))
    }
}

struct ConnectionsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: AppStore
    @ObservedObject var sessions: SessionStore
    @State private var selectedProvider: ProviderID?
    @State private var showingDiagnostics = false
    @State private var repairProvider: ProviderID?
    @State private var selectedRepair: ConnectionDiagnostic.Repair?
    /// Read through the store: an isolated store never reads the user's files (R2-U-04).
    @State private var statusLineObservedAt: Date?
    /// A check asked again within 30 s of the last one; shown instead of doing nothing (R2-U-03).
    @State private var checkNote: String?
    @State private var disconnectedProvider: ProviderID?
    @State private var disconnectedEventsOnly = false
    /// The card the user refreshed; background polls do not show progress in every card.
    @State private var refreshingCard: ProviderID?
    private var availability: QuotaCheckAvailability {
        QuotaCheckAvailability(refreshing: store.refreshing, offline: store.network.isOffline)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Достаточно одного подключения. Второе можно добавить в любое время."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Offline is already explained by the network banner above the page.
                if availability == .refreshing, let reason = availability.reason {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L(reason)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("connection-quota-refreshing")
                } else if let checkNote {
                    Text(checkNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connection-quota-too-soon")
                }
                ForEach(store.providers) { id in providerCard(id) }
                ForEach(ProviderID.allCases.filter { !store.providers.contains($0) }) { id in optionalProviderCard(id) }
                if let id = disconnectedProvider {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            L(
                                disconnectedEventsOnly
                                    ? "События {0} отключены. Сохранённые данные остались в Lunavect."
                                    : "{0} отключён в Lunavect. Сохранённые данные остались, остальные настройки клиента не изменены.",
                                id.title)
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("Подключить снова")) { selectedRepair = nil; selectedProvider = id; disconnectedProvider = nil }
                    }.accessibilityIdentifier("connection-removal-result")
                }
                DisclosureGroup(L("Подключение на вашем Mac")) { ConnectionPrivacyView().padding(.top, 8) }
                IDEConnectionsView()
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
                                if sessions.disconnect(id) {
                                    store.setProvider(id, enabled: false); sessions.useProviders(store.providers)
                                    disconnectedEventsOnly = false; disconnectedProvider = id
                                }
                            }
                            if sessions.hooksInstalled[id] == true {
                                Button(L("Отключить события {0}", id.title)) {
                                    sessions.toggleHooks(id)
                                    if sessions.hooksInstalled[id] != true {
                                        disconnectedEventsOnly = true; disconnectedProvider = id
                                    }
                                }
                            }
                        }
                        Text(L("Отключение останавливает опрос, удаляет обработчики Lunavect и восстанавливает прежнюю строку состояния Claude. Сохранённые данные остаются."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let message = sessions.connectionMessage { Text(L(message)).foregroundStyle(.secondary) }
                    }.font(.system(size: 11)).padding(.top, 8)
                }

            }.padding(8).fixedSize(horizontal: false, vertical: true)
        }.onAppear { statusLineObservedAt = store.statusLineObservedAt(); sessions.updateHookConfiguration() }
            .sheet(item: $selectedProvider, onDismiss: {
                statusLineObservedAt = store.statusLineObservedAt()
                sessions.updateHookConfiguration()
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
        let configured = sessions.hooksInstalled[id] == true && (id == .codex || sessions.connectionStates[.claude]?.statusLine == .ready)
        let card = ConnectionCardState(provider: id, resolver: store.clientResolver, configured: configured, snapshot: snapshot,
                                       local: sessions.connectionStates[id], eventsDisabled: sessions.eventsDisabledByUser.contains(id))
        let receivedEvents = sessions.currentSessions.contains { $0.provider == id && [.hook, .localEvent].contains($0.evidence) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProviderLogo(id: id).foregroundStyle(activityAccent(id, adaptive: true, scheme: scheme)).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(id == .claude ? "Claude Code" : "Codex").font(.system(size: 15, weight: .semibold))
                    Text(L(card.statusTitle))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L(card.actionTitle)) {
                    switch card.action {
                    case .setup: selectedRepair = nil; selectedProvider = id
                    case .enableEvents: sessions.toggleHooks(id); disconnectedProvider = nil
                    case .refresh:
                        refreshingCard = id
                        checkNote = nil
                        Task {
                            let outcome = await store.refresh(provider: id)
                            checkNote = QuotaCheckAvailability.note(for: outcome, now: Date())
                            await sessions.refresh(); refreshingCard = nil
                        }
                    }
                }
                    // Setup and turning events on do not ask the provider; only a check waits.
                    .disabled(card.action == .refresh && (!availability.allowsCheck || refreshingCard != nil))
                    .help(card.action == .refresh ? availability.reason.map { L($0) } ?? "" : "")
                    .accessibilityHint(card.action == .refresh ? availability.reason.map { L($0) } ?? "" : "")
                    .accessibilityIdentifier("connect-" + id.rawValue)
            }
            if refreshingCard == id { ProgressView().controlSize(.small) }
            if let date = snapshot?.fetchedAt {
                Text(L("Последние данные: {0}", date.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let note = ConnectionCardState.savedQuotaNote(provider: id, snapshot: snapshot) {
                Text(L(note)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if id == .claude, ClaudeStatusLineReach.onlyDesktopSessions(sessions.sessions, statusLineObservedAt: statusLineObservedAt, now: Date()) {
                InterfaceLabel(L("Статусная строка не работает в Claude Desktop; лимиты обновляются через /usage"), .info)
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let issue = snapshot?.issue, !(id == .claude && issue == UsageError.waitingForClaude.errorDescription) {
                if store.network.isOffline {
                    Text(L("Ждём соединение. Данные обновятся автоматически.")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(L(issue)).font(.system(size: 12)).foregroundStyle(.orange)
                    if let guidance = ConnectionCardState.issueGuidance(provider: id, issue: issue) {
                        Text(L(guidance)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // The saved message maps to its typed reason; sign-in, setup and the
                    // probe folder's trust question each open their own Terminal step.
                    let repair = ClientIntegrationIssue.legacy(issue, provider: id, capability: id == .codex ? .rateLimits : .usageProbe)?.repair
                    if let repair, repair == .signIn || repair == .reviewUsage {
                        Button(L(repair.title)) {
                            selectedRepair = repair; selectedProvider = id
                        }.buttonStyle(.link)
                    }
                }
            }
            DisclosureGroup(L("Подробности подключения")) {
                VStack(alignment: .leading, spacing: 10) {
                    ConnectionStepRow(number: 1, title: L("Приложение найдено"), complete: card.clientFound)
                    ConnectionStepRow(number: 2, title: L("Локальные события настроены"), complete: configured)
                    if let missing = sessions.connectionStates[id]?.missingExecutable {
                        Text(L("Не найден файл: {0}", missing)).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Text(L(receivedEvents ? "Получены события текущей сессии" : "Нет подтверждённых событий текущей сессии"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Настроить")) { selectedRepair = nil; selectedProvider = id }
                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex") {
                            Button(L("Открыть {0}", id.title)) { NSWorkspace.shared.open(appURL) }
                        }
                    }
                    if id == .claude {
                        Text(
                            L(
                                "Лимиты обновляются автоматически: после ответов Claude, каждые 15 минут во время работы, раз в час в простое и после сброса. Исчерпанный лимит до сброса не запрашивается. Запускать задачу в терминале не нужно."
                            )
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
