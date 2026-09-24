import XCTest
@testable import WeekleftCore

final class SessionFailureTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func hook(_ name: String, _ extra: [String: Any] = [:], provider: ProviderID = .claude, after previous: SessionRecord?, at seconds: Double) throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": "failure", "cwd": "/tmp/failure", "hook_event_name": name]
        payload.merge(extra) { $1 }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: provider, previous: previous, now: start.addingTimeInterval(seconds))
    }

    func testClassifiesDocumentedErrorsAndRealConnectionMessages() {
        let cases: [(String?, String?, SessionFailure)] = [
            ("rate_limit", "You've hit your session limit · resets 12:20pm (Europe/Vienna)", .limit),
            ("rate_limit", "You've reached your Fable limit. Switch to another model", .limit),
            ("server_error", "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)", .network),
            ("server_error", "API Error: Unable to connect to API (ENOTFOUND)", .network),
            ("server_error", "API Error: Connection lost mid-response. The response above may be incomplete.", .network),
            ("server_error", "API Error: 500 status code (no body)", .service),
            ("overloaded", "API Error: Overloaded", .service),
            ("authentication_failed", "401 OAuth access token has been revoked.", .signIn),
            ("oauth_org_not_allowed", nil, .signIn),
            ("cloud_credential_error", nil, .signIn),
            ("billing_error", nil, .account),
            ("account_on_hold", nil, .account),
            ("max_output_tokens", nil, .other),
            ("model_not_found", nil, .other),
            (nil, nil, .other),
            ("unknown", "Connection error.", .network),
            ("unknown", "Something unexpected", .other),
        ]
        for (error, message, expected) in cases {
            XCTAssertEqual(SessionFailure.classify(error: error, message: message), expected, "\(error ?? "nil") \(message ?? "")")
        }
    }

    func testStopFailureKeepsOnlyTheKindUntilWorkResumes() throws {
        let prompt = try hook("UserPromptSubmit", after: nil, at: 0)
        let failed = try hook("StopFailure", ["error": "rate_limit", "error_details": "429 Too Many Requests",
                                              "last_assistant_message": "You've hit your session limit · resets 12:20pm (Europe/Vienna)"], after: prompt, at: 5)
        XCTAssertEqual(failed.session.phase, .failed)
        XCTAssertEqual(failed.session.failure, .limit)
        let stored = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        for secret in ["session limit", "429", "Europe/Vienna"] { XCTAssertFalse(stored.contains(secret), secret) }
        let detailsOnly = try hook("StopFailure", ["error": "server_error", "error_details": "getaddrinfo ENOTFOUND api.anthropic.com",
                                                   "last_assistant_message": "API Error"], after: prompt, at: 6)
        XCTAssertEqual(detailsOnly.session.failure, .network, "both texts are considered")
        for next in ["UserPromptSubmit", "PreToolUse", "Stop", "SessionStart"] {
            XCTAssertNil(try hook(next, ["tool_name": "Bash", "tool_use_id": "t"], after: failed, at: 10).session.failure, next)
        }
        let codex = try hook("UserPromptSubmit", provider: .codex, after: nil, at: 0)
        XCTAssertNil(try hook("StopFailure", ["error": "rate_limit"], provider: .codex, after: codex, at: 5).session.failure)
    }

    func testFailureAfterWorkIsANotice() {
        var tracker = SessionNoticeTracker()
        func row(_ phase: SessionPhase, _ seconds: Double) -> AgentSession {
            AgentSession(provider: .claude, sessionID: "f", title: "f", cwd: "", phase: phase,
                         updatedAt: start.addingTimeInterval(seconds), observedAt: start.addingTimeInterval(seconds), evidence: .hook)
        }
        _ = tracker.update([row(.running, 0)], now: start)
        XCTAssertEqual(tracker.update([row(.failed, 1)], now: start.addingTimeInterval(1)).map(\.kind), [.failed])
        _ = tracker.update([row(.ready, 2)], now: start.addingTimeInterval(2))
        XCTAssertTrue(tracker.update([row(.failed, 3)], now: start.addingTimeInterval(3)).isEmpty)
    }

    func testInterfaceLocaleKeepsTheUsersRegionAndClock() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T12:30:00Z"))
        var style = Date.FormatStyle.dateTime.hour().minute(); style.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        let austria = L10n.locale(language: "en", base: Locale(identifier: "de_AT"))
        XCTAssertEqual(date.formatted(style.locale(austria)), "14:30")
        XCTAssertEqual(austria.firstDayOfWeek, .monday)
        XCTAssertEqual(austria.language.languageCode?.identifier, "en", "the interface language is kept")
        let unitedStates = L10n.locale(language: "en", base: Locale(identifier: "en_US"))
        XCTAssertTrue(date.formatted(style.locale(unitedStates)).hasSuffix("PM"))
        XCTAssertEqual(L10n.locale(language: "ru", base: Locale(identifier: "en_GB")).firstDayOfWeek, .monday)
    }
}
