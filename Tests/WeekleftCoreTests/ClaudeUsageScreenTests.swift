import XCTest
@testable import WeekleftCore

/// Screens of `/usage` that are not a normal subscription quota: they must end the
/// probe quickly with a reason the user can act on, never after the 25 s deadline.
final class ClaudeUsageScreenTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-28T08:00:00Z")!
    /// After a weekly reset the CLI keeps each block but has no reset time until
    /// the first request starts the new window (CLI cache: utilization 0, resets_at null).
    private let inactiveScreen = """
    Settings  Status   Config   Usage   Stats
    Current session
    0% used
    Current week (all models)
    0% used
    Current week (Fable)
    0% used
    Esc to cancel
    """

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-screen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A stand-in for Claude Code: prints one screen into the PTY and then waits,
    /// like the interactive CLI, ignoring SIGTERM. No real client is started.
    private func probe(printing screen: String, timeout: TimeInterval = 8) async throws -> (error: Error?, elapsed: TimeInterval) {
        let root = try temporaryDirectory()
        let screenFile = root.appendingPathComponent("screen"), pidFile = root.appendingPathComponent("pid")
        let executable = root.appendingPathComponent("cli")
        try Data(screen.utf8).write(to: screenFile)
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\n/bin/cat '\(screenFile.path)'\ntrap '' TERM\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        var failure: Error?
        do { _ = try await ClaudeUsageProbe.fetch(cliPath: executable.path, timeout: timeout, directory: root.appendingPathComponent("probe")) }
        catch { failure = error }
        let elapsed = Date().timeIntervalSince(started)
        if let pid = Int32((try? String(contentsOf: pidFile))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            XCTAssertEqual(kill(pid, 0), -1, "The probe must not leave the client running")
        }
        return (failure, elapsed)
    }

    // MARK: Q-03: an inactive window is data, not a parse failure

    func testInactiveWindowsAreZeroObservationsWithoutInventedReset() throws {
        let result = try ClaudeUsageText.parse(inactiveScreen, now: now)
        XCTAssertEqual(result.weekly?.usedPercent, 0)
        XCTAssertNil(result.weekly?.resetsAt)
        XCTAssertEqual(result.fiveHour?.usedPercent, 0)
        XCTAssertNil(result.fiveHour?.resetsAt)
        XCTAssertEqual(result.modelQuotas?.map(\.name), ["Fable"])
        XCTAssertTrue(ClaudeProvider.isTrustedSnapshot(result))
        let root = try temporaryDirectory()
        let usage = root.appendingPathComponent("usage.json")
        try ClaudeProvider.saveUsage(result, destination: usage)
        let stored = try ClaudeProvider.latest(statusLineURL: root.appendingPathComponent("missing.json"), usageURL: usage, now: now)
        XCTAssertEqual(stored.weekly, result.weekly)
        XCTAssertFalse(stored.isStale(window: stored.weekly, now: now))
    }

    func testUsedWindowWithoutResetIsNotMistakenForInactive() {
        let used = inactiveScreen.replacingOccurrences(of: "Current week (all models)\n0% used", with: "Current week (all models)\n41% used")
        XCTAssertThrowsError(try ClaudeUsageText.parse(used, now: now), "Only a confirmed 0% may lack a reset time")
        let session = inactiveScreen.replacingOccurrences(of: "Current session\n0% used", with: "Current session\n12% used")
        XCTAssertNil(try ClaudeUsageText.parse(session, now: now).fiveHour, "An optional used window without reset stays unknown")
    }

    // MARK: Q-02 / Q-04: finish shortly after the screen stops changing

    func testCompleteUnknownScreenEndsShortlyAfterItStopsChanging() async throws {
        let result = try await probe(printing: "Settings  Status   Config   Usage   Stats\nSomething the parser does not know\nEsc to cancel\n")
        XCTAssertEqual((result.error as? ClientIntegrationIssue)?.reason, .unsupportedResponse)
        XCTAssertLessThan(result.elapsed, 6, "A fully drawn screen must not keep the client alive until the deadline")
    }

    func testKnownUsageStatesEndEarlyWithTheirOwnReason() async throws {
        let cases: [(String, ClientIntegrationIssue.Reason)] = [
            ("Current week (all models)\nFailed to load usage data\nEsc to cancel\n", .usageFetchFailed),
            ("Could not refresh usage data\nEsc to cancel\n", .usageFetchFailed),
            ("Usage limit reached · resets at 11:59pm\nEsc to cancel\n", .limitReached),
            ("You've hit your weekly limit\nEsc to cancel\n", .limitReached),
            // No footer: the state line alone is conclusive once output settles.
            ("Failed to load usage data\n", .usageFetchFailed),
            ("Current week (all models)\n\nEsc to cancel\n", .windowInactive),
        ]
        for (screen, reason) in cases {
            let result = try await probe(printing: screen)
            let issue = result.error as? ClientIntegrationIssue
            XCTAssertEqual(issue?.reason, reason, screen)
            XCTAssertEqual(issue?.repair, .refresh, screen)
            XCTAssertLessThan(result.elapsed, 6, screen)
        }
    }

    func testSignInScreenStillAsksToFinishClaudeSetup() async throws {
        let result = try await probe(printing: "Not logged in · Please run /login\n")
        XCTAssertEqual(result.error as? UsageError, .claudeSignInRequired)
        XCTAssertLessThan(result.elapsed, 6)
    }

    // MARK: Q-19: workspace trust (real 2.1.280 capture)

    func testUntrustedProbeFolderAsksForTrustInsteadOfSignIn() async throws {
        let result = try await probe(printing: ClaudeUsageScreenFixtures.untrustedFolder)
        let issue = result.error as? ClientIntegrationIssue
        XCTAssertEqual(issue?.reason, .workspaceTrustRequired)
        XCTAssertEqual(issue?.repair, .reviewUsage, "Repair opens the probe folder in Terminal; the user answers once")
        XCTAssertLessThan(result.elapsed, 6)
        XCTAssertNotEqual(result.error as? UsageError, .claudeSignInRequired)
    }

    func testTrustRepairLauncherRunsUsageInTheProbeFolderWithoutAnsweringForTheUser() throws {
        let script = try ClientConnection.script(provider: .claude, action: .reviewUsage, executable: "/opt/fixture/bin/claude",
                                                 heading: "Heading", completion: "Done", environment: [:])
        XCTAssertTrue(script.contains("cd " + SessionHooks.quote(ClaudeUsageProbe.directory.path)))
        XCTAssertTrue(script.contains("/usage"))
        XCTAssertFalse(script.contains("yes"), "The trust question is the user's decision")
        XCTAssertFalse(script.contains("printf 'y"))
    }

    // MARK: Q-20: API billing / no subscription sign-in (real 2.1.280 capture)

    func testAPIBillingScreenReportsMissingSubscriptionLimitsQuickly() async throws {
        let result = try await probe(printing: ClaudeUsageScreenFixtures.apiBilling)
        let issue = result.error as? ClientIntegrationIssue
        XCTAssertEqual(issue?.reason, .subscriptionUnavailable)
        XCTAssertEqual(issue?.repair, .signIn)
        XCTAssertLessThan(result.elapsed, 6)
    }

    func testCapturedScreensNeverBecomeQuota() {
        for screen in [ClaudeUsageScreenFixtures.apiBilling, ClaudeUsageScreenFixtures.untrustedFolder] {
            XCTAssertThrowsError(try ClaudeUsageText.parse(screen, now: now))
        }
    }

    func testRealSubscriptionScreenFixture() throws {
        // TODO(real-subscription-capture): see ClaudeUsageScreenFixtures.subscription.
        guard let screen = ClaudeUsageScreenFixtures.subscription else {
            throw XCTSkip("No real subscription /usage capture yet (owner's manual step)")
        }
        let result = try ClaudeUsageText.parse(screen, now: now)
        XCTAssertNotNil(result.weekly)
    }

    // MARK: Typed reason survives on the saved quota and in diagnostics

    func testTrustFailureKeepsSavedQuotaAndOffersTheTerminalRepair() async throws {
        let saved = try UsageSnapshot(provider: .claude,
            weekly: QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now.addingTimeInterval(-3600), source: ClaudeUsageProbe.source)
        let trust = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .workspaceTrustRequired)
        let result = try await ClaudeProvider.refresh(force: true, now: now, cached: { saved }, probe: { throw trust }, save: { _ in })
        XCTAssertEqual(result.weekly, saved.weekly)
        XCTAssertEqual(result.fetchedAt, saved.fetchedAt)
        XCTAssertEqual(result.issue, trust.message)
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                              snapshot: result, sessionIssue: nil, now: now)
        XCTAssertEqual(diagnostic.repair, .reviewUsage)
        XCTAssertEqual(diagnostic.errorCode, trust.code)
    }

    // MARK: Q-16: opt-in screen dump for a failed probe

    func testFailedScreenIsSavedOnlyWhenOptedIn() async throws {
        let dump = try temporaryDirectory().appendingPathComponent("dump")
        setenv("LUNAVECT_PROBE_DUMP_DIR", dump.path, 1)
        defer { unsetenv("LUNAVECT_PROBE_DUMP_DIR") }
        _ = try await probe(printing: "\u{1B}[GSomething the parser does not know\r\nEsc to cancel\n")
        let files = (try? FileManager.default.contentsOfDirectory(at: dump, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.contains("Something the parser does not know"))
        XCTAssertFalse(text.contains("\u{1B}"), "Only the plain screen text is kept")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o077, 0)
        unsetenv("LUNAVECT_PROBE_DUMP_DIR")
        _ = try await probe(printing: "Another unknown screen\nEsc to cancel\n")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dump.path))?.count, 1, "Nothing is written without the opt-in")
    }
}
