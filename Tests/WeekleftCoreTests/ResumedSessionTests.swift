import XCTest
@testable import WeekleftCore

/// S-14 / §5.20, decision 13: `claude --resume` opens an existing task. It is
/// shown as ready for work before its first prompt; only a fresh start or
/// /clear stays out of the list until real work begins.
final class ResumedSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func sessionStart(_ source: String?, id: String = "resumed") throws -> SessionRecord {
        var payload: [String: Any] = ["session_id": id, "hook_event_name": "SessionStart", "cwd": "/Users/fixture/Projects/lunavect"]
        if let source { payload["source"] = source }
        return try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude, previous: nil, now: start)
    }

    func testResumeAndForkAreReadyForWorkBeforeTheFirstPrompt() throws {
        for source in ["resume", "fork"] {
            let row = try sessionStart(source).session
            XCTAssertEqual(row.phase, .idle, source)
            XCTAssertEqual(row.hasTaskActivity, true, source)
            XCTAssertFalse(row.isUnstartedClaudeLifecycle, source)
            XCTAssertTrue(row.isCurrent(now: start.addingTimeInterval(1)), source)
            XCTAssertFalse(row.effectivePhase(now: start).isActive, "Ready, not working: \(source)")
            let catalog = AgentSession(provider: .claude, sessionID: "resumed", title: "Old task", cwd: "/Users/fixture/Projects/lunavect",
                                       phase: .idle, updatedAt: start.addingTimeInterval(-86400), observedAt: start.addingTimeInterval(2))
            let merged = try XCTUnwrap(SessionList.merge(catalog: [catalog], events: [row], now: start.addingTimeInterval(2)).first)
            XCTAssertTrue(merged.isCurrent(now: start.addingTimeInterval(2)), "A newer idle catalog keeps the resumed task visible: \(source)")
            XCTAssertEqual(merged.title, "Old task")
        }
    }

    func testFreshStartAndClearStayOutUntilWorkBegins() throws {
        for source in ["startup", "clear", nil] {
            let row = try sessionStart(source).session
            XCTAssertTrue(row.isUnstartedClaudeLifecycle, source ?? "no source")
            XCTAssertFalse(row.isCurrent(now: start.addingTimeInterval(1)))
        }
    }
}
