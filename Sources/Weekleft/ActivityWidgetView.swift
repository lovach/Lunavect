import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum LunavectWidgetContent: String, CaseIterable, Identifiable {
    case limits, activity, overview
    var id: String { rawValue }
    var title: String {
        switch self {
        case .limits: return L("Лимиты")
        case .activity: return L("Статистика активности")
        case .overview: return L("Всё вместе")
        }
    }
    var sizes: [LunavectWidgetSize] { self == .overview ? [.large] : self == .limits ? [.small, .medium] : [.small, .medium, .large] }
}

enum LunavectWidgetSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return L("Маленький")
        case .medium: return L("Средний")
        case .large: return L("Большой")
        }
    }
    var dimensions: CGSize {
        switch self {
        case .small: return CGSize(width: 164, height: 164)
        case .medium: return CGSize(width: 344, height: 164)
        case .large: return CGSize(width: 344, height: 344)
        }
    }
}

struct LunavectWidgetCard: View {
    let snapshots: [UsageSnapshot]
    let preferences: WidgetPreferences
    let history: ActivityHistory
    let content: LunavectWidgetContent
    let family: LunavectWidgetSize
    var now = Date()
    var size: CGSize? = nil
    var activityUnavailable = false
    var period = ActivityPeriod.week
    var source = ActivitySource.all
    var selectedDate: Date? = nil
    var pointButtons: ((ActivityChartData) -> AnyView)? = nil
    var resetButton: AnyView? = nil
    var pointNavigation: ((ActivityChartData, Date) -> AnyView)? = nil
    private var dimensions: CGSize { size ?? family.dimensions }
    private var providers: [ProviderID] { source.providers(from: preferences.providers) }
    private func activity(_ family: LunavectWidgetSize, overview: Bool = false) -> some View {
        ActivityCard(data: ActivityChartData(history: history, now: now, period: period, providers: providers),
                     family: family, unavailable: activityUnavailable, source: source,
                     selectedDate: selectedDate, pointButtons: pointButtons, resetButton: resetButton, pointNavigation: pointNavigation)
    }

    var body: some View {
        Group {
            if preferences.providers.isEmpty {
                WidgetConnectionPrompt()
            } else if content == .limits {
                if family == .small {
                    SmallLimitsCard(snapshots: snapshots, preferences: preferences, now: now)
                } else {
                    WeekleftCard(snapshots: snapshots, preferences: preferences, now: now, drawsOutline: false, size: dimensions)
                }
            } else if content == .overview {
                VStack(spacing: 0) {
                    OverviewLimitsCard(snapshots: snapshots, preferences: preferences, now: now)
                        .frame(height: preferences.providers.count == 1 ? 92 : 144)
                    Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.horizontal, 18)
                    activity(.medium, overview: true)
                        .frame(maxHeight: .infinity)
                }
            } else {
                activity(family)
            }
        }.frame(width: dimensions.width, height: dimensions.height)
            .background { ActivityWidgetBackground(transparent: preferences.transparentBackground, transparency: preferences.transparency) }
            .foregroundStyle(.white)
    }
}

private struct SmallLimitsCard: View {
    let snapshots: [UsageSnapshot]
    let preferences: WidgetPreferences
    let now: Date
    private var visibleSnapshots: [UsageSnapshot] { snapshots.filter { preferences.providers.contains($0.provider) } }
    private var stale: Bool { visibleSnapshots.contains { $0.issue != nil || ($0.fetchedAt != nil && $0.isStale(now: now)) } }
    private var lastDate: Date? { visibleSnapshots.compactMap(\.fetchedAt).min() }
    var body: some View {
        if preferences.providers.count == 1, let id = preferences.providers.first {
            SingleProviderLimitsCard(snapshot: snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id), preferences: preferences, now: now, compact: true)
        } else {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(L("Недельный остаток")).font(.system(size: 10))
                Spacer(minLength: 0)
                if stale { Image(systemName: "exclamationmark.circle").font(.system(size: 10)) }
            }.foregroundStyle(.white.opacity(0.8))
            ForEach(preferences.providers) { id in
                let snapshot = snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id)
                let weekly = snapshot.weekly.flatMap { $0.isExpired(at: now) ? nil : $0 }
                let five = snapshot.fiveHour.flatMap { $0.isExpired(at: now) ? nil : $0 }
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(id.title).font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 2)
                        Text(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                            .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            if let weekly { Capsule().fill(activityAccent(id)).frame(width: geometry.size.width * weekly.remaining / 100) }
                        }
                    }.frame(height: 4)
                        .accessibilityLabel(L("Осталось")).accessibilityValue(weekly.map { L("{0} процентов", String(Int($0.remaining.rounded()))) } ?? L("Нет данных"))
                    if preferences.showFiveHour {
                        HStack {
                            Text(L("5 ч")); Spacer()
                            Text(five.map { "\(Int($0.remaining.rounded()))%" } ?? "—").monospacedDigit()
                        }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            Spacer(minLength: 0)
            Text(lastDate.map { L("Данные: {0}", $0.formatted(.dateTime.day().month(.twoDigits).hour().minute().locale(L10n.locale))) } ?? L("Подключите в настройках"))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(14)
        }
    }
}

