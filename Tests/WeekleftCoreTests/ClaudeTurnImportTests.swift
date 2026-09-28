import XCTest
@testable import WeekleftCore

/// Synthetic Claude Code transcripts in the public JSONL shape: one object per
/// line with `type`, `timestamp`, `isSidechain`, `sessionId`, `cwd` and a
/// `message`. No user transcript is read; every value here is made up.
final class ClaudeTurnImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "5d2c3f0e-0a8e-4c4b-9e55-1f3c6a7b8d90"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeTurnImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset))
    }
    private func row(_ type: String, _ offset: TimeInterval, sidechain: Bool = false, _ extra: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [
            "parentUuid": UUID().uuidString, "isSidechain": sidechain, "userType": "external", "cwd": "/tmp/fixture-project",
            "sessionId": session, "version": "2.1.0", "gitBranch": "main", "type": type, "uuid": UUID().uuidString,
            "timestamp": stamp(offset),
        ]
        for (key, item) in extra { value[key] = item }
        return value
    }
    private func prompt(_ offset: TimeInterval, sidechain: Bool = false, text: String = "PRIVATE PROMPT") -> [String: Any] {
        row("user", offset, sidechain: sidechain, ["message": ["role": "user", "content": text]])
    }
    private func blocksPrompt(_ offset: TimeInterval) -> [String: Any] {
        row("user", offset, ["message": ["role": "user", "content": [["type": "text", "text": "PRIVATE PROMPT WITH IMAGE"],
                                                                     ["type": "image", "source": ["type": "base64", "data": "AAAA"]]]]])
    }
    private func assistant(_ offset: TimeInterval, sidechain: Bool = false, blocks: [[String: Any]]? = nil) -> [String: Any] {
        row("assistant", offset, sidechain: sidechain, ["requestId": "req_fixture", "message": [
            "id": "msg_fixture", "type": "message", "role": "assistant", "model": "claude-fixture",
            "content": blocks ?? [["type": "text", "text": "PRIVATE ANSWER"]], "stop_reason": NSNull(),
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]])
    }
    private func toolUse(_ offset: TimeInterval, name: String = "Bash", id: String) -> [String: Any] {
        assistant(offset, blocks: [["type": "tool_use", "id": id, "name": name, "input": ["command": "PRIVATE COMMAND"]]])
    }
    private func toolResult(_ offset: TimeInterval, id: String, timing: [String: Any] = ["stdout": "PRIVATE OUTPUT", "stderr": "", "interrupted": false]) -> [String: Any] {
        row("user", offset, ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "PRIVATE OUTPUT", "is_error": false]]],
                             "toolUseResult": timing])
    }
    private func system(_ subtype: String, _ offset: TimeInterval, _ extra: [String: Any] = [:]) -> [String: Any] {
        var extra = extra; extra["subtype"] = subtype; extra["level"] = "info"; extra["content"] = "fixture"
        return row("system", offset, extra)
    }
    private func write(_ rows: [[String: Any]], name: String? = nil, to root: URL, trailing: Data? = nil) throws {
        var data = try rows.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        if let trailing { data.append(trailing) }
        let url = root.appendingPathComponent((name ?? session) + ".jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    private func read(_ root: URL, before boundary: Date? = nil) -> ActivityImportResult {
        ActivityHistoryImporter.read(sources: [.init(directory: root, provider: .claude)], before: boundary ?? now, now: now)
    }
    private func seconds(_ result: ActivityImportResult) -> TimeInterval {
        result.intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    func testPromptToLastAssistantOrStopHookFormsRecoveredTurns() throws {
        let root = try directory()
        try write([
            prompt(-600), assistant(-590, blocks: [["type": "thinking", "thinking": String(repeating: "x", count: 9000), "signature": "sig"]]),
            toolUse(-580, id: "toolu_1"), toolResult(-500, id: "toolu_1"), assistant(-400), system("stop_hook_summary", -395),
            blocksPrompt(-300), assistant(-200),
        ], to: root)
        let result = read(root)
        XCTAssertEqual(seconds(result), 205 + 100)
        XCTAssertTrue(result.intervals.allSatisfy { $0.recovered == true && $0.providers == 1 })
        let report = try XCTUnwrap(result.report.providers.first)
        XCTAssertEqual(report.taskRecords, 2)
        XCTAssertEqual(report.filesWithoutTiming, 0)
        XCTAssertFalse(result.limited)
        let detail = try XCTUnwrap(result.details.first)
        XCTAssertEqual(detail.sessionID, session); XCTAssertEqual(detail.cwd, "/tmp/fixture-project")
        XCTAssertEqual(ActivityDetails.totals(for: [detail], in: DateInterval(start: now.addingTimeInterval(-3600), end: now)).active, 305)
        let persisted = String(decoding: try JSONEncoder().encode(result.report), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(result.intervals), as: UTF8.self)
        XCTAssertFalse(persisted.contains("PRIVATE"))
    }

    func testToolResultRowsContinueTheTurnInsteadOfStartingOne() throws {
        let root = try directory()
        try write([prompt(-1000), toolUse(-990, id: "toolu_a"), toolResult(-900, id: "toolu_a"), assistant(-890)], to: root)
        XCTAssertEqual(seconds(read(root)), 110)
    }

    func testTurnWithoutAssistantReplyIsNotWork() throws {
        let root = try directory()
        // A prompt that never got an answer, a prompt answered 50 s later, and a trailing unanswered prompt.
        try write([prompt(-500), prompt(-400), assistant(-350), prompt(-100)], to: root)
        let result = read(root)
        XCTAssertEqual(seconds(result), 50)
        XCTAssertEqual(result.report.providers.first?.taskRecords, 1)
    }

    func testLongTurnsCountLikeLiveWorkAndIdleGapsInsideATurnAreNotWork() throws {
        let root = try directory()
        // R3-05: three hours of continuous activity (a row every ten minutes) count
        // in full, as live observation and Codex tasks count them; only silences split.
        var continuous = [prompt(-5 * 3600)]
        for step in 1...18 { continuous.append(assistant(-5 * 3600 + Double(step) * 600)) }
        try write(continuous, name: "continuous", to: root)
        XCTAssertEqual(seconds(read(root)), 10_800)
        let gap = try directory()
        // A permission request left open for two hours splits the turn; the wait is not counted.
        try write([prompt(-3 * 3600), toolUse(-3 * 3600 + 10, id: "toolu_wait"), toolResult(-3000, id: "toolu_wait"), assistant(-2940)], to: gap)
        XCTAssertEqual(seconds(read(gap)), 10 + 60)
    }

    /// R3-05: live accounting counts neither Input needed nor the wait for a plan
    /// approval. A question to the user (AskUserQuestion) or a plan waiting for
    /// approval (ExitPlanMode) splits the recovered turn until the answer arrives.
    func testQuestionsAndPlanApprovalsInsideATurnAreNotWork() throws {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            let root = try directory()
            try write([prompt(-3000), assistant(-2990), toolUse(-2980, name: tool, id: "toolu_ask"),
                       toolResult(-2380, id: "toolu_ask", timing: ["answers": ["PRIVATE": "PRIVATE"]]), assistant(-2370)], to: root)
            XCTAssertEqual(seconds(read(root)), 20 + 10, "\(tool): ten minutes waiting for the user are not counted")
        }
        // Other tools keep the turn going while they run.
        let root = try directory()
        try write([prompt(-3000), toolUse(-2980, id: "toolu_build"), toolResult(-2380, id: "toolu_build"), assistant(-2370)], to: root)
        XCTAssertEqual(seconds(read(root)), 630)
    }

    /// R3-04: re-importing for a boundary in the past reads only journals that can
    /// hold records before it: a file created after the boundary cannot. A boundary
    /// older than the 35-day window reads nothing at all.
    func testReimportSkipsJournalsThatCannotPrecedeTheBoundary() throws {
        let root = try directory(), boundary = now.addingTimeInterval(-10 * 86400)
        try write([prompt(-15 * 86400), assistant(-15 * 86400 + 60), prompt(-60), assistant(-30)], name: "spanning", to: root)
        try write([prompt(-3 * 86400), assistant(-3 * 86400 + 60)], name: "later", to: root)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-20 * 86400)],
                                              ofItemAtPath: root.appendingPathComponent("spanning.jsonl").path)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-5 * 86400)],
                                              ofItemAtPath: root.appendingPathComponent("later.jsonl").path)
        let result = read(root, before: boundary)
        XCTAssertEqual(seconds(result), 60, "Only the turn before the boundary")
        XCTAssertEqual(result.report.providers.first?.filesRead, 1, "The journal created after the boundary is not read")
        XCTAssertFalse(result.limited)
        let expired = read(root, before: now.addingTimeInterval(-36 * 86400))
        XCTAssertEqual(expired.report.providers.first?.filesRead, 0, "Nothing inside the window can precede an older boundary")
        XCTAssertEqual(expired.report.providers.first?.bytesRead, 0)
        XCTAssertTrue(expired.intervals.isEmpty)
        XCTAssertFalse(expired.limited)
    }

    func testAgentToolAndTurnDurationUnionWithMessageTurnsWithoutDoubleCounting() throws {
        let root = try directory()
        try write([
            prompt(-300), toolUse(-290, name: "Agent", id: "toolu_agent"),
            toolResult(-80, id: "toolu_agent", timing: ["status": "completed", "agentId": "fixture-agent", "totalDurationMs": 200_000]),
            assistant(-70), system("turn_duration", -70, ["durationMs": 230_000]),
        ], to: root)
        let result = read(root)
        XCTAssertEqual(seconds(result), 230)
        let report = try XCTUnwrap(result.report.providers.first)
        XCTAssertEqual(report.agentRecords, 1)
        XCTAssertEqual(report.recoveredSeconds, 230)
        // turn_duration is still honored on its own.
        let legacy = try directory()
        try write([system("turn_duration", -10, ["durationMs": 45_000])], to: legacy)
        XCTAssertEqual(seconds(read(legacy)), 45)
    }

    func testSidechainRowsNeverSplitOrStartAMainTurn() throws {
        let root = try directory()
        try write([
            prompt(-300), toolUse(-290, name: "Agent", id: "toolu_side"),
            prompt(-280, sidechain: true, text: "PRIVATE SUBAGENT PROMPT"), assistant(-100, sidechain: true),
            toolResult(-90, id: "toolu_side"), assistant(-80),
        ], to: root)
        XCTAssertEqual(seconds(read(root)), 220)
        // A separate subagent transcript contains only sidechain rows.
        let subagent = try directory()
        try write([prompt(-280, sidechain: true), assistant(-100, sidechain: true)], name: "\(session)/subagents/agent-fixture", to: subagent)
        XCTAssertEqual(seconds(read(subagent)), 0)
    }

    func testMetaCompactionAndInterruptionRowsDoNotStartTurns() throws {
        let root = try directory()
        try write([
            prompt(-600), assistant(-500), system("compact_boundary", -450),
            row("user", -440, ["isCompactSummary": true, "isVisibleInTranscriptOnly": true, "message": ["role": "user", "content": "PRIVATE SUMMARY"]]),
            row("user", -430, ["isMeta": true, "message": ["role": "user", "content": "PRIVATE CAVEAT"]]),
            assistant(-400),
        ], to: root)
        XCTAssertEqual(seconds(read(root)), 200)
        let interrupted = try directory()
        // An interruption ends the running turn at its last answer; it is not a new answered turn.
        try write([prompt(-300), assistant(-250), toolUse(-240, id: "toolu_int"), prompt(-200, text: "[Request interrupted by user]")], to: interrupted)
        XCTAssertEqual(seconds(read(interrupted)), 60)
    }

    func testTruncatedLastLineKeepsEarlierTurnsAndIsInformational() throws {
        let root = try directory()
        try write([prompt(-100), assistant(-60)], to: root, trailing: Data("{\"type\":\"assistant\",\"timestamp\":\"\(stamp(-50))\",\"message\":{\"content\":[{\"type\":\"te".utf8))
        let result = read(root)
        XCTAssertEqual(seconds(result), 40)
        XCTAssertEqual(result.report.providers.first?.issues[.malformed], 1)
        XCTAssertFalse(result.limited, "A truncated record is reported, not a limit on the whole import")
    }

    func testTurnsAreClippedAtTheLiveObservationBoundary() throws {
        let root = try directory()
        try write([prompt(-600), assistant(-100)], to: root)
        XCTAssertEqual(seconds(read(root, before: now.addingTimeInterval(-300))), 300)
    }

    func testImportVersionRequiresAutomaticReimportOfEarlierReports() throws {
        XCTAssertGreaterThanOrEqual(ActivityImportReport.currentVersion, 4)
        let legacy = Data("{\"intervals\":[],\"importedAt\":800000100,\"importCutoff\":800000000,\"providerImportCutoffs\":{\"claude\":800000000,\"codex\":800000000},\"providerImportVersions\":{\"claude\":3,\"codex\":3},\"importReport\":{\"version\":3,\"providers\":[]}}".utf8)
        let history = try JSONDecoder().decode(ActivityHistory.self, from: legacy)
        XCTAssertTrue(history.needsImport(providers: [.claude]))
        XCTAssertTrue(history.needsImport)
    }
}

