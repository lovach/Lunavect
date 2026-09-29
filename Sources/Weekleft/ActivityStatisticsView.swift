import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ActivityStatisticsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("statisticsPeriod") private var period = ActivityPeriod.week
    /// "year" or "all" while a long range is shown; empty for the period above.
    @AppStorage("statisticsLongRange") private var longRange = ""
    private var range: StatisticsRange {
        StatisticsRange(rawValue: longRange).flatMap { $0.period == nil ? $0 : nil } ?? StatisticsRange(rawValue: period.rawValue) ?? .week
    }
    private var rangeBinding: Binding<StatisticsRange> {
        Binding(get: { range }, set: { value in
            if let period = value.period { self.period = period; longRange = "" } else { longRange = value.rawValue }
        })
    }
    @AppStorage("statisticsSource") private var source = ActivitySource.all
    @AppStorage("settingsSection") private var settingsSection = SettingsSection.connections
    @State private var detailDate: Date?
    @State private var showingBreakdown = false
    @State var historyExpanded = false
    /// nil until the user asks; the check reads other Lunavect locations only then.
    @State private var legacyData: [URL]?
    @State private var legacyMoved = 0
    private var effectiveSource: ActivitySource { Self.resolvedSource(source, enabledProviders: store.providers) }
    private var providers: [ProviderID] { effectiveSource.providers(from: store.providers) }
    private var selectionScope: ActivityChartSelectionScope {
        ActivityChartSelectionScope(period: period, providers: providers, selection: $detailDate)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Picker(L("Период"), selection: rangeBinding) {
                    ForEach(StatisticsRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420, alignment: .leading).accessibilityIdentifier("statistics-period")
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
                    let archived = ActivityArchiveSummary.make(store.activityArchive, range: range, providers: providers, now: context.date)
                    if range.period == nil {
                        ActivityLongRangeChart(summary: archived, range: range, providers: providers, unavailable: store.activityUnavailable)
                    } else {
                        ActivityDetailChart(data: ActivityChartData(history: store.activityHistory, now: context.date, period: period, providers: providers),
                                            unavailable: store.activityUnavailable, onSelection: { detailDate = $0 })
                            .id(selectionScope.id)
                    }
                    let breakdown = ActivityBreakdownData(history: store.activityHistory, details: store.activityDetails,
                                                          providers: providers, period: period, selectedDate: detailDate, now: context.date)
                    if range.period != nil { ActivityBreakdownSummaryView(data: breakdown) }
                    ActivityStatisticsCards(archive: store.activityArchive, summary: archived, range: range, providers: providers, now: context.date)
                    if let issue = store.activityDetailsIssue { Text(L(issue)).font(.system(size: 12)).foregroundStyle(.orange) }
                    historySection
                    if range.period != nil {
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
                    "При первом запуске автоматически восстанавливаются доступные записи длительности Claude и Codex за последние 30 дней, а для «Года» и «Всего времени» — итоги по дням из всех журналов, которые ещё есть на этом Mac. Знак ≈ означает, что итог включает время из журналов: оно может включать ожидание внутри задачи. Удалённую или не записанную историю восстановить нельзя."
                )
                historyExplanation(
                    "Периоды и пробелы",
                    "День — по часам, неделя — последние 7 дней, месяц — последние 30 дней, год — по неделям, всё время — с первой записи. Итоги каждого дня хранятся без ограничения срока. Пик считается в текущем часовом поясе. Линия соединяет известные точки; между ними значения без записей остаются неизвестными."
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
                if let gaps = store.activityHistory.observationGaps, gaps.count > 0 {
                    Text(L("Не засчитано разрывов наблюдения: {0}, всего {1}, с {2}.", String(gaps.count), ActivitySummary.duration(gaps.seconds),
                           gaps.since.formatted(.dateTime.day().month().locale(L10n.locale))))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.activityUnavailable, !store.importingActivity {
                    Text(L("Файл статистики не читается. Lunavect сохранит его копию рядом и начнёт новую историю, восстановив недавние журналы."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if store.importingActivity {
                        ProgressView().controlSize(.small)
                        Text(L("Восстанавливаем историю…"))
                    } else if store.activityUnavailable {
                        // The only action that keeps a copy of the unreadable file and starts over.
                        Button(L("Сохранить копию и начать заново")) { store.startOverActivityHistory() }
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
                legacyDataControls
            }.font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(16)
                .background(sectionBackground, in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityIdentifier("statistics-history-disclosure")
    }
    /// Copies left by an earlier installation (decision 24): found and moved to
    /// the Trash only on request, never automatically.
    @ViewBuilder private var legacyDataControls: some View {
        HStack(alignment: .firstTextBaseline) {
            if let legacyData, !legacyData.isEmpty {
                LegacyCopiesList(urls: legacyData)
                Spacer(minLength: 8)
                Button(L("Переместить в Корзину")) {
                    let remaining = LegacySharedData.moveToTrash(legacyData)
                    legacyMoved = legacyData.count - remaining.count; self.legacyData = remaining
                }
            } else if legacyData != nil {
                Text(legacyMoved > 0 ? L("Перемещено в Корзину: {0}.", String(legacyMoved)) : L("Данные прежней установки не найдены."))
            } else {
                Button(L("Найти данные прежней установки")) { legacyData = LegacySharedData.find(); legacyMoved = 0 }
            }
        }
    }
    private func historyExplanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            Text(L(text)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Copies of an earlier installation: what would move to the Trash, with its last
/// change, before anything is moved (R3-07).
struct LegacyCopiesList: View {
    let urls: [URL]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Прежняя установка оставила копии, которые Lunavect не читает: {0}.", String(urls.count)))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LegacySharedData.details(of: urls), id: \.url) { item in
                Text((item.url.path as NSString).abbreviatingWithTildeInPath + (item.modified.map { " · " + $0.formatted(.dateTime.day().month().year().locale(L10n.locale)) } ?? ""))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
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

/// Year and All time: one line per source over weeks or months from the daily archive.
struct ActivityLongRangeChart: View {
    let summary: ActivityArchiveSummary
    let range: StatisticsRange
    let providers: [ProviderID]
    var unavailable = false
    var chartHeight: CGFloat = 200
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    private var sectionBackground: Color { reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L(summary.bucket == .week ? "По неделям" : summary.bucket == .month ? "По месяцам" : "По дням"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                ForEach(providers) { provider in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Capsule().fill(activityAccent(provider, adaptive: true, scheme: scheme)).frame(width: 12, height: 3)
                            Text(provider.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(value(provider == .claude ? summary.claude : summary.codex)).font(.system(size: 15, weight: .medium)).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }
            if unavailable || !summary.hasWork {
                VStack(alignment: .leading, spacing: 10) {
                    InterfaceIcon(.activity, size: 28)
                    Text(L(unavailable ? "Статистика недоступна" : "Пока нет данных")).font(.system(size: 15, weight: .medium))
                }.frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .leading)
            } else {
                plot.frame(height: chartHeight)
                    .accessibilityElement(children: .ignore).accessibilityLabel(L("Статистика активности"))
                    .accessibilityValue(accessibilityValue).accessibilityIdentifier("statistics-long-chart")
                if let first = summary.firstDay, summary.points.contains(where: { !$0.known }) {
                    Text(L("Записи начинаются {0}: более ранние журналы на этом Mac не сохранились.", first.formatted(.dateTime.day().month().year().locale(L10n.locale))))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                metric(L(summary.bucket == .week ? "Самая загруженная неделя" : summary.bucket == .month ? "Самый загруженный месяц" : "Самый загруженный день"),
                       summary.busiest.map { label($0.start) + " · " + ActivitySummary.duration($0.together) } ?? "—")
                metric(L("Пиковый час"), summary.peakHour.map { String(format: "%02d–%02d", $0, $0 + 1) } ?? "—")
                if providers.count > 1 { metric(L("Вместе, без пересечений"), value(summary.together)) }
            }
        }.padding(20).foregroundStyle(.primary)
            .background(sectionBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.055), lineWidth: 0.6))
    }
    private var title: String {
        if range == .all, let first = summary.firstDay {
            return L("С {0}", first.formatted(.dateTime.day().month().year().locale(L10n.locale)))
        }
        let formatter = DateIntervalFormatter(); formatter.locale = L10n.locale; formatter.dateTemplate = "dMMMy"
        return formatter.string(from: summary.range.start, to: summary.range.end.addingTimeInterval(-1))
    }
    private func value(_ seconds: TimeInterval) -> String {
        seconds > 0 ? (summary.recovered ? "≈ " : "") + ActivitySummary.duration(seconds) : "—"
    }
    private func label(_ date: Date) -> String {
        switch summary.bucket {
        case .month: return date.formatted(.dateTime.month(.wide).year().locale(L10n.locale))
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            let formatter = DateIntervalFormatter(); formatter.locale = L10n.locale; formatter.dateTemplate = "dMMM"
            return formatter.string(from: date, to: end)
        case .day: return date.formatted(.dateTime.day().month().locale(L10n.locale))
        }
    }
    private var accessibilityValue: String {
        providers.map { $0.title + ": " + value($0 == .claude ? summary.claude : summary.codex) }.joined(separator: "; ")
    }
    private var plot: some View {
        let points = summary.points
        let maximum = max(1, points.map { max($0.claude, $0.codex, providers.count == 1 ? $0.together : 0) }.max() ?? 1)
        return GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height - 16
            let step = points.count > 1 ? width / CGFloat(points.count - 1) : width
            let firstKnown = points.firstIndex { $0.known } ?? 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.08), lineWidth: 0.6).frame(height: height)
                if firstKnown > 0 {
                    Rectangle().fill(.primary.opacity(0.05)).frame(width: step * CGFloat(firstKnown), height: height)
                }
                ForEach(providers) { provider in
                    Path { path in
                        var started = false
                        let first = summary.firstDays[provider].map { day in
                            points.lastIndex { $0.start <= day } ?? 0
                        } ?? points.count
                        for (index, point) in points.enumerated() where point.known && index >= first {
                            let seconds = provider == .claude ? point.claude : point.codex
                            let location = CGPoint(x: step * CGFloat(index), y: height - CGFloat(seconds / maximum) * (height - 6) - 3)
                            if started { path.addLine(to: location) } else { path.move(to: location); started = true }
                        }
                    }.stroke(activityAccent(provider, adaptive: true, scheme: scheme), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(axisLabels(width: width), id: \.offset) { item in
                    Text(item.text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                        .position(x: min(max(item.offset, 14), width - 14), y: height + 9)
                }
            }
        }
    }
    private func axisLabels(width: CGFloat) -> [(offset: CGFloat, text: String)] {
        let points = summary.points
        guard points.count > 1 else { return [] }
        let step = width / CGFloat(points.count - 1), stride = max(1, points.count / 5)
        let indices = Array(Swift.stride(from: 0, to: points.count, by: stride))
        // Month names only when each label falls in another month; otherwise day and month.
        let months = indices.map { Calendar.current.dateComponents([.year, .month], from: points[$0].start) }
        let byMonth = summary.bucket != .day && Set(months.map { "\($0.year ?? 0)-\($0.month ?? 0)" }).count == months.count
        return indices.map { index in
            let date = points[index].start
            let text = byMonth ? date.formatted(.dateTime.month(.abbreviated).locale(L10n.locale))
                : date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale))
            return (step * CGFloat(index), text)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

/// Calendar, weekday × hour, projects, waiting and sessions for any range.
struct ActivityStatisticsCards: View {
    let archive: ActivityArchive
    let summary: ActivityArchiveSummary
    let range: StatisticsRange
    let providers: [ProviderID]
    let now: Date
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var sectionBackground: Color { reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035) }
    static let heat = Color(red: 0.54, green: 0.50, blue: 0.94)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if range == .year || range == .all { calendarCard }
            if range != .day { weekdayCard }
            HStack(alignment: .top, spacing: 12) {
                projectsCard
                waitingCard
            }
            sessionsCard
        }.accessibilityIdentifier("statistics-cards")
    }
    private func card<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(sectionBackground, in: RoundedRectangle(cornerRadius: 12))
    }
    private func level(_ seconds: TimeInterval?, maximum: TimeInterval) -> Color {
        guard let seconds else { return .clear }
        guard seconds > 0, maximum > 0 else { return .primary.opacity(0.06) }
        let ratio = seconds / maximum
        return Self.heat.opacity(ratio < 0.25 ? 0.3 : ratio < 0.5 ? 0.5 : ratio < 0.75 ? 0.75 : 1)
    }
    private var calendarCard: some View {
        let cells = ActivityArchiveSummary.calendarCells(archive, providers: providers, now: now)
        let maximum = cells.compactMap(\.seconds).max() ?? 0
        let active = cells.filter { ($0.seconds ?? 0) > 0 }.count
        return card(L("Календарь"), trailing: L("Дней с работой: {0}", String(active))) {
            HStack(alignment: .top, spacing: 2) {
                ForEach(0..<(cells.count / 7), id: \.self) { week in
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { day in
                            let cell = cells[week * 7 + day]
                            RoundedRectangle(cornerRadius: 2).fill(level(cell.seconds, maximum: maximum))
                                .aspectRatio(1, contentMode: .fit)
                                .help(cell.date.formatted(.dateTime.day().month().year().locale(L10n.locale)) + (cell.seconds.map { " · " + ActivitySummary.duration($0) } ?? ""))
                        }
                    }
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel(L("Календарь"))
                .accessibilityValue(L("Дней с работой: {0}", String(active)))
        }
    }
    private var weekdayCard: some View {
        let grid = summary.weekdayHours
        let maximum = grid.flatMap { $0 }.max() ?? 0
        var calendar = Calendar.current; calendar.locale = L10n.locale
        let symbols = calendar.shortWeekdaySymbols
        let names = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let peak = grid.enumerated().flatMap { day, hours in hours.enumerated().map { (day, $0.offset, $0.element) } }.max { $0.2 < $1.2 }
        return card(L("Когда вы работаете"), trailing: L("По дням недели и часам")) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(0..<7, id: \.self) { Text(names[$0]).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 11) }
                }
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 2) {
                            ForEach(0..<24, id: \.self) { hour in
                                RoundedRectangle(cornerRadius: 2).fill(level(grid[day][hour], maximum: maximum)).frame(height: 11)
                            }
                        }
                    }
                    HStack {
                        ForEach(["0", "6", "12", "18", "23"], id: \.self) { Text($0).font(.system(size: 9)).foregroundStyle(.secondary); if $0 != "23" { Spacer() } }
                    }
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel(L("Когда вы работаете"))
                .accessibilityValue(peak.map { $0.2 > 0 ? L("Чаще всего: {0}, {1}", names[$0.0], String(format: "%02d–%02d", $0.1, $0.1 + 1)) : L("Нет данных") } ?? L("Нет данных"))
        }
    }
    private var projectsCard: some View {
        let top = Array(summary.projects.prefix(5))
        let maximum = top.first?.seconds ?? 0
        return card(L("Проекты")) {
            if top.isEmpty {
                Text(L("Нет записей за выбранный период")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(top, id: \.name) { project in
                    HStack(spacing: 8) {
                        Text(project.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(width: 88, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(.primary.opacity(0.08)).overlay(alignment: .leading) {
                                Capsule().fill(Self.heat).frame(width: geometry.size.width * CGFloat(maximum > 0 ? project.seconds / maximum : 0))
                            }
                        }.frame(height: 6)
                        Text(ActivitySummary.duration(project.seconds)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.8).frame(width: 88, alignment: .trailing)
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
    private var waitingCard: some View {
        card(L("Агенты ждали вас")) {
            if summary.waiting <= 0 {
                Text(L("Время ожидания ответа или разрешения считается с этой версии, пока открыт Lunavect."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ActivitySummary.duration(summary.waiting)).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                if summary.together > 0 {
                    Text(L("{0} от времени работы", PercentText.format(Int((summary.waiting / summary.together * 100).rounded()))))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                row(L("Ответы"), ActivitySummary.duration(summary.waitingInput))
                row(L("Разрешения"), ActivitySummary.duration(summary.waitingPermission))
                if let typical = summary.typicalWait { row(L("Обычное ожидание"), ActivitySummary.duration(typical)) }
            }
        }
    }
    private var sessionsCard: some View {
        card(L("Сессии")) {
            HStack(alignment: .top, spacing: 24) {
                metric(L("Сессий с работой"), summary.sessions > 0 ? String(summary.sessions) : "—")
                metric(L("Средняя длина"), summary.averageSession.map(ActivitySummary.duration) ?? "—")
                metric(L("Самая длинная"), summary.longestSession.map { ActivitySummary.duration($0.seconds) + " · " + $0.project } ?? "—")
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
            .accessibilityElement(children: .combine)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