func activityAccent(_ id: ProviderID) -> Color {
    id == .claude ? Color(red: 1, green: 0.70, blue: 0.47) : Color(red: 0.61, green: 0.84, blue: 1)
}

struct ActivitySelectionResetLabel: View {
    var body: some View {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
            .accessibilityLabel(L("Весь период"))
    }
}

struct ActivityWidgetBackground: View {
    var transparent = true
    var transparency = 0.5
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        LinearGradient(colors: [Color(white: 0.11), Color(white: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(transparent && !reduceTransparency && contrast != .increased ? 0.65 + (1 - min(0.75, max(0.2, transparency))) * 0.32 : 0.98)
    }
}

struct OverviewLimitsCard: View {
    let snapshots: [UsageSnapshot]
    let preferences: WidgetPreferences
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Недельный остаток")).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            ForEach(preferences.providers) { id in
                let snapshot = snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id)
                let weekly = snapshot.weekly.flatMap { $0.isExpired(at: now) ? nil : $0 }
                let five = snapshot.fiveHour.flatMap { $0.isExpired(at: now) ? nil : $0 }
                VStack(spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(id.title).font(.system(size: 13, weight: .semibold))
                        if let date = preferences.subscriptionDates[id.rawValue], !date.isEmpty {
                            Text(L("до ") + subscriptionDate(date))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer(minLength: 4)
                        Text(weekly.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                            .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    }.frame(height: 23)
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.15))
                        if let weekly { Capsule().fill(activityAccent(id)).frame(width: proxy.size.width * weekly.remaining / 100) }
                    }.frame(height: 4)
                    HStack(spacing: 8) {
                        if snapshot.isStale(now: now) {
                            Text(L("Данные устарели"))
                        } else {
                            Text(weekly.map { L("Сброс через {0}", $0.countdown(now: now)) } ?? L("Нет данных"))
                        }
                        Spacer(minLength: 0)
                        if preferences.showFiveHour { Text(L("5 ч") + " · " + (five.map { "\(Int($0.remaining.rounded()))%" } ?? "—")) }
                    }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func subscriptionDate(_ value: String) -> String {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return "—" }
        return date.formatted(.dateTime.day().month(.twoDigits).locale(L10n.locale))
    }
}

