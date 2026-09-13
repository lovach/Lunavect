import XCTest
@testable import WeekleftCore

final class ActivityImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ records: [[String: Any]], to url: URL) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    private func codex(_ start: Double, _ end: Double, id: String = "fixture") -> [String: Any] {
        [
            "type": "event_msg",
            "payload": [
                "type": "task_complete", "started_at": start, "completed_at": end, "duration_ms": (end - start) * 1000,
                "turn_id": id, "last_agent_message": "PRIVATE TEXT MUST NOT BE SAVED",
            ],
        ]
    }
    func testRestoresBothProvidersClipsBoundaryAndUnionsCopiesWithoutMessages() throws {
        let root = try directory(), c = root.appendingPathComponent("c"), a = root.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let end = now.timeIntervalSince1970
        try write([codex(end - 120, end), codex(end - 120, end)], to: c.appendingPathComponent("one.jsonl"))
        let claude: [String: Any] = ["type": "system", "subtype": "turn_duration", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)), "durationMs": 120_000]
        try write([claude], to: a.appendingPathComponent("two.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: c, provider: .codex), .init(directory: a, provider: .claude)], before: now.addingTimeInterval(-30), now: now)
        var history = ActivityHistory(); _ = history.prepareImport(now: now.addingTimeInterval(-30))
        history.mergeRecovered(result.intervals, now: now, limited: result.limited)
        let totals = history.summary(now: now).totals
        XCTAssertEqual(totals.active, 150); XCTAssertEqual(totals.codex, 90); XCTAssertEqual(totals.claude, 120)
        XCTAssertEqual(totals.recovered, 150); XCTAssertFalse(result.limited)
        let json = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE")); XCTAssertFalse(json.contains("fixture")); XCTAssertFalse(json.contains("turn_id"))
    }
    func testOlderPairedLifecycleRequiresMatchingCompletedTurn() throws {
        let root = try directory(), t = now.timeIntervalSince1970
        func event(_ type: String, _ id: String, _ offset: Double) -> [String: Any] {
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)), "payload": ["type": type, "turn_id": id]]
        }
        try write([event("task_started", "a", -120), event("task_complete", "wrong", -110), event("task_complete", "a", -90),
                   event("task_started", "b", -80), event("turn_aborted", "b", -70), event("task_complete", "b", -60),
                   event("task_started", "unclosed", -50), codex(t + 10, t + 30), codex(t - 10, t - 20)], to: root.appendingPathComponent("rollout.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now)
        XCTAssertEqual(result.intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 30)
    }
    func testRejectsMessagesDisguisedAsDurationsAndMismatchedUnits() throws {
        let root = try directory(), t = now.timeIntervalSince1970
        var wrong = codex(t - 120, t - 60)
        var payload = wrong["payload"] as! [String: Any]; payload["duration_ms"] = 60; wrong["payload"] = payload
        try write(
            [
                wrong,
                [
                    "type": "assistant", "subtype": "turn_duration",
                    "timestamp": ISO8601DateFormatter().string(from: now), "durationMs": 120_000,
                ],
            ], to: root.appendingPathComponent("log.jsonl"))
        let codexResult = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now)
        XCTAssertTrue(codexResult.intervals.isEmpty); XCTAssertTrue(codexResult.limited)
        XCTAssertTrue(ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: now, now: now).intervals.isEmpty)
    }
    func testImportPreservesLiveObservationsAndRetryIsIdempotent() throws {
        let start = now.addingTimeInterval(-10)
        var tracker = ActivityTracker()
        XCTAssertEqual(tracker.prepareImport(now: start), start)
        let row = AgentSession(provider: .claude, sessionID: "live", title: "", cwd: "", phase: .running, updatedAt: start, observedAt: start, runtimeConfirmed: true)
        tracker.observe([row], now: start); tracker.observe([row], now: start.addingTimeInterval(5))
        var imported = ActivityImportResult()
        imported.intervals = [.init(start: now.addingTimeInterval(-60), end: now, providers: 2)]
        tracker.mergeImport(imported, now: now)
        tracker.mergeImport(imported, now: now)
        XCTAssertEqual(tracker.history.summary(now: now).totals.active, 55)
        XCTAssertEqual(tracker.history.summary(now: now).totals.recovered, 50)
        XCTAssertEqual(tracker.history.summary(now: now).totals.claude, 5)
        tracker.observe([row], now: start.addingTimeInterval(8))
        XCTAssertEqual(tracker.history.summary(now: now).totals.claude, 8)
        let url = try directory().appendingPathComponent("activity.json")
        try tracker.history.save(to: url)
        XCTAssertEqual(try ActivityHistory.load(from: url), tracker.history)
    }
    func testLegacyHistoryDecodesAndKeepsFirstRecordingBoundary() throws {
        let data = Data("{\"intervals\":[{\"start\":800000000,\"end\":800000010,\"providers\":2}]}".utf8)
        var history = try JSONDecoder().decode(ActivityHistory.self, from: data)
        XCTAssertNil(history.importedAt); XCTAssertNil(history.intervals[0].recovered)
        let first = history.intervals[0].start
        XCTAssertEqual(history.prepareImport(now: first.addingTimeInterval(100)), first)
        XCTAssertEqual(history.prepareImport(now: first.addingTimeInterval(200)), first)
    }
    func testBoundsAndSymlinksDoNotReadUnrelatedFiles() throws {
        let root = try directory(), outside = try directory().appendingPathComponent("secret.jsonl")
        try write([codex(now.timeIntervalSince1970 - 60, now.timeIntervalSince1970)], to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.jsonl"), withDestinationURL: outside)
        XCTAssertTrue(ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now).intervals.isEmpty)
        let file = root.appendingPathComponent("normal.jsonl")
        try Data(contentsOf: outside).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let bounded = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now, maximumBytes: 20)
        XCTAssertTrue(bounded.limited); XCTAssertTrue(bounded.intervals.isEmpty)
        let lineBound = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now, maximumLineBytes: 20)
        XCTAssertTrue(lineBound.limited); XCTAssertTrue(lineBound.intervals.isEmpty)
    }
    func testDayWeekMonthUseCorrectBoundariesAndDSTHours() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now), end = today.addingTimeInterval(12 * 3600)
        var history = ActivityHistory()
        for day in -30...0 {
            let start = today.addingTimeInterval(Double(day * 86400 + 3600))
            history.append(start: start, end: start.addingTimeInterval(60), providers: 1)
        }
        for (period, count) in [(ActivityPeriod.day, 1), (.week, 7), (.month, 30)] {
            let summary = history.summary(now: end, calendar: calendar, period: period)
            XCTAssertEqual(summary.days.count, count); XCTAssertEqual(summary.totals.active, Double(count * 60))
            XCTAssertEqual(summary.points.count, period == .day ? 24 : count)
            XCTAssertEqual(summary.points.reduce(0) { $0 + $1.totals.active }, summary.totals.active)
        }
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Vienna"))
        for (stamp, hours) in [("2026-03-29T12:00:00Z", 23), ("2026-10-25T12:00:00Z", 25)] {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))
            XCTAssertEqual(history.summary(now: date, calendar: calendar, period: .day).points.count, hours)
        }
    }
    func testReadAvailableLocalTimingMetadata() throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_VERIFY_LOCAL_HISTORY"] == "1" else { throw XCTSkip("Opt-in local metadata read; writes no user data") }
        let date = Date()
        let baseline = ProcessInfo.processInfo.environment["LUNAVECT_ACTIVITY_BASELINE"].map { URL(fileURLWithPath: $0) } ?? ActivityHistory.fileURL
        let saved = try ActivityHistory.load(from: baseline)
        let boundary = saved.importCutoff ?? date
        let result = ActivityHistoryImporter.read(before: boundary, now: date)
        XCTAssertEqual(try ActivityHistory.load(from: baseline).importedAt, saved.importedAt, "Dry run must not start an import")
        let old = saved.summary(now: date, period: .month).totals
        var merged = saved
        merged.mergeRecovered(result.intervals, now: date, limited: result.limited, report: result.report)
        let new = merged.summary(now: date, period: .month).totals
        XCTAssertGreaterThanOrEqual(new.active + 0.001, old.active)
        for provider in result.report.providers {
            print(
                "Import audit: provider=\(provider.id.rawValue), files=\(provider.filesRead), bytes=\(provider.bytesRead), days=\(provider.daysRecovered), tasks=\(provider.taskRecords), agents=\(provider.agentRecords), tools=\(provider.toolRecords), omittedLongStrings=\(provider.longStringsOmitted), issues=\(provider.issues)"
            )
        }
        print("Import gain in minutes: Claude=\(Int((new.claude - old.claude) / 60)), Codex=\(Int((new.codex - old.codex) / 60)), total=\(Int((new.active - old.active) / 60))")
        XCTAssertFalse(result.intervals.isEmpty)
        XCTAssertTrue(result.intervals.contains { $0.start < Calendar.current.startOfDay(for: date) })
        XCTAssertTrue(result.intervals.allSatisfy { $0.recovered == true && $0.end <= date })
        print("Local timing verification: Claude=\(result.intervals.contains { $0.providers & 1 != 0 }), Codex=\(result.intervals.contains { $0.providers & 2 != 0 }), partial=\(result.limited)")
    }
}

