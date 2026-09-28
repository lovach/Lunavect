import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// View models behind widgets and the breakdown, without rendering (matrix W1,
/// W2; audit 04 §4 items 2 and 7).
final class ActivityPresentationModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLimitsCardAtTheResetInstantShowsNoOldPercentage() throws {
        let reset = now.addingTimeInterval(1800)
        let snapshot = UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 60, durationMinutes: 10080, resetsAt: reset),
                                     fetchedAt: now, source: "fixture")
        for date in [reset, reset.addingTimeInterval(1)] {
            let status = widgetQuotaStatus(snapshot, now: date)
            XCTAssertFalse(status.contains("40"), "The expired remaining value is not presented as current")
            XCTAssertFalse(status.isEmpty)
            XCTAssertTrue(snapshot.weekly!.isExpired(at: date))
        }
        XCTAssertTrue(WidgetTimelineSchedule.dates(from: now, snapshots: [snapshot]).contains(reset))
    }

    func testThreeDaysWithoutTheAppMarksLimitsAndActivityStale() throws {
        let fetched = now.addingTimeInterval(-3 * 86400)
        let snapshot = UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 60, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                                     fetchedAt: fetched, source: "fixture")
        XCTAssertTrue(snapshot.isStale(window: snapshot.weekly, now: now))
        XCTAssertFalse(widgetQuotaStatus(snapshot, now: now).isEmpty)
        var history = ActivityHistory()
        history.append(start: fetched.addingTimeInterval(-60), end: fetched, providers: 2, observedProviders: 2)
        let data = ActivityChartData(history: history, now: now, providers: [.codex], staleAfter: ActivityChartData.widgetStaleness)
        XCTAssertTrue(data.stale)
        XCTAssertFalse(data.limited, "Staleness is the only desktop marker")
    }

    func testBreakdownOverlapWithImportedAndLiveSources() throws {
        // Claude observed live for 20 minutes; Codex enabled later and recovered from its logs.
        var history = ActivityHistory()
        _ = history.prepareImport(providers: [.claude], now: now.addingTimeInterval(-1200))
        history.append(start: now.addingTimeInterval(-1200), end: now, providers: 1, observedProviders: 1)
        history.mergeRecovered([ActivityInterval(start: now.addingTimeInterval(-900), end: now.addingTimeInterval(-300), providers: 2)],
                               now: now, limited: false, providers: [.codex])
        let data = ActivityBreakdownData(history: history, details: ActivityDetails(), providers: [.claude, .codex], period: .week,
                                         selectedDate: nil, now: now)
        let totals = data.totals
        XCTAssertEqual(totals.claude, 1200)
        XCTAssertEqual(totals.codex, 600)
        XCTAssertEqual(totals.active, 1200, "Wall time counts the overlap once")
        XCTAssertEqual(totals.claude + totals.codex - totals.active, 600, "The summary's simultaneous time")
        XCTAssertEqual(totals.recovered, 0, "Seconds proven by live Claude are observed, even with recovered Codex")
        let codexOnly = ActivityBreakdownData(history: history, details: ActivityDetails(), providers: [.codex], period: .week, selectedDate: nil, now: now)
        XCTAssertEqual(codexOnly.totals.recovered, 600)
    }
}
