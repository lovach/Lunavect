import XCTest
@testable import WeekleftCore

final class CodexActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ type: String, at time: Date, turn: String = "turn-1", extra: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = ["type": type, "turn_id": turn]
        extra.forEach { payload[$0] = $1 }
        return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: time), "payload": payload])
    }
    var catalog: AgentSession {
        AgentSession(provider: .codex, sessionID: "test-id", title: "Настрой проект", cwd: "/work", phase: .unknown, updatedAt: now, observedAt: now, runtimeConfirmed: false)
    }
    func testRealTurnEventsReviveNotLoadedCatalogAndCompletionStopsSpinner() throws {
        var state = CodexActivityState()
        try state.consume(event("task_started", at: now), sessionID: catalog.sessionID)
        let running = try XCTUnwrap(state.session(from: catalog))
        XCTAssertEqual(running.effectivePhase(now: now), .running)
        XCTAssertEqual(running.turnStartedAt, now)
        XCTAssertEqual(SessionList.merge(catalog: [catalog], events: [running], now: now).first?.title, "Настрой проект")
        try state.consume(event("task_complete", at: now.addingTimeInterval(10), extra: ["last_agent_message": "PRIVATE"]), sessionID: catalog.sessionID)
        let ready = try XCTUnwrap(state.session(from: catalog))
        XCTAssertEqual(ready.effectivePhase(now: now.addingTimeInterval(10)), .ready)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ready), as: UTF8.self).contains("PRIVATE"))
        try state.consume(event("item_completed", at: now.addingTimeInterval(11)), sessionID: catalog.sessionID)
        XCTAssertEqual(state.phase, .ready)
    }
    func testStaleActivityDoesNotBecomeFreshOnRepeatedPollsAndOtherThreadIsIgnored() throws {
        var state = CodexActivityState()
        try state.consume(event("task_started", at: now), sessionID: catalog.sessionID)
        try state.consume(event("item_completed", at: now.addingTimeInterval(10), extra: ["thread_id": "different"]), sessionID: catalog.sessionID)
        XCTAssertEqual(state.observedAt, now)
        XCTAssertFalse(try XCTUnwrap(state.session(from: catalog)).isCurrent(now: now.addingTimeInterval(121)))
    }
    func testReaderHandlesPartialAppendAndRejectsSymlinks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-test-id.jsonl")
        var start = Data(#"{"type":"session_meta","payload":{"id":"test-id","originator":"Codex Desktop","instructions":"PRIVATE"}}"#.utf8)
        start.append(10); start.append(try event("task_started", at: now)); start.append(10)
        try start.write(to: file)
        var row = catalog; row.activityPath = file.path
        let reader = CodexActivityReader(home: home)
        let first = await reader.events(catalog: [row])
        XCTAssertEqual(first.first?.phase, .running)
        XCTAssertEqual(first.first?.client, .desktop)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let finish = try event("task_complete", at: now.addingTimeInterval(5))
        try handle.write(contentsOf: finish.prefix(finish.count / 2))
        let partial = await reader.events(catalog: [row])
        XCTAssertEqual(partial.first?.phase, .running)
        try handle.write(contentsOf: finish.suffix(from: finish.count / 2) + Data([10]))
        let completed = await reader.events(catalog: [row])
        XCTAssertEqual(completed.first?.phase, .ready)
        let repeated = await reader.events(catalog: [row])
        XCTAssertEqual(repeated.first?.observedAt, now.addingTimeInterval(5))
        let link = dir.appendingPathComponent("link-test-id.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        row.activityPath = link.path
        let rejected = await reader.events(catalog: [row])
        XCTAssertTrue(rejected.isEmpty)
    }
}