extension ActivityImportTests {
    private func toolCall(_ name: String, _ id: String, at date: Date) -> [String: Any] {
        ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date),
         "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": ["prompt": "PRIVATE"]]]]]
    }
    private func toolResult(_ id: String, at date: Date, timing: [String: Any], error: Bool = false) -> [String: Any] {
        ["type": "user", "timestamp": ISO8601DateFormatter().string(from: date),
         "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": error, "content": "PRIVATE"]]], "toolUseResult": timing]
    }
    func testAgentDurationsOverlapParentsAndToolTimesWithoutDoubleCounting() throws {
        let root = try directory(), end = now.addingTimeInterval(-10)
        let agent: [String: Any] = ["totalDurationMs": 60_000, "status": "completed", "agentId": "PRIVATE_AGENT"]
        let result = toolResult("agent", at: end, timing: agent)
        try write([
            toolCall("Agent", "agent", at: end.addingTimeInterval(-65)), result, result,
            toolCall("WebFetch", "fetch", at: end.addingTimeInterval(-100)),
            toolResult("fetch", at: end.addingTimeInterval(-40), timing: ["durationMs": 60_000]),
            ["type": "system", "subtype": "turn_duration", "durationMs": 90_000, "timestamp": ISO8601DateFormatter().string(from: end)]
        ], to: root.appendingPathComponent("claude.jsonl"))
        let imported = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: now, now: now)
        XCTAssertEqual(imported.intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 100)
        XCTAssertFalse(imported.limited)
        let report = try XCTUnwrap(imported.report.providers.first)
        XCTAssertEqual(report.agentRecords, 1); XCTAssertEqual(report.toolRecords, 1); XCTAssertEqual(report.taskRecords, 1)
        XCTAssertEqual(report.recoveredSeconds, 100)
        let persisted = String(decoding: try JSONEncoder().encode(imported.report), as: UTF8.self)
        XCTAssertFalse(persisted.contains("PRIVATE")); XCTAssertFalse(persisted.contains("WebFetch"))
    }
    func testStandaloneAgentAfterCompactionAndTaskAlias() throws {
        let root = try directory()
        try write([
            toolResult("old", at: now.addingTimeInterval(-100), timing: ["status": "completed", "agentId": "opaque", "totalDurationMs": 30_000]),
            toolCall("Task", "task", at: now.addingTimeInterval(-65)),
            toolResult("task", at: now.addingTimeInterval(-5), timing: ["status": "completed", "totalDurationMs": 60_000])
        ], to: root.appendingPathComponent("claude.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(result.report.providers.first?.agentRecords, 2)
        XCTAssertEqual(result.report.providers.first?.recoveredSeconds, 85)
        XCTAssertFalse(result.limited)
    }
    func testRejectsFailedUnfinishedUnmatchedAndImpossibleToolDurations() throws {
        let root = try directory()
        try write([
            toolResult("noidentity", at: now, timing: ["status": "completed", "totalDurationMs": 60000]),
            toolResult("unfinished", at: now, timing: ["status": "async_launched", "agentId": "x", "totalDurationMs": 60000]),
            toolResult("error", at: now, timing: ["status": "completed", "agentId": "x", "totalDurationMs": 60000], error: true),
            toolCall("Agent", "wrongtime", at: now.addingTimeInterval(-5)),
            toolResult("wrongtime", at: now, timing: ["status": "completed", "totalDurationMs": 60000]),
            toolCall("Read", "fake", at: now.addingTimeInterval(-60)),
            toolResult("fake", at: now, timing: ["status": "completed", "totalDurationMs": 60000]),
            toolCall("Agent", "boolean", at: now.addingTimeInterval(-60)),
            toolResult("boolean", at: now, timing: ["status": "completed", "totalDurationMs": true]),
            ["type": "attachment", "timestamp": ISO8601DateFormatter().string(from: now), "attachment": ["type": "hook_success", "durationMs": 999999]],
            ["type": "cost-state", "totalDuration": 9999999]
        ], to: root.appendingPathComponent("claude.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: now, now: now)
        XCTAssertTrue(result.intervals.isEmpty); XCTAssertTrue(result.limited)
        XCTAssertEqual(result.report.providers.first?.issues[.invalidTiming], 2)
        XCTAssertEqual(result.report.providers.first?.issues[.unmatchedTool], 2)
        XCTAssertEqual(result.report.providers.first?.issues[.incompleteTask], 1)
    }
    func testKnownToolUnitsAndNoIdleGapReconstruction() throws {
        let root = try directory()
        try write([
            toolCall("Glob", "glob", at: now.addingTimeInterval(-2000)),
            toolResult("glob", at: now.addingTimeInterval(-1000), timing: ["durationMs": 1500]),
            toolCall("WebSearch", "search", at: now.addingTimeInterval(-800)),
            toolResult("search", at: now, timing: ["durationSeconds": 3.5])
        ], to: root.appendingPathComponent("claude.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: now, now: now)
        XCTAssertEqual(result.report.providers.first?.recoveredSeconds, 5)
        XCTAssertEqual(result.intervals.count, 2)
    }
    func testHugeQuotedContentDoesNotHideTimingMetadataOrTriggerPartialHistory() throws {
        let root = try directory()
        var record = codex(now.timeIntervalSince1970 - 60, now.timeIntervalSince1970)
        record["image"] = String(repeating: "a\\\"é\n", count: 1_000_000)
        try write([record], to: root.appendingPathComponent("image.jsonl"))
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now)
        XCTAssertEqual(result.report.providers.first?.recoveredSeconds, 60)
        XCTAssertGreaterThan(result.report.providers.first?.bytesRead ?? 0, 4 * 1024 * 1024)
        XCTAssertEqual(result.report.providers.first?.longStringsOmitted, 1)
        XCTAssertFalse(result.limited)
    }
    func testStreamingJSONPreservesEscapesAndStructureAcrossEveryChunkSize() throws {
        let original: [String: Any] = ["type": "event_msg", "escaped": "a\\\"\\\\é\n🧪", "nested": ["duration_ms": 1200, "items": ["a", "b"]]]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        for size in 1...data.count {
            var reader = TimingJSONLReader(maximumRecordBytes: 4096), lines: [Data] = []
            func consume(_ data: Data, _ failure: TimingJSONLReader.Failure?, _ omitted: Int) { XCTAssertNil(failure); XCTAssertEqual(omitted, 0); lines.append(data) }
            for start in stride(from: 0, to: data.count, by: size) { reader.feed(data.subdata(in: start..<min(data.count, start + size)), consume: consume) }
            reader.finish(consume: consume)
            XCTAssertEqual(lines, [data], "chunk size \(size)")
        }
    }
    func testTruncatedOversizedMetadataAndQuotedFakeEventsDoNotPoisonNextRecord() throws {
        let root = try directory(), file = root.appendingPathComponent("log.jsonl")
        let good = try JSONSerialization.data(withJSONObject: codex(now.timeIntervalSince1970 - 10, now.timeIntervalSince1970))
        let unrelated = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "function_call", "started_at": "bad", "arguments": "task_complete"]])
        var data = Data("{\"type\":\"event_msg\",\"payload\":\"task_complete\n".utf8)
        data.append(unrelated); data.append(10)
        data.append(Data(("[" + Array(repeating: "12345", count: 1000).joined(separator: ",") + "]\n").utf8))
        data.append(good) // Final complete record without newline is valid.
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now, maximumLineBytes: 1024)
        XCTAssertEqual(result.report.providers.first?.recoveredSeconds, 10)
        XCTAssertEqual(result.report.providers.first?.issues[.recordTooLarge], 1)
        XCTAssertEqual(result.report.providers.first?.issues[.malformed], 1)
        XCTAssertNil(result.report.providers.first?.issues[.invalidTiming])
    }
    func testTimeAndRecordBudgetsAreReportedWithoutLosingAcceptedIntervals() throws {
        let root = try directory(), t = now.timeIntervalSince1970
        try write([codex(t - 40, t - 30), codex(t - 20, t - 10)], to: root.appendingPathComponent("log.jsonl"))
        let timed = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now, maximumSeconds: 0)
        XCTAssertTrue(timed.intervals.isEmpty); XCTAssertNotNil(timed.report.providers.first?.issues[.budget])
        let counted = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now, now: now, maximumIntervals: 1)
        XCTAssertEqual(counted.report.providers.first?.recoveredSeconds, 10)
        XCTAssertTrue(counted.limited)
    }
    func testImportVersionMigratesWithoutMovingBoundaryAndReportRoundTrips() throws {
        var history = try JSONDecoder().decode(ActivityHistory.self, from: Data("{\"intervals\":[],\"importedAt\":800000100,\"importCutoff\":800000000}".utf8))
        XCTAssertTrue(history.needsImport)
        let boundary = history.importCutoff
        var result = ActivityImportResult(); result.report.providers = [.init(id: .claude)]
        history.mergeRecovered([], now: now, limited: false, report: result.report)
        XCTAssertFalse(history.needsImport); XCTAssertEqual(history.importCutoff, boundary)
        XCTAssertEqual(try JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(history)), history)
    }
}

