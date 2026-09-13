import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ActivityStatisticsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("statisticsPeriod") private var period = ActivityPeriod.week
    @AppStorage("statisticsSource") private var source = ActivitySource.all
    @AppStorage("settingsSection") private var settingsSection = SettingsSection.connections
    @State private var detailDate: Date?
    @State private var showingBreakdown = false
    @State var historyExpanded = false
    private var effectiveSource: ActivitySource { Self.resolvedSource(source, enabledProviders: store.providers) }
    private var providers: [ProviderID] { effectiveSource.providers(from: store.providers) }
    private var selectionScope: ActivityChartSelectionScope {
        ActivityChartSelectionScope(period: period, providers: providers, selection: $detailDate)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Picker(L("Период"), selection: $period) {
                    ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300, alignment: .leading).accessibilityIdentifier("statistics-period")
                Spacer(minLength: 0)
                if store.providers.count > 1 {
                    Picker(L("Источник"), selection: Binding(get: { effectiveSource }, set: { source = $0 })) {
                        ForEach(ActivitySource.available(for: store.providers)) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("statistics-source")
                }
            }
            if store.importingActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Восстанавливаем историю…")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if providers.isEmpty {
                Text(L("Подключите Claude или Codex в настройках подключений."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button(L("Подключения")) { settingsSection = .connections }
                    .accessibilityIdentifier("statistics-open-connections")
                historySection
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ActivityDetailChart(data: ActivityChartData(history: store.activityHistory, now: context.date, period: period, providers: providers),
                                        unavailable: store.activityUnavailable, onSelection: { detailDate = $0 })
                        .id(selectionScope.id)
                    let breakdown = ActivityBreakdownData(history: store.activityHistory, details: store.activityDetails,
                                                          providers: providers, period: period, selectedDate: detailDate, now: context.date)
                    ActivityBreakdownSummaryView(data: breakdown)
                    if let issue = store.activityDetailsIssue { Text(L(issue)).font(.system(size: 12)).foregroundStyle(.orange) }
                    historySection
                    Button { showingBreakdown = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Проекты и сессии")).font(.system(size: 14, weight: .semibold))
                                Text(breakdown.sessionCountLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                        }.padding(16).contentShape(Rectangle())
                            .background(sectionBackground, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("activity-breakdown-open")
                        .accessibilityLabel(L("Проекты и сессии"))
                        .accessibilityValue(breakdown.sessionCountLabel)
                        .sheet(isPresented: $showingBreakdown) { ActivityBreakdownView(data: breakdown) }
                }
            }
        }
        .onAppear { reconcileSource() }
        .modifier(selectionScope)
        .onChange(of: source) { _, _ in reconcileSource() }
        .onChange(of: store.providers) { _, _ in reconcileSource() }
    }
    static func resolvedSource(_ source: ActivitySource, enabledProviders: [ProviderID]) -> ActivitySource {
        let source = source.canonical
        guard let provider = source.provider, !enabledProviders.contains(provider) else { return source }
        return ActivitySource.available(for: enabledProviders).first ?? .all
    }
    private func reconcileSource() {
        if source != effectiveSource { source = effectiveSource }
    }
    private var sectionBackground: Color {
        reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035)
    }
    private var historySection: some View {
        DisclosureGroup(L("История и точность данных"), isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                historyExplanation(
                    "Наблюдено Lunavect",
                    "Пока открыт Lunavect, учитывается подтверждённое время работы. Ожидание ввода, сон и периоды без свежего статуса не добавляются. Параллельные задачи не удваивают общее время."
                )
                historyExplanation(
                    "Восстановлено из журналов",
                    "При первом запуске автоматически восстанавливаются доступные записи длительности Claude и Codex за последние 30 дней. Знак ≈ означает, что итог включает время из журналов: оно может включать ожидание внутри задачи. Удалённую или не записанную историю восстановить нельзя."
                )
                historyExplanation(
                    "Периоды и пробелы",
                    "День — по часам, неделя — последние 7 дней, месяц — последние 30 дней. Пик считается в текущем часовом поясе. Линия соединяет известные точки; между ними значения без записей остаются неизвестными."
                )
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(store.providers) { provider in
                    let summary = store.activityHistory.summary(providers: [provider])
                    if let date = summary.lastLiveObservedAt {
                        GridRow {
                            Text(provider.title).foregroundStyle(.primary)
                            Text(L("Последнее наблюдение: {0}", date.formatted(.dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))))
                                .monospacedDigit()
                        }
                    }
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(16)
                .background(sectionBackground, in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityIdentifier("statistics-history-disclosure")
    }
    private func historyExplanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            Text(L(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reset details for the same changes that replace the chart's local selection.
/// An unrelated connection or equivalent source filter keeps both selections.
struct ActivityChartSelectionScope: ViewModifier {
    let period: ActivityPeriod
    let providers: [ProviderID]
    @Binding var selection: Date?
    var id: String { period.rawValue + providers.map(\.rawValue).joined() }
    func body(content: Content) -> some View {
        content.onChange(of: id) { _, _ in selection = nil }
    }
}

/// The chart's keyboard, adjustable accessibility action and pointer selection
/// share these commands, including validation of future and unknown points.
struct ActivityChartSelectionActions {
    let data: ActivityChartData
    let selectedDate: Date?
    var onSelection: (Date?) -> Void

    func move(_ offset: Int) { onSelection(data.adjacent(to: selectedDate, offset: offset)) }
    func select(_ date: Date?) { onSelection(data.validSelection(date)) }
    func clear() { onSelection(nil) }
}

struct ActivityDetailChart: View {
    let data: ActivityChartData
    var unavailable = false
    var chartHeight: CGFloat = 220
    var onSelection: (Date?) -> Void = { _ in }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredDate: Date?
    @State var pinnedDate: Date?
    @FocusState private var chartFocused: Bool
    private var selected: Date? { data.validSelection(pinnedDate ?? hoveredDate) }
    private var currentHour: Date? {
        guard data.summary.period == .day else { return nil }
        return data.points.first { ActivityChartText.isCurrent($0.date, period: .day, now: data.now) }?.date
    }
    private var readoutDate: Date? { selected ?? currentHour }
    private var selectionActions: ActivityChartSelectionActions {
        ActivityChartSelectionActions(data: data, selectedDate: selected) { date in
            pinnedDate = date; hoveredDate = nil; chartFocused = date != nil
        }
    }
    private var sectionBackground: Color {
        reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(ActivityChartText.range(data.summary)).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L(data.summary.period == .day ? "По часам" : "По дням")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ActivitySeriesLegend(data: data, unavailable: unavailable, foreground: .primary, adaptiveColors: true).frame(height: 32)
            if unavailable || !data.hasData {
                VStack(alignment: .leading, spacing: 10) {
                    InterfaceIcon(.activity, size: 28)
                    Text(L(unavailable ? "Статистика недоступна" : "Пока нет данных")).font(.system(size: 15, weight: .medium))
                    Text(L("Откройте историю ниже: там видно, какие записи удалось восстановить."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .leading)
            } else {
                chart
                Text(L("Линия соединяет известные точки. В промежутках без записей значения неизвестны."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if data.hasData && !unavailable { readout }
            HStack(alignment: .top, spacing: 24) {
                metric(L("Пиковый час"), data.summary.peakLabel)
                if data.series.count > 1 { metric(L("Вместе, без пересечений"), ActivityChartText.value(data.summary.totals)) }
                else { metric(L("Дней с записями"), "\(data.summary.days.filter { $0.totals.observed > 0 }.count) / \(data.summary.days.count)") }
            }
            if data.stale || data.limited {
                Label(L(data.stale ? "Данные устарели" : "По доступным записям"), systemImage: data.stale ? "clock.badge.exclamationmark" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(20).foregroundStyle(.primary)
            .background(sectionBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.055), lineWidth: 0.6))
            .onChange(of: pinnedDate) { _, date in onSelection(date) }
    }
    private var chart: some View {
                ActivityTrendPlot(data: data, selectedDate: selected, foreground: .primary, adaptiveColors: true, cleanContour: true)
                    .frame(height: chartHeight)
                    .overlay(alignment: .top) { interactionOverlay }
                    .focusable().focused($chartFocused)
                    .onMoveCommand { direction in
                        if direction == .left { selectionActions.move(-1) }
                        if direction == .right { selectionActions.move(1) }
                    }
                    .onExitCommand { selectionActions.clear() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Статистика активности"))
                    .accessibilityValue(selectionDescription)
                    .accessibilityHint(L("Выберите час или день стрелками влево и вправо."))
                    .accessibilityAdjustableAction { direction in selectionActions.move(direction == .increment ? 1 : -1) }
                    .accessibilityIdentifier("statistics-chart")
    }
    private var interactionOverlay: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in handleHover(phase, width: geometry.size.width) }
                .gesture(SpatialTapGesture().onEnded { value in
                    let tapped = date(at: value.location.x, width: geometry.size.width)
                    if tapped == pinnedDate { selectionActions.clear() }
                    else { selectionActions.select(tapped) }
                })
        }.padding(.bottom, ActivityPlotGeometry.labelsHeight).padding(.trailing, ActivityPlotGeometry.scaleWidth)
    }
    private func handleHover(_ phase: HoverPhase, width: CGFloat) {
        guard pinnedDate == nil else { return }
        switch phase {
        case .active(let location): hoveredDate = date(at: location.x, width: width)
        case .ended: hoveredDate = nil
        }
    }
    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(readoutDate.map { Self.pointLabel($0, period: data.summary.period) } ?? L("За период"))
                    .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if let readoutDate, ActivityChartText.isCurrent(readoutDate, period: data.summary.period, now: data.now) {
                    Text(L("Ещё идёт")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: selectionActions.clear) { Label(L("Весь период"), systemImage: "xmark") }
                    .controlSize(.small).accessibilityIdentifier("statistics-clear-selection")
                    .opacity(pinnedDate == nil ? 0 : 1).disabled(pinnedDate == nil)
                    .accessibilityHidden(pinnedDate == nil)
            }.frame(minHeight: 20)
            HStack(spacing: 20) {
                ForEach(data.series) { series in
                    HStack(spacing: 6) {
                        Circle().fill(activityAccent(series.provider, adaptive: true, scheme: scheme)).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(series.provider.title)
                        Text(unavailable ? "—" : ActivityChartText.value(series.totals(at: readoutDate), compact: false)).monospacedDigit()
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                }
            }.frame(minHeight: 18)
        }.padding(10).frame(minHeight: 64).frame(maxWidth: .infinity, alignment: .leading)
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("statistics-selection")
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    static func pointLabel(_ date: Date, period: ActivityPeriod, calendar: Calendar = .current) -> String {
        ActivityChartText.point(date, period: period, calendar: calendar)
    }
    private var selectionDescription: String {
        let label = selected.map { Self.pointLabel($0, period: data.summary.period) } ?? L("За период")
        return label + ". " + data.series.map { series in
            let totals = series.totals(at: selected)
            return series.provider.title + ": " + (totals.observed > 0 ? ActivityChartText.value(totals, compact: false) : L("Нет данных"))
        }.joined(separator: "; ")
    }
    private func date(at x: CGFloat, width: CGFloat) -> Date? {
        guard let index = ActivityChartSelection.index(at: x, width: width, count: data.points.count) else { return nil }
        return data.validSelection(data.points[index].date)
    }
}
