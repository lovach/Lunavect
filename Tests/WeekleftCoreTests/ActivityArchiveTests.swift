import XCTest
@testable import WeekleftCore

/// Owner request 29.09: Year, All time and richer statistics from daily totals kept
/// after the 35-day history is pruned; the subscription end date in widgets.
final class ActivityArchiveTests: XCTestCase {
    private var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Vienna")!; value.firstWeekday = 2
        return value
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 22))!
    private func at(_ day: Int, _ hour: Int, month: Int = 9) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))! }
    private func detail(_ provider: ProviderID, _ id: String, _ cwd: String, _ spans: [(Date, Date)]) -> ActivityDetailRecord {
        let mask = provider == .claude ? 1 : 2
        return ActivityDetailRecord(provider: provider, sessionID: id, title: id, cwd: cwd,
                                    intervals: spans.map { ActivityInterval(start: $0.0, end: $0.1, providers: mask, observedProviders: mask) })
    }

    func testDaysInsideTheHistoryAreComputedPerSourceProjectAndSession() throws {
        var history = ActivityHistory()
        // 10:00–11:00 Claude, 10:30–12:00 Codex: together 2 h, overlap counted once.
        history.append(start: at(28, 10), end: at(28, 10).addingTimeInterval(1800), providers: 1, observedProviders: 3)
        history.append(start: at(28, 10).addingTimeInterval(1800), end: at(28, 11), providers: 3, observedProviders: 3)
        history.append(start: at(28, 11), end: at(28, 12), providers: 2, observedProviders: 3)
        var details = ActivityDetails()
        details.merge([detail(.claude, "a", "/Users/u/Lunavect", [(at(28, 10), at(28, 11))]),
                       detail(.codex, "b", "/Users/u/Lunavect", [(at(28, 10).addingTimeInterval(1800), at(28, 12))])], now: now)
        var archive = ActivityArchive()
        archive.refresh(history: history, details: details, now: now, calendar: calendar)
        let day = try XCTUnwrap(archive.days["2026-09-28"])
        XCTAssertEqual(day.parts["all"]?.active, 7200)
        XCTAssertEqual(day.parts["claude"]?.active, 3600)
        XCTAssertEqual(day.parts["codex"]?.active, 5400)
        XCTAssertEqual(day.parts["all"]?.hours[10], 3600)
        XCTAssertEqual(day.parts["all"]?.projects["Lunavect"], 7200, "parallel sessions of one project count once")
        XCTAssertEqual(day.sessions["claude:a"]?.seconds, 3600)
        XCTAssertEqual(day.sessions["codex:b"]?.project, "Lunavect")
        XCTAssertNil(archive.days["2026-09-29"], "a day without work is not stored")
    }

    func testRecomputationKeepsWaitingAndNeverTouchesOlderDays() {
        var archive = ActivityArchive()
        archive.days["2026-01-10"] = { var record = ActivityDayRecord(); var part = ActivityDayPart(); part.active = 3600; record.parts["all"] = part; return record }()
        archive.addWaiting(.claude, permission: false, seconds: 120, at: at(29, 9), calendar: calendar)
        archive.addWaiting(.codex, permission: true, seconds: 30, at: at(29, 9), calendar: calendar)
        archive.addWait(.claude, seconds: 120, endedAt: at(29, 9), calendar: calendar)
        archive.addWait(.claude, seconds: 2, endedAt: at(29, 9), calendar: calendar)
        archive.refresh(history: ActivityHistory(), details: ActivityDetails(), now: now, calendar: calendar)
        XCTAssertEqual(archive.days["2026-01-10"]?.parts["all"]?.active, 3600)
        XCTAssertEqual(archive.days["2026-09-29"]?.parts["all"]?.waitingInput, 120)
        XCTAssertEqual(archive.days["2026-09-29"]?.parts["all"]?.waitingPermission, 30)
        XCTAssertEqual(archive.days["2026-09-29"]?.parts["claude"]?.waits, [120], "waits under 5 s are not waits")
    }

    func testOlderLogsFillOnlyMissingDaysBeforeTheBoundary() {
        var result = ActivityImportResult()
        result.intervals = [ActivityInterval(start: at(5, 10, month: 7), end: at(5, 12, month: 7), providers: 1),
                            ActivityInterval(start: at(20, 10, month: 8), end: at(20, 11, month: 8), providers: 1),
                            ActivityInterval(start: at(28, 10), end: at(28, 11), providers: 1)]
        var archive = ActivityArchive()
        archive.days["2026-08-20"] = { var record = ActivityDayRecord(); var part = ActivityDayPart(); part.active = 60; record.parts["all"] = part; return record }()
        archive.fill(from: result, before: at(26, 0, month: 8), calendar: calendar)
        XCTAssertEqual(archive.days["2026-07-05"]?.parts["all"]?.active, 7200)
        XCTAssertEqual(archive.days["2026-07-05"]?.parts["all"]?.recovered, 7200, "recovered time is marked ≈")
        XCTAssertEqual(archive.days["2026-08-20"]?.parts["all"]?.active, 60, "a kept day is never replaced")
        XCTAssertNil(archive.days["2026-09-28"], "days inside the history window come from the history")
    }

    private func archive(days: [(Date, TimeInterval, TimeInterval)]) -> ActivityArchive {
        var archive = ActivityArchive()
        for (date, claude, codex) in days {
            var record = ActivityDayRecord()
            var all = ActivityDayPart(), c = ActivityDayPart(), x = ActivityDayPart()
            c.active = claude; x.active = codex; all.active = max(claude, codex)
            all.hours[calendar.component(.hour, from: date)] = all.active
            all.projects = ["Lunavect": all.active]
            record.parts = ["all": all, "claude": c, "codex": x]
            if claude > 0 { record.sessions["claude:s-\(ActivityArchive.key(date, calendar: calendar))"] = ActivityDaySession(provider: .claude, seconds: claude, project: "Lunavect") }
            archive.days[ActivityArchive.key(date, calendar: calendar)] = record
        }
        return archive
    }

    func testYearIsWeeklyWithUnknownTimeBeforeTheFirstRecord() throws {
        let value = archive(days: [(at(6, 10, month: 7), 3600, 0), (at(2, 11), 7200, 1800), (at(28, 22), 1800, 3600)])
        let summary = ActivityArchiveSummary.make(value, range: .year, providers: [.claude, .codex], now: now, calendar: calendar)
        XCTAssertEqual(summary.bucket, .week)
        XCTAssertEqual(summary.points.count, 53)
        XCTAssertFalse(summary.points.first!.known)
        XCTAssertTrue(summary.points.last!.known)
        XCTAssertEqual(summary.claude, 12600); XCTAssertEqual(summary.codex, 5400); XCTAssertEqual(summary.together, 14400)
        XCTAssertEqual(summary.firstDays[.claude], calendar.startOfDay(for: at(6, 10, month: 7)))
        XCTAssertEqual(summary.firstDays[.codex], calendar.startOfDay(for: at(2, 11)), "Codex's line starts at its own first record")
        XCTAssertEqual(summary.busiest?.together, 7200)
        XCTAssertEqual(summary.peakHour, 11)
        XCTAssertEqual(summary.weekdayHours[0][22], 3600, "Monday 28.09 at 22 with Monday as the first weekday")
        XCTAssertEqual(summary.projects.first?.name, "Lunavect")
        XCTAssertEqual(summary.sessions, 3)
        XCTAssertEqual(summary.longestSession?.seconds, 7200)
        let claude = ActivityArchiveSummary.make(value, range: .year, providers: [.claude], now: now, calendar: calendar)
        XCTAssertEqual(claude.together, 12600, "one source shows its own time"); XCTAssertEqual(claude.codex, 0)
    }

    func testAllTimeAdaptsItsBucketToTheAmountOfHistory() {
        func bucket(_ days: Int) -> StatisticsBucket {
            let first = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!.addingTimeInterval(3600 * 10)
            return ActivityArchiveSummary.make(archive(days: [(first, 3600, 0)]), range: .all, providers: [.claude], now: now, calendar: calendar).bucket
        }
        XCTAssertEqual(bucket(30), .day)
        XCTAssertEqual(bucket(100), .week)
        XCTAssertEqual(bucket(400), .month)
    }

    func testTypicalWaitIsTheMedianAndCalendarCoversFiftyThreeWeeks() {
        var value = archive(days: [(at(29, 10), 3600, 0)])
        for seconds in [30.0, 60, 600] { value.addWait(.claude, seconds: seconds, endedAt: at(29, 11), calendar: calendar) }
        value.addWaiting(.claude, permission: true, seconds: 90, at: at(29, 11), calendar: calendar)
        let summary = ActivityArchiveSummary.make(value, range: .week, providers: [.claude, .codex], now: now, calendar: calendar)
        XCTAssertEqual(summary.typicalWait, 60)
        XCTAssertEqual(summary.waitingPermission, 90)
        let cells = ActivityArchiveSummary.calendarCells(value, providers: [.claude, .codex], now: now, calendar: calendar)
        XCTAssertEqual(cells.count, 53 * 7)
        XCTAssertEqual(cells.first(where: { calendar.isDate($0.date, inSameDayAs: now) })?.seconds, 3600)
        XCTAssertNil(cells.last?.seconds, "days after today are empty cells, not zero")
    }

    /// Owner review 29.09: an empty year before the first record looked broken; the calendar starts at the record's week.
    func testCalendarStartsAtTheWeekOfTheFirstRecord() throws {
        let value = archive(days: [(at(22, 10, month: 7), 3600, 0), (at(29, 10), 1800, 0)])
        let first = calendar.startOfDay(for: at(22, 10, month: 7))
        let cells = ActivityArchiveSummary.calendarCells(value, providers: [.claude, .codex], now: now, since: first, calendar: calendar)
        // Monday 20 July to the week of Tuesday 29 September: 11 weeks.
        XCTAssertEqual(cells.count, 11 * 7)
        XCTAssertEqual(cells.first?.date, calendar.startOfDay(for: at(20, 0, month: 7)))
        XCTAssertEqual(cells.first(where: { calendar.isDate($0.date, inSameDayAs: first) })?.seconds, 3600)
        XCTAssertNil(cells.last?.seconds, "days after today stay empty cells")
        let older = calendar.date(byAdding: .year, value: -2, to: first)!
        XCTAssertEqual(ActivityArchiveSummary.calendarCells(value, providers: [.claude], now: now, since: older, calendar: calendar).count, 53 * 7,
                       "more than a year of records still shows the last 53 weeks")
    }

    /// Owner report 29.09: scrolling stuttered while agents worked; a live checkpoint recomputed
    /// the whole month (about 40 ms). A live refresh recomputes only the last days.
    func testLiveRefreshRecomputesOnlyTheLastDays() throws {
        func history(_ spans: [(Date, Date)]) -> ActivityHistory {
            var value = ActivityHistory()
            for span in spans { value.append(start: span.0, end: span.1, providers: 1, observedProviders: 1) }
            return value
        }
        var value = ActivityArchive()
        value.refresh(history: history([(at(20, 10), at(20, 11)), (at(29, 10), at(29, 11))]), details: ActivityDetails(), now: now, calendar: calendar)
        XCTAssertEqual(value.days["2026-09-20"]?.parts["all"]?.active, 3600)
        // An import later adds an hour on the 20th; the live day gains half an hour.
        let stale = history([(at(20, 10), at(20, 11)), (at(20, 12), at(20, 13)), (at(29, 10), at(29, 11)), (at(29, 12), at(29, 12).addingTimeInterval(1800))])
        value.refresh(history: stale, details: ActivityDetails(), now: now, recentDays: 2, calendar: calendar)
        XCTAssertEqual(value.days["2026-09-29"]?.parts["all"]?.active, 5400, "today follows the history")
        XCTAssertEqual(value.days["2026-09-20"]?.parts["all"]?.active, 3600, "an older day waits for the next full refresh")
        value.refresh(history: stale, details: ActivityDetails(), now: now, calendar: calendar)
        XCTAssertEqual(value.days["2026-09-20"]?.parts["all"]?.active, 7200)
    }

    func testArchiveRoundTripsAndOldPartsDecode() throws {
        let value = archive(days: [(at(29, 10), 3600, 60)])
        XCTAssertEqual(try JSONDecoder().decode(ActivityArchive.self, from: JSONEncoder().encode(value)), value)
        let part = try JSONDecoder().decode(ActivityDayPart.self, from: Data(#"{"active":60}"#.utf8))
        XCTAssertEqual(part.hours.count, 24); XCTAssertEqual(part.waits, [])
    }

    func testPlanEndStatesAndRenewal() throws {
        var preferences = WidgetPreferences()
        XCTAssertTrue(preferences.showPlanEnd, "shown once a date is set")
        XCTAssertTrue(try JSONDecoder().decode(WidgetPreferences.self, from: Data(#"{"showFiveHour":true}"#.utf8)).showPlanEnd)
        XCTAssertNil(PlanEndState.of(preferences, provider: .claude, now: now, calendar: calendar))
        preferences.subscriptionDates["claude"] = "2026-10-18"
        XCTAssertEqual(PlanEndState.of(preferences, provider: .claude, now: now, calendar: calendar), .until(at(18, 0, month: 10)))
        preferences.subscriptionDates["claude"] = "2026-10-02"
        XCTAssertEqual(PlanEndState.of(preferences, provider: .claude, now: now, calendar: calendar), .soon(days: 3, end: at(2, 0, month: 10)))
        preferences.subscriptionDates["claude"] = "2026-09-29"
        XCTAssertEqual(PlanEndState.of(preferences, provider: .claude, now: now, calendar: calendar), .soon(days: 0, end: at(29, 0)))
        preferences.subscriptionDates["claude"] = "2026-09-27"
        XCTAssertEqual(PlanEndState.of(preferences, provider: .claude, now: now, calendar: calendar), .expired(at(27, 0)))
        // Limits observed after the end date: renewed, maybe a day late.
        let week = try QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400))
        let fresh = UsageSnapshot(provider: .claude, weekly: week, fetchedAt: now.addingTimeInterval(-60), source: "Claude Code /usage")
        XCTAssertEqual(PlanRenewal.renewed(preferences, snapshots: [fresh], providers: [.claude], now: now, calendar: calendar), [.claude])
        let before = UsageSnapshot(provider: .claude, weekly: week, fetchedAt: at(27, 20), source: "Claude Code /usage")
        XCTAssertEqual(PlanRenewal.renewed(preferences, snapshots: [before], providers: [.claude], now: at(27, 21), calendar: calendar), [],
                       "not expired yet on its last day")
        var failed = fresh; failed.issue = "signed out"
        XCTAssertEqual(PlanRenewal.renewed(preferences, snapshots: [failed], providers: [.claude], now: now, calendar: calendar), [])
        XCTAssertEqual(PlanRenewal.suggestedEnd(after: at(27, 0), now: now, calendar: calendar), at(27, 0, month: 10))
    }
}
