import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ActivityStatisticsView: View {
    @ObservedObject var store: AppStore
    @AppStorage("statisticsPeriod") private var period = ActivityPeriod.week
    @AppStorage("statisticsSource") private var source = ActivitySource.all
    @State private var detailDate: Date?
    private var providers: [ProviderID] { source.canonical.providers(from: store.providers) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Picker(L("Период"), selection: $period) {
                    ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300).accessibilityIdentifier("statistics-period")
                Spacer(minLength: 0)
                if store.providers.count > 1 {
                    Picker(L("Источник"), selection: Binding(get: { source.canonical }, set: { source = $0 })) {
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
                Text(L(store.providers.isEmpty ? "Подключите Claude или Codex в настройках подключений." : "Источник отключён"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ActivityDetailChart(data: ActivityChartData(history: store.activityHistory, now: context.date, period: period, providers: providers),
                                        unavailable: store.activityUnavailable, onSelection: { detailDate = $0 })
                        .id(period.rawValue + providers.map(\.rawValue).joined())
                    ActivityBreakdownView(history: store.activityHistory, details: store.activityDetails,
                                          providers: providers, period: period, selectedDate: detailDate, now: context.date)
                    if let issue = store.activityDetailsIssue { Text(L(issue)).font(.system(size: 12)).foregroundStyle(.orange) }
                }
            }
        }
        .onChange(of: period) { _, _ in detailDate = nil }
        .onChange(of: source) { _, _ in detailDate = nil }
    }
}

struct ActivityDetailChart: View {
    let data: ActivityChartData
    var unavailable = false
    var chartHeight: CGFloat = 220
    var onSelection: (Date?) -> Void = { _ in }
    @State private var hoveredDate: Date?
    @State private var pinnedDate: Date?
    @FocusState private var chartFocused: Bool
    private var selected: Date? { data.validSelection(pinnedDate ?? hoveredDate) }
    private var currentHour: Date? {
        guard data.summary.period == .day else { return nil }
        return data.points.first { ActivityChartText.isCurrent($0.date, period: .day, now: data.now) }?.date
    }
    private var readoutDate: Date? { selected ?? currentHour }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(ActivityChartText.range(data.summary)).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(L(data.summary.period == .day ? "По часам" : "По дням")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ActivitySeriesLegend(data: data, unavailable: unavailable, foreground: .primary).frame(height: 32)
            if unavailable || !data.hasData {
                VStack(alignment: .leading, spacing: 10) {
                    InterfaceIcon(.activity, size: 28)
                    Text(L(unavailable ? "Статистика недоступна" : "Пока нет данных")).font(.system(size: 15, weight: .medium))
                    Text(L("Откройте историю ниже: там видно, какие записи удалось восстановить."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .leading)
            } else {
                chart
                Text(L("Тренд по имеющимся записям")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(L("Линия соединяет известные точки. В промежутках без записей значения неизвестны."))
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
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.055), lineWidth: 0.6))
            .onChange(of: pinnedDate) { _, date in onSelection(date) }
    }
    private var chart: some View {
                ActivityTrendPlot(data: data, selectedDate: selected, foreground: .primary, adaptiveColors: true, cleanContour: true)
                    .frame(height: chartHeight)
                    .overlay(alignment: .top) { interactionOverlay }
                    .focusable().focused($chartFocused)
                    .onMoveCommand { direction in
                        if direction == .left { move(-1) }
                        if direction == .right { move(1) }
                    }
                    .onExitCommand { clearSelection() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Статистика активности"))
                    .accessibilityValue(selectionDescription)
                    .accessibilityHint(L("Выберите час или день стрелками влево и вправо."))
                    .accessibilityAdjustableAction { direction in move(direction == .increment ? 1 : -1) }
                    .accessibilityIdentifier("statistics-chart")
    }
    private var interactionOverlay: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in handleHover(phase, width: geometry.size.width) }
                .gesture(SpatialTapGesture().onEnded { value in
                    pinnedDate = date(at: value.location.x, width: geometry.size.width)
                    chartFocused = true
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
            if readoutDate == nil {
                Text(L("Выберите точку на графике")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
            HStack {
                Text(readoutDate.map { Self.pointLabel($0, period: data.summary.period) } ?? L("За период"))
                    .font(.system(size: 12, weight: .medium))
                if let readoutDate, ActivityChartText.isCurrent(readoutDate, period: data.summary.period, now: data.now) {
                    Text(L("Ещё идёт")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { clearSelection() } label: { Image(systemName: "xmark").frame(width: 24, height: 20) }
                    .buttonStyle(.plain).accessibilityLabel(L("Весь период"))
                    .opacity(selected == nil ? 0 : 1).disabled(selected == nil)
            }.frame(height: 20)
            HStack(spacing: 20) {
                ForEach(data.series) { series in
                    HStack(spacing: 6) {
                        Circle().fill(activityAccent(series.provider)).frame(width: 5, height: 5)
                        Text(series.provider.title)
                        Text(unavailable ? "—" : ActivityChartText.value(series.totals(at: readoutDate), compact: false)).monospacedDigit()
                    }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: 18)
            }
        }.padding(10).frame(height: 64).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine).accessibilityIdentifier("statistics-selection")
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
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
    private func move(_ offset: Int) { pinnedDate = data.adjacent(to: selected, offset: offset); hoveredDate = nil }
    private func clearSelection() { pinnedDate = nil; hoveredDate = nil }
}
