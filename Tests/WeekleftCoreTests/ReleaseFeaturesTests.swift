import XCTest
@testable import WeekleftCore

final class ReleaseFeaturesTests: XCTestCase {
    func testConnectionRouteSkipsOnlyVerifiedCompletedSteps() {
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: false, signIn: .signedIn, configured: true, enabled: true), 0)
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: true, signIn: .unavailable, configured: true, enabled: true), 1)
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: true, signIn: .signedOut, configured: true, enabled: true), 1)
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: true, signIn: .signedIn, configured: false, enabled: true), 2)
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: true, signIn: .signedIn, configured: true, enabled: false), 2)
        XCTAssertEqual(ConnectionSetupRoute.next(clientFound: true, signIn: .signedIn, configured: true, enabled: true), 3)
    }
    func testDiagnosticActionsMatchTheActualMissingStep() throws {
        XCTAssertEqual(diagnostic(try quota(), found: false).repair, .install)
        XCTAssertEqual(diagnostic(try quota(), signIn: .signedOut).repair, .signIn)
        XCTAssertEqual(diagnostic(try quota(), signIn: .unavailable).repair, .checkSignIn)
        XCTAssertEqual(diagnostic(try quota(), hooks: false).repair, .events)
        XCTAssertEqual(diagnostic(try quota(), sessionIssue: "source unavailable").repair, .refresh)
        XCTAssertEqual(diagnostic(try quota(issue: UsageError.timeout.errorDescription)).repair, .refresh)
        XCTAssertEqual(diagnostic(try quota(issue: UsageError.claudeSignInRequired.errorDescription)).repair, .reviewUsage)
        XCTAssertNil(diagnostic(try quota()).repair)
    }
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func quota(at date: Date? = nil, issue: String? = nil) throws -> UsageSnapshot {
        try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 50, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)), fetchedAt: date ?? now, issue: issue)
    }
    func diagnostic(_ snapshot: UsageSnapshot?, found: Bool = true, signIn: ClientConnection.SignInState = .signedIn,
                    hooks: Bool = true, sessionIssue: String? = nil) -> ConnectionDiagnostic {
        ConnectionDiagnostic(provider: .claude, clientFound: found, signIn: signIn, eventsConfigured: hooks, snapshot: snapshot, sessionIssue: sessionIssue, now: now)
    }
    func testCachedLimitsCannotMaskConnectionFailure() throws {
        XCTAssertEqual(diagnostic(try quota()).state, .ready)
        XCTAssertEqual(diagnostic(try quota(), found: false).state, .missingClient)
        XCTAssertEqual(diagnostic(try quota(), signIn: .signedOut).state, .signedOut)
        XCTAssertEqual(diagnostic(try quota(), signIn: .unavailable).state, .authUnknown)
        XCTAssertEqual(diagnostic(try quota(issue: UsageError.timeout.errorDescription)).state, .sourceError)
        XCTAssertEqual(diagnostic(try quota(at: now.addingTimeInterval(-901))).state, .staleQuota)
        XCTAssertEqual(diagnostic(UsageSnapshot(provider: .claude, fetchedAt: now)).state, .waitingForQuota)
        XCTAssertEqual(diagnostic(try quota(), hooks: false).state, .eventsMissing)
        XCTAssertEqual(diagnostic(try quota(), sessionIssue: "private path").state, .eventsMissing)
    }
    func testReportNeverIncludesSourceTextOrPersonalData() throws {
        let secret = "secret123 /Users/example/project session-title @email token=abc"
        let value = diagnostic(try quota(issue: secret), sessionIssue: secret)
        let report = ConnectionDiagnosticReport(appVersion: secret, build: "47", macOS: "26.0.1", connections: [value])
        let text = try report.text()
        for word in ["secret123", "/Users/", "session-title", "@email", "token=abc", "usedPercent"] { XCTAssertFalse(text.contains(word)) }
        XCTAssertTrue(text.contains("source_error")); XCTAssertTrue(text.contains("unknown"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schema", "appVersion", "build", "macOS", "connections"]))
        let rows = try XCTUnwrap(object["connections"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), Set(["provider", "clientFound", "eventsConfigured", "state", "quotaAgeMinutes", "errorCode"]))
    }
    func testUnconfiguredOrUntrustedReleaseFeedStaysOffline() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let valid = "https://github.com/example/Lunavect/releases/latest/download/appcast.xml"
        XCTAssertNotNil(ReleaseConfiguration(feed: valid, publicKey: key))
        for feed in [
            nil, "", "$(LUNAVECT_UPDATE_FEED_URL)",
            "http://github.com/example/Lunavect/releases/latest/download/appcast.xml",
            "https://evil.example/appcast.xml", valid + "?token=abc", valid + "#test",
            "https://user@github.com/example/Lunavect/releases/latest/download/appcast.xml",
            "https://github.com/example/Lunavect/releases/latest/download/other.xml",
        ] {
            XCTAssertNil(ReleaseConfiguration(feed: feed, publicKey: key), feed ?? "nil")
        }
        for badKey in [nil, "", "bad", Data(repeating: 0, count: 31).base64EncodedString()] {
            XCTAssertNil(ReleaseConfiguration(feed: valid, publicKey: badKey))
        }
    }
    func testWelcomeSkipAndCompletionSurviveRelaunch() throws {
        let suite = "Lunavect.WelcomeTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(WelcomeProgress.shouldPresent(defaults: defaults))
        WelcomeProgress.complete(defaults: defaults)
        XCTAssertFalse(WelcomeProgress.shouldPresent(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
    }
}
