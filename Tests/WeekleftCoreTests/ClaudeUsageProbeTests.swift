import XCTest
@testable import WeekleftCore

final class ClaudeUsageProbeTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-10T16:00:00Z")!
    private let text = """
    Session
    Total cost: $0.0000
    Current session
    17% 17% used
    Resets 7:39pm (Europe/Vienna)
    Current week (all models)
    31% 31% used
    Resets Sep 13 at 11:59pm (Europe/Vienna)
    +50% weekly limits promo through Sep 13
    Current week (Fable)
    46% 46% used
    Resets Sep 13 at 11:59pm (Europe/Vienna)
    Usage credits
    Usage credits are off
    Esc to cancel
    """
    func testUsageCommandSeparatesAccountWindowsFromModelAndPromoPercentages() throws {
        let result = try ClaudeUsageText.parse(text, now: now)
        XCTAssertEqual(result.weekly?.remaining, 69)
        XCTAssertEqual(result.fiveHour?.remaining, 83)
        XCTAssertEqual(result.modelQuotas?.map(\.name), ["Fable"])
        XCTAssertEqual(result.modelQuotas?.first?.window.remaining, 54)
        XCTAssertEqual(result.modelQuotas?.first?.fetchedAt, now)
        XCTAssertEqual(result.fetchedAt, now)
        XCTAssertEqual(result.source, "Claude Code /usage")
        XCTAssertEqual(result.weekly?.resetsAt, ISO8601DateFormatter().date(from: "2026-09-13T21:59:00Z"))
        XCTAssertEqual(result.fiveHour?.resetsAt, ISO8601DateFormatter().date(from: "2026-09-10T17:39:00Z"))
    }
    func testTerminalEscapesAndPartialRendersCannotInventQuota() throws {
        let ansi = "\u{1b}]0;Claude Code\u{07}\u{1b}[?25h\u{1b}[G" + text.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[3A"
        XCTAssertEqual(try ClaudeUsageText.parse(ansi, now: now).weekly?.remaining, 69)
        XCTAssertThrowsError(try ClaudeUsageText.parse(text.replacingOccurrences(of: "Esc to cancel", with: ""), now: now))
        XCTAssertThrowsError(try ClaudeUsageText.parse(text.replacingOccurrences(of: "31% 31% used", with: "101% used"), now: now))
        XCTAssertThrowsError(try ClaudeUsageText.parse(text.replacingOccurrences(of: "Current week (all models)", with: "Other window"), now: now))
        XCTAssertThrowsError(try ClaudeUsageText.parse("Not logged in. Please run /login", now: now))
    }
    func testMissingFiveHourIsUnknownAndResetUsesExplicitTimezone() throws {
        let withoutFive = text.components(separatedBy: "Current week (all models)").last!
        let result = try ClaudeUsageText.parse("Current week (all models)" + withoutFive, now: now, timeZone: TimeZone(secondsFromGMT: -28800)!)
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(try ClaudeUsageText.parse(text.replacingOccurrences(of: "Resets 7:39pm (Europe/Vienna)", with: ""), now: now).fiveHour)
        XCTAssertEqual(result.weekly?.remaining, 69)
        XCTAssertEqual(result.weekly?.resetsAt, ISO8601DateFormatter().date(from: "2026-09-13T21:59:00Z"))
        XCTAssertThrowsError(try ClaudeUsageText.parse(text.replacingOccurrences(of: "Europe/Vienna", with: "Unknown/Zone"), now: now))
    }
    func testResetRolloverAndAlreadyExpiredWindows() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let newYear = ISO8601DateFormatter().date(from: "2026-12-31T23:00:00Z")!
        XCTAssertEqual(ClaudeUsageText.resetDate("Jan 2 at 12am (UTC)", now: newYear, durationMinutes: 10080, timeZone: utc), ISO8601DateFormatter().date(from: "2027-01-02T00:00:00Z"))
        XCTAssertEqual(ClaudeUsageText.resetDate("1am (UTC)", now: newYear, durationMinutes: 300, timeZone: utc), ISO8601DateFormatter().date(from: "2027-01-01T01:00:00Z"))
        XCTAssertNil(ClaudeUsageText.resetDate("Dec 31 at 10pm (UTC)", now: newYear, durationMinutes: 10080, timeZone: utc))
        XCTAssertNil(ClaudeUsageText.resetDate("10pm (UTC)", now: newYear, durationMinutes: 300, timeZone: utc))
    }
    /// The CLI shows a reset rounded to the minute and may still show it just
    /// after it passed. Keep the elapsed time (displayed as expired) instead of
    /// failing the whole probe or inventing the next day.
    func testJustElapsedResetIsKeptAsExpiredWithoutFailingTheProbe() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-10T15:00:20Z")!
        let elapsed = ISO8601DateFormatter().date(from: "2026-09-10T15:00:00Z")!
        XCTAssertEqual(ClaudeUsageText.resetDate("3pm (UTC)", now: now, durationMinutes: 300, timeZone: utc), elapsed)
        XCTAssertEqual(ClaudeUsageText.resetDate("Sep 10 at 3pm (UTC)", now: now, durationMinutes: 10080, timeZone: utc), elapsed)
        XCTAssertNil(ClaudeUsageText.resetDate("2:57pm (UTC)", now: now, durationMinutes: 300, timeZone: utc), "Only a reset that has just passed")
        let screen = text.replacingOccurrences(of: "Resets 7:39pm (Europe/Vienna)", with: "Resets 3pm (UTC)")
        let result = try ClaudeUsageText.parse(screen, now: now)
        XCTAssertEqual(result.weekly?.remaining, 69)
        XCTAssertEqual(result.fiveHour?.resetsAt, elapsed)
        XCTAssertEqual(result.fiveHour.map { $0.isExpired(at: now) }, true)
        XCTAssertTrue(result.isStale(window: result.fiveHour, now: now), "An elapsed window is never shown as current")
        XCTAssertFalse(result.isStale(window: result.weekly, now: now))
    }
    func testNewestObservationWinsAndOldStatusLineCannotOverwriteUsageProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = root.appendingPathComponent("quota.json"), usage = root.appendingPathComponent("usage.json")
        let result = try ClaudeUsageText.parse(text, now: now)
        try ClaudeProvider.saveUsage(result, destination: usage)
        let old = try UsageParser.claude(["seven_day": ["used_percentage": 84, "resets_at": now.addingTimeInterval(3 * 86400).timeIntervalSince1970]], now: now.addingTimeInterval(-3600))
        try JSONEncoder().encode(old).write(to: status)
        XCTAssertEqual(try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now), result)
        let newer = try UsageParser.claude(["seven_day": ["used_percentage": 86, "resets_at": now.addingTimeInterval(3 * 86400).timeIntervalSince1970]], now: now.addingTimeInterval(30))
        try JSONEncoder().encode(newer).write(to: status)
        let combined = try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(30))
        XCTAssertEqual(combined.weekly, result.weekly)
        XCTAssertEqual(combined.fetchedAt, result.fetchedAt)
        XCTAssertEqual(combined.modelQuotas, result.modelQuotas)
        XCTAssertTrue(try XCTUnwrap(combined.modelQuotas?.first).isStale(now: now.addingTimeInterval(901)))
        XCTAssertEqual(try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(1000)).fetchedAt, newer.fetchedAt)
        XCTAssertNotNil(try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(1000)).issue)
        let withoutModel = text.replacingOccurrences(of: "Current week (Fable)\n46% 46% used\nResets Sep 13 at 11:59pm (Europe/Vienna)\n", with: "")
        try ClaudeProvider.saveUsage(ClaudeUsageText.parse(withoutModel, now: now.addingTimeInterval(40)), destination: usage)
        XCTAssertEqual(try ClaudeProvider.latest(statusLineURL: status, usageURL: usage, now: now.addingTimeInterval(40)).modelQuotas, [])
    }
    func testOptionalModelQuotaDoesNotBreakOtherWindowsOrLegacySnapshots() throws {
        let invalidModel = text.replacingOccurrences(of: "46% 46% used", with: "140% used")
        let parsed = try ClaudeUsageText.parse(invalidModel, now: now)
        XCTAssertEqual(parsed.weekly?.remaining, 69)
        XCTAssertEqual(parsed.modelQuotas, [])
        let old = Data("{\"provider\":\"claude\",\"source\":\"Claude Code /usage\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(UsageSnapshot.self, from: old).modelQuotas)
    }
    func testHungCLIStopsAtDeadlineAndDoesNotLeaveProcessRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cli"), pidFile = root.appendingPathComponent("pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\ntrap '' TERM\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        do { _ = try await ClaudeUsageProbe.fetch(cliPath: executable.path, timeout: 2, directory: root.appendingPathComponent("probe")); XCTFail("A hung command cannot produce quotas") }
        catch { XCTAssertEqual(error as? ClientIntegrationIssue, .init(provider: .claude, capability: .usageProbe, reason: .timedOut)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
    func testLiveUsageCommandWithoutModelRequest() async throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_LIVE_CLAUDE_USAGE"] == "1" else { throw XCTSkip("Opt-in /usage through installed Claude Code") }
        let path = try XCTUnwrap(SessionSources.discoverClaude())
        let result = try await ClaudeUsageProbe.fetch(cliPath: path)
        XCTAssertEqual(result.provider, .claude)
        XCTAssertNotNil(result.weekly)
        XCTAssertFalse(result.isStale())
    }
}
