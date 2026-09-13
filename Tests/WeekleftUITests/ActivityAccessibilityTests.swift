import AppKit
import SwiftUI
import XCTest
import WeekleftCore
@testable import Weekleft

final class ActivityAccessibilityTests: XCTestCase {
    func testChartSelectionCommandsKeepUnknownPointsSelectableAndClearThroughCallback() throws {
        let fixture = try fixture()
        let data = ActivityChartData(history: fixture.history, now: fixture.now, period: .week,
                                     providers: [.claude, .codex], calendar: fixture.calendar)
        var selected: Date?
        var callbacks: [Date?] = []
        func actions() -> ActivityChartSelectionActions {
            ActivityChartSelectionActions(data: data, selectedDate: selected) { date in
                selected = date; callbacks.append(date)
            }
        }

        actions().move(-1)
        XCTAssertEqual(selected, data.points[data.points.count - 2].date)
        XCTAssertEqual(data.series.reduce(0) { $0 + $1.totals(at: selected).observed }, 0,
                       "Keyboard and adjustable navigation must select a missing day, not snap to a recorded day")
        actions().move(1)
        XCTAssertEqual(selected, data.points.last?.date)
        actions().move(100)
        XCTAssertEqual(selected, data.points.last?.date, "Navigation must stop at the current day")
        actions().select(data.points[2].date)
        XCTAssertEqual(selected, data.points[2].date)
        actions().move(-100)
        XCTAssertEqual(selected, data.points.first?.date)
        actions().clear()
        XCTAssertNil(selected, "The same callback restores whole-period breakdown after Escape or Clear")
        XCTAssertEqual(callbacks.count, 6)
        XCTAssertNil(callbacks.last!)
    }

    func testChartSelectionCommandsRejectFutureHours() throws {
        let fixture = try fixture()
        let data = ActivityChartData(history: fixture.history, now: fixture.now, period: .day,
                                     providers: [.claude, .codex], calendar: fixture.calendar)
        var selections: [Date?] = []
        let actions = ActivityChartSelectionActions(data: data, selectedDate: nil) { selections.append($0) }
        actions.select(try XCTUnwrap(data.points.first { $0.date > fixture.now }).date)
        actions.move(100)
        actions.clear()
        XCTAssertNil(selections[0])
        XCTAssertEqual(selections[1], data.points.last { $0.date <= fixture.now }?.date)
        XCTAssertNil(selections[2])
    }

    @MainActor func testBreakdownSearchMatchesWordsDiacriticsAndSessionIDWithoutChangingTotals() throws {
        let fixture = try fixture()
        let data = ActivityBreakdownData(history: fixture.history, details: fixture.details,
                                        providers: [.claude, .codex], period: .week, selectedDate: nil, now: fixture.now)
        let before = data.totals
        func matches(_ query: String) -> [String] {
            ActivityBreakdownView(data: data, query: query).projects.flatMap(\.rows).map(\.sessionID).sorted()
        }
        XCTAssertEqual(matches("  uberprufung\n ATLAS  claude "), ["fixture-alpha"])
        XCTAssertEqual(matches("fixture-beta"), ["fixture-beta"])
        XCTAssertEqual(matches("  \n "), ["fixture-alpha", "fixture-beta"])
        XCTAssertEqual(matches("Codex atlas"), ["fixture-beta"])
        XCTAssertTrue(matches("nonexistent-project").isEmpty)
        XCTAssertEqual(data.records.count, 2)
        XCTAssertEqual(data.totals.active, before.active, "Searching must not narrow the period aggregate")
        XCTAssertEqual(data.totals.recovered, before.recovered)
    }

    @MainActor func testRenderLongActivityLabels() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ACTIVITY_ACCESSIBILITY"] else {
            throw XCTSkip("Opt-in isolated activity accessibility rendering")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try fixture()
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "ru"
        let data = ActivityChartData(history: fixture.history, now: fixture.now, period: .week,
                                     providers: [.claude, .codex], calendar: fixture.calendar)
        let breakdown = ActivityBreakdownData(history: fixture.history, details: fixture.details,
                                             providers: [.claude, .codex], period: .week, selectedDate: nil, now: fixture.now)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = language + (scheme == .light ? "-light" : "-dark")
            try render(ActivityDetailChart(data: data, pinnedDate: data.points[2].date).padding(16),
                       size: CGSize(width: 520, height: 570), scheme: scheme,
                       url: directory.appendingPathComponent("activity-unknown-point-" + suffix + ".png"))
            try render(ActivityBreakdownView(data: breakdown, expanded: Set(breakdown.records.map(\.cwd))),
                       size: CGSize(width: 640, height: 540), scheme: scheme,
                       url: directory.appendingPathComponent("activity-long-projects-" + suffix + ".png"))
        }
    }

    private func fixture() throws -> (now: Date, calendar: Calendar, history: ActivityHistory, details: ActivityDetails) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 10, minute: 30)))
        let today = calendar.startOfDay(for: now)
        let first = ActivityInterval(start: today.addingTimeInterval(-6 * 86400 + 9 * 3600),
                                     end: today.addingTimeInterval(-6 * 86400 + 10 * 3600), providers: 1)
        let last = ActivityInterval(start: today.addingTimeInterval(9 * 3600),
                                    end: today.addingTimeInterval(10 * 3600), providers: 2)
        var history = ActivityHistory()
        history.append(start: first.start, end: first.end, providers: 1)
        history.append(start: last.start, end: last.end, providers: 2)
        var details = ActivityDetails()
        let path = "/Users/demo/Projects/Arbeitsbereich mit einem sehr langen Namen/Überarbeitung der Bedienung und der Verbindungseinstellungen/Atlas"
        details.merge([
            ActivityDetailRecord(provider: .claude, sessionID: "fixture-alpha",
                    title:
                        "Überprüfung der ausführlichen Verbindungseinstellungen und Wiederherstellung sehr langer Sitzungsnamen — Проверка подробных настроек подключения и восстановления названий сессий без потери информации",
                    cwd: path, intervals: [first]),
            ActivityDetailRecord(provider: .codex, sessionID: "fixture-beta",
                    title:
                        "Подготовить подробную документацию для восстановления локальной истории и проверить доступность всех элементов интерфейса — Dokumentation zur Wiederherstellung des lokalen Verlaufs und Prüfung der Bedienelemente",
                    cwd: path, intervals: [last])
        ], now: now)
        return (now, calendar, history, details)
    }

    @MainActor private func render<V: View>(_ content: V, size: CGSize, scheme: ColorScheme, url: URL) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