extension ActivityImportTests {
    private final class ImportClock: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let expireAtCall: Int?
        let cancelAtCall: Int?
        init(expireAtCall: Int? = nil, cancelAtCall: Int? = nil) {
            self.expireAtCall = expireAtCall; self.cancelAtCall = cancelAtCall
        }
        var callCount: Int { lock.withLock { calls } }
        func now() -> TimeInterval {
            let call = lock.withLock { calls += 1; return calls }
            if let cancelAtCall, call >= cancelAtCall { withUnsafeCurrentTask { $0?.cancel() } }
            return expireAtCall.map { call >= $0 } == true ? 10 : 0
        }
    }

    func testMonotonicDeadlineAtBoundaryStopsBeforeReadingFiles() throws {
        let root = try directory(), end = now.timeIntervalSince1970
        try write([codex(end - 20, end - 10)], to: root.appendingPathComponent("log.jsonl"))
        let clock = ImportClock(expireAtCall: 2)
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now,
            now: now, maximumSeconds: 10, monotonicNow: { clock.now() })
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.intervals.isEmpty)
        XCTAssertEqual(result.report.providers.first?.filesRead, 0)
        XCTAssertEqual(result.report.providers.first?.bytesRead, 0)
        XCTAssertNotNil(result.report.providers.first?.issues[.budget])
    }

    func testDeadlineDuringChunkPreservesOnlyAcceptedCompleteRecords() throws {
        let root = try directory(), end = now.timeIntervalSince1970
        var records: [[String: Any]] = []
        for index in 0..<1_000 {
            let offset = Double(index) * 20
            let start = end - offset - 20
            let finish = end - offset - 10
            records.append(codex(start, finish))
        }
        let file = root.appendingPathComponent("log.jsonl")
        try write(records, to: file)
        let clock = ImportClock(expireAtCall: 50)
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: now,
            now: now, maximumSeconds: 10, monotonicNow: { clock.now() })
        let report = try XCTUnwrap(result.report.providers.first)
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.limited)
        XCTAssertGreaterThan(report.recordsRecovered, 0)
        XCTAssertLessThan(report.recordsRecovered, records.count)
        XCTAssertEqual(report.recoveredSeconds, Double(report.recordsRecovered * 10))
        XCTAssertEqual(result.intervals.count, report.recordsRecovered)
        XCTAssertLessThanOrEqual(report.bytesRead, 256 * 1024)
        XCTAssertNotNil(report.issues[.budget])
    }

    func testCancellationBeforeEnumerationReturnsNoCompletedImport() async throws {
        let root = try directory(), end = now.timeIntervalSince1970, date = now
        try write([codex(end - 20, end - 10)], to: root.appendingPathComponent("log.jsonl"))
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: date, now: date)
        }.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.intervals.isEmpty)
        XCTAssertTrue(result.details.isEmpty)
        XCTAssertTrue(result.report.providers.isEmpty)
    }

    func testCancellationDuringReadAndFinalizationDiscardsWorkerPayload() async throws {
        let root = try directory(), end = now.timeIntervalSince1970, date = now
        var records: [[String: Any]] = []
        for index in 0..<1_000 {
            let offset = Double(index) * 20
            let start = end - offset - 20
            let finish = end - offset - 10
            records.append(codex(start, finish))
        }
        try write(records, to: root.appendingPathComponent("log.jsonl"))
        let baselineClock = ImportClock()
        let completed = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: date,
            now: date, maximumSeconds: 10, monotonicNow: { baselineClock.now() })
        XCTAssertEqual(completed.report.providers.first?.recordsRecovered, records.count)
        XCTAssertFalse(completed.cancelled)
        XCTAssertFalse(completed.limited)
        // The successful timeline identifies its last checkpoint without relying
        // on wall-clock timing or a particular number of implementation checks.
        for checkpoint in [50, baselineClock.callCount] {
            let clock = ImportClock(cancelAtCall: checkpoint)
            let cancelled = await Task.detached {
                ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: date,
                    now: date, maximumSeconds: 10, monotonicNow: { clock.now() })
            }.value
            XCTAssertGreaterThanOrEqual(clock.callCount, checkpoint)
            XCTAssertTrue(cancelled.cancelled)
            XCTAssertTrue(cancelled.limited)
            XCTAssertTrue(cancelled.intervals.isEmpty)
            XCTAssertTrue(cancelled.details.isEmpty)
            XCTAssertTrue(cancelled.report.providers.isEmpty)
        }
    }

    func testMissingOptionalArchiveAndInvalidSourceHaveDifferentDiagnostics() throws {
        let root = try directory(), file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let invalid = ActivityHistoryImporter.read(sources: [.init(directory: file, provider: .claude)], before: now, now: now)
        XCTAssertEqual(invalid.report.providers.first?.issues[.unreadable], 1)
        XCTAssertNil(invalid.report.providers.first?.issues[.symlink])
        let missing = ActivityHistoryImporter.read(sources: [.init(directory: root.appendingPathComponent("projects"), provider: .claude)], before: now, now: now)
        XCTAssertEqual(missing.report.providers.first?.issues[.missingSource], 1)
        let optional = ActivityHistoryImporter.read(sources: [.init(directory: root.appendingPathComponent("archived_sessions"), provider: .codex)], before: now, now: now)
        XCTAssertFalse(optional.limited)
    }
}
