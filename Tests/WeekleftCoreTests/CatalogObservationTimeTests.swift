import XCTest
@testable import WeekleftCore

/// S-07: a catalog describes the moment its command started, not the moment
/// its output was parsed. `claude agents --json --all` took 0.14-0.45 s on the
/// owner's Mac; a hook event written inside that window must stay newer.
final class CatalogObservationTimeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogTime-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testClaudeCatalogIsStampedBeforeTheCommandRunsSoAStopDuringItWins() async throws {
        let id = "5d7a4a33-1c1e-4b0c-8a60-6f2d7c1b9e01"
        let script = try temporaryDirectory().appendingPathComponent("claude")
        let row: [String: Any] = ["pid": 51_234, "cwd": "/Users/fixture/Projects/lunavect", "kind": "interactive",
                                  "startedAt": 1_795_000_100_000, "sessionId": id, "name": "Fix widgets", "status": "busy"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [row]), as: UTF8.self)
        // The command takes its time before it answers, as `claude agents` does.
        try "#!/bin/sh\nsleep 0.5\ncat <<'JSON'\n\(json)\nJSON\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let started = Date()
        let rows = try await SessionSources.claude(path: script.path, isInternal: { _, _ in false })
        let finished = Date()
        let observed = try XCTUnwrap(rows.first).observedAt
        XCTAssertGreaterThanOrEqual(observed, started)
        XCTAssertLessThan(observed, finished.addingTimeInterval(-0.3), "Observation time is taken before the process starts")

        // Stop arrived while the command was still running.
        let stopAt = started.addingTimeInterval(0.25)
        let prompt = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": "UserPromptSubmit", "cwd": "/Users/fixture/Projects/lunavect"]),
            provider: .claude, previous: nil, now: started.addingTimeInterval(-30))
        let stop = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": "Stop", "cwd": "/Users/fixture/Projects/lunavect", "last_assistant_message": "Done."]),
            provider: .claude, previous: prompt, now: stopAt)
        let merged = try XCTUnwrap(SessionList.merge(catalog: rows, events: [stop.session], now: finished).first)
        XCTAssertEqual(merged.effectivePhase(now: finished), .ready, "The busy listing predates the Stop")
    }

    func testCodexPagesAreStampedWhenEachRequestStarts() throws {
        let id = "019a5f0e-1d2c-7b3a-8e4f-5a6b7c8d9e0f"
        var requestedAt: Date?
        let result = try SessionProcess.readCodexCatalog(deadline: 12, uptime: { 0 }) { _, _, _ in
            requestedAt = Date()
            Thread.sleep(forTimeInterval: 0.4)
            return ["data": [["id": id, "name": "Codex task", "status": ["type": "active", "activeFlags": []], "updatedAt": 1_789_200_000]],
                    "nextCursor": NSNull()]
        }
        let finished = Date()
        let started = try XCTUnwrap(requestedAt)
        let row = try XCTUnwrap(result.sessions.first)
        XCTAssertLessThan(row.observedAt, finished.addingTimeInterval(-0.3), "Observation time is the request start")
        // Both stamps are taken around one in-process call; 0.3 s tolerates a
        // descheduled thread on a loaded runner and still excludes the 0.4 s request.
        XCTAssertLessThanOrEqual(abs(row.observedAt.timeIntervalSince(started)), 0.3)

        let stop = try SessionRecord.event(JSONSerialization.data(withJSONObject: [
            "session_id": id, "hook_event_name": "Stop", "cwd": "/Users/fixture/Projects/codex"]),
            provider: .codex, previous: nil, now: started.addingTimeInterval(0.2))
        let merged = try XCTUnwrap(SessionList.merge(catalog: result.sessions, events: [stop.session], now: finished).first)
        XCTAssertEqual(merged.phase, .ready, "A Stop written during the request is newer than the page")
    }
}
