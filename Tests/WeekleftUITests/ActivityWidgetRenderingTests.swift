import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ActivityWidgetRenderingTests: XCTestCase {
    @MainActor func testRenderLimitsOnLightAndDarkBackgrounds() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMIT_CONTRAST"] else { throw XCTSkip("Opt-in native contrast rendering") }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let snapshots = try ProviderID.allCases.map { id in
            try UsageSnapshot(provider: id, weekly: QuotaWindow(usedPercent: id == .claude ? 30 : 60, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                          fiveHour: QuotaWindow(usedPercent: 15, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)), fetchedAt: now)
        }
        for experimental in [false, true] {
        for light in [true, false] {
            var prefs = WidgetPreferences(); prefs.showFiveHour = true; prefs.transparency = 0.75
            prefs.transparentBackground = experimental
            let view = LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: ActivityHistory(), content: .limits, family: .medium, now: now)
                .clipShape(RoundedRectangle(cornerRadius: 24)).padding(20).background(light ? Color.white : Color.black)
            try render(view, size: CGSize(width: 384, height: 212), to: directory.appendingPathComponent((experimental ? "experimental-" : "standard-") + (light ? "light.png" : "dark.png")), scheme: light ? .light : .dark)
        }
        }
    }
    @MainActor func testActivityIncludesHiddenSessionsWithoutChangingTheirVisibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let now = Date()
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Fixture", cwd: "", phase: .running, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        var tracker = ActivityTracker()
        store.onObservation = { tracker.observe($0, now: $1) }
        store.acceptSessions([row], now: now)
        try store.hide(row)
        store.acceptSessions([row], now: now.addingTimeInterval(2))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(tracker.history.summary(now: now.addingTimeInterval(2)).totals.active, 2)
    }
    @MainActor func testRenderEveryWidgetLayout() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ACTIVITY"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(18 * 3600)
        var history = ActivityHistory()
        var recovered: [ActivityInterval] = []
        _ = history.prepareImport(now: Calendar.current.startOfDay(for: now))
        for day in -29...0 {
            for hour in [9, 10, 14, 15, 16] {
                let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(day * 86400 + hour * 3600))
                let seconds = Double((((day + 30) * (day + 30) * (hour + 3) + hour * 7) % 50 + 5) * 60)
                let mask = hour < 12 ? 1 : hour == 15 ? 3 : 2
                if day < 0 { recovered.append(ActivityInterval(start: start, end: start.addingTimeInterval(seconds), providers: mask)) }
                else { history.append(start: start, end: start.addingTimeInterval(seconds), providers: mask) }
            }
        }
        history.mergeRecovered(recovered, now: now, limited: false)
        let snapshots = try ProviderID.allCases.map { id in
            UsageSnapshot(provider: id, weekly: try QuotaWindow(usedPercent: id == .claude ? 35 : 58, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)), fiveHour: try QuotaWindow(usedPercent: 22, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)), fetchedAt: now)
        }
        var prefs = WidgetPreferences(); prefs.showFiveHour = true
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for content in LunavectWidgetContent.allCases {
                for family in content.sizes {
                    for period in content == .limits ? [.week] : ActivityPeriod.allCases {
                        let view = LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: content, family: family, now: now, period: period)
                        try render(view, size: family.dimensions, to: directory.appendingPathComponent("\(language)-\(content.rawValue)-\(family.rawValue)-\(period.rawValue).png"))
                    }
                }
            }
        }
        for language in ["ru", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for source in [ActivitySource.claude, .codex, .comparison] {
                for family in LunavectWidgetSize.allCases {
                    for period in [ActivityPeriod.week, .month] {
                        let selected = history.summary(now: now, period: period).points.dropLast().last?.date
                        try render(LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: .activity, family: family, now: now,
                                                     period: period, source: source), size: family.dimensions,
                                   to: directory.appendingPathComponent("\(language)-\(source.rawValue)-\(family.rawValue)-\(period.rawValue).png"))
                        try render(LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: .activity, family: family, now: now,
                                                     period: period, source: source, selectedDate: selected, resetButton: AnyView(ActivitySelectionResetLabel())), size: family.dimensions,
                                   to: directory.appendingPathComponent("\(language)-selected-\(source.rawValue)-\(family.rawValue)-\(period.rawValue).png"))
                    }
                }
            }
        }
        L10n.defaults.set("ru", forKey: "languageCode")
        for family in LunavectWidgetSize.allCases {
            try render(LunavectWidgetCard(snapshots: [], preferences: prefs, history: ActivityHistory(), content: .activity, family: family, now: now), size: family.dimensions, to: directory.appendingPathComponent("empty-\(family.rawValue).png"))
        }
        var stale = snapshots; stale[0].fetchedAt = now.addingTimeInterval(-86400)
        stale[0].weekly = try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-1))
        try render(LunavectWidgetCard(snapshots: stale, preferences: prefs, history: history, content: .limits, family: .small, now: now), size: LunavectWidgetSize.small.dimensions, to: directory.appendingPathComponent("expired-small.png"))
        func card(_ content: LunavectWidgetContent, _ family: LunavectWidgetSize, _ period: ActivityPeriod = .week, _ source: ActivitySource = .all) -> some View {
            LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: content, family: family, now: now, period: period, source: source)
                .background(Color(red: 0.09, green: 0.11, blue: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
        }
        let board = VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Lunavect").font(.system(size: 24, weight: .semibold))
                Spacer()
                Text("Нативный интерфейс · демонстрационные данные").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ОТДЕЛЬНЫЕ ВИДЖЕТЫ").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 16) { card(.limits, .small); card(.activity, .small) }
                    card(.activity, .medium)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("ВСЁ ВМЕСТЕ").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    card(.overview, .large)
                }
            }
        }.padding(24).foregroundStyle(.white)
        try render(board, size: CGSize(width: 760, height: 458), to: directory.appendingPathComponent("overview.png"))
        let comparisonBoard = HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Claude и Codex отдельно").font(.system(size: 16, weight: .semibold))
                card(.activity, .medium, .week, .claude)
                card(.activity, .medium, .week, .codex)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Claude + Codex · один график").font(.system(size: 16, weight: .semibold))
                card(.activity, .large, .week, .comparison)
            }
        }.padding(24).foregroundStyle(.white)
        try render(comparisonBoard, size: CGSize(width: 756, height: 430), to: directory.appendingPathComponent("comparison.png"))
        let periods = VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Статистика активности").font(.system(size: 24, weight: .semibold))
                Spacer()
                Text("Lunavect · демонстрационные данные").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(ActivityPeriod.allCases) { period in
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Период", selection: .constant(period)) {
                            ForEach(ActivityPeriod.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        card(.activity, .medium, period)
                        card(.activity, .small, period)
                    }.frame(width: 344)
                }
            }
        }.padding(24).foregroundStyle(.white)
        try render(periods, size: CGSize(width: 1120, height: 480), to: directory.appendingPathComponent("periods.png"))
        // Render the real controls with the same synthetic history; never publish user history.
        let store = AppStore(state: SharedState(snapshots: snapshots, preferences: prefs), savesChanges: false, activityHistory: history)
        for language in ["ru", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            let suite = "Lunavect.ActivityRendering." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            for section in [SettingsSection.statistics, .widget] {
                defaults.set(section.rawValue, forKey: "settingsSection")
                try render(SettingsView(store: store, menuBarAppearance: MenuBarAppearance(defaults: defaults), sessions: SessionStore()).defaultAppStorage(defaults),
                           size: CGSize(width: 840, height: 680), to: directory.appendingPathComponent("\(language)-page-\(section.rawValue).png"))
            }
        }
        L10n.defaults.set("ru", forKey: "languageCode")
        for period in ActivityPeriod.allCases {
            try render(ActivityDetailChart(data: ActivityChartData(history: history, now: now, period: period)),
                       size: CGSize(width: 554, height: 530), to: directory.appendingPathComponent("detail-\(period.rawValue).png"))
            try render(WidgetPreviewPicker(store: store, content: .activity, family: .small, period: period),
                       size: CGSize(width: 540, height: 540), to: directory.appendingPathComponent("settings-\(period.rawValue)-local.png"))
        }
    }
    @MainActor func testRenderSharedChartStates() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ACTIVITY"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(language, forKey: "languageCode") }
        L10n.defaults.set("ru", forKey: "languageCode")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(18 * 3600)
        func history(_ claude: [Double?], _ codex: [Double?], stale: Bool = false, limited: Bool = false) -> ActivityHistory {
            var result = ActivityHistory()
            for index in claude.indices {
                let start = Calendar.current.date(byAdding: .day, value: index - 6, to: Calendar.current.startOfDay(for: now))!
                let a = claude[index], b = codex[index]
                let observed = (a == nil ? 0 : 1) | (b == nil ? 0 : 2)
                guard observed != 0 else { continue }
                let boundaries = Array(Set([0, a ?? 0, b ?? 0, index == 6 ? 64800 : 86400])).sorted()
                for pair in zip(boundaries, boundaries.dropFirst()) {
                    let mask = ((a ?? 0) > pair.0 ? 1 : 0) | ((b ?? 0) > pair.0 ? 2 : 0)
                    let end = stale && index == 6 ? min(pair.1, 60000) : pair.1
                    if end > pair.0 { result.append(start: start.addingTimeInterval(pair.0), end: start.addingTimeInterval(end), providers: mask, observedProviders: observed) }
                }
            }
            if limited { result.mergeRecovered([], now: now, limited: true) }
            return result
        }
        let contourHistory = history([18, 46, 34, 72, 41, 85, 32].map { Double($0 * 60) },
                                     [42, 28, 85, 61, 122, 74, 101].map { Double($0 * 60) })
        for scheme in [ColorScheme.dark, .light] {
            try render(ActivityDetailChart(data: ActivityChartData(history: contourHistory, now: now))
                .padding(24).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 740, height: 560),
                       to: directory.appendingPathComponent(scheme == .dark ? "contour-week-dark.png" : "contour-week-light.png"), scheme: scheme)
        }
        let equal: [Double?] = [2400, 4800, 3600, 7200, 3000, 9000, 4200]
        let fixtures: [(String, String, ActivityHistory)] = [
            ("equal", "Совпадающие линии", history(equal, equal)),
            ("difference", "Разница в 20 раз", history([120, 240, 180, 360, 150, 450, 210], equal)),
            ("gaps", "Пропуски и одиночная точка", history([nil, 2400, nil, nil, nil, nil, nil], [1800, 3000, 4200, 2800, 5000, 4000, 3000])),
            ("zero", "Известный ноль", history(Array(repeating: 0, count: 7), equal)),
            ("unknown", "Нет записей Claude", history(Array(repeating: nil, count: 7), equal)),
            ("partial", "Неполная история и устаревание", history(equal, equal.map { $0.map { $0 * 0.5 } }, stale: true, limited: true))
        ]
        var prefs = WidgetPreferences(); prefs.transparency = 0.75
        func card(_ entry: (String, String, ActivityHistory), selected: Bool = false) -> some View {
            LunavectWidgetCard(snapshots: [], preferences: prefs, history: entry.2, content: .activity, family: .medium, now: now,
                              selectedDate: selected ? Calendar.current.startOfDay(for: now) : nil,
                              resetButton: AnyView(ActivitySelectionResetLabel()))
                .background(LinearGradient(colors: [.white, .purple, .pink, .white], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        for entry in fixtures {
            try render(card(entry), size: LunavectWidgetSize.medium.dimensions, to: directory.appendingPathComponent("state-\(entry.0).png"))
        }
        try render(card(fixtures[0], selected: true), size: LunavectWidgetSize.medium.dimensions, to: directory.appendingPathComponent("state-current-selected.png"))
        try render(card(fixtures[0]), size: LunavectWidgetSize.medium.dimensions, to: directory.appendingPathComponent("state-light-host.png"), scheme: .light)
        try render(ActivityDetailChart(data: ActivityChartData(history: fixtures[3].2, now: now))
            .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 554, height: 530),
                   to: directory.appendingPathComponent("detail-light.png"), scheme: .light)
        // NSHostingView.cacheDisplay does not apply system widget tint or compositor saturation.
        // Test those states on the desktop; do not label an identical bitmap as proof.
        let board = VStack(alignment: .leading, spacing: 18) {
            Text("Проверка состояний · нативный интерфейс · демонстрационные данные").font(.system(size: 14, weight: .semibold))
            ForEach(0..<3) { row in
                HStack(spacing: 24) {
                    ForEach(0..<2) { column in
                        let entry = fixtures[row * 2 + column]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.1).font(.system(size: 12))
                            card(entry)
                        }
                    }
                }
            }
        }.padding(24).foregroundStyle(.white)
        try render(board, size: CGSize(width: 760, height: 696), to: directory.appendingPathComponent("states.png"))
    }
    @MainActor func testRenderCleanContourAndSeparateCurrentHour() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_GAPS"] else { throw XCTSkip("Opt-in native gap preview") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let today = Calendar.current.startOfDay(for: Date())
        let now = today.addingTimeInterval(9 * 3600 + 56 * 60)
        var history = ActivityHistory()
        for (hour, minutes) in [(0, 27), (1, 24), (2, 0), (3, 0), (8, 50), (9, 54)] {
            let start = today.addingTimeInterval(Double(hour * 3600))
            let end = min(now, start.addingTimeInterval(3600))
            if minutes > 0 { history.append(start: start, end: start.addingTimeInterval(Double(minutes * 60)), providers: 2, observedProviders: 2) }
            history.append(start: start.addingTimeInterval(Double(minutes * 60)), end: end, providers: 0, observedProviders: 2)
        }
        let data = ActivityChartData(history: history, now: now, period: .day)
        let codex = try XCTUnwrap(data.series.first { $0.provider == .codex })
        XCTAssertEqual(codex.summary.points[5].totals.observed, 0)
        XCTAssertEqual(codex.summary.points[2].totals.active, 0)
        XCTAssertGreaterThan(codex.summary.points[2].totals.observed, 0)
        XCTAssertEqual(codex.summary.totals.active, 155 * 60)
        let displayed = ActivityTrendSamples.values(for: codex, period: .day, now: now)
        XCTAssertNil(displayed[5], "Unknown values stay unknown for the model")
        XCTAssertEqual(displayed[2], 0, "Known idle is still zero")
        XCTAssertEqual(displayed[8], 50 * 60)
        XCTAssertNil(displayed[9], "Unfinished hour is shown separately, without a false drop")
        XCTAssertEqual(codex.summary.points[9].totals.active, 54 * 60, "Current-hour observations are retained")
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        for language in ["ru", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for scheme in [ColorScheme.dark, .light] {
                try render(ActivityDetailChart(data: data).padding(20).background(Color(nsColor: .windowBackgroundColor)),
                           size: CGSize(width: 620, height: 540), to: directory.appendingPathComponent("contour-day-" + language + (scheme == .dark ? "-dark.png" : "-light.png")), scheme: scheme)
            }
        }
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, to url: URL, scheme: ColorScheme = .dark) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(red: 0.09, green: 0.11, blue: 0.14)).preferredColorScheme(scheme))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }
}
