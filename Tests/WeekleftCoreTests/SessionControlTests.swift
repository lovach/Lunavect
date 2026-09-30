import XCTest
@testable import WeekleftCore

/// Owner decisions 30.09: a session stops when the week reaches the user's level; hooks refuse its next action.
final class SessionControlTests: XCTestCase {
    func testWrapUpComesBeforeTheLevelAndStopAtIt() {
        let control = SessionControl(provider: .claude, sessionID: "s", title: "t", cwd: "/p", stopAtWeek: 85, startLevel: 75)
        XCTAssertEqual(control.decide(weekLevel: 80), .watching)
        XCTAssertEqual(control.decide(weekLevel: 83), .wrappingUp, "80 % of the way from 75 to 85")
        XCTAssertEqual(control.decide(weekLevel: 85), .stopped)
        let close = SessionControl(provider: .claude, sessionID: "s", title: "t", cwd: "/p", stopAtWeek: 76, startLevel: 75.5)
        XCTAssertEqual(close.decide(weekLevel: 75), .wrappingUp, "at least one point before the level")
        XCTAssertEqual(SessionControl(provider: .codex, sessionID: "s", title: "t", cwd: "/p").decide(weekLevel: 99), .watching)
    }

    func testHooksRefuseTheNextActionOnlyInALimitedSession() throws {
        var file = SessionLimitFile()
        file.entries["claude:A"] = .init(state: .stopped, agent: "agent-stop", user: "user-stop")
        file.entries["codex:B"] = .init(state: .wrappingUp, agent: "agent-wrap", user: "user-wrap")
        func reply(_ event: String, _ session: String) throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": session])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.reply(payload: payload).utf8)) as? [String: Any])
        }
        let deny = try reply("PreToolUse", "A")["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(deny?["permissionDecision"] as? String, "deny")
        XCTAssertEqual(deny?["permissionDecisionReason"] as? String, "agent-stop")
        XCTAssertEqual(try reply("UserPromptSubmit", "A")["decision"] as? String, "block")
        XCTAssertEqual(try reply("UserPromptSubmit", "A")["reason"] as? String, "user-stop")
        XCTAssertEqual((try reply("PreToolUse", "B")["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String, "agent-wrap")
        XCTAssertTrue(try reply("PreToolUse", "other").isEmpty, "every other session gets {}")
        XCTAssertTrue(try reply("Stop", "A").isEmpty)
        XCTAssertEqual(SessionLimitFile().reply(payload: Data("not json".utf8)), "{}")
    }

    func testTheWeekLevelRunsAheadOfTheReadingAndFallsAfterTheReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = TokenLedger()
        let calendar = Calendar(identifier: .gregorian)
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-7200), now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-60), now: now, calendar: calendar)
        let week = try QuotaWindow(usedPercent: 50, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let snapshot = UsageSnapshot(provider: .claude, weekly: week, fetchedAt: now.addingTimeInterval(-1800))
        // 50 % over 10,000 weighted units; 5,000 more since the reading adds 25 points.
        XCTAssertEqual(try XCTUnwrap(WeekLevel.estimate(snapshot: snapshot, ledger: ledger, now: now)), 75, accuracy: 0.01)
        let passed = UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 90, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-60)), fetchedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(WeekLevel.estimate(snapshot: passed, ledger: ledger, now: now), 0)
    }

    func testTypedTextIsOneQuotedLine() {
        XCTAssertEqual(TerminalLocation.typedText("say \"hi\"\nnow \\ ok"), "say \\\"hi\\\" now \\\\ ok")
        XCTAssertNil(TerminalLocation.typeScript(tty: "/dev/ttys001; rm", app: "Terminal", text: "x"))
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "iTerm2", text: "go")?.contains("write text \"go\"") == true)
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go")?.contains("do script \"go\" in t") == true)
    }
}
