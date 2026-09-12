import XCTest
@testable import WeekleftCore

final class UsageParserTests: XCTestCase {
    func testCodexWeeklyCanBePrimaryAndFiveHourCanBeAbsent() throws {
        let snapshot = try UsageParser.codex(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]], "spark": ["primary": ["usedPercent": 99, "windowDurationMins": 300]]]])
        XCTAssertEqual(snapshot.weekly?.remaining, 82)
        XCTAssertNil(snapshot.fiveHour)
    }
    func testSeparateCodexWindowsAreMappedByDuration() throws {
        let snapshot = try UsageParser.codex(["rateLimits": ["primary": ["usedPercent": 71, "windowDurationMins": 300], "secondary": ["usedPercent": 100, "windowDurationMins": 10080]]])
        XCTAssertEqual(snapshot.fiveHour?.remaining, 29)
        XCTAssertEqual(snapshot.weekly?.remaining, 0)
    }
    func testModelSpecificBucketCannotMasqueradeAsMainLimit() {
        XCTAssertThrowsError(try UsageParser.codex(["rateLimits": ["limitId": "spark", "primary": ["usedPercent": 0, "windowDurationMins": 10080]]]))
    }
    func testUnknownAndZeroAreDifferent() throws {
        let unavailable = try UsageParser.claude(["seven_day": NSNull(), "five_hour": NSNull()])
        XCTAssertNil(unavailable.weekly)
        let exhausted = try UsageParser.claude(["seven_day": ["used_percentage": 100, "resets_at": 1_900_000_000]])
        XCTAssertEqual(exhausted.weekly?.remaining, 0)
        XCTAssertNotNil(exhausted.weekly?.resetsAt)
    }
    func testInvalidPercentIsNotDisplayedAsValidQuota() {
        for number in [-1.0, 101.0, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try QuotaWindow(usedPercent: number, durationMinutes: 10080, resetsAt: nil))
        }
        XCTAssertThrowsError(try UsageParser.claude(["seven_day": ["resets_at": 1_900_000_000]]))
    }
    func testClaudeRejectsQuotaWithoutResetTime() {
        XCTAssertThrowsError(try UsageParser.claude(["seven_day": ["used_percentage": 42.5], "five_hour": ["used_percentage": 10]]))
    }
    func testResetZeroDoesNotRefillQuota() throws {
        let now = Date(), window = try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-1))
        XCTAssertEqual(window.countdown(now: now, language: "ru"), "обновление")
        XCTAssertEqual(window.remaining, 0)
        XCTAssertTrue(UsageSnapshot(provider: .codex, weekly: window, fetchedAt: now).isStale(now: now))
    }
    func testStoredSettingsAndSnapshotRoundTripWithoutCredentials() throws {
        var prefs = WidgetPreferences(); prefs.showFiveHour = true; prefs.subscriptionDates["claude"] = "2026-09-24"
        let data = try JSONEncoder().encode(SharedState(preferences: prefs))
        XCTAssertEqual(try JSONDecoder().decode(SharedState.self, from: data).preferences, prefs)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("accessToken"))
        XCTAssertFalse(WidgetPreferences().showFiveHour)
    }
}

final class ClaudeStatusLineTests: XCTestCase {
    func testCaptureKeepsOnlyQuotaAndMissingPayloadDoesNotRefreshIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("quota.json")
        let input = Data(#"{"rate_limits":{"seven_day":{"used_percentage":27,"resets_at":1900000000}},"transcript_path":"PRIVATE","accessToken":"SECRET","cwd":"PRIVATE"}"#.utf8)
        try ClaudeProvider.capture(input, destination: destination)
        let first = try Data(contentsOf: destination)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: first)
        XCTAssertEqual(snapshot.weekly?.remaining, 73)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("PRIVATE"))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("SECRET"))
        try ClaudeProvider.capture(Data("{}".utf8), destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), first)
        XCTAssertThrowsError(try ClaudeProvider.capture(Data(#"{"rate_limits":{"seven_day":{"used_percentage":101}}}"#.utf8), destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), first)
    }
    func testRefreshReportsStaleClaudeCacheWithoutInventingFreshData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota.json")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = try UsageParser.claude([
            "seven_day": ["used_percentage": 84, "resets_at": 1_900_300_000],
            "five_hour": ["used_percentage": 0, "resets_at": 1_899_999_999]
        ], now: now.addingTimeInterval(-8 * 3600))
        try JSONEncoder().encode(old).write(to: file)
        let stale = try await ClaudeProvider.fetch(from: file, now: now)
        XCTAssertEqual(stale.fetchedAt, old.fetchedAt)
        XCTAssertEqual(stale.weekly?.remaining, 16)
        XCTAssertTrue(try XCTUnwrap(stale.fiveHour).isExpired(at: now))
        XCTAssertEqual(stale.issue, UsageError.claudeQuotaStale.errorDescription)
        // A new real observation replaces the old values and clears the warning.
        let fresh = try UsageParser.claude([
            "seven_day": ["used_percentage": 85, "resets_at": 1_900_300_000],
            "five_hour": ["used_percentage": 4, "resets_at": 1_900_008_000]
        ], now: now)
        try JSONEncoder().encode(fresh).write(to: file)
        let reread = try await ClaudeProvider.fetch(from: file, now: now)
        XCTAssertNil(reread.issue)
        XCTAssertEqual(reread.weekly?.remaining, 15)
        XCTAssertEqual(reread.fiveHour?.remaining, 96)
    }
    func testFiveHourResetMakesSnapshotStaleEvenWhenWeeklyIsCurrent() throws {
        let now = Date()
        let snapshot = UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 84, durationMinutes: 10080, resetsAt: now.addingTimeInterval(10000)),
            fiveHour: try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: now), fetchedAt: now)
        XCTAssertTrue(snapshot.isStale(now: now))
        XCTAssertFalse(try XCTUnwrap(snapshot.weekly).isExpired(at: now))
        XCTAssertTrue(try XCTUnwrap(snapshot.fiveHour).isExpired(at: now))
    }
    func testInstallPreservesExistingHUDAndOtherSettingsAndIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json"), bridge = directory.appendingPathComponent("bridge")
        let original = Data(#"{"statusLine":{"type":"command","command":"cat","padding":2},"permissions":{"allow":["Read"]}}"#.utf8)
        try original.write(to: settings)
        try ClaudeProvider.installStatusLine(executable: "/Applications/Test App's.app/main", settingsURL: settings, bridgeDirectory: bridge)
        let first = try Data(contentsOf: settings)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertNotNil(root["permissions"])
        XCTAssertEqual((root["statusLine"] as? [String: Any])?["padding"] as? Int, 2)
        let prior = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bridge.appendingPathComponent("previous-statusline.json"))) as? [String: Any])
        XCTAssertEqual(prior["command"] as? String, "cat")
        try ClaudeProvider.installStatusLine(executable: "/Applications/Test App's.app/main", settingsURL: settings, bridgeDirectory: bridge)
        XCTAssertEqual(try Data(contentsOf: settings), first)
    }
}