struct ActivityCard: View {
    let data: ActivityChartData
    let family: LunavectWidgetSize
    var unavailable: Bool
    var source = ActivitySource.all
    var selectedDate: Date? = nil
    var pointButtons: ((ActivityChartData) -> AnyView)? = nil
    var resetButton: AnyView? = nil
    var pointNavigation: ((ActivityChartData, Date) -> AnyView)? = nil
    private var small: Bool { family == .small }
    private var selected: Date? { small ? nil : data.validSelection(selectedDate) }
    private var title: String {
        if data.series.count == 1 { return data.series[0].provider.title }
        return L(data.summary.period == .day ? "Активность по часам" : "Активность по дням")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let selected {
                    Text(ActivityChartText.point(selected, period: data.summary.period, compact: true))
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if ActivityChartText.isCurrent(selected, period: data.summary.period, now: data.now) {
                        Text(L("Ещё идёт")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let pointNavigation { pointNavigation(data, selected) }
                    else if let resetButton { resetButton }
                } else {
                    if !small { Text(title).font(.system(size: 12, weight: .medium)) }
                    if !small { Spacer(minLength: 0) }
                    Text(ActivityChartText.range(data.summary, compact: small))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    if small { Spacer(minLength: 0) }
                    if data.stale || data.limited {
                        Image(systemName: data.stale ? "clock.badge.exclamationmark" : "info.circle")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                            .accessibilityLabel(L(data.stale ? "Данные устарели" : "По доступным записям"))
                    }
                }
            }.frame(height: small ? 16 : 26)
            if unavailable || !data.hasData {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(unavailable ? "Статистика недоступна" : data.series.isEmpty ? "Источник отключён" : "Пока нет данных"))
                        .font(.system(size: 13, weight: .medium))
                    if !small { Text(L("История и подробности — в приложении")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ActivityTrendPlot(data: data, selectedDate: selected, compact: small, showsScale: !small)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        if !small, let pointButtons {
                            pointButtons(data).padding(.bottom, ActivityPlotGeometry.labelsHeight).padding(.trailing, ActivityPlotGeometry.scaleWidth)
                        }
                    }
            }
            ActivitySeriesLegend(data: data, selectedDate: selected, small: small, unavailable: unavailable, inline: true)
                .frame(height: small ? 34 : 18)
        }.padding(.horizontal, small ? 14 : 16).padding(.vertical, small ? 14 : family == .medium ? 10 : 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Статистика активности") + ", " + ActivityChartText.range(data.summary))
    }
}

struct ActivitySeriesLegend: View {
    let data: ActivityChartData
    var selectedDate: Date? = nil
    var small = false
    var unavailable = false
    var inline = false
    var foreground = Color.white
    var body: some View {
        if small {
            VStack(spacing: 4) {
                ForEach(data.series) { series in
                    HStack(spacing: 5) {
                        swatch(series.provider)
                        Text(series.provider.title).font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 2)
                        Text(unavailable ? "—" : ActivityChartText.value(series.totals(at: selectedDate)))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
                    }.accessibilityElement(children: .combine)
                }
            }
        } else if inline {
            HStack(spacing: 10) {
                ForEach(data.series) { series in
                    HStack(spacing: 4) {
                        swatch(series.provider)
                        Text(series.provider.title).font(.system(size: 11, weight: .medium))
                        Text(unavailable ? "—" : ActivityChartText.value(series.totals(at: selectedDate)))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
            }
        } else {
            HStack(spacing: 12) {
                ForEach(data.series) { series in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            swatch(series.provider)
                            Text(series.provider.title).font(.system(size: 11, weight: .medium)).foregroundStyle(foreground.opacity(0.8))
                        }
                        Text(unavailable ? "—" : ActivityChartText.value(series.totals(at: selectedDate)))
                            .font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
            }
        }
    }
    private func swatch(_ provider: ProviderID) -> some View {
        Capsule().fill(activityAccent(provider)).frame(width: small || inline ? 10 : 14, height: 3).accessibilityHidden(true)
    }
}

enum ActivityPlotGeometry {
    static let scaleWidth: CGFloat = 42
    static let labelsHeight: CGFloat = 20
}

enum ActivityChartSelection {
    static func index(at x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard width > 0, count > 0, x.isFinite else { return nil }
        return min(count - 1, max(0, Int(floor(max(0, min(1, x / width)) * CGFloat(count)))))
    }
    static func x(for index: Int, width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return width * (CGFloat(index) + 0.5) / CGFloat(count)
    }
}

struct ActivityTrendPlot: View {
    let data: ActivityChartData
    var selectedDate: Date? = nil
    var compact = false
    var showsScale = true
    var foreground = Color.white
    var adaptiveColors = false
    var cleanContour = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var maximum: Double { data.maximum }
    private var selectedIndex: Int? { data.points.firstIndex { $0.date == selectedDate } }
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let height = max(1, geometry.size.height - 12)
                    ZStack(alignment: .topLeading) {
                        Path { path in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = 6 + height * fraction
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(foreground.opacity(contrast == .increased ? 0.32 : 0.095), style: StrokeStyle(lineWidth: 0.5))
                        if let index = selectedIndex {
                            let x = ActivityChartSelection.x(for: index, width: geometry.size.width, count: data.points.count)
                            Path { path in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height)) }
                                .stroke(foreground.opacity(0.3), lineWidth: 0.7)
                        }
                        ForEach(data.series) { series in
                            let values = cleanContour
                                ? ActivityTrendSamples.values(for: series, period: data.summary.period, now: data.now)
                                : series.summary.points.map { $0.totals.observed > 0 ? $0.totals.active : nil }
                            let ink = adaptiveColors && scheme == .light
                                ? (series.provider == .claude ? Color(red: 0.74, green: 0.39, blue: 0.18) : Color(red: 0.17, green: 0.47, blue: 0.66))
                                : activityAccent(series.provider)
                            if cleanContour {
                                ActivityTrendShape(values: values, maximum: maximum, connectsKnownPoints: true)
                                    .stroke(ink, style: StrokeStyle(lineWidth: contrast == .increased ? 2.6 : 2, lineCap: .round, lineJoin: .round))
                            } else {
                                ActivityTrendArea(values: values, maximum: maximum)
                                    .fill(LinearGradient(stops: [.init(color: ink.opacity(0.13), location: 0), .init(color: ink.opacity(0.04), location: 0.65), .init(color: ink.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom))
                                ActivityTrendShape(values: values, maximum: maximum)
                                    .stroke(ink.opacity(0.04), style: StrokeStyle(lineWidth: compact ? 3.5 : 4.5, lineCap: .round, lineJoin: .round))
                                ActivityTrendShape(values: values, maximum: maximum)
                                    .stroke(LinearGradient(colors: [ink, ink.opacity(0.88)], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: compact ? 2 : 2.3, lineCap: .round, lineJoin: .round))
                            }
                            ForEach(values.indices, id: \.self) { index in
                                if let value = values[index], shouldShowPoint(index, values: values) {
                                    let chosen = index == selectedIndex
                                    let isolated = (index == 0 || values[index - 1] == nil) && (index == values.count - 1 || values[index + 1] == nil)
                                    let current = ActivityChartText.isCurrent(series.summary.points[index].date, period: data.summary.period, now: data.now)
                                    let size: CGFloat = chosen ? 6 : cleanContour ? 5 : isolated ? 4 : 3.5
                                    Circle().fill(cleanContour && !chosen ? Color(nsColor: .windowBackgroundColor) : ink)
                                        .overlay(Circle().stroke(cleanContour && !chosen ? ink : foreground.opacity(chosen ? 0.9 : 0), lineWidth: cleanContour ? 1.6 : 1.1))
                                        .frame(width: size, height: size)
                                        .background { if chosen || current { Circle().fill(ink.opacity(chosen ? 0.16 : 0.08)).frame(width: chosen ? 13 : 8, height: chosen ? 13 : 8) } }
                                        .position(x: ActivityChartSelection.x(for: index, width: geometry.size.width, count: values.count),
                                                  y: 6 + height * (1 - min(1, value / maximum)))
                                }
                            }
                        }
                    }
                }
                GeometryReader { geometry in
                    ForEach(labelIndices, id: \.self) { index in
                        let labelWidth: CGFloat = data.summary.period == .month ? 44 : 30
                        Text(label(data.points[index].date)).font(.system(size: 11))
                            .foregroundStyle(foreground.opacity(0.76)).lineLimit(1).frame(width: labelWidth)
                            .position(x: min(geometry.size.width - labelWidth / 2, max(labelWidth / 2, ActivityChartSelection.x(for: index, width: geometry.size.width, count: data.points.count))), y: 7)
                    }
                }.frame(height: 14)
            }
            if showsScale {
                GeometryReader { geometry in
                    Text(ActivityChartScale.tick(maximum, maximum: maximum) + " " + ActivityChartScale.unit(maximum: maximum)).position(x: 19, y: 7)
                    if geometry.size.height > 82 { Text(ActivityChartScale.tick(maximum / 2, maximum: maximum)).position(x: 19, y: geometry.size.height / 2) }
                    Text("0").position(x: 19, y: max(7, geometry.size.height - 6))
                }.frame(width: 38).padding(.bottom, ActivityPlotGeometry.labelsHeight)
                    .font(.system(size: 11)).foregroundStyle(foreground.opacity(0.7)).accessibilityHidden(true)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Статистика активности"))
            .accessibilityValue(data.series.map { $0.provider.title + ": " + ($0.totals(at: selectedDate).observed > 0 ? ActivityChartText.value($0.totals(at: selectedDate), compact: false) : L("Нет данных")) }.joined(separator: "; "))
    }
    private func shouldShowPoint(_ index: Int, values: [Double?]) -> Bool {
        if cleanContour { return index == selectedIndex || index == values.lastIndex(where: { $0 != nil }) || values.compactMap { $0 }.count == 1 }
        return index == selectedIndex || index == values.lastIndex(where: { $0 != nil }) ||
        ((index == 0 || values[index - 1] == nil) && (index == values.count - 1 || values[index + 1] == nil))
    }
    private var labelIndices: [Int] {
        guard !data.points.isEmpty else { return [] }
        let count = min(compact ? 3 : data.summary.period == .week ? 7 : 5, data.points.count)
        return (0..<count).map { $0 * (data.points.count - 1) / max(1, count - 1) }
    }
    private func label(_ date: Date) -> String {
        ActivityChartText.axis(date, period: data.summary.period)
    }
}

/// A faint underlay follows each existing segment; missing observations never get bridged.
struct ActivityTrendArea: Shape {
    let values: [Double?]
    let maximum: Double
    func path(in rect: CGRect) -> Path {
        var result = Path(), start: Int?
        func close(_ end: Int) {
            guard let first = start, end > first else { start = nil; return }
            var segment = values.map { _ in Optional<Double>.none }
            for index in first...end { segment[index] = values[index] }
            var area = ActivityTrendShape(values: segment, maximum: maximum).path(in: rect)
            let baseline = max(6, rect.height - 6)
            area.addLine(to: CGPoint(x: ActivityChartSelection.x(for: end, width: rect.width, count: values.count), y: baseline))
            area.addLine(to: CGPoint(x: ActivityChartSelection.x(for: first, width: rect.width, count: values.count), y: baseline))
            area.closeSubpath(); result.addPath(area); start = nil
        }
        for index in values.indices {
            if let value = values[index], value.isFinite { if start == nil { start = index } }
            else { close(index - 1) }
        }
        if !values.isEmpty { close(values.count - 1) }
        return result
    }
}

/// Monotone cubic interpolation: smooth slopes without inventing extrema between recorded points.
struct ActivityTrendShape: Shape {
    let values: [Double?]
    let maximum: Double
    var connectsKnownPoints = false
    func path(in rect: CGRect) -> Path {
        var path = Path(), segment: [CGPoint] = []
        func flush() {
            guard let first = segment.first else { return }
            path.move(to: first)
            if segment.count > 1 {
                let deltas = (1..<segment.count).map { (segment[$0].y - segment[$0 - 1].y) / (segment[$0].x - segment[$0 - 1].x) }
                var slopes = [deltas[0]]
                for i in 1..<segment.count - 1 {
                    let a = deltas[i - 1], b = deltas[i]
                    slopes.append(a * b <= 0 ? 0 : 2 * a * b / (a + b))
                }
                slopes.append(deltas.last!)
                for i in 1..<segment.count {
                    let a = segment[i - 1], b = segment[i], dx = (b.x - a.x) / 3
                    path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y + slopes[i - 1] * dx),
                                  control2: CGPoint(x: b.x - dx, y: b.y - slopes[i] * dx))
                }
            }
            segment.removeAll(keepingCapacity: true)
        }
        guard maximum > 0, rect.width > 0 else { return path }
        for index in values.indices {
            guard let value = values[index], value.isFinite else { if !connectsKnownPoints { flush() }; continue }
            segment.append(CGPoint(x: ActivityChartSelection.x(for: index, width: rect.width, count: values.count),
                                   y: 6 + max(1, rect.height - 12) * (1 - min(1, max(0, value) / maximum))))
        }
        flush(); return path
    }
}


/// Display-only sampling. Source values remain unchanged for readouts/totals.
enum ActivityTrendSamples {
    static func values(for series: ActivityChartSeries, period: ActivityPeriod, now: Date) -> [Double?] {
        series.summary.points.map { point in
            guard point.date <= now, point.totals.observed > 0 else { return nil }
            if period == .day && ActivityChartText.isCurrent(point.date, period: period, now: now) { return nil }
            return point.totals.active
        }
    }
}
