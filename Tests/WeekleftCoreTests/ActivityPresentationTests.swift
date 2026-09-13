import XCTest
@testable import WeekleftCore

final class ActivityPresentationTests: XCTestCase {
    func testSelectionIsScopedAndDoesNotChangeActivityData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let untouched = directory.appendingPathComponent("activity.json"), marker = Data("unchanged history".utf8)
        try marker.write(to: untouched)
        let a = Date(timeIntervalSince1970: 1800000000), b = a.addingTimeInterval(-86400)
        let activity = "LunavectActivityWidget", overview = "LunavectOverviewWidget"
        try ActivityWidgetSelection.write(a, kind: activity, period: .week, source: .claude, directory: directory)
        try ActivityWidgetSelection.write(b, kind: activity, period: .week, source: .codex, directory: directory)
        try ActivityWidgetSelection.write(b, kind: overview, period: .week, source: .claude, directory: directory)
        XCTAssertEqual(ActivityWidgetSelection.read(kind: activity, period: .week, source: .claude, directory: directory), a)
        XCTAssertEqual(ActivityWidgetSelection.read(kind: activity, period: .week, source: .codex, directory: directory), b)
        XCTAssertNil(ActivityWidgetSelection.read(kind: activity, period: .month, source: .claude, directory: directory))
        try ActivityWidgetSelection.write(nil, kind: activity, period: .week, source: .claude, directory: directory)
        XCTAssertNil(ActivityWidgetSelection.read(kind: activity, period: .week, source: .claude, directory: directory))
        XCTAssertEqual(ActivityWidgetSelection.read(kind: overview, period: .week, source: .claude, directory: directory), b)
        try ActivityWidgetSelection.write(a, kind: "../activity", period: .week, source: .all, directory: directory)
        XCTAssertEqual(try Data(contentsOf: untouched), marker)
    }
    func testSourcesAndDeepLinksKeepProviderBoundaries() throws {
        for source in ActivitySource.allCases {
            for period in ActivityPeriod.allCases {
                let url = source.widgetURL(period: period)
                XCTAssertEqual(ActivityPeriod.from(widgetURL: url), period)
                XCTAssertEqual(ActivitySource.from(widgetURL: url), source)
            }
        }
        XCTAssertEqual(ActivitySource.claude.providers(from: [.codex]), [])
        XCTAssertEqual(ActivitySource.comparison.providers(from: [.claude, .codex]), [.claude, .codex])
        XCTAssertFalse(ActivitySource.available(for: [.codex]).contains(.comparison))
        XCTAssertEqual(ActivitySource.from(widgetURL: ActivityPeriod.week.widgetURL), .all)
        XCTAssertNil(ActivitySource.from(widgetURL: try XCTUnwrap(URL(string: "lunavect://activity?source=claude&source=codex"))))
    }
    func testComparisonUsesSameScaleWithoutAddingParallelWork() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-1800), end: now, providers: 3)
        let combined = history.summary(now: now, period: .day),
            claude = history.summary(now: now, period: .day, providers: [.claude]),
            codex = history.summary(now: now, period: .day, providers: [.codex])
        XCTAssertEqual(combined.totals.active, 1800)
        XCTAssertEqual(claude.totals.active, 1800); XCTAssertEqual(codex.totals.active, 1800)
        XCTAssertEqual(ActivityChartScale.ceiling(3500), 3600)
        XCTAssertEqual(ActivityChartScale.ceiling(0), 60)
        XCTAssertEqual(ActivityChartScale.ceiling(25 * 3600), 30 * 3600)
    }
    func testKnownIdleProviderStaysFreshWhileOtherWorks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: ProviderID, phase: SessionPhase) -> AgentSession {
            AgentSession(provider: id, sessionID: id.rawValue, title: "Fixture", cwd: "", phase: phase,
                         updatedAt: now, observedAt: now, evidence: .localEvent, runtimeConfirmed: true)
        }
        let rows = [row(.claude, phase: .ready), row(.codex, phase: .running)]
        var tracker = ActivityTracker()
        tracker.observe(rows, now: now); tracker.observe(rows, now: now.addingTimeInterval(5))
        let data = ActivityChartData(history: tracker.history, now: now.addingTimeInterval(5), period: .day)
        XCTAssertEqual(data.series[0].summary.totals.active, 0)
        XCTAssertEqual(data.series[0].summary.totals.observed, 5)
        XCTAssertEqual(data.series[1].summary.totals.active, 5)
        XCTAssertEqual(data.series[0].summary.lastLiveObservedAt, now.addingTimeInterval(5))
        XCTAssertFalse(data.stale)
        XCTAssertEqual(tracker.history.intervals.first?.observedProviders, 3)
        var onlyCodex = ActivityTracker()
        onlyCodex.observe([rows[1]], now: now); onlyCodex.observe([rows[1]], now: now.addingTimeInterval(5))
        XCTAssertFalse(onlyCodex.history.summary(now: now.addingTimeInterval(5), providers: [.claude]).hasObservations)
    }
    func testLegacyIdleAndImportedOtherProviderDoNotInventZeros() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-10), end: now, providers: 0)
        let restored = try JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(history))
        XCTAssertTrue(restored.summary(now: now).hasObservations)
        XCTAssertFalse(restored.summary(now: now, providers: [.claude]).hasObservations)
        history.mergeRecovered([ActivityInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), providers: 2)], now: now, limited: false)
        let data = ActivityChartData(history: history, now: now)
        XCTAssertFalse(data.series[0].summary.hasObservations)
        XCTAssertEqual(data.series[1].summary.totals.active, 1800)
        XCTAssertTrue(data.series[1].summary.totals.recovered > 0)
        XCTAssertFalse(data.stale, "Old imported work is not itself a stale live feed")
    }
    func testUnionAndPersistencePreserveProviderObservationMasks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spans = [ActivityInterval(start: now, end: now.addingTimeInterval(20), providers: 0, observedProviders: 3),
                     ActivityInterval(start: now.addingTimeInterval(5), end: now.addingTimeInterval(10), providers: 2, recovered: true)]
        let union = ActivityHistory.union(spans)
        XCTAssertEqual(union.count, 3)
        XCTAssertTrue(union.allSatisfy { $0.observedProviders == 3 })
        XCTAssertEqual(union.map(\.providers), [0, 2, 0])
        XCTAssertEqual(try JSONDecoder().decode([ActivityInterval].self, from: JSONEncoder().encode(union)), union)
    }
    func testSelectionKeepsCalendarPositionsAndStopsBeforeFutureHours() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 10, minute: 20)))
        let data = ActivityChartData(history: ActivityHistory(), now: now, period: .day, calendar: calendar)
        let last = try XCTUnwrap(data.adjacent(to: nil, offset: 1))
        XCTAssertEqual(calendar.component(.hour, from: last), 10)
        XCTAssertEqual(data.adjacent(to: last, offset: 1), last)
        XCTAssertEqual(data.adjacent(to: data.points[0].date, offset: -1), data.points[0].date)
        XCTAssertNil(data.validSelection(data.points[12].date))
        XCTAssertNotNil(data.validSelection(data.points[5].date), "Unknown history is selectable, not replaced by nearby activity")
    }
    func testScaleDoesNotDoubleImmediatelyAboveTwelveHours() {
        XCTAssertEqual(ActivityChartScale.ceiling(12.1 * 3600), 14 * 3600)
        XCTAssertEqual(ActivityChartScale.ceiling(3600), 3600)
        XCTAssertEqual(ActivityChartScale.ceiling(.nan), 60)
        XCTAssertEqual(ActivitySource(rawValue: "comparison")?.canonical, .all)
        XCTAssertEqual(ActivitySource.available(for: [.claude, .codex]), [.all, .claude, .codex])
        XCTAssertEqual(ActivitySource.available(for: [.claude]), [.claude])
    }
    func testEnglishDayAxisKeepsMidnightAndEveningDistinct() throws {
        let old = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(old, forKey: "languageCode") }
        L10n.defaults.set("en", forKey: "languageCode")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10)))
        let labels = [0, 11, 23].map { ActivityChartText.axis(midnight.addingTimeInterval(Double($0) * 3600), period: .day, calendar: calendar) }
        XCTAssertEqual(labels, ["00", "11", "23"])
    }

}
