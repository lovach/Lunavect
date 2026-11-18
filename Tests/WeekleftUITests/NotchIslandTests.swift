import XCTest
import WeekleftCore
@testable import Weekleft

final class NotchIslandTests: XCTestCase {
    /// The owner's Mac16,5 as AppKit reported it on 18.11.2026.
    func testHousingLiesBetweenTheTwoMenuBarStrips() {
        let geometry = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeTop: 32,
                                          leftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
                                          rightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32), menuBarHeight: 24)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notch, CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    }

    func testScreenWithoutHousingGetsANarrowGapAtTheTopCentre() {
        let geometry = NotchGeometry.make(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440), safeTop: 0,
                                          leftArea: nil, rightArea: nil, menuBarHeight: 24)
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.notch.midX, 1728 + 1280)
        XCTAssertEqual(geometry.notch.maxY, 1440)
        XCTAssertEqual(geometry.notch.height, 24)
    }

    func testWaitingSessionsComeFirstAndIdleOnesStayInThePanel() {
        let now = Date()
        func row(_ id: String, _ phase: SessionPhase, _ age: TimeInterval) -> AgentSession {
            var session = AgentSession(provider: .claude, sessionID: id, title: id, cwd: "/Users/fixture/project", client: .desktop,
                                       phase: phase, updatedAt: now - age, observedAt: now - age, evidence: .hook)
            if phase == .running { session.turnStartedAt = now - age - 60 }
            return session
        }
        let summary = IslandSummary.make([row("run", .running, 5), row("idle", .idle, 5), row("ask", .permission, 30),
                                          row("done", .ready, 2), row("run2", .running, 1)], now: now)
        XCTAssertEqual(summary.rows.map(\.id), ["claude:ask", "claude:run", "claude:run2", "claude:done"])
        XCTAssertEqual([summary.working, summary.waiting, summary.ready], [2, 1, 1])
        XCTAssertEqual(summary.rows.first?.since, now - 30, "A waiting row counts from the request")
        XCTAssertEqual(summary.rows[1].since, now - 65, "A working row counts from the turn")
        XCTAssertNil(summary.rows.last?.since)
    }

    /// Owner's check, 18.11.2026: rows sorted by their last event swapped places
    /// while the pointer was on the open island, so a click could open another session.
    func testRowsKeepTheirPlaceWhenSessionsReportEvents() {
        let now = Date()
        func row(_ id: String, updated age: TimeInterval) -> AgentSession {
            var session = AgentSession(provider: .claude, sessionID: id, title: id, cwd: "/Users/fixture/project", client: .desktop,
                                       phase: .running, updatedAt: now - age, observedAt: now - age, evidence: .hook)
            session.turnStartedAt = now - 300
            return session
        }
        let order = ["claude:a", "claude:b"]
        let before = IslandSummary.make([row("a", updated: 1), row("b", updated: 9)], order: order, now: now)
        let after = IslandSummary.make([row("b", updated: 0), row("a", updated: 20)], order: order, now: now)
        XCTAssertEqual(before.rows.map(\.id), order)
        XCTAssertEqual(after.rows.map(\.id), order)
    }

    func testPermissionRequestLeadsTheIslandEvenForAnUnknownSession() throws {
        let now = Date()
        var working = AgentSession(provider: .claude, sessionID: "run", title: "run", cwd: "/Users/fixture/project", client: .desktop,
                                   phase: .running, updatedAt: now, observedAt: now, evidence: .hook)
        working.turnStartedAt = now - 30
        func request(_ session: String) throws -> PermissionPrompt {
            try XCTUnwrap(PermissionPrompt(payload: ["session_id": session, "cwd": "/Users/fixture/Projects/shop", "hook_event_name": "PermissionRequest",
                                                     "tool_name": "Bash", "tool_input": ["command": "npm test"]], now: now - 5))
        }
        let summary = IslandSummary.make([working], prompts: [try request("run"), try request("new")], now: now)
        XCTAssertEqual(summary.rows.map(\.id), ["claude:run", "claude:new"])
        XCTAssertEqual(summary.rows.map(\.title), ["run", "shop"], "An unknown session is named by its folder")
        XCTAssertTrue(summary.rows.allSatisfy { $0.prompt != nil && $0.phase == .permission })
        XCTAssertEqual([summary.working, summary.waiting], [0, 2])
        let plain = IslandLayout.expanded(notch: CGSize(width: 185, height: 32), summary: IslandSummary.make([working], now: now), limits: 0)
        let asking = IslandLayout.expanded(notch: CGSize(width: 185, height: 32), summary: summary, limits: 0)
        XCTAssertEqual(asking.height - plain.height, IslandLayout.rowHeight + 2 * IslandLayout.promptHeight)
    }

    /// Owner's yes 18.11.2026 (R1539): the agent's question waits for an answer in the island,
    /// on a card tall enough for its options.
    func testQuestionOfTheAgentWaitsForAnAnswerOnATallerCard() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let question = try XCTUnwrap(PermissionPrompt(payload: [
            "session_id": "ask", "cwd": "/Users/fixture/Projects/shop", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which colour should the button be?", "header": "Colour", "multiSelect": false,
                                          "options": [["label": "Red", "description": "Warmer"], ["label": "Blue", "description": ""]]]]]], now: now))
        let summary = IslandSummary.make([], prompts: [question], now: now)
        XCTAssertEqual(summary.rows.first?.phase, .input)
        XCTAssertEqual(summary.rows.first?.activity, SessionPhase.input.title)
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertGreaterThan(IslandLayout.promptHeight(question), IslandLayout.promptHeight + IslandLayout.optionHeight)
        // The card fits the question it shows: the island grows for the second, longer one.
        let two = try XCTUnwrap(PermissionPrompt(payload: [
            "session_id": "ask", "cwd": "/Users/fixture/Projects/shop", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which colour?", "header": "Colour", "multiSelect": false,
                                          "options": [["label": "Red"], ["label": "Blue"]]],
                                         ["question": "Which sizes?", "header": "Sizes", "multiSelect": true,
                                          "options": [["label": "S", "description": "Small"], ["label": "M", "description": "Medium"],
                                                      ["label": "L", "description": "Large"]]]]]], now: now))
        let first = IslandSummary.make([], prompts: [two], now: now), second = IslandSummary.make([], prompts: [two], steps: [two.id: 1], now: now)
        XCTAssertEqual([first.rows.first?.step, second.rows.first?.step], [0, 1])
        XCTAssertEqual(IslandSummary.make([], prompts: [two], steps: [two.id: 7], now: now).rows.first?.step, 1)
        let notch = CGSize(width: 185, height: 32)
        XCTAssertEqual(IslandLayout.expanded(notch: notch, summary: second, limits: 1).height
                       - IslandLayout.expanded(notch: notch, summary: first, limits: 1).height,
                       IslandLayout.promptHeight(two, step: 1) - IslandLayout.promptHeight(two, step: 0))
        XCTAssertEqual(IslandLayout.promptHeight(two, step: 1) - IslandLayout.promptHeight(two, step: 0),
                       IslandLayout.optionHeight + 3 * 13 + 5)
        // A long question takes more lines, up to three; Chinese needs them sooner than Latin text.
        XCTAssertEqual(IslandLayout.questionLines("Which colour?"), 1)
        XCTAssertEqual(IslandLayout.questionLines(String(repeating: "Which colour should it be? ", count: 30)), 3)
        XCTAssertGreaterThan(IslandLayout.questionLines(String(repeating: "按钮应该是什么颜色", count: 4)),
                             IslandLayout.questionLines(String(repeating: "Which colour?", count: 3)))
    }

    func testClosedIslandHasEarsOnlyWithSomethingToShow() {
        let notch = CGSize(width: 185, height: 32)
        XCTAssertEqual(IslandLayout.compact(notch: notch, summary: IslandSummary()), notch)
        var busy = IslandSummary(); busy.working = 1
        XCTAssertEqual(IslandLayout.compact(notch: notch, summary: busy).width, 185 + 2 * IslandLayout.ear)
    }
}
