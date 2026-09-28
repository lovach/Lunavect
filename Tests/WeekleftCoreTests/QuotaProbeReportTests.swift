import XCTest
@testable import WeekleftCore

/// Q-16: `--probe` must show what the /usage probe returns, not only the saved status line.
final class QuotaProbeReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testReportShowsTheRealProbeResultAndItsTypedFailure() async throws {
        let probe = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil), fetchedAt: now, source: ClaudeUsageProbe.source)
        let saved = try UsageParser.claude(["seven_day": ["used_percentage": 56, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]], now: now)
        var probes = 0
        let lines = await QuotaProbeReport.lines(claudeProbe: { probes += 1; return probe }, claudeStatusLine: { saved },
                                                 codex: { throw UsageError.missingCLI })
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(lines.contains { $0.contains("Claude Code /usage") && $0.contains("\"usedPercent\":0") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("Claude Code statusLine") })
        let trust = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .workspaceTrustRequired)
        let failed = await QuotaProbeReport.lines(claudeProbe: { throw trust }, claudeStatusLine: { saved }, codex: { throw UsageError.missingCLI })
        XCTAssertTrue(failed.contains { $0.contains("claude.usageProbe.workspaceTrustRequired") }, failed.joined(separator: "\n"))
    }
}
