import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SettingsSection: String, CaseIterable, Identifiable {
    case limits, general, connections, notifications, menuBar, statistics, widget, subscriptions, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .limits: return L("Лимиты")
        case .general: return L("Основные")
        case .connections: return L("Подключения")
        case .notifications: return L("Уведомления")
        case .menuBar: return L("Строка меню")
        case .statistics: return L("Статистика")
        case .widget: return L("Виджеты")
        case .subscriptions: return L("Подписки")
        case .updates: return L("Обновления")
        }
    }
    var glyph: InterfaceGlyph {
        switch self {
        case .limits: return .activity
        case .general: return .settings
        case .connections: return .link
        case .notifications: return .bell
        case .menuBar: return .menuBar
        case .statistics: return .activity
        case .widget: return .widget
        case .subscriptions: return .calendar
        case .updates: return .refresh
        }
    }
    var subtitle: String {
        switch self {
        case .limits: return L("Остаток и время следующего сброса.")
        case .general: return L("Язык интерфейса и информация о приложении.")
        case .connections: return L("Claude и Codex: подключение, состояние и получение данных.")
        case .notifications: return L("Сообщения о завершении работы и запросах внимания.")
        case .menuBar: return L("Формат статуса, персонаж и анимация в верхней строке экрана.")
        case .statistics: return L("Время работы, пики активности и доступная история.")
        case .widget: return L("Лимиты и графики в системных виджетах macOS.")
        case .subscriptions: return L("Даты окончания подписок для отображения в виджете.")
        case .updates: return L("Новые версии Lunavect и автоматическое скачивание.")
        }
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var menuBarAppearance: MenuBarAppearance
    @ObservedObject var sessions: SessionStore
    @ObservedObject var updates = AppUpdates.shared
    var onShowSessions: () -> Void = {}
    var onShowWelcome: () -> Void = {}
    @AppStorage("settingsSection") private var section: SettingsSection = .connections
    @AppStorage("interfaceAppearance") private var appearance = InterfaceAppearance.dark

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.title).font(.system(size: 23, weight: .semibold))
                        Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if section == .connections || section == .limits {
                        Button {
                            Task { await store.refresh(); await sessions.refresh() }
                        } label: { InterfaceLabel(L("Обновить"), .refresh) }
                            .disabled(store.refreshing || sessions.refreshing)
                    }
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        NetworkStatusView(network: store.network)
                        page
                        if let issue = store.storageIssue {
                            InterfaceLabel(L(issue), .warning)
                                .font(.system(size: 12)).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: 640, alignment: .leading)
                        .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }.id(section)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 800, minHeight: 580)
            .disclosureGroupStyle(FullRowDisclosureStyle())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let mark = AppArtwork.brandMark {
                    Image(nsImage: mark).resizable().renderingMode(.original).scaledToFit().frame(width: 40, height: 40).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lunavect").font(.system(size: 15, weight: .semibold))
                    Text(L("Настройки")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 26)
            ScrollView {
            VStack(spacing: 5) {
                ForEach(SettingsSectionGroup.allCases) { group in
                    Text(group.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.top, 10)
                ForEach(group.sections) { item in
                    Button { section = item } label: {
                        HStack(spacing: 10) {
                            InterfaceIcon(item.glyph, size: 18).frame(width: 18)
                            Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(section == item ? Color.white : Color.primary)
                            .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("settings-" + item.rawValue)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                }
            }.padding(.horizontal, 10)
            }
            Spacer(minLength: 24)
            Button { section = .updates } label: {
                HStack(spacing: 10) {
                    InterfaceIcon(.refresh, size: 18)
                    Text(L("Обновления")).font(.system(size: 13))
                    Spacer(minLength: 0)
                    if updates.notice != nil { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                }.padding(12).contentShape(Rectangle())
                    .background(section == .updates ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 8)
                .accessibilityIdentifier("settings-updates")
                .accessibilityValue(updates.notice ?? "")
            Divider().padding(.horizontal, 16)
            Button(action: onShowSessions) {
                InterfaceLabel(L("Назад к сессиям"), .back)
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.frame(width: 190).frame(maxHeight: .infinity)
            .background(SettingsSidebarMaterial())
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .limits:
            LimitsOverview(store: store) { section = .connections }
        case .general:
            AppBehaviorSettings()
            GroupBox {
                VStack(spacing: 16) {
                    LanguagePicker()
                    Divider()
                    HStack {
                    Text(L("Тема приложения"))
                    Spacer()
                    Picker(L("Тема приложения"), selection: $appearance) {
                        ForEach(InterfaceAppearance.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190).accessibilityIdentifier("interface-appearance")
                    }
                }.padding(12)
            }
            GroupBox(L("Сессии")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("Скрывать неактивные сессии"), selection: $sessions.autoHideMinutes) {
                        Text(L("Выключено")).tag(0)
                        Text(L("Через 5 минут")).tag(5)
                        Text(L("Через 10 минут")).tag(10)
                        Text(L("Через 20 минут")).tag(20)
                    }
                    .accessibilityIdentifier("session-auto-hide")
                    Text(L("Завершённые сессии переходят в скрытые. Работающие и ожидающие ответа остаются. При новой задаче сессия возвращается автоматически."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(12)
            }
            Text(L("Изменения сохраняются автоматически."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup(L("Обучение")) {
            GroupBox(L("Начало работы")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Подключение приложений, виджет и управление сессиями — короткое обучение всегда под рукой."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Показать обучение"), action: onShowWelcome)
                        .accessibilityIdentifier("show-welcome")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            GroupBox(L("О приложении")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lunavect").font(.system(size: 15, weight: .semibold))
                    Text(L("Недельные лимиты Claude и Codex")).foregroundStyle(.secondary)
                    Text(L("Версия {0} · сборка {1}",
                           Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                           Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        case .notifications:
            NotificationSettingsView()
        case .updates:
            UpdateSettingsView()
        case .connections:
            ConnectionsView(store: store, sessions: sessions)
        case .menuBar:
            MenuBarAppearanceView(appearance: menuBarAppearance)
        case .statistics:
            ActivityStatisticsView(store: store)
            DisclosureGroup(L("История и точность данных")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Пока открыт Lunavect, учитывается подтверждённое время работы. Ожидание ввода, сон и периоды без свежего статуса не добавляются. Параллельные задачи не удваивают общее время."))
                    Text(L("При первом запуске автоматически восстанавливаются доступные записи длительности Claude и Codex за последние 30 дней. Знак ≈ означает, что итог включает время из журналов: оно может включать ожидание внутри задачи. Удалённую или не записанную историю восстановить нельзя."))
                    Text(L("День — по часам, неделя — последние 7 дней, месяц — последние 30 дней. Пик считается за выбранный период в текущем часовом поясе. Пробелы означают отсутствие данных."))
                    ForEach(store.providers) { provider in
                        let summary = store.activityHistory.summary(providers: [provider])
                        if let date = summary.lastLiveObservedAt {
                            Text(provider.title + " · " + L("Последнее наблюдение: {0}", date.formatted(.dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))))
                        }
                    }
                    HStack {
                        if store.importingActivity {
                            ProgressView().controlSize(.small)
                            Text(L("Восстанавливаем историю…"))
                        } else {
                            Button(L("Обновить историю")) { store.importActivityHistory() }
                            if store.activityHistory.importedAt != nil, store.activityHistory.importReport == nil {
                                Text(store.activityHistory.intervals.contains { $0.recovered == true } ? L("Доступная история восстановлена") : L("Записи длительности не найдены"))
                            }
                        }
                    }
                    if let report = store.activityHistory.importReport {
                        ActivityImportReportView(report: report)
                    } else if store.activityHistory.importWasLimited == true {
                        Text(L("Часть журналов недоступна или пропущена. Показаны только прочитанные данные.")).foregroundStyle(.orange)
                    }
                    if let issue = store.activityIssue { Text(L(issue)).foregroundStyle(.orange) }
                }.font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        case .widget:
            WidgetPreviewPicker(store: store)
            GroupBox(L("Отображение лимитов")) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L("Показывать 5-часовой лимит"))
                        Spacer()
                        Toggle(L("Показывать 5-часовой лимит"), isOn: $store.preferences.showFiveHour)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    HStack {
                        Text(L("Прозрачный фон")); Spacer()
                        Toggle(L("Прозрачный фон"), isOn: $store.preferences.transparentBackground).labelsHidden().toggleStyle(.switch)
                    }
                    HStack(spacing: 12) {
                        Text(L("Прозрачность"))
                        Slider(value: $store.preferences.transparency, in: 0.2...0.75)
                            .accessibilityLabel(L("Прозрачность")).disabled(!store.preferences.transparentBackground)
                        Text("\(Int((store.preferences.transparency * 100).rounded()))%")
                            .monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Text(L("Прозрачный фон системного виджета — экспериментальная функция этой сборки. После обновления macOS оформление может измениться."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12)
            }
        case .subscriptions:
            Text(L("Источники лимитов не предоставляют подтверждённую дату окончания подписки. Она появится в виджете только после ввода здесь."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.providers.isEmpty {
                Text(L("Подключите Claude или Codex в настройках подключений.")).foregroundStyle(.secondary)
            }
            ForEach(store.providers) { id in
                SubscriptionSettingsRow(store: store, provider: id)
            }
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case overview, application, appearance, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("Обзор")
        case .application: return L("Приложение")
        case .appearance: return L("Оформление")
        case .data: return L("Данные")
        }
    }
    var sections: [SettingsSection] {
        switch self {
        case .overview: return [.limits, .statistics]
        case .application: return [.general, .connections, .notifications]
        case .appearance: return [.menuBar, .widget]
        case .data: return [.subscriptions]
        }
    }
}

struct WidgetPreviewPicker: View {
    @ObservedObject var store: AppStore
    @State private var content = LunavectWidgetContent.activity
    @State private var family = LunavectWidgetSize.medium
    @State private var period = ActivityPeriod.week
    @State private var source = ActivitySource.all
    init(store: AppStore, content: LunavectWidgetContent = .activity, family: LunavectWidgetSize = .medium, period: ActivityPeriod = .week) {
        self.store = store
        _content = State(initialValue: content); _family = State(initialValue: family); _period = State(initialValue: period)
    }
    private var selectionSummary: String {
        var parts = [content.title, family.title]
        if content != .limits { parts += [period.title, source.title] }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("Предпросмотр")).font(.headline)
                Spacer()
                Text(L("Установленный виджет не меняется")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker(L("Содержимое виджета"), selection: $content) {
                ForEach(LunavectWidgetContent.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: content) { _, value in if !value.sizes.contains(family) { family = value.sizes[0] } }
            HStack(spacing: 16) {
                Text(L("Размер виджета")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if content.sizes.count > 1 {
                    Picker(L("Размер виджета"), selection: $family) {
                        ForEach(content.sizes) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                } else { Text(family.title).font(.system(size: 12)) }
            }
            if content != .limits {
                HStack(spacing: 16) {
                    Picker(L("Период"), selection: $period) {
                        ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                    Spacer(minLength: 0)
                    if store.providers.count > 1 {
                        Picker(L("Источник"), selection: $source) {
                            ForEach(ActivitySource.available(for: store.providers)) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                LunavectWidgetCard(snapshots: store.snapshots, preferences: store.preferences, history: store.activityHistory,
                                  content: content, family: family, now: context.date, activityUnavailable: store.activityUnavailable, period: period, source: source)
                    .background { GlassMaterial() }
                    .clipShape(RoundedRectangle(cornerRadius: 26))
            }
            DisclosureGroup(L("Добавление виджета")) { WidgetGalleryControls(selection: selectionSummary) }
            Text(L("Период и сервисы установленного виджета: правый клик → «Изменить виджет». Эти параметры меняют только предпросмотр."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        }.padding(16).frame(maxWidth: .infinity)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))

    }
}

struct ActivityImportReportView: View {
    let report: ActivityImportReport
    @State private var expandedProviders: Set<ProviderID>
    init(report: ActivityImportReport, expanded: Bool = false) {
        self.report = report
        _expandedProviders = State(initialValue: expanded ? Set(report.providers.map(\.id)) : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Результат последнего импорта")).fontWeight(.medium).foregroundStyle(.primary)
            ForEach(report.providers, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(provider.id == .claude ? "Claude" : "Codex").fontWeight(.medium)
                        Spacer()
                        Text(provider.recoveredSeconds > 0 ? "≈ " + ActivitySummary.duration(provider.recoveredSeconds) : L("Записи длительности не найдены"))
                            .monospacedDigit()
                    }.foregroundStyle(.primary)
                    if let first = provider.firstRecovered, let last = provider.lastRecovered {
                        Text(L("Дней с записями: {0}", String(provider.daysRecovered)) + " · " + date(first) + " — " + date(last))
                    }
                    DisclosureGroup(isExpanded: Binding(get: { expandedProviders.contains(provider.id) }, set: {
                        if $0 { expandedProviders.insert(provider.id) } else { expandedProviders.remove(provider.id) }
                    })) {
                        diagnosticDetails(provider)
                    } label: {
                        Text(provider.issues.isEmpty ? L("Подробности импорта") : L("Подробности импорта — есть пропуски"))
                            .foregroundStyle(provider.issues.isEmpty ? Color.secondary : Color.orange)
                    }
                }
            }
            Text(L("Пробелы в истории не означают отсутствие работы. Показано только время, которое удалось восстановить."))
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
    }
    private func date(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.selection)
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
    private func diagnosticDetails(_ provider: ActivityImportReport.Provider) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Прочитано журналов: {0}. Без записей длительности: {1}.", String(provider.filesRead), String(provider.filesWithoutTiming)))
            Text(L("Записи времени: задачи — {0}, подзадачи — {1}, инструменты — {2}.", String(provider.taskRecords), String(provider.agentRecords), String(provider.toolRecords)))
            ForEach(ActivityImportIssue.allCases.filter { provider.issues[$0, default: 0] > 0 }, id: \.self) { issue in
                Text(issue.title + ": " + String(provider.issues[issue, default: 0])).foregroundStyle(.orange)
            }
        }.padding(.vertical, 6)
    }
}

/// On macOS the default disclosure only hits its small arrow. Use the whole row.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 14)
                    configuration.label
                    Spacer(minLength: 0)
                }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(L(configuration.isExpanded ? "Развёрнуто" : "Свёрнуто"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct LimitsOverview: View {
    @ObservedObject var store: AppStore
    var onConnections: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.providers.isEmpty {
                Text(L("Подключите Claude или Codex в настройках подключений.")).foregroundStyle(.secondary)
                Button(L("Подключить приложения"), action: onConnections).buttonStyle(.borderedProminent)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ForEach(store.providers) { id in
                    LimitsProviderSummary(snapshot: store.snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id),
                                          showFiveHour: store.preferences.showFiveHour, now: context.date)
                }
            }
            if !store.providers.isEmpty {
                Toggle(L("Показывать 5-часовой лимит"), isOn: $store.preferences.showFiveHour)
                Button(L("Проверить подключение"), action: onConnections).buttonStyle(.link)
            }
        }.accessibilityIdentifier("limits-overview")
    }
}

struct LimitsProviderSummary: View {
    let snapshot: UsageSnapshot
    var showFiveHour: Bool
    let now: Date
    @AppStorage("showClaudeModelQuotas") private var showModelQuotas = false
    private var weekly: QuotaWindow? { snapshot.weekly.flatMap { $0.isExpired(at: now) ? nil : $0 } }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProviderLogo(id: snapshot.provider).foregroundStyle(activityAccent(snapshot.provider)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.provider.title).font(.system(size: 15, weight: .semibold))
                        Text(L("Осталось на неделю")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                }
                if let weekly {
                    ProgressView(value: weekly.remaining, total: 100).tint(activityAccent(snapshot.provider))
                        .accessibilityLabel(L("Осталось на неделю"))
                        .accessibilityValue(L("{0} процентов", String(Int(weekly.remaining.rounded()))))
                    Text(L("Сброс через {0}", weekly.countdown(now: now))).font(.system(size: 12)).foregroundStyle(.secondary)
                } else { Text(L("Недельный лимит недоступен")).font(.system(size: 12)).foregroundStyle(.secondary) }
                if showFiveHour {
                    Divider()
                    DetailedQuotaMeter(title: L("Пятичасовой лимит"), window: snapshot.fiveHour,
                                       tint: activityAccent(snapshot.provider), now: now)
                }
                if snapshot.provider == .claude, let quotas = snapshot.modelQuotas, !quotas.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showModelQuotas) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(quotas) { quota in
                                DetailedQuotaMeter(title: quota.name, window: quota.window, tint: .orange, now: now)
                                if quota.isStale(now: now) {
                                    Text(L("Данные этого лимита устарели")).font(.system(size: 11)).foregroundStyle(.orange)
                                }
                            }
                        }.padding(.top, 12)
                    } label: {
                        Text(quotas.count == 1 ? L("Лимит {0}", quotas[0].name) : L("Лимиты моделей"))
                            .font(.system(size: 13, weight: .medium))
                    }.accessibilityIdentifier("claude-model-quotas")
                }
                if snapshot.isStale(now: now) || snapshot.issue != nil {
                    InterfaceLabel(L(snapshot.hasQuota ? "Показаны последние полученные данные" : "Ждём первые данные"), .history)
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    if let issue = snapshot.issue {
                        Text(L(issue)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let fetched = snapshot.fetchedAt {
                    Text(L("Последние данные: {0}", fetched.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DetailedQuotaMeter: View {
    let title: String
    let window: QuotaWindow?
    let tint: Color
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(window.flatMap { $0.isExpired(at: now) ? nil : "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .monospacedDigit().fontWeight(.semibold)
            }.font(.system(size: 13))
            if let window, !window.isExpired(at: now) {
                ProgressView(value: window.remaining, total: 100).tint(tint)
                    .accessibilityLabel(title).accessibilityValue(L("Осталось {0}%", String(Int(window.remaining.rounded()))))
                Text(window.resetsAt == nil ? L("Источник не передал время сброса") : L("Сброс через {0}", window.countdown(now: now)))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(L(window == nil ? "Источник не передал этот лимит" : "Срок сброса наступил. Ждём свежие данные."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .contain)
    }
}

struct SubscriptionSettingsRow: View {
    @ObservedObject var store: AppStore
    let provider: ProviderID
    @State private var editing = false
    @State private var draft = Date()
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                ProviderLogo(id: provider).foregroundStyle(activityAccent(provider)).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.title).font(.headline)
                    Text(L(store.preferences.subscriptionDates[provider.rawValue] == nil ? "Дата не указана" : "Указано вручную"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    draft = store.subscriptionBinding(provider).wrappedValue; editing = true
                } label: {
                    if store.preferences.subscriptionDates[provider.rawValue] != nil {
                        Text(store.subscriptionBinding(provider).wrappedValue.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))
                    } else { Text(L("Указать дату")) }
                }.popover(isPresented: $editing) {
                    VStack(spacing: 0) {
                        SubscriptionCalendarView(provider: provider, selection: $draft) {
                            store.subscriptionBinding(provider).wrappedValue = draft; editing = false
                        }
                        Button(L("Отмена")) { editing = false }.keyboardShortcut(.cancelAction).padding(.bottom, 12)
                    }
                }
                if store.preferences.subscriptionDates[provider.rawValue] != nil {
                    Button { store.preferences.subscriptionDates.removeValue(forKey: provider.rawValue) } label: { InterfaceIcon(.close).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help(L("Убрать дату")).accessibilityLabel(L("Убрать дату"))
                }
            }.padding(12)
        }
    }
}

private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
