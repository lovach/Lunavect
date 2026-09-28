import XCTest
@testable import WeekleftCore

/// Automatic Claude probes follow the window state (01-quota.md §3, variant B):
/// no probe for an exhausted window before its reset, one confirming probe after
/// the reset plus grace, and no fixed five-minute cadence.
final class QuotaRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func probeSnapshot(used: Double, fetchedAt: Date, weeklyReset: Date?) throws -> UsageSnapshot {
        try UsageSnapshot(provider: .claude,
                          weekly: QuotaWindow(usedPercent: used, durationMinutes: 10080, resetsAt: weeklyReset, resetPrecision: .minute),
                          fetchedAt: fetchedAt, source: ClaudeUsageProbe.source)
    }
    private func probes(force: Bool, at date: Date, cached: UsageSnapshot, returning result: UsageSnapshot? = nil,
                        saved: ((UsageSnapshot) -> Void)? = nil) async throws -> Int {
        var count = 0
        _ = try await ClaudeProvider.refresh(force: force, now: date, cached: { cached },
                                             probe: { count += 1; return result ?? cached }, save: { saved?($0) })
        return count
    }

    // 01-quota.md §6 п.1, matrix L2
    func testExhaustedWindowIsNotProbedAutomaticallyBeforeItsReset() async throws {
        let reset = now.addingTimeInterval(2 * 86400)
        let exhausted = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: reset)
        for age in [1200.0, 3 * 3600.0, 30 * 3600.0] {
            let count = try await probes(force: false, at: now.addingTimeInterval(age), cached: exhausted)
            XCTAssertEqual(count, 0, "age \(age): 0% remaining cannot change before the reset")
        }
        let manual = try await probes(force: true, at: now.addingTimeInterval(1200), cached: exhausted)
        XCTAssertEqual(manual, 1, "An explicit refresh may still ask")
    }

    // 01-quota.md §6 п.2
    func testResetPassingLeadsToOneConfirmingProbeAfterGrace() async throws {
        let reset = now.addingTimeInterval(3600)
        let exhausted = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: reset)
        // WP-1b: the stored reset is the end of the minute the CLI showed; the CLI then needs a moment.
        let early = try await probes(force: false, at: reset.addingTimeInterval(29), cached: exhausted)
        XCTAssertEqual(early, 0, "Wait for the grace period after the reset")
        // The new window has not started: the probe reports 0% without a reset.
        let inactive = try probeSnapshot(used: 0, fetchedAt: reset.addingTimeInterval(91), weeklyReset: nil)
        var stored: UsageSnapshot?
        let confirming = try await probes(force: false, at: reset.addingTimeInterval(91), cached: exhausted, returning: inactive, saved: { stored = $0 })
        XCTAssertEqual(confirming, 1)
        XCTAssertEqual(stored, inactive, "An unstarted window is saved as the new observation")
        let run1 = try await probes(force: false, at: reset.addingTimeInterval(120), cached: inactive)
        XCTAssertEqual(run1, 0,
                       "The confirmed observation is current")
    }

    func testStatusLineObservationDoesNotCountAsAVerifiedProbe() async throws {
        let status = try UsageParser.claude(["seven_day": ["used_percentage": 40, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]], now: now)
        let run6 = try await probes(force: false, at: now.addingTimeInterval(10), cached: status)
        XCTAssertEqual(run6, 1,
                       "statusLine carries no server observation time")
        var exhausted = status
        exhausted.weekly = try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let run7 = try await probes(force: false, at: now.addingTimeInterval(10), cached: exhausted)
        XCTAssertEqual(run7, 0,
                       "Usage within a window never decreases, whatever the source")
    }

    // 01-quota.md §6 п.7 (documented payload); matrix L5
    func testDocumentedStatusLinePayloadKeepsBothWindowsAndIgnoresSpendLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("quota.json")
        let received = Date(timeIntervalSince1970: 1_738_420_000)
        // Full JSON schema from code.claude.com/docs/en/statusline (Claude Code 2.1.x).
        let payload = """
        {"cwd":"/current/working/directory","session_id":"abc123","session_name":"my-session",
         "prompt_id":"550e8400-e29b-41d4-a716-446655440000","transcript_path":"/path/to/transcript.jsonl",
         "model":{"id":"claude-opus-5-5","display_name":"Opus"},
         "workspace":{"current_dir":"/current/working/directory","project_dir":"/original/project/directory","added_dirs":[]},
         "version":"2.1.280","output_style":{"name":"default"},
         "cost":{"total_cost_usd":0.01234,"total_duration_ms":45000,"total_api_duration_ms":2300,"total_lines_added":156,"total_lines_removed":23},
         "context_window":{"total_input_tokens":15500,"total_output_tokens":1200,"context_window_size":200000,"used_percentage":8,
           "remaining_percentage":92,"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}},
         "exceeds_200k_tokens":false,"fast_mode":false,"effort":{"level":"high"},"thinking":{"enabled":true},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                        "seven_day":{"used_percentage":41.2,"resets_at":1738857600},
                        "spend_limit":{"used_percentage":162.8,"resets_at":1740787200}},
         "vim":{"mode":"NORMAL"},"agent":{"name":"security-reviewer"}}
        """
        try ClaudeProvider.capture(Data(payload.utf8), destination: destination, now: received)
        let stored = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: destination))
        XCTAssertEqual(stored.weekly?.usedPercent, 41.2)
        XCTAssertEqual(stored.weekly?.resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertEqual(stored.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(stored.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(stored.fetchedAt, received)
        // L5: a later payload without rate_limits (signed out / API key) keeps the saved quota.
        let before = try Data(contentsOf: destination)
        try ClaudeProvider.capture(Data(#"{"session_id":"abc123","cost":{"total_api_duration_ms":9000}}"#.utf8), destination: destination, now: received.addingTimeInterval(60))
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }
}
