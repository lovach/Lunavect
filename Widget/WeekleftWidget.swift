import SwiftUI
import WidgetKit
import AppIntents

struct ActivityConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Activity statistics"
    @Parameter(title: "Period", default: .week) var period: ActivityPeriod
    @Parameter(title: "Source", default: .all) var source: ActivitySource
    static var parameterSummary: some ParameterSummary { Summary("\(\.$period) · \(\.$source)") }
}

struct WeekleftEntry: TimelineEntry {
    let date: Date
    let state: SharedState
    var activity = ActivityHistory()
    var activityUnavailable = false
    var period = ActivityPeriod.week
    var source = ActivitySource.all
    var selectedDate: Date? = nil
}
struct WeekleftTimeline: TimelineProvider {
    func placeholder(in context: Context) -> WeekleftEntry { WeekleftEntry(date: .now, state: SharedState()) }
    func entry(at date: Date) -> WeekleftEntry {
        let state = SnapshotStore.load()
        LunavectSetWidgetBackgroundEnabled(state.preferences.transparentBackground)
        do { return WeekleftEntry(date: date, state: state, activity: try ActivityHistory.load()) }
        catch { return WeekleftEntry(date: date, state: state, activityUnavailable: true) }
    }
    func getSnapshot(in context: Context, completion: @escaping (WeekleftEntry) -> Void) {
        completion(entry(at: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekleftEntry>) -> Void) {
        let now = Date(), snapshot = entry(at: .now)
        let entries = WidgetTimelineSchedule.dates(from: now, snapshots: snapshot.state.snapshots).map {
            WeekleftEntry(date: $0, state: snapshot.state,
                          activity: snapshot.activity, activityUnavailable: snapshot.activityUnavailable)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}
struct ActivityTimeline: AppIntentTimelineProvider {
    var kind = "LunavectActivityWidget"
    func placeholder(in context: Context) -> WeekleftEntry { WeekleftEntry(date: .now, state: SharedState()) }
    func snapshot(for configuration: ActivityConfiguration, in context: Context) async -> WeekleftEntry {
        var entry = WeekleftTimeline().entry(at: .now); entry.period = configuration.period
        entry.source = configuration.source.canonical
        entry.selectedDate = ActivityWidgetSelection.read(kind: kind, period: entry.period, source: entry.source)
        return entry
    }
    func timeline(for configuration: ActivityConfiguration, in context: Context) async -> Timeline<WeekleftEntry> {
        let current = await snapshot(for: configuration, in: context)
        let entries = WidgetTimelineSchedule.dates(from: current.date, snapshots: current.state.snapshots).map { date in
            let entry = current
            return WeekleftEntry(date: date, state: entry.state,
                                 activity: entry.activity, activityUnavailable: entry.activityUnavailable, period: entry.period, source: entry.source, selectedDate: entry.selectedDate)
        }
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(900)))
    }
}
struct WeekleftWidgetView: View {
    let entry: WeekleftEntry
    var content: LunavectWidgetContent = .limits
    @Environment(\.widgetFamily) private var family
    private var size: LunavectWidgetSize {
        family == .systemSmall ? .small : family == .systemLarge ? .large : .medium
    }
    private var kind: String { content == .overview ? "LunavectOverviewWidget" : "LunavectActivityWidget" }
    private func selection(_ date: Date?) -> SelectActivityPointIntent {
        SelectActivityPointIntent(date: date, period: entry.period, source: entry.source, kind: kind)
    }
    private func pointControls(_ data: ActivityChartData) -> some View {
        HStack(spacing: 0) {
            ForEach(data.points) { point in
                Button(intent: selection(point.date)) {
                    Color.white.opacity(0.01).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(ActivityChartText.point(point.date, period: data.summary.period))
                    .accessibilityValue(
                        data.series.map {
                            $0.provider.title + ": "
                                + ($0.totals(at: point.date).observed > 0
                                    ? ActivityChartText.value($0.totals(at: point.date), compact: false)
                                    : L("Нет данных"))
                        }.joined(separator: "; ")
                    )
                    .disabled(point.date > data.now)
            }
        }
    }
    private var resetSelection: some View {
        Button(intent: selection(nil)) {
            ActivitySelectionResetLabel()
        }.buttonStyle(.plain)
    }
    private func navigation(_ data: ActivityChartData, date: Date) -> some View {
        HStack(spacing: 2) {
            Button(intent: selection(data.adjacent(to: date, offset: -1))) {
                Image(systemName: "chevron.left").frame(width: 26, height: 26)
            }.disabled(data.adjacent(to: date, offset: -1) == date).accessibilityLabel(L("Предыдущая точка"))
            resetSelection
            Button(intent: selection(data.adjacent(to: date, offset: 1))) {
                Image(systemName: "chevron.right").frame(width: 26, height: 26)
            }.disabled(data.adjacent(to: date, offset: 1) == date).accessibilityLabel(L("Следующая точка"))
        }.font(.system(size: 10, weight: .semibold)).buttonStyle(.plain)
    }
    var body: some View {
        GeometryReader { geometry in
            LunavectWidgetCard(snapshots: entry.state.snapshots, preferences: entry.state.preferences,
                              history: entry.activity, content: content, family: size, now: entry.date,
                              size: geometry.size, activityUnavailable: entry.activityUnavailable, period: entry.period,
                              source: entry.source, selectedDate: entry.selectedDate,
                              pointButtons: { AnyView(pointControls($0)) }, resetButton: AnyView(resetSelection),
                              pointNavigation: { AnyView(navigation($0, date: $1)) }, drawsBackground: false)
        }
        .containerBackground(for: .widget) {
            ActivityWidgetBackground(transparent: entry.state.preferences.transparentBackground,
                                     transparency: entry.state.preferences.transparency)
        }
        .widgetURL(content == .limits ? URL(string: "lunavect://limits") : entry.source.widgetURL(period: entry.period))
    }
}
struct WeekleftWidget: Widget {
    // Preserve the kind of every already installed limits widget.
    let kind = "WeekleftWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekleftTimeline()) { entry in WeekleftWidgetView(entry: entry) }
            .configurationDisplayName(L("Лимиты"))
            .description(L("Недельные лимиты Claude и Codex. Настройка 5 часов — в приложении Lunavect."))
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}
struct LunavectActivityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LunavectActivityWidget", intent: ActivityConfiguration.self, provider: ActivityTimeline()) { entry in
            WeekleftWidgetView(entry: entry, content: .activity)
        }
        .configurationDisplayName(L("Статистика активности"))
        .description(L("Время работы Claude и Codex за день, неделю или месяц."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
struct LunavectOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LunavectOverviewWidget", intent: ActivityConfiguration.self, provider: ActivityTimeline(kind: "LunavectOverviewWidget")) { entry in
            WeekleftWidgetView(entry: entry, content: .overview)
        }
        .configurationDisplayName(L("Всё вместе"))
        .description(L("Недельные лимиты и статистика активности в одном большом виджете."))
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
@main struct LunavectWidgets: WidgetBundle {
    init() { LunavectSetWidgetBackgroundEnabled(SnapshotStore.load().preferences.transparentBackground) }
    var body: some Widget {
        WeekleftWidget()
        LunavectActivityWidget()
        LunavectOverviewWidget()
    }
}
