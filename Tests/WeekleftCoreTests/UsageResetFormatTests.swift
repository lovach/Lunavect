import XCTest
@testable import WeekleftCore

/// Q-11, Q-15, matrix L6/L7: the forms a `/usage` reset line can take. Every case
/// has a fixed `now` and an explicit zone; no client is started. A reset is stored
/// as the end of what the CLI shows (Q-05): minute, day or relative unit.
final class UsageResetFormatTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let vienna = TimeZone(identifier: "Europe/Vienna")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    /// Wednesday 2026-09-23 10:00 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func reset(_ text: String, minutes: Int = 10080, now: Date? = nil, zone: TimeZone? = nil) -> (date: Date, precision: ResetPrecision)? {
        ClaudeUsageText.reset(text, now: now ?? self.now, durationMinutes: minutes, timeZone: zone ?? utc)
    }
    private func weeklyScreen(_ resets: String) -> String {
        "Current week (all models)\n40% used\nResets \(resets)\nEsc to cancel"
    }

    // MARK: Q-11

    func testDateWithoutTimeIsTheEndOfThatDayWithinTheWindow() throws {
        let shown = try XCTUnwrap(reset("Sep 28"))
        XCTAssertEqual(shown.date, date("2026-09-29T00:00:00Z"), "Sep 28 ends at midnight")
        XCTAssertEqual(shown.precision, .day)
        // A weekly window observed on Sep 21 cannot run past Sep 28 10:00.
        XCTAssertEqual(reset("Sep 28", now: date("2026-09-21T10:00:00Z"))?.date, date("2026-09-28T10:00:00Z"))
        XCTAssertEqual(try ClaudeUsageText.parse(weeklyScreen("Sep 28"), now: now, timeZone: utc).weekly?.resetsAt,
                       date("2026-09-29T00:00:00Z"))
        XCTAssertNil(reset("Sep 31"), "No such day")
        XCTAssertNil(reset("Sep 14"), "A day that has passed")
    }

    func testTwelveHourTimeWithASpaceAndCapitalMeridiem() throws {
        for text in ["Sep 28 at 11:59 PM", "Sep 28 at 11:59 pm", "Sep 28 at 11:59\u{202F}PM", "Sep 28, 11:59pm", "Sep 28 11:59 p.m."] {
            let shown = try XCTUnwrap(reset(text), text)
            XCTAssertEqual(shown.date, date("2026-09-29T00:00:00Z"), text)
            XCTAssertEqual(shown.precision, .minute, text)
        }
        XCTAssertEqual(reset("Sep 28 at 12 AM")?.date, date("2026-09-28T00:01:00Z"))
        XCTAssertNil(reset("Sep 28 at 13:00 PM"))
        XCTAssertNil(reset("Sep 28 at 0:30 am"))
    }

    func testRelativeResetCountsFromNowToTheEndOfItsSmallestUnit() throws {
        let cases: [(String, Int, TimeInterval, ResetPrecision)] = [
            ("in 2h 15m", 300, 2 * 3600 + 16 * 60, .minute),
            ("in 45m", 300, 46 * 60, .minute),
            ("in 3d", 10080, 4 * 86400, .day),
            ("in 1d 4h", 10080, 86400 + 5 * 3600, .hour),
            ("in 2 hours, 5 minutes", 300, 2 * 3600 + 6 * 60, .minute),
            // A five-hour window observed now cannot run past now + 5 hours.
            ("in 5h", 300, 5 * 3600, .hour),
        ]
        for (text, minutes, seconds, precision) in cases {
            let shown = try XCTUnwrap(reset(text, minutes: minutes), text)
            XCTAssertEqual(shown.date, now.addingTimeInterval(seconds), text)
            XCTAssertEqual(shown.precision, precision, text)
        }
        XCTAssertNil(reset("in 8d"), "Beyond the weekly window")
        XCTAssertNil(reset("in 2 fortnights"))
        XCTAssertNil(reset("in"))
        let screen = "Current session\n30% used\nResets in 2h 15m\n" + weeklyScreen("in 3d")
        let parsed = try ClaudeUsageText.parse(screen, now: now, timeZone: utc)
        XCTAssertEqual(parsed.fiveHour?.resetsAt, now.addingTimeInterval(2 * 3600 + 16 * 60))
        XCTAssertEqual(parsed.weekly?.resetsAt, now.addingTimeInterval(4 * 86400))
    }

    func testTodayAndTomorrow() throws {
        XCTAssertEqual(reset("today at 2pm", minutes: 300)?.date, date("2026-09-23T14:01:00Z"))
        XCTAssertEqual(reset("Today at 2:30 PM", minutes: 300)?.date, date("2026-09-23T14:31:00Z"))
        XCTAssertEqual(reset("tomorrow at 9:30am")?.date, date("2026-09-24T09:31:00Z"))
        XCTAssertEqual(reset("tomorrow, 09:30")?.date, date("2026-09-24T09:31:00Z"))
        XCTAssertNil(reset("tomorrow at 9:30am", minutes: 300), "Beyond the five-hour window")
        // "today" is the day in the shown zone: at 01:00 in Vienna it is already Sep 23 there, still Sep 22 in UTC.
        XCTAssertEqual(reset("today at 11pm (Europe/Vienna)", now: date("2026-09-22T23:00:00Z"))?.date, date("2026-09-23T21:01:00Z"))
    }

    func testTwentyFourHourTime() throws {
        XCTAssertEqual(reset("13:30", minutes: 300)?.date, date("2026-09-23T13:31:00Z"))
        XCTAssertEqual(reset("00:15", minutes: 300, now: date("2026-09-23T22:00:00Z"))?.date, date("2026-09-24T00:16:00Z"))
        XCTAssertEqual(reset("Sep 28 at 23:59")?.date, date("2026-09-29T00:00:00Z"))
        XCTAssertEqual(reset("Sep 28, 23:59 (Europe/Vienna)")?.date, date("2026-09-28T22:00:00Z"))
        XCTAssertNil(reset("24:00", minutes: 300))
        XCTAssertNil(reset("13", minutes: 300), "An hour needs minutes or am/pm")
    }

    func testZoneGivenAsAnAbbreviation() throws {
        // The CLI may name the zone by its abbreviation instead of an IANA identifier.
        let vienna = reset("Sep 28 at 11:59pm (Europe/Vienna)")?.date
        XCTAssertEqual(vienna, date("2026-09-28T22:00:00Z"))
        XCTAssertEqual(reset("Sep 28 at 11:59pm (CEST)", zone: newYork)?.date, vienna)
        XCTAssertEqual(reset("3pm (EDT)", minutes: 300, now: date("2026-09-23T16:00:00Z"))?.date, date("2026-09-23T19:01:00Z"))
        XCTAssertEqual(reset("1pm (UTC)", minutes: 300, zone: newYork)?.date, date("2026-09-23T13:01:00Z"))
        XCTAssertEqual(reset("3pm (GMT+2)", minutes: 300)?.date, date("2026-09-23T13:01:00Z"))
        XCTAssertNil(reset("3pm (Mars/Olympus)", minutes: 300), "An unknown zone is not replaced by the device zone")
    }

    func testAnyModelLabelIsAModelQuotaAndNeverTheAccountWindow() throws {
        let screen = """
        Current session
        17% used
        Resets 1:30pm (UTC)
        Current week (all models)
        31% used
        Resets Sep 27 at 11:59pm (UTC)
        Current week (Sonnet only)
        46% used
        Resets Sep 27 at 11:59pm (UTC)
        Current week (Opus 4.1 (beta))
        3% used
        Resets Sep 27 at 11:59pm (UTC)
        Esc to cancel
        """
        let parsed = try ClaudeUsageText.parse(screen, now: now, timeZone: utc)
        XCTAssertEqual(parsed.weekly?.usedPercent, 31)
        XCTAssertEqual(parsed.fiveHour?.usedPercent, 17)
        XCTAssertEqual(parsed.modelQuotas?.map(\.name), ["Sonnet only", "Opus 4.1 (beta)"])
        XCTAssertEqual(parsed.modelQuotas?.map(\.window.usedPercent), [46, 3])
        XCTAssertEqual(parsed.modelQuotas?.first?.window.resetsAt, date("2026-09-28T00:00:00Z"))
    }

    /// Matrix L6: an overage block after the account window is not its reset.
    func testExtraUsageBlockIsNotReadAsTheWeeklyWindow() throws {
        let screen = """
        Current week (all models)
        0% used
        Extra usage
        $4.10 of $20.00 used · 21% used
        Resets Oct 1
        Esc to cancel
        """
        let parsed = try ClaudeUsageText.parse(screen, now: now, timeZone: utc)
        XCTAssertEqual(parsed.weekly, try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil),
                       "The unstarted weekly window keeps no reset of another block")
    }

    func testResetOnThePercentageLine() throws {
        let parsed = try ClaudeUsageText.parse("Current week (all models)\n40% used · Resets Sep 28 at 11:59pm (UTC)\nEsc to cancel", now: now, timeZone: utc)
        XCTAssertEqual(parsed.weekly?.resetsAt, date("2026-09-29T00:00:00Z"))
    }

    // MARK: Q-15 / 01-quota.md §6 п.10: dated resets in daylight-saving changes

    func testDatedResetConsidersBothRepeatedDaylightSavingHours() throws {
        // 2026-10-25 in Vienna: 02:00-03:00 happens twice (CEST 00:00-01:00Z, then CET 01:00-02:00Z).
        let text = "Oct 25 at 2:30am (Europe/Vienna)"
        let second = date("2026-10-25T01:31:00Z")
        XCTAssertEqual(reset(text, minutes: 300, now: date("2026-10-24T23:45:00Z"))?.date, second,
                       "Before either 02:30 the later one is kept: the earlier could announce the reset an hour early")
        XCTAssertEqual(reset(text, minutes: 300, now: date("2026-10-25T00:45:00Z"))?.date, second,
                       "The second 02:30 is still ahead after the first has passed")
        XCTAssertEqual(reset(text, minutes: 300, now: date("2026-10-25T01:31:20Z"))?.date, second, "Just elapsed")
        XCTAssertEqual(reset("Oct 25 at 2:30am", minutes: 10080, now: date("2026-10-20T08:00:00Z"), zone: vienna)?.date, second)
        XCTAssertEqual(reset("2:30am", minutes: 300, now: date("2026-10-24T23:45:00Z"), zone: vienna)?.date, second,
                       "The clock-only form keeps the same rule")
    }

    func testDatedResetRejectsASkippedDaylightSavingHour() throws {
        // 2026-03-29 in Vienna: 02:00-03:00 does not exist.
        let spring = date("2026-03-29T00:30:00Z")
        XCTAssertNil(reset("Mar 29 at 2:30am (Europe/Vienna)", minutes: 300, now: spring), "A nonexistent 02:30 cannot turn into 03:30")
        XCTAssertEqual(reset("Mar 29 at 3:30am (Europe/Vienna)", minutes: 300, now: spring)?.date, date("2026-03-29T01:31:00Z"))
        XCTAssertEqual(reset("Mar 29 at 1:30am (Europe/Vienna)", minutes: 300, now: date("2026-03-28T23:00:00Z"))?.date,
                       date("2026-03-29T00:31:00Z"))
    }

    // MARK: Matrix L7 / 01-quota.md §6 п.11: the device zone changes between probes

    func testExplicitZoneDoesNotDependOnTheDeviceZone() throws {
        let screen = weeklyScreen("Sep 27 at 11:59pm (Europe/Vienna)")
        let inVienna = try ClaudeUsageText.parse(screen, now: now, timeZone: vienna)
        let inNewYork = try ClaudeUsageText.parse(screen, now: now, timeZone: newYork)
        XCTAssertEqual(inVienna.weekly?.resetsAt, inNewYork.weekly?.resetsAt)
        let abbreviated = try ClaudeUsageText.parse(weeklyScreen("Sep 27 at 11:59pm (CEST)"), now: now, timeZone: newYork)
        XCTAssertEqual(abbreviated.weekly?.resetsAt, inVienna.weekly?.resetsAt)
        // Countdowns are computed from the stored instant, not from the zone's wall clock.
        XCTAssertEqual(inNewYork.weekly?.countdown(now: now, language: "en"), inVienna.weekly?.countdown(now: now, language: "en"))
    }

    func testResetWithoutZoneUsesTheZoneOfTheProbe() throws {
        let screen = weeklyScreen("Sep 27 at 11:59pm")
        XCTAssertEqual(try ClaudeUsageText.parse(screen, now: now, timeZone: vienna).weekly?.resetsAt, date("2026-09-27T22:00:00Z"))
        XCTAssertEqual(try ClaudeUsageText.parse(screen, now: now, timeZone: newYork).weekly?.resetsAt, date("2026-09-28T04:00:00Z"))
    }
}
