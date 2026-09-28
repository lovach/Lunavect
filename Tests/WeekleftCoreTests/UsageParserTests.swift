import XCTest
@testable import WeekleftCore

final class UsageParserTests: XCTestCase {
    func testCodexWeeklyCanBePrimaryAndFiveHourCanBeAbsent() throws {
        let snapshot = try UsageParser.codex([
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]],
                "spark": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            ]
        ])
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
    func testJSONBooleansAndMalformedResetValuesCannotBecomeQuotas() throws {
        // Exercise Foundation's JSON bridging: a JSON Boolean is an NSNumber,
        // but is not a measured percentage, duration or reset timestamp.
        let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
        func decoded(_ value: [String: Any]) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? [String: Any])
        }
        for invalid in [true, false, "25", NSNull()] as [Any] {
            XCTAssertThrowsError(try UsageParser.codex(decoded(["rateLimits": ["primary": ["usedPercent": invalid, "windowDurationMins": 300, "resetsAt": reset]]])))
            XCTAssertThrowsError(try UsageParser.claude(decoded(["five_hour": ["used_percentage": invalid, "resets_at": reset]])))
        }
        for invalid in [true, false, "tomorrow", [1], ["time": reset]] as [Any] {
            XCTAssertThrowsError(try UsageParser.codex(decoded(["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": invalid]]])))
            // Q-10: a status-line window without a usable reset is absent, never a quota.
            XCTAssertNil(try UsageParser.claude(decoded(["five_hour": ["used_percentage": 25, "resets_at": invalid]])).fiveHour)
        }
        for invalid in [true, false, 300.5, "300"] as [Any] {
            XCTAssertThrowsError(try UsageParser.codex(decoded(["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": invalid, "resetsAt": reset]]])))
        }
        let unknownReset = try UsageParser.codex(decoded(["rateLimits": ["primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": NSNull()]]]))
        XCTAssertEqual(unknownReset.fiveHour?.remaining, 100)
        XCTAssertNil(unknownReset.fiveHour?.resetsAt)
    }
    func testQuotaDecodeUsesTheSameValidationAsDirectInitialization() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for percent in ["-1", "150", "\"Infinity\"", "\"NaN\""] {
            let bytes = Data("{\"usedPercent\":\(percent),\"durationMinutes\":10080}".utf8)
            XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: bytes), percent) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
        for duration in ["-1", "0", "1.5", "9223372036854775808"] {
            let bytes = Data("{\"usedPercent\":50,\"durationMinutes\":\(duration)}".utf8)
            XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: bytes), duration)
        }
        for duration in [-1, 0, Int.min] {
            XCTAssertThrowsError(try QuotaWindow(usedPercent: 50, durationMinutes: duration, resetsAt: nil))
        }
        for raw in ["1e300", "-1e300", "\"Infinity\"", "\"NaN\""] {
            let bytes = Data("{\"usedPercent\":50,\"durationMinutes\":10080,\"resetsAt\":\(raw)}".utf8)
            XCTAssertThrowsError(try decoder.decode(QuotaWindow.self, from: bytes), raw) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
        for seconds in [1e300, -1e300, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try QuotaWindow(usedPercent: 50, durationMinutes: 10080,
                resetsAt: Date(timeIntervalSinceReferenceDate: seconds)))
        }
    }
    func testValidQuotaRoundTripPreservesUnknownResetAndExhaustedExpiredValue() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        for window in [try QuotaWindow(usedPercent: 0, durationMinutes: 300, resetsAt: nil),
                       try QuotaWindow(usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-1))] {
            let decoded = try JSONDecoder().decode(QuotaWindow.self, from: JSONEncoder().encode(window))
            XCTAssertEqual(decoded, window)
            XCTAssertEqual(decoded.isExpired(at: now), window.resetsAt != nil)
            XCTAssertEqual(decoded.countdown(now: now, language: "ru"), window.resetsAt == nil ? "—" : "обновление")
        }
    }
    func testImpossibleObservationDatesAndWrongNamedDurationsCannotDecode() throws {
        let quota: [String: Any] = ["usedPercent": 40, "durationMinutes": 10080]
        let base: [String: Any] = ["provider": "codex", "source": "Codex CLI", "weekly": quota]
        var invalid: [[String: Any]] = []
        for date in [1e300, -1e300] {
            var snapshot = base; snapshot["fetchedAt"] = date; invalid.append(snapshot)
            snapshot = base
            snapshot["modelQuotas"] = [["name": "Sonnet", "window": quota, "fetchedAt": date]]
            invalid.append(snapshot)
        }
        for (key, duration) in [("weekly", 300), ("weekly", Int.max), ("fiveHour", 10080)] {
            var snapshot = base
            snapshot[key] = ["usedPercent": 40, "durationMinutes": duration]
            invalid.append(snapshot)
        }
        for snapshot in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot))) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
    }
    func testResetPlausibilityUsesObservationTimeAndPreservesExpiredHistory() throws {
        let observed = Date(timeIntervalSince1970: 1_600_000_000)
        for duration in [300, 10080] {
            for (interval, accepted) in [(-3600.0, true), (Double(duration) * 60 + 120, true),
                                         (Double(duration) * 60 + 121, false), (Date.distantFuture.timeIntervalSince(observed), false)] {
                let quota = try QuotaWindow(usedPercent: 80, durationMinutes: duration, resetsAt: observed.addingTimeInterval(interval))
                let snapshot = UsageSnapshot(provider: .codex, weekly: duration == 10080 ? quota : nil,
                    fiveHour: duration == 300 ? quota : nil, fetchedAt: observed)
                let model = ModelQuota(name: "Model", window: quota, fetchedAt: observed)
                let snapshotBytes = try JSONEncoder().encode(snapshot), modelBytes = try JSONEncoder().encode(model)
                if accepted {
                    XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: snapshotBytes), snapshot)
                    XCTAssertEqual(try JSONDecoder().decode(ModelQuota.self, from: modelBytes), model)
                } else {
                    XCTAssertThrowsError(try JSONDecoder().decode(UsageSnapshot.self, from: snapshotBytes))
                    XCTAssertThrowsError(try JSONDecoder().decode(ModelQuota.self, from: modelBytes))
                }
                XCTAssertEqual(snapshot.isStale(now: observed), !accepted || interval < 0)
                XCTAssertEqual(model.isStale(now: observed), !accepted || interval < 0)
            }
        }
    }
    func testFutureObservationNeverClaimsFreshnessButNormalFreshnessWindowRemains() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let quota = try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600))
        for (age, stale) in [(-1.0, true), (0.0, false), (900.0, false), (901.0, true)] {
            let date = now.addingTimeInterval(-age)
            let snapshot = UsageSnapshot(provider: .codex, weekly: quota, fetchedAt: date)
            let model = ModelQuota(name: "Sonnet", window: quota, fetchedAt: date)
            XCTAssertEqual(snapshot.isStale(now: now), stale)
            XCTAssertEqual(model.isStale(now: now), stale)
        }
        XCTAssertTrue(UsageSnapshot(provider: .codex, weekly: quota).isStale(now: now))
    }
    /// Q-10: status-line windows are independent. One without a usable `resets_at`
    /// (not started, or malformed) is absent; it no longer discards the other window.
    func testClaudeWindowWithoutResetTimeIsAbsentAndKeepsTheOtherWindow() throws {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        func decoded(_ value: [String: Any]) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? [String: Any])
        }
        for missing in [NSNull(), 0, -1, "soon", true, [1]] as [Any] {
            let weeklyOnly = try UsageParser.claude(decoded([
                "seven_day": ["used_percentage": 42.5, "resets_at": reset.timeIntervalSince1970],
                "five_hour": ["used_percentage": 10, "resets_at": missing]]))
            XCTAssertEqual(weeklyOnly.weekly, try QuotaWindow(usedPercent: 42.5, durationMinutes: 10080, resetsAt: reset), "\(missing)")
            XCTAssertNil(weeklyOnly.fiveHour, "\(missing)")
            let fiveOnly = try UsageParser.claude(decoded([
                "seven_day": ["used_percentage": 0, "resets_at": missing],
                "five_hour": ["used_percentage": 10, "resets_at": reset.timeIntervalSince1970]]))
            // R1-10: 0 % with `resets_at: null` is the unstarted window; a malformed reset stays absent.
            XCTAssertEqual(fiveOnly.weekly, missing is NSNull ? try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil) : nil, "\(missing)")
            XCTAssertEqual(fiveOnly.fiveHour?.usedPercent, 10, "\(missing)")
        }
        let neither = try UsageParser.claude(["seven_day": ["used_percentage": 42.5], "five_hour": ["used_percentage": 10]])
        XCTAssertFalse(neither.hasQuota, "No window with a reset: nothing to store")
        XCTAssertThrowsError(try UsageParser.claude(["seven_day": ["used_percentage": "42", "resets_at": reset.timeIntervalSince1970]]),
                             "A malformed percentage is still an unsupported response")
    }

    /// Matrix L4 / 01-quota.md §6 п.7: a current status-line payload with extra
    /// fields and one window without `resets_at` keeps the valid window.
    func testCaptureKeepsTheValidWindowOfACurrentPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("quota.json")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = #"""
        {"session_id":"fixture","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"version":"2.1.280",
         "cost":{"total_cost_usd":0.12,"total_api_duration_ms":2300},"exceeds_200k_tokens":false,"agent":{"name":"main"},
         "context_window":{"total_input_tokens":1200,"total_output_tokens":80,"current_usage":{"input_tokens":10}},
         "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1900003600},
                        "seven_day":{"used_percentage":0,"resets_at":null},
                        "spend_limit":{"used_percentage":162.8,"resets_at":1902592000},
                        "future_window":{"used_percentage":5}}}
        """#
        try ClaudeProvider.capture(Data(payload.utf8), destination: destination, now: now)
        let stored = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: destination))
        XCTAssertEqual(stored.fiveHour, try QuotaWindow(usedPercent: 23.5, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_900_003_600)))
        XCTAssertEqual(stored.weekly, try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil),
                       "R1-10: the unstarted weekly window is the inactive state, not an error")
        XCTAssertEqual(stored.source, "Claude Code statusLine")
    }

    /// R1-10: the status line's unstarted window (0 %, `resets_at: null`) is the same
    /// fact as `/usage`'s inactive block (decision 5): a confirmed 0 % whose window
    /// starts with the first request. A used window without a reset stays absent.
    func testStatusLineUnstartedWindowIsTheInactiveStateLikeTheProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("quota.json")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let payload = #"{"session_id":"fixture","rate_limits":{"seven_day":{"used_percentage":0,"resets_at":null},"five_hour":{"used_percentage":12,"resets_at":null}}}"#
        try ClaudeProvider.capture(Data(payload.utf8), destination: destination, now: now)
        let stored = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: destination))
        XCTAssertEqual(stored.weekly, try QuotaWindow(usedPercent: 0, durationMinutes: 10080, resetsAt: nil))
        XCTAssertNil(stored.fiveHour, "A used window without its reset stays unknown")
        XCTAssertTrue(ClaudeProvider.isTrustedSnapshot(stored))
        let fetched = try await ClaudeProvider.fetch(from: destination, now: now)
        XCTAssertEqual(fetched.weekly, stored.weekly, "`--probe` reads it as well")
        let probe = try ClaudeUsageText.parse("Current week (all models)\n0% used\nEsc to cancel", now: now)
        XCTAssertEqual(stored.weekly, probe.weekly, "One fact, one value")
        let status = stored.status(of: stored.weekly, now: now), probed = probe.status(of: probe.weekly, now: now)
        XCTAssertEqual(status, .inactive(stale: true), "statusLine carries no server observation time")
        XCTAssertEqual(probed, .inactive(stale: false))
        XCTAssertEqual(status.note(now: now, language: "ru"), probed.note(now: now, language: "ru"))
        XCTAssertEqual(status.remaining(of: stored.weekly), 100)
    }

    /// Matrix L10: a Codex reply with only a model bucket (Spark) has no account
    /// limit; the model's value is never shown as the main limit.
    func testCodexModelBucketAloneLeavesTheMainLimitUnknown() throws {
        let spark: [String: Any] = ["limitId": "codex_spark", "primary": ["usedPercent": 99, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]]
        XCTAssertThrowsError(try UsageParser.codex(["rateLimitsByLimitId": ["codex_spark": spark]])) {
            XCTAssertEqual($0 as? UsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try UsageParser.codex(["rateLimitsByLimitId": ["codex_spark": spark], "rateLimits": spark]))
        let main: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]]
        let snapshot = try UsageParser.codex(["rateLimitsByLimitId": ["codex_spark": spark], "rateLimits": main])
        XCTAssertEqual(snapshot.weekly?.usedPercent, 12, "The account bucket of the legacy field, never Spark")
        XCTAssertNotEqual(snapshot.unlimited, true)
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
        let reset = Date().addingTimeInterval(3600).timeIntervalSince1970
        let input = try JSONSerialization.data(withJSONObject: ["rate_limits": ["seven_day": ["used_percentage": 27, "resets_at": reset]],
            "transcript_path": "PRIVATE", "accessToken": "SECRET", "cwd": "PRIVATE"])
        try ClaudeProvider.capture(input, destination: destination)
        let first = try Data(contentsOf: destination)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: first)
        XCTAssertEqual(snapshot.weekly?.remaining, 73)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: reset))
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
            "five_hour": ["used_percentage": 0, "resets_at": now.addingTimeInterval(-4 * 3600).timeIntervalSince1970]
        ], now: now.addingTimeInterval(-8 * 3600))
        try JSONEncoder().encode(old).write(to: file)
        let stale = try await ClaudeProvider.fetch(from: file, now: now)
        XCTAssertEqual(stale.fetchedAt, old.fetchedAt)
        XCTAssertEqual(stale.weekly?.remaining, 16)
        XCTAssertTrue(try XCTUnwrap(stale.fiveHour).isExpired(at: now))
        XCTAssertEqual(stale.issue, UsageError.claudeQuotaStale.errorDescription)
        // A new statusLine receipt replaces values without certifying server freshness.
        let fresh = try UsageParser.claude([
            "seven_day": ["used_percentage": 85, "resets_at": 1_900_300_000],
            "five_hour": ["used_percentage": 4, "resets_at": 1_900_008_000]
        ], now: now)
        try JSONEncoder().encode(fresh).write(to: file)
        let reread = try await ClaudeProvider.fetch(from: file, now: now)
        XCTAssertNotNil(reread.issue)
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
