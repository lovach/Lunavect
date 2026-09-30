import XCTest
@testable import WeekleftCore

/// Automatic requests follow the window state (01-quota.md §3, variant B): an
/// exhausted window is asked about before its reset only for a manual reset (Claude
/// after session activity, at most hourly; Codex hourly), one confirming probe after
/// the reset plus grace, backoff after failures and no fixed five-minute cadence.
/// The app asks `QuotaRefreshPolicy` before every automatic request; these tests
/// use the policy exactly as `AppStore` does (R1-13).
final class QuotaRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let automatic: [QuotaRefreshPolicy.Trigger] = [.launch, .timer, .sessionEvent, .wake, .networkRestored, .resetDue]
    private func probeSnapshot(used: Double, fetchedAt: Date, weeklyReset: Date?, fiveHour: QuotaWindow? = nil) throws -> UsageSnapshot {
        try UsageSnapshot(provider: .claude,
                          weekly: QuotaWindow(usedPercent: used, durationMinutes: 10080, resetsAt: weeklyReset, resetPrecision: .minute),
                          fiveHour: fiveHour, fetchedAt: fetchedAt, source: ClaudeUsageProbe.source)
    }
    private func due(_ policy: QuotaRefreshPolicy, _ snapshot: UsageSnapshot?, at date: Date,
                     provider: ProviderID = .claude) -> [QuotaRefreshPolicy.Trigger] {
        automatic.filter { policy.shouldFetch(provider, snapshot: snapshot, trigger: $0, now: date) }
    }

    // 01-quota.md §6 п.1, matrix L2; owner report 30.09: the Claude app offers a manual limit reset too.
    func testExhaustedClaudeWindowIsAskedAboutOnlyAfterSessionActivity() throws {
        let reset = now.addingTimeInterval(2 * 86400)
        let exhausted = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: reset)
        let policy = QuotaRefreshPolicy()
        XCTAssertEqual(due(policy, exhausted, at: now.addingTimeInterval(1200)), [], "not within the hour, whatever the trigger")
        for age in [3600.0, 3 * 3600.0, 30 * 3600.0] {
            XCTAssertEqual(due(policy, exhausted, at: now.addingTimeInterval(age)), [.sessionEvent],
                           "age \(age): no timer probe (R1-01); activity may follow a manual reset")
        }
        XCTAssertTrue(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .manual, now: now.addingTimeInterval(1200)),
                      "An explicit refresh may still ask")
    }

    /// Owner report 30.09: after a Codex usage-limit reset the widget kept 0 % for three days.
    /// Codex's rate-limit read answers while a window is used up, so it is asked hourly and after activity.
    func testUsedUpCodexWindowIsAskedAboutHourly() throws {
        let exhausted = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                                          fetchedAt: now, source: "Codex CLI")
        let policy = QuotaRefreshPolicy()
        XCTAssertEqual(due(policy, exhausted, at: now.addingTimeInterval(60), provider: .codex), [], "not right after the reading")
        XCTAssertEqual(due(policy, exhausted, at: now.addingTimeInterval(1200), provider: .codex), [.sessionEvent], "within the hour only session activity")
        XCTAssertEqual(due(policy, exhausted, at: now.addingTimeInterval(3600), provider: .codex).count, automatic.count, "then hourly")
    }

    /// R1-01: while one window is used up the other window's passed reset brings no
    /// probe of its own (owner: "when limits are exhausted the probe keeps appearing").
    /// Only session activity asks, at most hourly; both are confirmed together after
    /// the exhausted window's own reset.
    func testExhaustedWindowOutranksTheOtherWindowsPassedReset() throws {
        let weeklyReset = now.addingTimeInterval(3 * 86400), fiveReset = now.addingTimeInterval(2 * 3600)
        let week = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: weeklyReset,
            fiveHour: QuotaWindow(usedPercent: 60, durationMinutes: 300, resetsAt: fiveReset, resetPrecision: .minute))
        var policy = QuotaRefreshPolicy()
        for offset: TimeInterval in [30, 3600, 86400, 2 * 86400] {
            XCTAssertEqual(due(policy, week, at: fiveReset.addingTimeInterval(offset)), [.sessionEvent], "five-hour reset + \(offset) s")
        }
        policy.record(.claude, snapshot: week, succeeded: false, reason: .unsupportedResponse, at: fiveReset.addingTimeInterval(60))
        policy.resetBackoff()
        XCTAssertEqual(due(policy, week, at: fiveReset.addingTimeInterval(7200)), [.sessionEvent], "An unreadable screen does not lift the exhausted week")
        XCTAssertEqual(due(policy, week, at: weeklyReset.addingTimeInterval(30)).count, automatic.count)
        // The same for a used-up five-hour window and a passed weekly reset.
        let session = try probeSnapshot(used: 40, fetchedAt: now, weeklyReset: now.addingTimeInterval(3600),
            fiveHour: QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: fiveReset, resetPrecision: .minute))
        XCTAssertEqual(due(QuotaRefreshPolicy(), session, at: now.addingTimeInterval(3540)), [])
        XCTAssertEqual(due(QuotaRefreshPolicy(), session, at: now.addingTimeInterval(3630)), [.sessionEvent])
        XCTAssertEqual(due(QuotaRefreshPolicy(), session, at: fiveReset.addingTimeInterval(30)).count, automatic.count)
    }

    // 01-quota.md §6 п.2
    func testResetPassingLeadsToOneConfirmingProbeAfterGrace() throws {
        let reset = now.addingTimeInterval(3600)
        let exhausted = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: reset)
        var policy = QuotaRefreshPolicy()
        // WP-1b: the stored reset is the end of the minute the CLI showed; the CLI then needs a moment.
        XCTAssertEqual(due(policy, exhausted, at: reset.addingTimeInterval(29)), [], "Wait for the grace period after the reset")
        XCTAssertTrue(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .resetDue, now: reset.addingTimeInterval(30)))
        // The new window has not started: the probe reports 0% without a reset.
        let inactive = try probeSnapshot(used: 0, fetchedAt: reset.addingTimeInterval(31), weeklyReset: nil)
        policy.record(.claude, snapshot: inactive, succeeded: true, at: reset.addingTimeInterval(31))
        XCTAssertEqual(due(policy, inactive, at: reset.addingTimeInterval(120)), [], "The confirmed observation is current")
    }

    func testStatusLineObservationDoesNotCountAsAVerifiedProbe() throws {
        let status = try UsageParser.claude(["seven_day": ["used_percentage": 40, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]], now: now)
        XCTAssertTrue(QuotaRefreshPolicy().shouldFetch(.claude, snapshot: status, trigger: .timer, now: now.addingTimeInterval(10)),
                      "statusLine carries no server observation time")
        var exhausted = status
        exhausted.weekly = try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        XCTAssertEqual(due(QuotaRefreshPolicy(), exhausted, at: now.addingTimeInterval(10)), [],
                       "Usage within a window never decreases, whatever the source")
    }

    /// R1-02: Claude reports the limit as reached. Automatic requests wait for the
    /// earliest known reset; without a known reset they wait for the longest backoff
    /// step. Wake does not shorten the pause; session activity may ask after an hour,
    /// since a manual reset lifts the limit early (owner report 30.09).
    func testLimitReachedPausesUntilTheEarliestKnownReset() throws {
        let weeklyReset = now.addingTimeInterval(3 * 86400), fiveReset = now.addingTimeInterval(2 * 3600)
        var saved = try probeSnapshot(used: 92, fetchedAt: now.addingTimeInterval(-7200), weeklyReset: weeklyReset,
            fiveHour: QuotaWindow(usedPercent: 40, durationMinutes: 300, resetsAt: fiveReset, resetPrecision: .minute))
        saved.issue = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .limitReached).message
        var policy = QuotaRefreshPolicy()
        policy.record(.claude, snapshot: saved, succeeded: false, reason: .limitReached, at: now)
        policy.resetBackoff()
        for offset in [300.0, 3599] {
            XCTAssertEqual(due(policy, saved, at: now.addingTimeInterval(offset)), [], "\(offset)")
        }
        XCTAssertEqual(due(policy, saved, at: now.addingTimeInterval(3600)), [.sessionEvent], "a manual reset may have lifted it")
        XCTAssertEqual(due(policy, saved, at: fiveReset.addingTimeInterval(29)), [], "the grace after the five-hour reset")
        XCTAssertTrue(policy.shouldFetch(.claude, snapshot: saved, trigger: .manual, now: now.addingTimeInterval(60)))
        XCTAssertFalse(due(policy, saved, at: fiveReset.addingTimeInterval(30)).isEmpty, "The five-hour reset may lift the limit")
        XCTAssertEqual(policy.nextCheck([saved], now: now), fiveReset.addingTimeInterval(30))

        var unknown = QuotaRefreshPolicy()
        unknown.record(.claude, snapshot: nil, succeeded: false, reason: .limitReached, at: now)
        unknown.resetBackoff()
        XCTAssertEqual(due(unknown, nil, at: now.addingTimeInterval(3599)), [], "No known reset: the longest backoff step")
        XCTAssertFalse(due(unknown, nil, at: now.addingTimeInterval(3600)).isEmpty)
    }

    /// R1-03: wake and a restored network may remove a transient cause (network,
    /// timeout, the client's own usage request), never one only the user changes.
    func testWakeRestartsTheBackoffOnlyForTransientCauses() throws {
        let stale = try probeSnapshot(used: 40, fetchedAt: now.addingTimeInterval(-7200), weeklyReset: now.addingTimeInterval(86400))
        let transient: [ClientIntegrationIssue.Reason?] = [nil, .timedOut, .usageFetchFailed, .sourceUnavailable]
        let permanent: [ClientIntegrationIssue.Reason] = [.workspaceTrustRequired, .setupRequired, .signInRequired,
            .subscriptionUnavailable, .unsupportedResponse, .missingClient, .clientPathUnavailable]
        for reason in transient {
            var policy = QuotaRefreshPolicy()
            policy.record(.claude, snapshot: stale, succeeded: false, reason: reason, at: now)
            XCTAssertFalse(policy.shouldFetch(.claude, snapshot: stale, trigger: .wake, now: now.addingTimeInterval(60)))
            policy.resetBackoff()
            XCTAssertTrue(policy.shouldFetch(.claude, snapshot: stale, trigger: .wake, now: now.addingTimeInterval(60)), "\(String(describing: reason))")
        }
        for reason in permanent {
            var policy = QuotaRefreshPolicy()
            policy.record(.claude, snapshot: stale, succeeded: false, reason: reason, at: now)
            policy.resetBackoff()
            XCTAssertFalse(policy.shouldFetch(.claude, snapshot: stale, trigger: .wake, now: now.addingTimeInterval(60)), "\(reason)")
            XCTAssertTrue(policy.shouldFetch(.claude, snapshot: stale, trigger: .timer, now: now.addingTimeInterval(300)), "\(reason)")
            XCTAssertTrue(policy.shouldFetch(.claude, snapshot: stale, trigger: .manual, now: now.addingTimeInterval(60)), "\(reason)")
        }
    }

    /// R1-04: an answer that still reports the reset that has just passed is the
    /// previous window, not the first data of the new one.
    func testAnswerThatStillShowsThePassedResetIsNotAConfirmation() throws {
        let reset = now.addingTimeInterval(3600)
        let exhausted = try probeSnapshot(used: 100, fetchedAt: now, weeklyReset: reset)
        var policy = QuotaRefreshPolicy()
        let confirming = reset.addingTimeInterval(30)
        XCTAssertTrue(policy.shouldFetch(.claude, snapshot: exhausted, trigger: .resetDue, now: confirming))
        let previous = try probeSnapshot(used: 100, fetchedAt: confirming, weeklyReset: reset)
        policy.record(.claude, snapshot: previous, succeeded: true, at: confirming)
        XCTAssertEqual(previous.status(of: previous.weekly, now: confirming), .resetPassed(reset))
        XCTAssertEqual(due(policy, previous, at: confirming.addingTimeInterval(299)), [])
        XCTAssertEqual(policy.nextCheck([previous], now: confirming), confirming.addingTimeInterval(300), "The next confirmation after the first backoff step")
        XCTAssertFalse(due(policy, previous, at: confirming.addingTimeInterval(300)).isEmpty)
        let current = try probeSnapshot(used: 0, fetchedAt: confirming.addingTimeInterval(300), weeklyReset: nil)
        policy.record(.claude, snapshot: current, succeeded: true, at: confirming.addingTimeInterval(300))
        XCTAssertFalse(policy.shouldFetch(.claude, snapshot: current, trigger: .timer, now: confirming.addingTimeInterval(600)))
        XCTAssertNil(policy.nextCheck([current], now: confirming.addingTimeInterval(600)))
    }

    /// R1-05, R1-06: an answer without any known window and without an explicit
    /// "unlimited" is unknown data and backs off like a failure; an explicit
    /// "unlimited" is a verified observation reused for the idle interval.
    func testAnswerWithoutAKnownWindowBacksOffAndUnlimitedIsReused() throws {
        let empty = UsageSnapshot(provider: .codex, fetchedAt: now, source: "Codex CLI")
        var policy = QuotaRefreshPolicy()
        policy.record(.codex, snapshot: empty, succeeded: true, at: now)
        XCTAssertEqual(due(policy, empty, at: now.addingTimeInterval(299), provider: .codex), [])
        XCTAssertFalse(due(policy, empty, at: now.addingTimeInterval(300), provider: .codex).isEmpty)
        policy.record(.codex, snapshot: empty, succeeded: true, at: now.addingTimeInterval(300))
        XCTAssertEqual(due(policy, empty, at: now.addingTimeInterval(899), provider: .codex), [], "Second step: 10 minutes")

        let unlimited = UsageSnapshot(provider: .codex, fetchedAt: now, source: "Codex CLI", unlimited: true)
        var known = QuotaRefreshPolicy()
        known.record(.codex, snapshot: unlimited, succeeded: true, at: now)
        XCTAssertFalse(known.shouldFetch(.codex, snapshot: unlimited, trigger: .timer, now: now.addingTimeInterval(3599)))
        XCTAssertTrue(known.shouldFetch(.codex, snapshot: unlimited, trigger: .timer, now: now.addingTimeInterval(3600)))
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
