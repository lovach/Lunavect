import XCTest
@testable import WeekleftCore

/// Owner request 29.09: "на что ушли токены" per session, project, model and subagents, read from local logs.
final class TokenLedgerTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T20:00:00Z")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var sources: [ActivityHistoryImporter.Source] {
        [.init(directory: root.appendingPathComponent("codex"), provider: .codex), .init(directory: root.appendingPathComponent("claude"), provider: .claude)]
    }
    private func write(_ path: String, _ lines: [[String: Any]], append: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined()
        if append, let handle = try? FileHandle(forWritingTo: url) { try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close() }
        else { try Data(text.utf8).write(to: url) }
    }
    private func claude(_ id: String, input: Int, output: Int, cache: Int = 0, model: String = "claude-opus-5-5", time: String = "2026-09-29T19:00:00Z",
                        sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "sessionId": "s1", "cwd": "/Users/u/Lunavect", "timestamp": time, "isSidechain": sidechain,
         "message": ["id": id, "role": "assistant", "model": model, "usage": ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cache, "cache_creation_input_tokens": 0]]]
    }
    private func tokenCount(input: Int, cached: Int, output: Int, reasoning: Int, time: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": ["total_token_usage":
            ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]]]]
    }

    func testClaudeRepeatsOfOneResponseCountOnceAndSubagentsJoinTheirSession() throws {
        let file = "claude/-Users-u-Lunavect/11111111-1111-1111-1111-111111111111.jsonl"
        // One response written on three lines (text, tool use), usage repeated; the last reading is higher.
        try write(file, [claude("m1", input: 10, output: 4, cache: 1000), claude("m1", input: 10, output: 4, cache: 1000), claude("m1", input: 10, output: 9, cache: 1000),
                         ["type": "user", "sessionId": "s1", "message": ["role": "user", "content": "usage is fine"]]])
        try write("claude/-Users-u-Lunavect/11111111-1111-1111-1111-111111111111/subagents/agent-a1.jsonl",
                  [claude("m2", input: 5, output: 20, model: "claude-haiku-4-5", sidechain: true)])
        var ledger = TokenLedger()
        let report = ledger.scan(sources: sources, now: now)
        XCTAssertTrue(report.complete)
        let session = try XCTUnwrap(ledger.sessions["claude:s1"])
        XCTAssertEqual(session.total, TokenCounts(input: 15, cacheRead: 1000, output: 29))
        XCTAssertEqual(session.subagents, TokenCounts(input: 5, output: 20))
        XCTAssertEqual(session.models["claude-haiku-4-5"]?.output, 20)
        XCTAssertEqual(session.project, "Lunavect")
        XCTAssertEqual(ledger.daily["2026-09-29"]?[TokenLedger.entryKey(.claude, project: "Lunavect", model: "claude-opus-5-5", subagent: false)]?.output, 9)

        // Appended lines are read without counting the old ones again.
        try write(file, [claude("m3", input: 1, output: 1, time: "2026-09-29T19:30:00Z")], append: true)
        _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(ledger.sessions["claude:s1"]?.total.output, 30)
    }

    func testCodexCumulativeTotalsAddDifferencesAndSubagentsJoinTheParent() throws {
        try write("codex/2026/09/29/rollout-a.jsonl", [
            ["type": "session_meta", "payload": ["id": "t1", "cwd": "/Users/u/capsule", "source": "vscode"]],
            ["type": "turn_context", "payload": ["model": "gpt-6-astra", "cwd": "/Users/u/capsule"]],
            tokenCount(input: 1000, cached: 800, output: 50, reasoning: 20, time: "2026-09-29T18:00:00Z"),
            tokenCount(input: 1000, cached: 800, output: 50, reasoning: 20, time: "2026-09-29T18:00:01Z"),
            tokenCount(input: 3000, cached: 2600, output: 90, reasoning: 30, time: "2026-09-29T18:10:00Z")])
        try write("codex/2026/09/29/rollout-b.jsonl", [
            ["type": "session_meta", "payload": ["id": "t2", "cwd": "/Users/u/capsule",
                                                 "source": ["subagent": ["thread_spawn": ["parent_thread_id": "t1", "depth": 1]]]]],
            tokenCount(input: 100, cached: 0, output: 10, reasoning: 0, time: "2026-09-29T18:05:00Z")])
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        let session = try XCTUnwrap(ledger.sessions["codex:t1"])
        XCTAssertEqual(session.total, TokenCounts(input: 500, cacheRead: 2600, output: 70, reasoning: 30))
        XCTAssertEqual(session.subagents, TokenCounts(input: 100, output: 10))
        XCTAssertNil(ledger.sessions["codex:t2"], "a spawned thread is part of its parent session")
        XCTAssertEqual(session.models["gpt-6-astra"]?.reasoning, 30)
    }

    private func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(path).path)
    }
    private func codexTotal(_ ledger: TokenLedger, _ thread: String) -> Int64 { ledger.sessions["codex:" + thread]?.total.total ?? 0 }

    /// Audit 30.09: Codex continues a long thread in a new file (`history_base`) whose totals start from the
    /// earlier file's; it counts once whichever file is read first, and a reset total is not lost.
    func testACodexThreadContinuedInANewFileCountsOnce() throws {
        let base = "codex/2026/09/20/rollout-2026-09-20T02-00-00-t9.jsonl", next = "codex/2026/09/20/rollout-2026-09-20T13-00-00-t9_n1.jsonl"
        try write(base, [["type": "session_meta", "payload": ["id": "t9", "cwd": "/Users/u/capsule"]],
                         tokenCount(input: 1000, cached: 0, output: 100, reasoning: 0, time: "2026-09-29T10:00:00Z"),
                         tokenCount(input: 3000, cached: 0, output: 300, reasoning: 0, time: "2026-09-29T11:00:00Z")])
        try write(next, [["type": "session_meta", "payload": ["id": "t9", "cwd": "/Users/u/capsule", "history_base": ["thread_id": "t9", "end_byte_offset": 1]]],
                         tokenCount(input: 3500, cached: 0, output: 350, reasoning: 0, time: "2026-09-29T13:00:00Z"),
                         tokenCount(input: 4000, cached: 0, output: 400, reasoning: 0, time: "2026-09-29T14:00:00Z")])
        // The earlier file read first (it is the more recently written): exact.
        try setModified(next, now.addingTimeInterval(-7200)); try setModified(base, now.addingTimeInterval(-60))
        var first = TokenLedger(); _ = first.scan(sources: sources, now: now)
        XCTAssertEqual(codexTotal(first, "t9"), 4400)
        // The continuation read first: at most its first response is not counted, never the earlier file twice.
        try setModified(next, now.addingTimeInterval(-60)); try setModified(base, now.addingTimeInterval(-7200))
        var second = TokenLedger(); _ = second.scan(sources: sources, now: now)
        XCTAssertEqual(codexTotal(second, "t9"), 3300 + 550)
    }

    func testAResetCodexTotalCountsWhatWasSpentAfterIt() throws {
        try write("codex/2026/09/29/rollout-r.jsonl", [["type": "session_meta", "payload": ["id": "tr", "cwd": "/Users/u/capsule"]],
            tokenCount(input: 100, cached: 0, output: 0, reasoning: 0, time: "2026-09-29T10:00:00Z"),
            tokenCount(input: 150, cached: 0, output: 0, reasoning: 0, time: "2026-09-29T10:01:00Z"),
            tokenCount(input: 30, cached: 0, output: 0, reasoning: 0, time: "2026-09-29T10:02:00Z"),
            tokenCount(input: 50, cached: 0, output: 0, reasoning: 0, time: "2026-09-29T10:03:00Z")])
        var ledger = TokenLedger(); _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(codexTotal(ledger, "tr"), 150 + 30 + 20)
    }

    /// Codex moves finished rollouts to its archive: the same file under a new path is not read again.
    func testAMovedRolloutIsNotCountedAgain() throws {
        let path = "codex/2026/09/29/rollout-m.jsonl"
        try write(path, [["type": "session_meta", "payload": ["id": "tm", "cwd": "/Users/u/capsule"]],
                         tokenCount(input: 500, cached: 0, output: 50, reasoning: 0, time: "2026-09-29T10:00:00Z")])
        var ledger = TokenLedger(); _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(codexTotal(ledger, "tm"), 550)
        let archived = root.appendingPathComponent("codex/archived/rollout-m.jsonl")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(path), to: archived)
        _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(codexTotal(ledger, "tm"), 550)
    }

    /// Codex 0.159 writes no agent_message events: the reply comes from the turn's end or the assistant's message.
    func testTheLastCodexReplyIsReadFromItsTurnEnd() {
        XCTAssertEqual(SessionReply.reply(["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": " Completed 5 of 8. "]], provider: .codex),
                       "Completed 5 of 8.")
        XCTAssertEqual(SessionReply.reply(["type": "response_item", "payload": ["type": "message", "role": "assistant",
                                                                               "content": [["type": "output_text", "text": "Done: x"]]]], provider: .codex), "Done: x")
        XCTAssertNil(SessionReply.reply(["type": "response_item", "payload": ["type": "message", "role": "user",
                                                                             "content": [["type": "input_text", "text": "hi"]]]], provider: .codex))
    }

    /// Codex does not keep its error event; the limit travels with the turn's completion (codex-rs rollout policy).
    func testACodexTurnTheLimitEndedIsNotedAndTheLogsAreFound() throws {
        try write("codex/2026/09/29/rollout-a.jsonl", [
            ["type": "session_meta", "payload": ["id": "t1", "cwd": "/Users/u/capsule"]],
            ["type": "event_msg", "timestamp": "2026-09-29T18:00:00Z", "payload": ["type": "task_complete", "turn_id": "x", "last_agent_message": NSNull()]],
            ["type": "event_msg", "timestamp": "2026-09-29T19:30:00Z", "payload": ["type": "task_complete", "turn_id": "y", "last_agent_message": NSNull(),
                "error": ["message": "You\u{2019}ve hit your usage limit.", "codex_error_info": "usage_limit_exceeded"]]]])
        try write("codex/2026/09/29/rollout-b.jsonl", [
            ["type": "session_meta", "payload": ["id": "t2", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "t1"]]]]],
            ["type": "event_msg", "timestamp": "2026-09-29T19:40:00Z", "payload": ["type": "task_complete",
                "error": ["message": "limit", "codex_error_info": "usage_limit_exceeded"]]]])
        try write("claude/-Users-u-Lunavect/0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21.jsonl", [claude("m1", input: 10, output: 5)])
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(ledger.limitHits, ["codex:t1": ISO8601DateFormatter().date(from: "2026-09-29T19:30:00Z")!], "a finished turn and a subagent do not count")
        XCTAssertEqual(ledger.transcript(.codex, sessionID: "t1")?.lastPathComponent, "rollout-a.jsonl")
        XCTAssertEqual(ledger.transcript(.claude, sessionID: "0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21")?.lastPathComponent, "0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21.jsonl")
        XCTAssertNil(ledger.transcript(.codex, sessionID: "t2"))
    }

    /// Live check 30.09: Claude Code wrote 623 earlier responses back into one transcript hours later
    /// (same uuid and timestamp); a 64-id window counted them twice, 5.8 % too much over 35 days.
    func testCopiesOfEarlierResponsesWrittenBackLaterCountOnce() throws {
        var lines = [claude("m0", input: 10, output: 100, time: "2026-09-29T10:00:00Z")]
        for index in 1...80 { lines.append(claude("m\(index)", input: 1, output: 1, time: String(format: "2026-09-29T11:%02d:%02dZ", index / 60, index % 60))) }
        lines.append(claude("m0", input: 10, output: 100, time: "2026-09-29T10:00:00Z"))
        lines.append(claude("m81", input: 1, output: 1, time: "2026-09-29T12:30:00Z"))
        try write("claude/p/s1.jsonl", lines)
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(ledger.sessions["claude:s1"]?.total.output, 100 + 81)
        XCTAssertEqual(ledger.sessions["claude:s1"]?.total.input, 10 + 81)
    }

    func testLimitShareSplitsTheUsedPercentByWeight() throws {
        var ledger = TokenLedger()
        let calendar = Calendar(identifier: .gregorian)
        ledger.record(TokenCounts(output: 300), provider: .claude, session: "a", cwd: "/p/A", model: "m", subagent: false, at: now.addingTimeInterval(-3600), now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 100), provider: .claude, session: "b", cwd: "/p/B", model: "m", subagent: false, at: now.addingTimeInterval(-7200), now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 999), provider: .codex, session: "c", cwd: "/p/C", model: "m", subagent: false, at: now.addingTimeInterval(-3600), now: now, calendar: calendar)
        let week = try QuotaWindow(usedPercent: 40, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(try XCTUnwrap(ledger.limitPercent(of: ledger.sessions["claude:a"]!, window: week, now: now)), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(ledger.limitPercent(of: ledger.sessions["claude:b"]!, window: week, now: now)), 10, accuracy: 0.001)
        XCTAssertNil(ledger.limitPercent(of: ledger.sessions["claude:a"]!, window: nil, now: now))
        XCTAssertEqual(ledger.sessions["claude:a"]!.rate(now: now), 1500, accuracy: 1, "300 output tokens at weight 5 in the last hour")
    }

    func testOldDaysFeedTheArchiveButNotTheSessions() throws {
        var ledger = TokenLedger()
        let calendar = Calendar(identifier: .gregorian)
        let old = now.addingTimeInterval(-60 * 86400)
        ledger.record(TokenCounts(input: 7), provider: .claude, session: "old", cwd: "/p/X", model: "m", subagent: false, at: old, now: now, calendar: calendar)
        XCTAssertNil(ledger.sessions["claude:old"])
        XCTAssertEqual(ledger.daily[ActivityArchive.key(old, calendar: calendar)]?.values.first?.input, 7)
        ledger.pruneDays(now: now, calendar: calendar)
        XCTAssertFalse(ledger.daily.isEmpty, "the first pass keeps every day: its next slice may add to it")
        ledger.caughtUp = true
        ledger.pruneDays(now: now, calendar: calendar)
        XCTAssertTrue(ledger.daily.isEmpty, "the archive keeps old days; the ledger drops them")
        ledger.record(TokenCounts(input: 3), provider: .claude, session: "old", cwd: "/p/X", model: "m", subagent: false, at: old, now: now, calendar: calendar)
        XCTAssertTrue(ledger.daily.isEmpty, "after the first pass an old response would overwrite its archived day")
    }

    /// A resumed or forked session's new transcript starts with copies of earlier responses
    /// (1656 of 93852 responses on the owner's Mac, 30.09): each response counts once.
    func testCopiesInAResumedSessionsTranscriptCountOnce() throws {
        try write("claude/p/33333333-3333-3333-3333-333333333333.jsonl",
                  [claude("m1", input: 10, output: 100, time: "2026-09-29T10:00:00Z"), claude("m2", input: 1, output: 5, time: "2026-09-29T10:05:00Z")])
        var copy = claude("m1", input: 10, output: 100, time: "2026-09-29T10:00:00Z"); copy["sessionId"] = "s2"
        try write("claude/p/44444444-4444-4444-4444-444444444444.jsonl",
                  [copy, claude("m3", input: 2, output: 7, time: "2026-09-29T18:00:00Z")])
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        let total = ledger.sessions.values.reduce(TokenCounts()) { $0 + $1.total }
        XCTAssertEqual(total.output, 100 + 5 + 7)
        XCTAssertEqual(ledger.daily["2026-09-29"]?.values.reduce(0) { $0 + $1.output }, 112)
    }

    /// The first pass reads the logs in slices; a day older than the kept window keeps every slice's share.
    func testTheFirstPassKeepsOldDaysWholeAcrossSlices() throws {
        let calendar = Calendar(identifier: .gregorian)
        var ledger = TokenLedger()
        let old = now.addingTimeInterval(-50 * 86400)
        ledger.record(TokenCounts(output: 4), provider: .claude, session: "a", cwd: "/p", model: "m", subagent: false, at: old, now: now, calendar: calendar)
        ledger.pruneDays(now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 6), provider: .claude, session: "b", cwd: "/p", model: "m", subagent: false, at: old, now: now, calendar: calendar)
        XCTAssertEqual(ledger.daily[ActivityArchive.key(old, calendar: calendar)]?.values.reduce(0) { $0 + $1.output }, 10)
        // The archive takes the ledger's older days only when they rise.
        var archive = ActivityArchive()
        let day = ActivityArchive.key(old, calendar: calendar)
        archive.setTokens([day: ["k": TokenCounts(output: 50)]])
        archive.setTokens(ledger.daily, replaceFrom: "~")
        XCTAssertEqual(archive.days[day]?.tokens?["k"]?.output, 50, "a partial pass or deleted logs never lower an archived day")
        archive.setTokens([day: ["k": TokenCounts(output: 70)]], replaceFrom: "~")
        XCTAssertEqual(archive.days[day]?.tokens?["k"]?.output, 70)
        archive.setTokens([day: ["k": TokenCounts(output: 60)]], replaceFrom: day)
        XCTAssertEqual(archive.days[day]?.tokens?["k"]?.output, 60, "inside the kept window the ledger is the source")
    }

    func testRoundTripKeepsCursorsSoNothingIsCountedTwice() throws {
        try write("claude/p/22222222-2222-2222-2222-222222222222.jsonl", [claude("m1", input: 1, output: 2)])
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        let url = root.appendingPathComponent("ledger.json")
        try ledger.save(to: url)
        var loaded = try TokenLedger.load(from: url)
        XCTAssertEqual(loaded, ledger)
        _ = loaded.scan(sources: sources, now: now)
        XCTAssertEqual(loaded.sessions["claude:s1"]?.total.output, 2)
    }

    func testModelTitlesAndArchiveSummaryGroupTokensByProjectAndModel() throws {
        XCTAssertEqual(TokenLedger.modelTitle("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(TokenLedger.modelTitle("claude-opus-5"), "Opus 5")
        XCTAssertEqual(TokenLedger.modelTitle("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(TokenLedger.modelTitle("gpt-6-astra"), "gpt-6-astra")
        let calendar = Calendar(identifier: .gregorian)
        var ledger = TokenLedger()
        ledger.record(TokenCounts(output: 100), provider: .claude, session: "a", cwd: "/p/Lunavect", model: "claude-opus-5-5", subagent: false, at: now, now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 100), provider: .claude, session: "a", cwd: "/p/Lunavect", model: "claude-haiku-4-5", subagent: true, at: now, now: now, calendar: calendar)
        ledger.record(TokenCounts(output: 100), provider: .codex, session: "c", cwd: "/p/capsule", model: "gpt-6-astra", subagent: false, at: now, now: now, calendar: calendar)
        var archive = ActivityArchive()
        archive.setTokens(ledger.daily)
        let claudeOnly = ActivityArchiveSummary.make(archive, range: .week, providers: [.claude], now: now, calendar: calendar)
        XCTAssertEqual(claudeOnly.tokens.output, 200, "Codex tokens stay out of a Claude view")
        XCTAssertEqual(claudeOnly.tokenSubagentWeight, 500, accuracy: 0.001)
        XCTAssertEqual(claudeOnly.tokenProjects.map(\.name), ["Lunavect"])
        let both = ActivityArchiveSummary.make(archive, range: .week, providers: [.claude, .codex], now: now, calendar: calendar)
        // 200 Claude output tokens weigh 1000, 100 Codex output tokens 800: Codex output is priced higher per token.
        XCTAssertEqual(both.tokenProjects.map(\.name), ["Lunavect", "capsule"])
        XCTAssertEqual(both.tokenProjects.last?.weight ?? 0, 800, accuracy: 0.001)
    }

    /// Owner's Mac 30.09: lines of tens of megabytes (a written file, a long tool output) made one pass peak at 3 GB.
    func testHugeClaudeLinesAreReadWithoutParsingTheWholeLine() throws {
        let big = String(repeating: "x\\\"{}", count: 120_000)
        var line = claude("m-big", input: 3, output: 7, cache: 11, sidechain: false)
        var message = line["message"] as! [String: Any]
        message["content"] = [["type": "text", "text": big + " \"usage\":{\"output_tokens\":999999}"]]
        line["message"] = message
        try write("claude/p/33333333-3333-3333-3333-333333333333.jsonl", [line])
        let data = try Data(contentsOf: root.appendingPathComponent("claude/p/33333333-3333-3333-3333-333333333333.jsonl"))
        XCTAssertGreaterThan(data.count, TokenLedger.wholeLineLimit)
        var ledger = TokenLedger()
        _ = ledger.scan(sources: sources, now: now)
        XCTAssertEqual(ledger.sessions["claude:s1"]?.total, TokenCounts(input: 3, cacheRead: 11, output: 7),
                       "the real usage object is the last one, not text that looks like it")
        XCTAssertEqual(ledger.sessions["claude:s1"]?.models["claude-opus-5-5"]?.output, 7)
        XCTAssertEqual(ledger.sessions["claude:s1"]?.project, "Lunavect")
    }
}
