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
        file.entries["claude:A"] = .init(state: .stopped, agent: "agent-stop", continued: "agent-continued")
        file.entries["codex:B"] = .init(state: .wrappingUp, agent: "agent-wrap")
        func reply(_ event: String, _ session: String) throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": session])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.reply(payload: payload).utf8)) as? [String: Any])
        }
        let deny = try reply("PreToolUse", "A")["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(deny?["permissionDecision"] as? String, "deny")
        XCTAssertEqual(deny?["permissionDecisionReason"] as? String, "agent-stop")
        // Owner 30.09: the user's own message is never blocked; it lifts the stop.
        XCTAssertNil(try reply("UserPromptSubmit", "A")["decision"])
        XCTAssertEqual((try reply("UserPromptSubmit", "A")["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String, "agent-continued")
        let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse", "session_id": "A"])
        XCTAssertEqual(file.reply(payload: payload, overridden: ["claude:A"]), "{}", "the agent's next actions follow the user's message")
        XCTAssertEqual((try reply("PreToolUse", "B")["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String, "agent-wrap")
        XCTAssertTrue(try reply("PreToolUse", "other").isEmpty, "every other session gets {}")
        XCTAssertTrue(try reply("Stop", "A").isEmpty)
        XCTAssertEqual(SessionLimitFile().reply(payload: Data("not json".utf8)), "{}")
    }

    /// Only Lunavect lifts an entry; when it is not running, the entry lapses with its window's reset.
    func testALimitEntryLapsesAfterItsWindowResets() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        var file = SessionLimitFile()
        file.entries["claude:A"] = .init(state: .stopped, agent: "agent-stop", until: reset)
        let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse", "session_id": "A"])
        XCTAssertTrue(file.reply(payload: payload, now: reset.addingTimeInterval(-1)).contains("deny"))
        XCTAssertEqual(file.reply(payload: payload, now: reset), "{}")
        let old = try JSONDecoder().decode(SessionLimitFile.self, from: Data(#"{"entries":{"claude:A":{"state":"stopped","agent":"a","user":"u"}}}"#.utf8))
        XCTAssertTrue(old.reply(payload: payload, now: reset).contains("deny"), "an entry without a date stays until Lunavect lifts it")
    }

    func testTheWeekLevelRunsAheadOfTheReadingAndFallsAfterTheReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = TokenLedger()
        let calendar = Calendar(identifier: .gregorian)
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-7200), now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-60), now: now, calendar: calendar)
        let week = try QuotaWindow(usedPercent: 50, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let snapshot = UsageSnapshot(provider: .claude, weekly: week, fetchedAt: now.addingTimeInterval(-1800))
        XCTAssertEqual(WeekLevel.estimate(snapshot: snapshot, ledger: ledger, now: now), 50, "a ledger still on its first pass adds nothing")
        ledger.caughtUp = true
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
        // Live check 30.09: Codex took the one Return of a fast burst as a new line; a second one after a pause sends it.
        XCTAssertFalse(script.contains("delay 0.6"))
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go", submitAgain: true)?.contains("delay 0.6\ndo script \"\" in t") == true)
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "iTerm2", text: "go", submitAgain: true)?.contains("tell s to write text \"\"") == true)
        // Live check 30.09: Claude Code's fullscreen interface sends only on a carriage return; Terminal's own line feed is a new line.
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go", carriageReturn: true)?.contains("do script (\"go\" & return) in t") == true)
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "", carriageReturn: true)?.contains("do script (\"\" & return) in t") == true,
                      "Enter alone for a Claude Code waiting after the limit")
        // Live check 30.09: the native installer's process is named by its version, not "claude".
        XCTAssertTrue(script.contains(#""0123456789" contains (character 1 of pn)"#))
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go", agent: "my \"agent\"")?.contains(#""my \"agent\"""#) == true)
    }

    /// The hook notes the user's message to a stopped session and lets the agent act again.
    func testTheUsersMessageLiftsAStopInTheHook() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let limits = folder.appendingPathComponent("limits.json"), overrides = folder.appendingPathComponent("limit-overrides.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try SessionLimitFile(entries: ["codex:A": .init(state: .stopped, agent: "agent-stop", continued: "agent-continued")]).save(to: limits)
        func event(_ name: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": "A"]) }
        XCTAssertTrue(SessionLimitFile.answer(payload: try event("PreToolUse"), limits: limits, overrides: overrides, now: now).contains("deny"))
        XCTAssertTrue(SessionLimitOverrides.load(from: overrides).sessions.isEmpty, "the agent's own action notes nothing")
        XCTAssertTrue(SessionLimitFile.answer(payload: try event("UserPromptSubmit"), limits: limits, overrides: overrides, now: now).contains("agent-continued"))
        XCTAssertEqual(SessionLimitOverrides.load(from: overrides).sessions["codex:A"], now)
        XCTAssertEqual(SessionLimitFile.answer(payload: try event("PreToolUse"), limits: limits, overrides: overrides, now: now), "{}")
        XCTAssertEqual(SessionLimitFile.answer(payload: try event("PreToolUse"), limits: limits, overrides: overrides, now: now), "{}")
    }

    /// A long message is cut before quoting: the command always closes its quotes.
    func testALongMessageKeepsTheResumeCommandWhole() throws {
        let text = String(repeating: "слово ", count: 90)
        let command = try XCTUnwrap(TerminalLocation.resumeCommand(provider: .claude, sessionID: "0f3c2a51-5e2b", text: text,
                                                                   cwd: "/Users/u/Projects/" + String(repeating: "deep/", count: 20)))
        XCTAssertTrue(command.hasSuffix("'"))
        let script = try XCTUnwrap(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: text, command: command))
        XCTAssertTrue(script.contains(TerminalLocation.scriptLine(command)), "the whole command reaches the shell")
        XCTAssertTrue(TerminalLocation.openScript(app: "Terminal", command: command).contains(TerminalLocation.scriptLine(command)))
        XCTAssertEqual(TerminalLocation.resumeCommand(provider: .codex, sessionID: "019a0c0a-96ca", text: "-v please"), "codex resume 019a0c0a-96ca ' -v please'",
                       "a message is never read as an option")
    }

    /// The session's agent is gone from the device: a program there is someone else's and gets no text.
    func testNoTextForAnotherProgramOnTheDevice() throws {
        let script = try XCTUnwrap(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go", command: "cd '/p' && claude --resume 0f3c2a51-5e2b 'go'",
                                                               agent: "2.1.283", agentAllowed: false))
        XCTAssertFalse(script.contains("\"node\""))
        XCTAssertFalse(script.contains("\"2.1.283\""))
        XCTAssertFalse(script.contains("character 1 of pn"))
        XCTAssertTrue(script.contains("do script \"cd '/p' && claude --resume 0f3c2a51-5e2b 'go'\" in t"), "a shell prompt still resumes it")
        let iterm = try XCTUnwrap(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "iTerm2", text: "go", agentAllowed: false))
        XCTAssertTrue(iterm.contains("if {} contains job or false then"))
    }

    /// Claude Code's own wait for a usage limit reaches the merged row of a Terminal session.
    func testTheLimitWaitSurvivesTheCatalogMerge() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = AgentSession(provider: .claude, sessionID: "S", title: "t", cwd: "/p", phase: .idle, updatedAt: at, observedAt: at, runtimeConfirmed: true)
        var event = AgentSession(provider: .claude, sessionID: "S", title: "t", cwd: "/p", phase: .failed, updatedAt: at, observedAt: at.addingTimeInterval(-5),
                                 evidence: .hook)
        event.limitWait = "stale"; event.limitWaitAt = at
        let merged = SessionList.merge(catalog: [catalog], events: [event], now: at.addingTimeInterval(10)).first
        XCTAssertEqual(merged?.limitWait, "stale")
        XCTAssertEqual(merged?.limitWaitAt, at)
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

    /// Live check 30.09: hourly buckets counted the tokens spent before a reading in the same hour
    /// as spent after it. Within six hours the ledger keeps minutes.
    func testOnlyTokensAfterTheReadingRaiseTheFiveHourLevel() throws {
        let now = Date(timeIntervalSince1970: 1_800_001_800)   // half past an hour
        var ledger = TokenLedger(); ledger.recentFrom = now.addingTimeInterval(-TokenLedger.recentSpan); ledger.caughtUp = true
        let calendar = Calendar(identifier: .gregorian)
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-1500), now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 3000), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: now.addingTimeInterval(-300), now: now, calendar: calendar)
        let window = try QuotaWindow(usedPercent: 10, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))
        let snapshot = UsageSnapshot(provider: .claude, fiveHour: window, fetchedAt: now.addingTimeInterval(-1200))
        // 10 % over the 5,000 units spent before the reading; 15,000 after it add 30 points
        // (whole hours gave 20: the ratio over 20,000 units times 20,000 "since").
        XCTAssertEqual(try XCTUnwrap(WeekLevel.estimate(snapshot: snapshot, window: window, ledger: ledger, now: now)), 40, accuracy: 0.01)
        ledger.pruneSessions(now: now.addingTimeInterval(7 * 3600))
        XCTAssertEqual(ledger.recent?["claude"]?.isEmpty, true, "minutes older than six hours are dropped")
    }

    /// Live check 30.09: Codex's `hooks/list` showed Lunavect's hooks "modified" while the others were trusted.
    func testCodexHookTrustComesFromLunavectsOwnHooks() {
        func list(_ lunavect: [String], other: String = "trusted") -> [String: Any] {
            let marker = "'/x/LunavectHook' --session-hook codex # lunavect-session-monitor:codex"
            return ["data": [["cwd": "/Users/u", "hooks": lunavect.map { ["handlerType": "command", "command": marker, "trustStatus": $0] }
                + [["handlerType": "command", "command": "node statusbar.js", "trustStatus": other]], "warnings": [], "errors": []]]]
        }
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list(["trusted", "trusted"], other: "modified")), .trusted, "only Lunavect's hooks count")
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list(["trusted", "modified"])), .untrusted)
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list(["untrusted"])), .untrusted)
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list(["trusted", "pending"])), .unknown, "a status Lunavect does not know warns of nothing")
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list(["managed"])), .trusted)
        XCTAssertEqual(CodexProvider.hookTrust(fromList: list([])), .unknown, "no Lunavect hook: nothing to warn about")
        XCTAssertEqual(CodexProvider.hookTrust(fromList: [:]), .unknown)
    }

    func testTypedTextIsOneQuotedLine() {
        XCTAssertEqual(TerminalLocation.typedText("say \"hi\"\nnow \\ ok"), "say \\\"hi\\\" now \\\\ ok")
        XCTAssertNil(TerminalLocation.typeScript(tty: "/dev/ttys001; rm", app: "Terminal", text: "x"))
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "iTerm2", text: "go")?.contains("write text \"go\"") == true)
        XCTAssertTrue(TerminalLocation.typeScript(tty: "/dev/ttys012", app: "Terminal", text: "go")?.contains("do script \"go\" in t") == true)
    }
}
