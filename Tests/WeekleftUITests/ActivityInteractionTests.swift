import XCTest
import SwiftUI
import WeekleftCore
@testable import Weekleft

final class ActivityInteractionTests: XCTestCase {
    func testDetailedYAxisUsesReadableHoursWithoutExtendingOrCrowdingTheScale() {
        XCTAssertEqual(ActivityPlotGeometry.intermediateYValues(maximum: 14 * 3600, height: 140),
                       [2, 4, 6, 8, 10, 12].map { Double($0) * 3600 })
        for maximum: Double in [60, 600, 3600, 7200, 14 * 3600, 24 * 3600] {
            for height: CGFloat in [60, 100, 140, 220] {
                let ticks = [0.0] + ActivityPlotGeometry.intermediateYValues(maximum: maximum, height: height) + [maximum]
                XCTAssertGreaterThanOrEqual(ticks.count, 3, "Every chart has an intermediate Y mark")
                XCTAssertEqual(ticks, ticks.sorted())
                XCTAssertEqual(Set(ticks).count, ticks.count)
                for pair in zip(ticks, ticks.dropFirst()) {
                    XCTAssertGreaterThanOrEqual((pair.1 - pair.0) / maximum * Double(height - 12), 16)
                }
            }
        }
        XCTAssertTrue(ActivityPlotGeometry.intermediateYValues(maximum: .nan, height: 140).isEmpty)
        for height: CGFloat in [40, 60, 82, 100, 220] {
            XCTAssertEqual(ActivityPlotGeometry.intermediateYValues(maximum: 10 * 3600, height: height, detailed: false), [5 * 3600],
                           "Compact widgets must retain the midpoint label")
        }
    }
    func testWidgetRoutesPreserveEachPeriodAndRejectUnrelatedLinks() throws {
        for period in ActivityPeriod.allCases { XCTAssertEqual(ActivityPeriod.from(widgetURL: period.widgetURL), period) }
        XCTAssertEqual(ActivityPeriod.from(widgetURL: try XCTUnwrap(URL(string: "lunavect://activity"))), .week)
        for link in [
            "https://activity?period=day", "lunavect://settings?period=month", "lunavect://activity?period=year",
            "lunavect://activity?period=day&period=month", "lunavect://activity/other?period=day",
        ] {
            XCTAssertNil(ActivityPeriod.from(widgetURL: try XCTUnwrap(URL(string: link))), link)
        }
    }
    func testSelectionKeepsMissingDaysSelectableAndClampsAtPlotEdges() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000), today = calendar.startOfDay(for: now)
        var history = ActivityHistory()
        history.append(start: today.addingTimeInterval(-6 * 86400), end: today.addingTimeInterval(-6 * 86400 + 600), providers: 1)
        history.append(start: today, end: today.addingTimeInterval(600), providers: 2)
        let summary = history.summary(now: now, calendar: calendar)
        let middle = try XCTUnwrap(ActivityChartSelection.index(at: 172, width: 344, count: summary.points.count))
        XCTAssertEqual(middle, 3)
        XCTAssertEqual(summary.points[middle].totals.observed, 0, "Hover must report no data, not snap to a nearby recorded day")
        XCTAssertEqual(ActivityChartSelection.index(at: -50, width: 344, count: 7), 0)
        XCTAssertEqual(ActivityChartSelection.index(at: 400, width: 344, count: 7), 6)
        XCTAssertNil(ActivityChartSelection.index(at: 100, width: 0, count: 7))
        XCTAssertNil(ActivityChartSelection.index(at: 100, width: 344, count: 0))
    }
    func testRepeatedDSTHourCanBeSelectedIndependently() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23)))
        let summary = ActivityHistory().summary(now: now, calendar: calendar, period: .day)
        XCTAssertEqual(summary.points.count, 25)
        let repeated = summary.points.indices.filter { calendar.component(.hour, from: summary.points[$0].date) == 2 }
        XCTAssertEqual(repeated.count, 2)
        for i in repeated {
            XCTAssertEqual(ActivityChartSelection.index(at: ActivityChartSelection.x(for: i, width: 554, count: 25), width: 554, count: 25), i)
        }
        XCTAssertEqual(summary.points[repeated[1]].date.timeIntervalSince(summary.points[repeated[0]].date), 3600)
        XCTAssertNotEqual(ActivityDetailChart.pointLabel(summary.points[repeated[0]].date, period: .day, calendar: calendar),
                          ActivityDetailChart.pointLabel(summary.points[repeated[1]].date, period: .day, calendar: calendar))
    }
    func testCleanContourConnectsOnlyKnownPointsAndPreservesTimePositions() {
        let values: [Double?] = [nil, 0, 10, nil, nil, 40, 45, nil]
        let path = ActivityTrendShape(values: values, maximum: 60, connectsKnownPoints: true)
            .path(in: CGRect(x: 0, y: 0, width: 320, height: 132))
        var moves: [CGPoint] = [], ends: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let point): moves.append(point)
            case .curve(let end, let first, let second):
                ends.append(end)
                for point in [end, first, second] {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertTrue((36...126).contains(point.y), "No invented extrema")
                }
            case .closeSubpath: XCTFail("A contour must not create a filled area")
            default: break
            }
        }
        XCTAssertEqual(moves, [CGPoint(x: 60, y: 126)], "Leading unknown time is not extended; recorded zero is preserved")
        XCTAssertEqual(ends.map(\.x), [100, 220, 260], "Each known value keeps its actual time position, including across gaps")
        XCTAssertEqual(ends.last?.y, 36)
        XCTAssertNil(values[3], "Connecting a display path never fills missing records")
        XCTAssertTrue(ActivityTrendShape(values: [nil, .nan, nil], maximum: 60, connectsKnownPoints: true)
            .path(in: CGRect(x: 0, y: 0, width: 320, height: 132)).isEmpty)
    }
    func testSmoothLinesStayInBoundsAndBreakAtMissingData() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let path = ActivityTrendShape(values: [0, 10, 4, nil, 2, 9, 0], maximum: 10).path(in: rect)
        var moves = 0
        path.forEach { element in
            switch element {
            case .move: moves += 1
            case .curve(let end, let first, let second):
                for point in [end, first, second] {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertGreaterThanOrEqual(point.y, 6)
                    XCTAssertLessThanOrEqual(point.y, 94)
                }
            default: break
            }
        }
        XCTAssertEqual(moves, 2, "A missing day must split the curve")
        XCTAssertTrue(ActivityTrendShape(values: [nil, nil], maximum: 60).path(in: rect).isEmpty)
        let area = ActivityTrendArea(values: [0, 10, 4, nil, 2, 9, 0], maximum: 10).path(in: rect)
        var closedAreas = 0
        area.forEach { if case .closeSubpath = $0 { closedAreas += 1 } }
        XCTAssertEqual(closedAreas, 2, "The soft fill must preserve the same gap as its line")
        XCTAssertTrue(ActivityTrendArea(values: [nil, 10, nil], maximum: 10).path(in: rect).isEmpty, "An isolated point must not invent a filled interval")
    }

}
