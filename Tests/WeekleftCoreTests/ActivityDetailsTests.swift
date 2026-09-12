import XCTest
@testable import WeekleftCore

final class ActivityDetailsTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String, provider: ProviderID = .codex, cwd: String = "/Users/demo/Projects/App", phase: SessionPhase = .running) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Session title", cwd: cwd, phase: phase, updatedAt: base, observedAt: base, runtimeConfirmed: true)
    }
    func testDetailsUseConfirmedIntervalsAndKeepParallelSessionTimesSeparate() {
        var tracker = ActivityTracker()
        let rows = [row("a"), row("b"), row("c", provider: .claude, cwd: "/tmp/Other"), row("waiting", phase: .permission)]
        tracker.observe(rows, now: base)
        XCTAssertTrue(tracker.details.records.isEmpty)
        tracker.observe(rows, now: base.addingTimeInterval(5))
        tracker.observe(rows, now: base.addingTimeInterval(10))
        let range = DateInterval(start: base, duration: 10)
        let records = tracker.details.selected(in: range, providers: ProviderID.allCases)
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.totals(in: range).active == 10 })
        XCTAssertEqual(ActivityDetails.totals(for: records, in: range).active, 10)
        XCTAssertEqual(ActivityDetails.totals(for: records.filter { $0.cwd.hasSuffix("/App") }, in: range).active, 10)
        tracker.observe([], now: base.addingTimeInterval(15))
        tracker.observe(rows, now: base.addingTimeInterval(3600))
        XCTAssertEqual(ActivityDetails.totals(for: Array(tracker.details.records.values), in: DateInterval(start: base, duration: 4000)).active, 10)
        XCTAssertEqual(tracker.details.selected(in: DateInterval(start: base.addingTimeInterval(3), duration: 2), providers: [.claude]).first?.totals(in: DateInterval(start: base.addingTimeInterval(3), duration: 2)).active, 2)
    }
    func testImportClipsAtLiveBoundaryAndCannotDuplicateOnRetry() throws {
        var tracker = ActivityTracker()
        _ = tracker.prepareImport(now: base)
        var result = ActivityImportResult()
        result.details = [.init(provider: .codex, sessionID: "a", title: "Actual name", cwd: "/tmp/App", intervals: [.init(start: base.addingTimeInterval(-20), end: base.addingTimeInterval(20), providers: 2)])]
        result.intervals = result.details[0].intervals
        tracker.mergeImport(result, now: base.addingTimeInterval(30))
        tracker.mergeImport(result, now: base.addingTimeInterval(30))
        let record = try XCTUnwrap(tracker.details.records.values.first)
        let totals = record.totals(in: DateInterval(start: base.addingTimeInterval(-20), duration: 50))
        XCTAssertEqual(totals.active, 20); XCTAssertEqual(totals.recovered, 20)
    }
    func testPrivatePersistenceAndMetadataExtractionNeverSaveMessageContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, t = base.timeIntervalSince1970
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/Fixture"]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn", "started_at": t-60, "completed_at": t, "last_agent_message": "PRIVATE MESSAGE"]]
        ]
        let data = try records.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        try data.write(to: root.appendingPathComponent("log.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: root.appendingPathComponent("log.jsonl").path)
        let result = ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .codex)], before: base, now: base)
        let record = try XCTUnwrap(result.details.first)
        XCTAssertEqual(record.sessionID, id); XCTAssertEqual(record.cwd, "/tmp/Fixture")
        var details = ActivityDetails(); details.merge(result.details, now: base)
        let file = root.appendingPathComponent("private/details.json")
        try details.save(to: file)
        XCTAssertEqual(try ActivityDetails.load(from: file), details)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(try String(contentsOf: file).contains("PRIVATE MESSAGE"))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try ActivityDetails.load(from: file))
    }
    func testProjectPathStaysShortAndDoesNotExposeScratchIdentifier() {
        XCTAssertEqual(row("a").shortProjectPath, "…/Projects/App")
        XCTAssertEqual(row("a", cwd: "/tmp/Тест").shortProjectPath, "/tmp/Тест")
        XCTAssertEqual(row("a", cwd: "/").shortProjectPath, "/")
        let scratch = row("a", cwd: "/tmp/scratch-workspaces/private-id")
        XCTAssertEqual(scratch.shortProjectPath, scratch.project)
    }
}
