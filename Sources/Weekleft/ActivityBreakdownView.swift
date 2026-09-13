import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct ActivityBreakdownData {
    let history: ActivityHistory
    let details: ActivityDetails
    let providers: [ProviderID]
    let period: ActivityPeriod
    let selectedDate: Date?
    let now: Date
    var range: DateInterval {
        let calendar = Calendar.current
        if let selectedDate, let interval = calendar.dateInterval(of: period == .day ? .hour : .day, for: selectedDate) {
            return DateInterval(start: interval.start, end: max(interval.start, min(now, interval.end)))
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: today) ?? today
        return DateInterval(start: start, end: now)
    }
    var title: String {
        selectedDate.map { ActivityChartText.point($0, period: period) } ?? L("За выбранный период")
    }
    var records: [ActivityDetailRecord] { details.selected(in: range, providers: providers) }
    var totals: ActivityTotals {
        let mask = providers.reduce(0) { $0 | ($1 == .claude ? 1 : 2) }
        let spans = history.intervals.compactMap { span -> ActivityInterval? in
            guard span.knownProviders & mask != 0 else { return nil }
            var value = span; value.providers &= mask; return value
        }
        return ActivityDetailRecord(provider: .claude, sessionID: "aggregate", intervals: spans).totals(in: range)
    }
    var sessionCountLabel: String {
        L("Сессий с записями: {0}", String(Set(records.map { $0.provider.rawValue + ":" + $0.sessionID }).count))
    }
}

struct ActivityBreakdownSummaryView: View {
    let data: ActivityBreakdownData
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Подробности активности")).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(data.title).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if data.totals.observed > 0 {
                HStack(spacing: 20) {
                    metric(L("Наблюдалось в Lunavect"), ActivitySummary.duration(max(0, data.totals.active - data.totals.recovered)))
                    metric(L("Восстановлено из журналов"), "≈ " + ActivitySummary.duration(data.totals.recovered))
                }
                if data.providers.count > 1 {
                    Text(L("Одновременно Claude и Codex: {0}", ActivitySummary.duration(max(0, data.totals.claude + data.totals.codex - data.totals.active))))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(L("Нет записей за выбранный период")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("activity-breakdown-summary")
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct ActivityBreakdownView: View {
    @Environment(\.colorScheme) private var scheme
    let data: ActivityBreakdownData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State var query = ""
    @State var expanded: Set<String> = []
    private var records: [ActivityDetailRecord] { data.records }
    private var range: DateInterval { data.range }
    var projects: [(path: String, rows: [ActivityDetailRecord])] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = records.filter { record in
            let searchable = [record.displayTitle, record.cwd, record.provider.title, record.sessionID].joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
        return Dictionary(grouping: filtered, by: \.cwd).map { (path: $0.key, rows: $0.value) }.sorted {
            let a = ActivityDetails.totals(for: $0.rows, in: range).active, b = ActivityDetails.totals(for: $1.rows, in: range).active
            return a == b ? $0.path < $1.path : a > b
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Проекты и сессии")).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(
                        (data.selectedDate == nil
                            ? ActivityChartText.range(
                                data.history.summary(now: data.now, period: data.period, providers: data.providers))
                            : data.title) + " · " + data.providers.map(\.title).joined(separator: " + ")
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(data.sessionCountLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("activity-breakdown-close")
            }.padding(20)
            if !records.isEmpty {
                TextField(L("Найти сессию или проект"), text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("activity-breakdown-search")
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if records.isEmpty {
                        Text(L("Для этого периода нет разбивки по сессиям. Общий итог статистики включает все доступные записи."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if projects.isEmpty {
                        Text(L("Ничего не найдено")).foregroundStyle(.secondary)
                    }
                    ForEach(projects, id: \.path) { project in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(project.path) }, set: { value in
                            if value { expanded.insert(project.path) } else { expanded.remove(project.path) }
                        })) {
                            LazyVStack(spacing: 10) {
                                ForEach(project.rows) { record in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle().fill(activityAccent(record.provider, adaptive: true, scheme: scheme)).frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(record.displayTitle).lineLimit(2).help(record.displayTitle)
                                            Text(record.provider.title).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Text(ActivityChartText.value(record.totals(in: range))).monospacedDigit()
                                            .fixedSize(horizontal: true, vertical: false)
                                    }.font(.system(size: 12)).padding(.leading, 5)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel(record.displayTitle + ". " + record.provider.title)
                                        .accessibilityValue(ActivityChartText.value(record.totals(in: range), compact: false))
                                }
                            }.padding(.top, 12)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.path.isEmpty ? L("Без проекта") : URL(fileURLWithPath: project.path).lastPathComponent)
                                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        .help(project.path.isEmpty ? L("Без проекта") : project.path)
                                    if !project.path.isEmpty {
                                        Text((project.path as NSString).abbreviatingWithTildeInPath)
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                            .help(project.path)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(ActivityChartText.value(ActivityDetails.totals(for: project.rows, in: range)))
                                    .font(.system(size: 13, weight: .medium)).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                            }.accessibilityElement(children: .combine)
                        }.padding(12).background(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text(L("Внутри проекта параллельные сессии считаются один раз. Время разных проектов может пересекаться. ≈ — восстановленная оценка, которая может включать ожидание."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if ActivityDetails.totals(for: records, in: range).active + 1 < data.totals.active {
                        Text(L("Часть общего времени не связана с конкретными сессиями: в старых записях не хватает метаданных."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }.accessibilityIdentifier("activity-breakdown-list")
        }.frame(width: 640, height: 540)
            .background(Color(nsColor: .windowBackgroundColor))
            .disclosureGroupStyle(FullRowDisclosureStyle())
            .accessibilityIdentifier("activity-breakdown")
    }
}