/// Decision 22: only lost coverage makes an import partial. Skipped or
/// inconsistent individual records stay visible as report information.
final class ActivityImportLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyCoverageLossLimitsTheImport() {
        for issue in ActivityImportIssue.allCases {
            var report = ActivityImportReport()
            var provider = ActivityImportReport.Provider(id: .codex); provider.issues[issue] = 3
            report.providers = [provider]
            let limiting: Set<ActivityImportIssue> = [.budget, .unreadable, .missingSource, .symlink]
            XCTAssertEqual(report.limited, limiting.contains(issue), issue.rawValue)
        }
    }

    func testInformationalIssuesNoLongerMarkHistoryOrChartsAsPartial() throws {
        var report = ActivityImportReport()
        var codex = ActivityImportReport.Provider(id: .codex); codex.issues = [.invalidTiming: 3, .incompleteTask: 5]
        report.providers = [codex]
        var history = ActivityHistory()
        history.mergeRecovered([.init(start: now.addingTimeInterval(-60), end: now, providers: 2)], now: now,
                               limited: report.limited, report: report, providers: [.codex])
        XCTAssertEqual(history.importWasLimited, false)
        XCTAssertFalse(ActivityChartData(history: history, now: now).limited)
        // A history saved by 0.2.4 stored the old flag; its report shows it was informational only.
        var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as! [String: Any]
        stored["importWasLimited"] = true
        let legacy = try JSONDecoder().decode(ActivityHistory.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertFalse(ActivityChartData(history: legacy, now: now).limited)
        var budget = report; budget.providers[0].issues[.budget] = 1
        var limited = ActivityHistory()
        limited.mergeRecovered([], now: now, limited: budget.limited, report: budget, providers: [.codex])
        XCTAssertTrue(ActivityChartData(history: limited, now: now).limited)
    }
}
