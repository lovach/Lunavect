import XCTest
@testable import WeekleftCore

/// Codex plans without rate-limit windows and the documented reached-limit flag
/// (app-server v2 `RateLimitSnapshot`: `credits.unlimited`, `rateLimitReachedType`).
final class CodexLimitStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func decoded(_ value: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? [String: Any])
    }

    // Q-18 / T-19, matrix L9
    func testUnlimitedCreditsWithoutWindowsIsAKnownStateNotWaiting() throws {
        let result = try decoded(["rateLimits": ["limitId": "codex", "primary": NSNull(), "secondary": NSNull(),
                                                 "credits": ["hasCredits": true, "unlimited": true, "balance": NSNull()]],
                                  "rateLimitsByLimitId": ["codex": ["limitId": "codex", "primary": NSNull(), "secondary": NSNull(),
                                                                    "credits": ["hasCredits": true, "unlimited": true, "balance": NSNull()]]]])
        XCTAssertNoThrow(try ClientResponseContract.validateCodexRateLimits(result))
        let snapshot = try UsageParser.codex(result, now: now)
        XCTAssertEqual(snapshot.unlimited, true)
        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.fiveHour)
        let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                              snapshot: snapshot, sessionIssue: nil, now: now)
        XCTAssertEqual(diagnostic.state, .ready, "No limits is an answer, not missing data")
        XCTAssertEqual(snapshot.connectionQuotaTitle(now: now), "Лимиты получены")
    }

    /// R1-06: only the documented `credits.unlimited` flag means "no limits". A
    /// bucket without windows for any other reason (API-key sign-in, a plan name,
    /// a temporary empty answer) is unknown, never "∞".
    func testOnlyTheUnlimitedCreditsFlagMeansNoLimits() throws {
        let unknown: [[String: Any]] = [
            ["limitId": "codex", "planType": "enterprise"],
            ["limitId": "codex", "primary": NSNull(), "secondary": NSNull()],
            ["limitId": "codex", "primary": NSNull(), "credits": ["hasCredits": true, "unlimited": false]],
            ["limitId": "codex", "credits": ["hasCredits": true, "unlimited": "true"]],
            ["limitId": "codex", "credits": ["hasCredits": true, "unlimited": 1]],
        ]
        for bucket in unknown {
            let snapshot = try UsageParser.codex(decoded(["rateLimitsByLimitId": ["codex": bucket]]), now: now)
            XCTAssertNil(snapshot.unlimited, "\(bucket)")
            XCTAssertEqual(snapshot.status(of: snapshot.weekly, now: now), .unknown, "\(bucket)")
            let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                                  snapshot: snapshot, sessionIssue: nil, now: now)
            XCTAssertEqual(diagnostic.state, .waitingForQuota, "\(bucket)")
        }
        let explicit = try UsageParser.codex(decoded(["rateLimitsByLimitId": ["codex": ["limitId": "codex", "planType": "enterprise",
            "credits": ["hasCredits": true, "unlimited": true]]]]), now: now)
        XCTAssertEqual(explicit.unlimited, true)
        XCTAssertEqual(explicit.status(of: explicit.weekly, now: now), .unlimited)
        XCTAssertThrowsError(try ClientResponseContract.validateCodexRateLimits(decoded(["rateLimitsByLimitId": ["codex_spark": ["primary": NSNull()]]])),
                             "Another model's bucket is never the main account limit")
    }

    func testWindowsAreKeptEvenWhenCreditsAreUnlimited() throws {
        let reset = now.addingTimeInterval(3 * 86400).timeIntervalSince1970
        let snapshot = try UsageParser.codex(decoded(["rateLimits": [
            "primary": ["usedPercent": 40, "windowDurationMins": 10080, "resetsAt": reset],
            "credits": ["hasCredits": true, "unlimited": true]]]), now: now)
        XCTAssertEqual(snapshot.weekly?.usedPercent, 40)
        XCTAssertNotEqual(snapshot.unlimited, true)
    }

    // 01-quota.md §6 п.19: a reached limit is 100 % even when the percentage rounds lower.
    func testReachedLimitTypeMarksTheBindingWindowUsedUp() throws {
        let weeklyReset = now.addingTimeInterval(3 * 86400).timeIntervalSince1970, fiveReset = now.addingTimeInterval(3600).timeIntervalSince1970
        func bucket(_ type: Any) throws -> UsageSnapshot {
            try UsageParser.codex(decoded(["rateLimits": [
                "primary": ["usedPercent": 99, "windowDurationMins": 10080, "resetsAt": weeklyReset],
                "secondary": ["usedPercent": 40, "windowDurationMins": 300, "resetsAt": fiveReset],
                "rateLimitReachedType": type]]), now: now)
        }
        for type in ["rate_limit_reached", "workspace_member_usage_limit_reached", "workspace_owner_usage_limit_reached"] {
            let reached = try bucket(type)
            XCTAssertEqual(reached.weekly?.usedPercent, 100, type)
            XCTAssertEqual(reached.fiveHour?.usedPercent, 40, type)
        }
        XCTAssertEqual(try bucket("workspace_member_credits_depleted").weekly?.usedPercent, 99, "Credits, not a window")
        XCTAssertEqual(try bucket(NSNull()).weekly?.usedPercent, 99)
    }

    func testUnlimitedStateSurvivesStorageAndOlderSnapshotsStillDecode() throws {
        let snapshot = UsageSnapshot(provider: .codex, fetchedAt: now, source: "Codex CLI", unlimited: true)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.unlimited, true)
        let legacy = Data(#"{"provider":"codex","source":"Codex CLI","fetchedAt":800000000}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UsageSnapshot.self, from: legacy).unlimited)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(UsageSnapshot(provider: .codex))) as? [String: Any])
        XCTAssertNil(plain["unlimited"], "Snapshots with limits keep the earlier format")
    }
}
