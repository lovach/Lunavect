import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SettingsSection: String, CaseIterable, Identifiable {
    case limits, general, connections, notifications, keepAwake, menuBar, statistics, widget, subscriptions, updates
    var id: String { rawValue }
    static var navigationOrder: [Self] { SettingsSectionGroup.allCases.flatMap(\.sections) + [.updates] }
    func adjacent(offset: Int) -> Self {
        let order = Self.navigationOrder, index = Self.navigationOrder.firstIndex(of: self) ?? 0
        return order[min(order.count - 1, max(0, index + offset))]
    }
    var title: String {
        switch self {
        case .limits: return L("Лимиты")
        case .general: return L("Основные")
        case .connections: return L("Подключения")
        case .notifications: return L("Уведомления")
        case .keepAwake: return "Keep Awake"
        case .menuBar: return L("Строка меню")
        case .statistics: return L("Статистика")
        case .widget: return L("Виджеты")
        case .subscriptions: return L("Подписки")
        case .updates: return L("Обновления")
        }
    }
    var glyph: InterfaceGlyph {
        switch self {
        case .limits: return .limits
        case .general: return .settings
        case .connections: return .link
        case .notifications: return .bell
        case .keepAwake: return .eye
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
        case .general: return L("Запуск, язык, тема и базовые настройки.")
        case .connections: return L("Claude и Codex: подключение, состояние и получение данных.")
        case .notifications: return L("Сообщения о завершении работы и запросах внимания.")
        case .keepAwake: return L("Работа с закрытой крышкой, питание и условия остановки.")
        case .menuBar: return L("Лимиты и персонажи в верхней строке экрана.")
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
    @ObservedObject var updates: AppUpdates
    @ObservedObject var awake: KeepAwake
    @ObservedObject var features: AppFeatures
    @ObservedObject var language: LanguageSettings
    var onShowSessions: () -> Void = {}
    var onShowWelcome: () -> Void = {}
    @AppStorage("settingsSection") private var section: SettingsSection = .connections
    @AppStorage("interfaceAppearance") private var appearance = InterfaceAppearance.dark
    @FocusState private var focusedSection: SettingsSection?

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
                    VStack(alignment: .leading, spacing: InterfaceMetrics.settingsSectionSpacing) {
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
            }.padding(.horizontal, 16).padding(.vertical, 14)
            ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsSectionGroup.allCases) { group in
                    VStack(spacing: 2) {
                        Text(group.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12).padding(.top, 8)
                        ForEach(group.sections) { item in
                            SettingsNavigationRow(section: item, selected: section == item) { section = item }
                                .focused($focusedSection, equals: item)
                        }
                    }
                }
            }.padding(.horizontal, 10)
            }
            Spacer(minLength: 8)
            SettingsNavigationRow(section: .updates, selected: section == .updates, hasNotice: updates.notice != nil) {
                section = .updates
            }.padding(.horizontal, 10).padding(.bottom, 8)
                .focused($focusedSection, equals: .updates)
                .accessibilityValue(updates.notice ?? "")
            if menuBarAppearance.showsSessionStatus {
            Divider().padding(.horizontal, 16)
            Button(action: onShowSessions) {
                InterfaceLabel(L("Назад к сессиям"), .back)
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            }
        }.frame(width: 190).frame(maxHeight: .infinity)
            .background(SettingsSidebarBackground())
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard let focusedSection else { return .ignored }
                let destination = focusedSection.adjacent(offset: press.key == .downArrow ? 1 : -1)
                section = destination; self.focusedSection = destination
                return .handled
            }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .limits:
            LimitsOverview(store: store) { section = .connections }
        case .general:
            AppBehaviorSettings(features: features)
            GroupBox {
                VStack(spacing: 16) {
                    SettingsRow(L("Язык")) {
                        Picker(L("Язык"), selection: $language.code) {
                            ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                        }.labelsHidden().accessibilityIdentifier("app-language")
                    }
                    Divider()
                    SettingsRow(L("Тема приложения")) {
                    Picker(L("Тема приложения"), selection: $appearance) {
                        ForEach(InterfaceAppearance.allCases) { Text($0 == .system ? L("Системная тема") : $0.title).tag($0) }
                    }.labelsHidden().accessibilityIdentifier("interface-appearance")
                    }
                }.padding(12)
            }
            GroupBox(L("Сессии")) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(L("Скрывать неактивные сессии")) {
                    Picker(L("Скрывать неактивные сессии"), selection: $sessions.autoHideMinutes) {
                        Text(L("Выключено")).tag(0)
                        Text(L("Через 5 минут")).tag(5)
                        Text(L("Через 10 минут")).tag(10)
                        Text(L("Через 20 минут")).tag(20)
                    }
                    .labelsHidden().accessibilityIdentifier("session-auto-hide")
                    }
                    Text(L("Завершённые сессии переходят в скрытые. Работающие и ожидающие ответа остаются. При новой задаче сессия возвращается автоматически."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(12)
            }
            Text(L("Изменения сохраняются автоматически."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            BaseSettingsView(canRestore: !awake.isBusy && !features.busy) {
                await awake.restoreDefaults()
                await features.restoreDefaults()
                menuBarAppearance.restoreDefaults()
                sessions.autoHideMinutes = 0
                store.preferences.restoreAppearanceDefaults()
                updates.setAutomatic(false)
                updates.setCheckingAutomatically(true)
                appearance = AppDefaultSettings.appearance
                language.code = "system"
            }
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
                    Text(L("Сессии, лимиты и статистика Claude и Codex")).foregroundStyle(.secondary)
                    Text(L("Версия {0} · сборка {1}",
                           Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
                           Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        case .notifications:
            NotificationSettingsView(features: features)
        case .keepAwake:
            KeepAwakeSettingsView(awake: awake)
        case .updates:
            UpdateSettingsView(updates: updates)
        case .connections:
            ConnectionsView(store: store, sessions: sessions)
        case .menuBar:
            MenuBarAppearanceView(appearance: menuBarAppearance, snapshots: store.snapshots, providers: store.providers)
        case .statistics:
            ActivityStatisticsView(store: store)
        case .widget:
            GroupBox(L("Общие настройки виджетов")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Применяются к установленным виджетам и предпросмотру. macOS обновляет виджеты по своему расписанию."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SettingsRow(L("Показывать 5-часовой лимит")) {
                        Toggle(L("Показывать 5-часовой лимит"), isOn: $store.preferences.showFiveHour)
                            .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("widget-shared-five-hour")
                    }
                    Divider()
                    SettingsRow(L("Стеклянный фон")) {
                        Toggle(L("Стеклянный фон"), isOn: $store.preferences.transparentBackground)
                            .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("widget-shared-background")
                    }
                    SettingsRow(L("Прозрачность подложки")) {
                        HStack(spacing: 8) {
                            Slider(value: $store.preferences.transparency, in: 0...1, step: 0.05)
                                .accessibilityLabel(L("Прозрачность подложки"))
                                .accessibilityValue(L("{0} процентов", String(Int((store.preferences.transparency * 100).rounded()))))
                                .accessibilityIdentifier("widget-backdrop-transparency")
                            Text(store.preferences.transparency.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit().frame(width: 42, alignment: .trailing).accessibilityHidden(true)
                        }
                        .disabled(!store.preferences.transparentBackground)
                    }
                    Text(L("0% — плотная подложка, 100% — только системное стекло. Размытие и оттенок фона подстраиваются под обои и настройки macOS."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12)
            }.accessibilityIdentifier("widget-shared-settings")
            WidgetPreviewPicker(store: store)
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

/// Sidebar destinations share the same visual and accessibility selection state.
struct SettingsNavigationRow: View {
    let section: SettingsSection
    let selected: Bool
    var hasNotice = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                InterfaceIcon(section.glyph, size: 18).frame(width: 18)
                Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                if hasNotice { Circle().fill(selected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor).frame(width: 7, height: 7) }
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
                .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: InterfaceMetrics.selectionCornerRadius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("settings-" + section.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep settings labels and controls on consistent axes, including multiline labels.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.control = control
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            control().frame(width: InterfaceMetrics.settingsControlWidth, alignment: .trailing)
        }
    }
}

/// Segmented choices get the available width; long labels wrap above the control.
struct SettingsChoiceRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.control = control
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            control().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
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
        case .application: return [.general, .connections, .notifications, .keepAwake]
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
                Text(L("Посмотреть варианты")).font(.headline)
                Spacer()
                Text(L("Только предпросмотр")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker(L("Содержимое виджета"), selection: $content) {
                ForEach(LunavectWidgetContent.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("widget-preview-content")
                .onChange(of: content) { _, value in if !value.sizes.contains(family) { family = value.sizes[0] } }
            HStack(spacing: 16) {
                Text(L("Размер виджета")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if content.sizes.count > 1 {
                    Picker(L("Размер виджета"), selection: $family) {
                        ForEach(content.sizes) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300, alignment: .leading)
                } else { Text(family.title).font(.system(size: 12)) }
            }
            if content != .limits {
                HStack(spacing: 16) {
                    Picker(L("Период"), selection: $period) {
                        ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280, alignment: .leading)
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
            .accessibilityIdentifier("widget-preview")

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
        let formatter = DateFormatter(); formatter.locale = L10n.locale
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
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
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
            if configuration.isExpanded { configuration.content.frame(maxWidth: .infinity, alignment: .leading) }
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
                SettingsRow(L("Показывать 5-часовой лимит")) {
                    Toggle(L("Показывать 5-часовой лимит"), isOn: $store.preferences.showFiveHour)
                        .labelsHidden().toggleStyle(.switch)
                }
                Button(L("Проверить подключение"), action: onConnections).buttonStyle(.link)
            }
        }.accessibilityIdentifier("limits-overview")
    }
}

struct LimitsProviderSummary: View {
    // Brand accents are tuned for dark surfaces; Settings follows the system appearance.
    @Environment(\.colorScheme) private var scheme
    let snapshot: UsageSnapshot
    var showFiveHour: Bool
    let now: Date
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ProviderLogo(id: snapshot.provider).foregroundStyle(activityAccent(snapshot.provider, adaptive: true, scheme: scheme)).frame(width: 24, height: 24)
                    Text(snapshot.provider.title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    if let fetched = snapshot.fetchedAt {
                        Text(fetched.formatted(.dateTime.hour().minute().locale(L10n.locale)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .help(L("Последние данные: {0}", fetched.formatted(.dateTime.day().month().hour().minute().locale(L10n.locale))))
                    }
                }
                DetailedQuotaMeter(title: L("Осталось на неделю"), window: snapshot.weekly,
                                   tint: activityAccent(snapshot.provider, adaptive: true, scheme: scheme), now: now)
                if showFiveHour {
                    DetailedQuotaMeter(title: L("Пятичасовой лимит"), window: snapshot.fiveHour,
                                       tint: activityAccent(snapshot.provider, adaptive: true, scheme: scheme), now: now)
                }
                if snapshot.provider == .claude, let quotas = snapshot.modelQuotas, !quotas.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(quotas) { quota in
                            DetailedQuotaMeter(title: quota.name, window: quota.window, tint: activityAccent(.claude, adaptive: true, scheme: scheme), now: now)
                            if quota.isStale(now: now) {
                                Text(L("Данные этого лимита устарели")).font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }.accessibilityIdentifier("claude-model-quotas")
                }
                if snapshot.isStale(now: now) || snapshot.issue != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        InterfaceLabel(L(snapshot.hasQuota ? "Показаны последние полученные данные" : "Ждём первые данные"), .history)
                            .foregroundStyle(.orange)
                        if let issue = snapshot.issue { Text(L(issue)).foregroundStyle(.secondary) }
                    }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DetailedQuotaMeter: View {
    let title: String
    let window: QuotaWindow?
    let tint: Color
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                if let window, !window.isExpired(at: now), window.resetsAt != nil {
                    Text(L("Сброс через {0}", window.countdown(now: now)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(window.flatMap { $0.isExpired(at: now) ? nil : "\(Int($0.remaining.rounded()))%" } ?? "—")
                    .monospacedDigit().fontWeight(.semibold)
            }.font(.system(size: 13))
            if let window, !window.isExpired(at: now) {
                ProgressView(value: window.remaining, total: 100).tint(tint)
                    .accessibilityLabel(title).accessibilityValue(L("Осталось {0}%", String(Int(window.remaining.rounded()))))
                if window.resetsAt == nil {
                    Text(L("Источник не передал время сброса")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text(L(window == nil ? "Источник не передал этот лимит" : "Срок сброса наступил. Ждём свежие данные."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .contain)
    }
}

struct SubscriptionSettingsRow: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: AppStore
    let provider: ProviderID
    @State private var editing = false
    @State private var draft = Date()
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                ProviderLogo(id: provider).foregroundStyle(activityAccent(provider, adaptive: true, scheme: scheme)).frame(width: 28, height: 28)
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

private struct SettingsSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
        else { SettingsSidebarMaterial() }
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
