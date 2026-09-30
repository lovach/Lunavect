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

    func testTheFiveHourGuardWrapsUpThenRestsAndTheWeekStopComesFirst() {
        var control = SessionControl(provider: .claude, sessionID: "s", title: "t", cwd: "/p", stopAtWeek: 60, startLevel: 40)
        control.fiveHourGuard = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(control.decide(weekLevel: 45, fiveHourLevel: 50, now: now).state, .watching)
        XCTAssertEqual(control.decide(weekLevel: 45, fiveHourLevel: 90, now: now).reason, .fiveHour)
        XCTAssertEqual(control.decide(weekLevel: 45, fiveHourLevel: 97, now: now).state, .resting)
        XCTAssertEqual(control.decide(weekLevel: 61, fiveHourLevel: 97, now: now).state, .stopped, "the week's stop is final and comes first")
        XCTAssertEqual(control.decide(weekLevel: 57, fiveHourLevel: 97, now: now).state, .resting, "a rest outranks the week's wrap-up")
        control.guardOffUntil = now.addingTimeInterval(60)
        XCTAssertEqual(control.decide(weekLevel: 45, fiveHourLevel: 97, now: now).state, .watching, "continued by hand until the next window")
    }

    func testTheSuggestedLevelSpreadsTheRestOfTheWeekOverTheDaysLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SessionControl.suggestedStop(level: 40, resetsAt: now.addingTimeInterval(3.5 * 86400), now: now), 55)
        XCTAssertEqual(SessionControl.suggestedStop(level: 90, resetsAt: now.addingTimeInterval(3600), now: now), 100, "the last day may use the rest")
        XCTAssertEqual(SessionControl.suggestedStop(level: 40, resetsAt: nil, now: now), 50)
    }

    func testTheSummaryAndTheLastReplyComeFromTheAgentsOwnWords() throws {
        XCTAssertEqual(SessionControl.summaryParts(L("Сделано:") + " экспорт.\n" + L("Осталось:") + " тесты.")?.left, "тесты.")
        XCTAssertNil(SessionControl.summaryParts("Всё готово."))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Сделано: всё."]]]],
            ["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent"]]]],
            ["type": "assistant", "isApiErrorMessage": true, "message": ["content": [["type": "text", "text": "Claude usage limit reached"]]]]]
        try Data(lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8).write(to: url)
        XCTAssertEqual(SessionReply.last(in: url, provider: .claude), "Сделано: всё.", "an API error line and a subagent are not the reply")
        XCTAssertEqual(SessionReply.reply(["type": "event_msg", "payload": ["type": "agent_message", "message": " done "]], provider: .codex), "done")
    }

    func testResumeCommandsAreQuotedAndOnlyForRealSessionIDs() {
        XCTAssertEqual(TerminalLocation.resumeCommand(provider: .claude, sessionID: "0f3c2a51-5e2b", text: "it's\nok", cwd: "/p/a b"),
                       "cd '/p/a b' && claude --resume 0f3c2a51-5e2b 'it'\\''s ok'")
        XCTAssertEqual(TerminalLocation.resumeCommand(provider: .codex, sessionID: "019a0c0a-96ca", text: "go"), "codex resume 019a0c0a-96ca 'go'")
        XCTAssertNil(TerminalLocation.resumeCommand(provider: .claude, sessionID: "x; rm -rf ~", text: "go"))
        XCTAssertEqual(TerminalLocation.resumeCommand(provider: .claude, sessionID: "0f3c2a51-5e2b", text: "go", cwd: "relative"), "claude --resume 0f3c2a51-5e2b 'go'")
        let script = TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go", command: "claude --resume 0f3c2a51-5e2b 'go'") ?? ""
        XCTAssertTrue(script.contains("do script \"go\" in t") && script.contains("do script \"claude --resume 0f3c2a51-5e2b 'go'\" in t"),
                      "the message while the agent runs, the resume command at a shell prompt")
    }

    func testClaudeAutomaticContinueFollowsItsSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let managed = home.appendingPathComponent("managed.json")
        XCTAssertTrue(ClaudeAutoContinue.enabled(home: home, managed: managed), "on by default")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"autoContinueAtUsageLimit": false}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        XCTAssertFalse(ClaudeAutoContinue.enabled(home: home, managed: managed))
        try Data(#"{"autoContinueAtUsageLimit": true}"#.utf8).write(to: managed)
        XCTAssertTrue(ClaudeAutoContinue.enabled(home: home, managed: managed), "managed settings come first")
    }

    func testTypedTextIsOneQuotedLine() {
        XCTAssertEqual(TerminalLocation.typedText("say \"hi\"\nnow \\ ok"), "say \\\"hi\\\" now \\\\ ok")
        XCTAssertNil(TerminalLocation.typeScript(tty: "/dev/ttys001; rm", app: "Terminal", text: "x"))
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "iTerm2", text: "go")?.contains("write text \"go\"") == true)
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go")?.contains("do script \"go\" in t") == true)
    }
}
