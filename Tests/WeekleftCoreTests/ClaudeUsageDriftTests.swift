import XCTest
@testable import WeekleftCore

/// R2 (Q-I8, matrix L1): changes of the `/usage` screen that do not change what it
/// says. The relations follow from the contract — a block is read by its own label,
/// presentation does not carry meaning, blocks Lunavect does not know leave the
/// known windows alone — not from a guessed future format. Fixed `now` and zone.
final class ClaudeUsageDriftTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// Wednesday 2026-09-23 10:00 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!
    private let session = ["Current session", "17% used", "Resets 1:30pm (UTC)"]
    private let week = ["Current week (all models)", "31% used", "Resets Sep 27 at 11:59pm (UTC)"]
    private let model = ["Current week (Sonnet only)", "46% used", "Resets Sep 27 at 11:59pm (UTC)"]
    private func screen(_ lines: [String]) -> String { (["Settings  Status   Config   Usage   Stats"] + lines + ["Esc to cancel"]).joined(separator: "\n") }
    private func parse(_ text: String) throws -> UsageSnapshot { try ClaudeUsageText.parse(text, now: now, timeZone: utc) }

    /// Line endings, indentation, escape sequences, block order and a full redraw
    /// (the last frame is the reading) are presentation.
    func testPresentationDoesNotChangeTheReading() throws {
        let lines = session + week + model
        let expected = try parse(screen(lines))
        XCTAssertEqual(expected.weekly?.usedPercent, 31)
        let variants: [(String, String)] = [
            ("CRLF", screen(lines).replacingOccurrences(of: "\n", with: "\r\n")),
            ("indent", screen(lines.map { "   " + $0 + "  " })),
            ("escapes", screen(lines.map { "\u{1B}[2K\u{1B}[G\u{1B}[1m" + $0 + "\u{1B}[0m" })),
            ("order", screen(week + model + session)),
            ("redraw", screen((session + week + model).map { $0.replacingOccurrences(of: "31%", with: "12%") }) + "\n" + screen(lines)),
        ]
        for (name, text) in variants { XCTAssertEqual(try parse(text), expected, name) }
    }

    /// A block Lunavect does not know, wherever it appears, changes no known window.
    func testUnknownBlocksDoNotChangeKnownWindows() throws {
        let expected = try parse(screen(session + week + model))
        let unknown = [["Daily routines", "5% used", "Resets in 3h"], ["Weekly spend", "$4.10 of $20.00 · 21% used", "Resets Oct 1"]]
        for block in unknown {
            for position in [0, 3, 6, 9] {
                var lines = session + week + model
                lines.insert(contentsOf: block, at: position)
                XCTAssertEqual(try parse(screen(lines)).weekly, expected.weekly, "\(block[0]) at \(position)")
                XCTAssertEqual(try parse(screen(lines)).fiveHour, expected.fiveHour, "\(block[0]) at \(position)")
            }
        }
    }

    /// A block that has not started shows no reset. The reset of a following block
    /// Lunavect does not know is not its reset (Q-I3): the window stays inactive and
    /// the other windows are still read, instead of a false countdown or a failed probe.
    func testNextBlocksResetIsNotLentToAnInactiveWindow() throws {
        let inactiveSession = ["Current session", "0% used"]
        for block in [["Daily routines", "5% used", "Resets in 3h"], ["Weekly spend", "$4.10 of $20.00 · 21% used", "Resets Oct 1"]] {
            let parsed = try parse(screen(inactiveSession + block + week))
            XCTAssertEqual(parsed.fiveHour, try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil), block[0])
            XCTAssertEqual(parsed.weekly?.usedPercent, 31, block[0])
            let inactiveWeek = try parse(screen(session + ["Current week (all models)", "0% used"] + block))
            XCTAssertEqual(inactiveWeek.weekly, try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil), block[0])
            XCTAssertEqual(inactiveWeek.fiveHour?.usedPercent, 17, block[0])
        }
    }

    /// Only "N% used" is usage (Q-I1). A remaining percentage is never read as used:
    /// the window stays unknown rather than inverted.
    func testRemainingPercentageIsNeverReadAsUsed() throws {
        let parsed = try parse(screen(["Current session", "83% left", "Resets 1:30pm (UTC)"] + week))
        XCTAssertNil(parsed.fiveHour)
        XCTAssertEqual(parsed.weekly?.usedPercent, 31)
        XCTAssertThrowsError(try parse(screen(session + ["Current week (all models)", "69% remaining", "Resets Sep 27 at 11:59pm (UTC)"])))
    }
}
