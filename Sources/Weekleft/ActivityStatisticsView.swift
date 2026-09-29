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
                    ActivityStatisticsCards(archive: store.activityArchive, summary: archived, range: range, providers: providers, now: context.date,
                                            catchingUp: store.tokenService.catchingUp)
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
    @State var hovered: Int?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    private var sectionBackground: Color { reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035) }
    /// Starts at the first record: a year of unknown weeks would squeeze the known ones.
    private var points: [ActivityArchiveSummary.Point] { Array(summary.points.drop { !$0.known }) }
    private var hoveredPoint: ActivityArchiveSummary.Point? {
        hovered.flatMap { points.indices.contains($0) ? points[$0] : nil }
    }
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
                readout
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
        let start = max(summary.range.start, summary.firstDay ?? summary.range.start)
        return formatter.string(from: start, to: summary.range.end.addingTimeInterval(-1))
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
    /// The index where a provider's line starts: earlier points are unknown for it.
    private func lineStart(_ provider: ProviderID, in points: [ActivityArchiveSummary.Point]) -> Int {
        summary.firstDays[provider].map { day in points.lastIndex { $0.start <= day } ?? 0 } ?? points.count
    }
    private func seconds(_ point: ActivityArchiveSummary.Point, _ provider: ProviderID) -> TimeInterval {
        provider == .claude ? point.claude : point.codex
    }
    private var readout: some View {
        let point = hoveredPoint
        return VStack(alignment: .leading, spacing: 6) {
            Text(point.map { label($0.start) } ?? L("За период")).font(.system(size: 12, weight: .medium))
            HStack(spacing: 20) {
                ForEach(providers) { provider in
                    HStack(spacing: 6) {
                        Circle().fill(activityAccent(provider, adaptive: true, scheme: scheme)).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(provider.title)
                        Text(readoutValue(provider, point)).monospacedDigit()
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
                if providers.count > 1 {
                    HStack(spacing: 6) {
                        Text(L("Вместе")).foregroundStyle(.secondary)
                        Text(point.map { $0.known ? ActivitySummary.duration($0.together) : "—" } ?? value(summary.together)).monospacedDigit()
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("statistics-long-selection")
    }
    private func readoutValue(_ provider: ProviderID, _ point: ActivityArchiveSummary.Point?) -> String {
        guard let point, let index = hovered else { return value(provider == .claude ? summary.claude : summary.codex) }
        guard point.known, index >= lineStart(provider, in: points) else { return L("Записей нет") }
        return (point.recovered ? "≈ " : "") + ActivitySummary.duration(seconds(point, provider))
    }
    private var plot: some View {
        let points = points
        let maximum = max(1, points.map { max($0.claude, $0.codex, providers.count == 1 ? $0.together : 0) }.max() ?? 1)
        let starts = Dictionary(uniqueKeysWithValues: providers.map { ($0, lineStart($0, in: points)) })
        return GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height - 16
            let step = points.count > 1 ? width / CGFloat(points.count - 1) : width
            let y = { (seconds: TimeInterval) in height - CGFloat(seconds / maximum) * (height - 6) - 3 }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.08), lineWidth: 0.6).frame(height: height)
                ForEach(providers) { provider in
                    Path { path in
                        var started = false
                        let start = starts[provider] ?? points.count
                        for (index, point) in points.enumerated() where point.known && index >= start {
                            let location = CGPoint(x: step * CGFloat(index), y: y(seconds(point, provider)))
                            if started { path.addLine(to: location) } else { path.move(to: location); started = true }
                        }
                    }.stroke(activityAccent(provider, adaptive: true, scheme: scheme), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let hovered, points.indices.contains(hovered) {
                    let x = step * CGFloat(hovered)
                    Rectangle().fill(.primary.opacity(0.25)).frame(width: 1, height: height).offset(x: x - 0.5)
                    ForEach(providers) { provider in
                        if points[hovered].known && hovered >= starts[provider] ?? points.count {
                            Circle().fill(activityAccent(provider, adaptive: true, scheme: scheme))
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                .frame(width: 8, height: 8).position(x: x, y: y(seconds(points[hovered], provider)))
                        }
                    }
                }
                ForEach(axisLabels(width: width), id: \.offset) { item in
                    Text(item.text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                        .position(x: min(max(item.offset, 14), width - 14), y: height + 9)
                }
                Color.clear.contentShape(Rectangle()).frame(width: width, height: height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let index = points.isEmpty ? nil : min(points.count - 1, max(0, Int((location.x / step).rounded())))
                            if index != hovered { hovered = index }
                        case .ended: if hovered != nil { hovered = nil }
                        }
                    }
            }
        }
    }
    private func axisLabels(width: CGFloat) -> [(offset: CGFloat, text: String)] {
        let points = points
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

/// A statistics card: title, optional note on the right, content.
struct StatisticsCard<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
            }
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Calendar, time of day, projects, waiting and sessions for any range.
struct ActivityStatisticsCards: View {
    let archive: ActivityArchive
    let summary: ActivityArchiveSummary
    let range: StatisticsRange
    let providers: [ProviderID]
    let now: Date
    /// The first pass over the logs is still running: no tokens yet is not zero tokens.
    var catchingUp = false
    static let heat = Color(red: 0.54, green: 0.50, blue: 0.94)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if range == .year || range == .all {
                ActivityCalendarCard(archive: archive, firstDay: summary.firstDay, providers: providers, now: now)
            }
            if range != .day { timeOfDayCard }
            HStack(alignment: .top, spacing: 12) {
                projectsCard
                waitingCard
            }
            tokensCard
            sessionsCard
        }.accessibilityIdentifier("statistics-cards")
    }
    private func card<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        StatisticsCard(title: title, trailing: trailing, content: content)
    }
    /// Where the tokens went: projects and models by weight, which tracks the limit they used.
    private var tokensCard: some View {
        let total = summary.tokens.total
        let share = { (weight: Double) in PercentText.format(Int((weight / max(summary.tokenWeight, 1) * 100).rounded())) }
        return card(L("На что ушли токены"), trailing: total > 0 ? L("{0} токенов", TokenText.compact(total)) : nil) {
            if total <= 0 {
                Text(L(catchingUp ? "Считаем токены по журналам Claude и Codex…" : "Нет записей за выбранный период"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    metric(L("Из кэша"), PercentText.format(Int((Double(summary.tokens.cacheRead) / Double(total) * 100).rounded())))
                    metric(L("Субагенты"), share(summary.tokenSubagentWeight))
                    metric(L("Ответы"), TokenText.compact(summary.tokens.output + summary.tokens.reasoning))
                }
                HStack(alignment: .top, spacing: 24) {
                    tokenGroups(L("По проектам"), Array(summary.tokenProjects.prefix(5)), title: { $0 }, share: share)
                    tokenGroups(L("По моделям"), Array(summary.tokenModels.prefix(5)), title: TokenLedger.modelTitle, share: share)
                }
                Text(L("Доли учитывают цену токенов: чтение из кэша в 10 раз дешевле обычного ввода, ответ в 5–8 раз дороже. Примерно так расходуется лимит."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Мониторинг агентов…")) { NSApp.sendAction(Selector(("showMonitor")), to: nil, from: nil) }
                    .accessibilityIdentifier("statistics-open-monitor")
            }
        }
    }
    private func tokenGroups(_ heading: String, _ groups: [ActivityArchiveSummary.TokenGroup], title: @escaping (String) -> String,
                             share: @escaping (Double) -> String) -> some View {
        let maximum = groups.first?.weight ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(groups, id: \.name) { group in
                HStack(spacing: 8) {
                    Text(title(group.name)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(width: 96, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(.primary.opacity(0.08)).overlay(alignment: .leading) {
                            Capsule().fill(Self.heat).frame(width: geometry.size.width * CGFloat(maximum > 0 ? group.weight / maximum : 0))
                        }
                    }.frame(height: 6)
                    Text(share(group.weight)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                }.help(title(group.name) + " · " + L("{0} токенов", TokenText.compact(group.counts.total)))
                    .accessibilityElement(children: .combine)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    /// Night, morning, afternoon and evening as shares of the time, then the weekdays.
    private var timeOfDayCard: some View {
        let grid = summary.weekdayHours
        let hours = (0..<24).map { hour in grid.reduce(0) { $0 + $1[hour] } }
        let total = hours.reduce(0, +)
        let parts = [(L("Ночью"), 0), (L("Утром"), 6), (L("Днём"), 12), (L("Вечером"), 18)]
        let values = parts.map { part in hours[part.1..<(part.1 + 6)].reduce(0, +) }
        let top = values.indices.max { values[$0] < values[$1] } ?? 0
        let days = grid.map { $0.reduce(0, +) }
        let busiestDay = days.indices.max { days[$0] < days[$1] } ?? 0
        var calendar = Calendar.current; calendar.locale = L10n.locale
        let symbols = calendar.shortWeekdaySymbols
        let names = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let share = { (value: TimeInterval) in PercentText.format(Int((value / max(total, 1) * 100).rounded())) }
        return card(L("Когда вы работаете"), trailing: total > 0 ? L("Чаще всего: {0}, {1}", parts[top].0.lowercased(with: L10n.locale), names[busiestDay]) : nil) {
            if total <= 0 {
                Text(L("Нет записей за выбранный период")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { index in
                            Rectangle().fill(Self.heat.opacity(0.3 + 0.7 * values[index] / max(values[top], 1)))
                                .frame(width: max(2, (geometry.size.width - 6) * values[index] / total))
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 5))
                }.frame(height: 14).accessibilityHidden(true)
                HStack(alignment: .top) {
                    ForEach(0..<4, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parts[index].0 + " · " + String(format: "%02d–%02d", parts[index].1, parts[index].1 + 6))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            Text(share(values[index])).font(.system(size: 16, weight: index == top ? .semibold : .medium)).monospacedDigit()
                            Text(ActivitySummary.duration(values[index])).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                    }
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { day in
                        VStack(spacing: 4) {
                            GeometryReader { geometry in
                                Capsule().fill(.primary.opacity(0.08)).overlay(alignment: .leading) {
                                    Capsule().fill(Self.heat.opacity(day == busiestDay ? 1 : 0.55))
                                        .frame(width: geometry.size.width * days[day] / max(days[busiestDay], 1))
                                }
                            }.frame(height: 6)
                            Text(names[day]).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(days[day] > 0 ? ActivitySummary.duration(days[day]) : "—").font(.system(size: 10)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
                    }
                }
            }
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

/// Days with work since the first record. Hover state lives here, so moving over
/// the grid redraws only this card; the cells are one drawing, not a view each.
struct ActivityCalendarCard: View {
    let archive: ActivityArchive
    let firstDay: Date?
    let providers: [ProviderID]
    let now: Date
    @State var hoveredDay: Int?
    /// The grid keeps the cell size of a full year so the card does not jump as history grows.
    @State var width: CGFloat = 640
    private static let gap: CGFloat = 2, weeks = 53, top: CGFloat = 16
    private var cell: CGFloat { (width - Self.gap * CGFloat(Self.weeks - 1)) / CGFloat(Self.weeks) }
    var body: some View {
        let first = firstDay.map { Calendar.current.startOfDay(for: $0) }
        let cells = ActivityArchiveSummary.calendarCells(archive, providers: providers, now: now, since: first)
        let columns = cells.count / 7
        let maximum = cells.compactMap(\.seconds).max() ?? 0
        let worked = cells.compactMap(\.seconds).filter { $0 > 0 }
        let longest = cells.filter { ($0.seconds ?? 0) > 0 }.max { ($0.seconds ?? 0) < ($1.seconds ?? 0) }
        let pitch = cell + Self.gap, gridWidth = pitch * CGFloat(columns) - Self.gap
        return StatisticsCard(title: L("Календарь"), trailing: trailing(cells, first: first, worked: worked.count)) {
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels(cells), id: \.column) { item in
                    Text(item.text).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize().offset(x: pitch * CGFloat(item.column))
                }
                Canvas { context, _ in
                    for (index, item) in cells.enumerated() {
                        let rect = CGRect(x: pitch * CGFloat(index / 7), y: Self.top + pitch * CGFloat(index % 7), width: cell, height: cell)
                        let shape = Path(roundedRect: rect, cornerRadius: 2)
                        guard let seconds = item.seconds else { continue }
                        if let first, item.date < first {
                            context.stroke(shape, with: .color(.primary.opacity(0.08)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 1.5]))
                        } else {
                            context.fill(shape, with: .color(level(seconds, maximum: maximum)))
                        }
                    }
                }.frame(width: max(0, gridWidth), height: Self.top + pitch * 7)
                if let hoveredDay {
                    RoundedRectangle(cornerRadius: 2).stroke(.primary.opacity(0.8), lineWidth: 1).frame(width: cell, height: cell)
                        .offset(x: pitch * CGFloat(hoveredDay / 7), y: Self.top + pitch * CGFloat(hoveredDay % 7))
                }
                if width - gridWidth > 190, !worked.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        metric(L("Самый долгий день"), longest.map { dayText($0.date) + " · " + ActivitySummary.duration($0.seconds ?? 0) } ?? "—")
                        metric(L("В среднем за день с работой"), ActivitySummary.duration(worked.reduce(0, +) / Double(worked.count)))
                    }.frame(width: min(260, width - gridWidth - 28), alignment: .leading).offset(x: gridWidth + 28, y: Self.top)
                }
                Color.clear.contentShape(Rectangle()).frame(width: max(0, gridWidth), height: Self.top + pitch * 7)
                    .onContinuousHover { phase in
                        var index: Int?
                        if case .active(let location) = phase, location.y >= Self.top {
                            let week = Int(location.x / pitch), day = Int((location.y - Self.top) / pitch)
                            let candidate = week * 7 + day
                            if week < columns, day < 7, cells.indices.contains(candidate), cells[candidate].seconds != nil { index = candidate }
                        }
                        if index != hoveredDay { hoveredDay = index }
                    }
            }.frame(maxWidth: .infinity, minHeight: Self.top + pitch * 7, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs($0 - width) > 0.5 { width = $0 } }
                .accessibilityElement(children: .ignore).accessibilityLabel(L("Календарь"))
                .accessibilityValue(L("Дней с работой: {0}", String(worked.count)))
        }
    }
    private func trailing(_ cells: [(date: Date, seconds: TimeInterval?)], first: Date?, worked: Int) -> String {
        guard let hoveredDay, cells.indices.contains(hoveredDay), let seconds = cells[hoveredDay].seconds else { return L("Дней с работой: {0}", String(worked)) }
        if let first, cells[hoveredDay].date < first { return dayText(cells[hoveredDay].date) + " · " + L("Записей нет") }
        return dayText(cells[hoveredDay].date) + " · " + (seconds > 0 ? ActivitySummary.duration(seconds) : L("Без работы"))
    }
    private func level(_ seconds: TimeInterval, maximum: TimeInterval) -> Color {
        guard seconds > 0, maximum > 0 else { return .primary.opacity(0.06) }
        let ratio = seconds / maximum
        return ActivityStatisticsCards.heat.opacity(ratio < 0.25 ? 0.3 : ratio < 0.5 ? 0.5 : ratio < 0.75 ? 0.75 : 1)
    }
    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month().year().locale(L10n.locale))
    }
    private func monthLabels(_ cells: [(date: Date, seconds: TimeInterval?)]) -> [(column: Int, text: String)] {
        var result: [(column: Int, text: String)] = [], last = -1
        for week in 0..<(cells.count / 7) {
            let month = Calendar.current.component(.month, from: cells[week * 7].date)
            guard month != last else { continue }
            // Skip a label squeezed against the previous one.
            if let previous = result.last, week - previous.column < 3 { result.removeLast() }
            result.append((week, cells[week * 7].date.formatted(.dateTime.month(.abbreviated).locale(L10n.locale))))
            last = month
        }
        return result
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

/// Token counts in the interface: "1.2B" in English, "1,2 млрд" in Russian.
enum TokenText {
    static func compact(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)).locale(L10n.locale))
    }
}
