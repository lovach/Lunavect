import XCTest
import Darwin
@testable import WeekleftCore

/// Owner's yes, 18.11.2026 (R1537): a Claude permission request waits up to a
/// minute for her answer in the island; without the app Claude Code asks as before.
final class PermissionBridgeTests: XCTestCase {
    private final class Box: @unchecked Sendable { var answer: PermissionBridge.Reply? }

    private func payload(_ tool: String = "Bash", suggestions: [Any]? = nil) -> [String: Any] {
        var object: [String: Any] = ["session_id": "perm", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": "PermissionRequest",
                                     "tool_name": tool, "tool_input": ["command": "touch /tmp/x\nsecond line", "description": "Make a file"]]
        if let suggestions { object["permission_suggestions"] = suggestions }
        return object
    }
    private func socketURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lv-\(UUID().uuidString.prefix(8)).sock")
    }

    func testAnswersBecomeClaudeCodeDecisions() throws {
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "touch:*"]],
                                   "behavior": "allow", "destination": "localSettings"]
        let object = payload(suggestions: [rule])
        func decision(_ answer: PermissionBridge.Answer) throws -> [String: Any]? {
            guard let text = PermissionBridge.output(for: answer, payload: object) else { return nil }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            return output["decision"] as? [String: Any]
        }
        XCTAssertEqual(try decision(.allow)?["behavior"] as? String, "allow")
        XCTAssertNil(try decision(.allow)?["updatedPermissions"])
        XCTAssertEqual((try decision(.always)?["updatedPermissions"] as? [[String: Any]])?.first?["type"] as? String, "addRules")
        XCTAssertEqual(try decision(.deny)?["behavior"] as? String, "deny")
        XCTAssertNil(try decision(.ask), "No decision: Claude Code shows its own dialog")
    }

    func testPromptNamesTheCommandOnOneLine() throws {
        let prompt = try XCTUnwrap(PermissionPrompt(payload: payload()))
        XCTAssertEqual(prompt.tool, "Bash")
        XCTAssertEqual(prompt.detail, "touch /tmp/x")
        XCTAssertEqual(prompt.rowID, "claude:perm")
        XCTAssertFalse(prompt.canAlways)
        XCTAssertTrue(try XCTUnwrap(PermissionPrompt(payload: payload(suggestions: [["type": "addRules"]]))).canAlways)
        XCTAssertNil(PermissionPrompt(payload: payload("AskUserQuestion")), "A question without options stays in the session")
    }

    private func question(_ questions: [[String: Any]]) -> [String: Any] {
        ["session_id": "ask", "cwd": "/Users/fixture/Projects/lunavect", "hook_event_name": "PermissionRequest",
         "tool_name": "AskUserQuestion", "tool_input": ["questions": questions]]
    }
    private let colour: [String: Any] = ["question": "Which colour?", "header": "Colour", "multiSelect": false,
                                         "options": [["label": "Red", "description": "Warmer"], ["label": "Blue", "description": ""]]]
    private let sizes: [String: Any] = ["question": "Which sizes?", "header": "Size", "multiSelect": true,
                                        "options": [["label": "S"], ["label": "M"], ["label": "L"]]]

    /// Owner's yes 18.11.2026 (R1539): the agent's questions are answered from the island. Claude
    /// Code reads the answers by question text and maps over `questions`, so both go back.
    func testAgentQuestionsBecomeChoicesAndAnswersByQuestionText() throws {
        let object = question([colour, sizes])
        let prompt = try XCTUnwrap(PermissionPrompt(payload: object))
        XCTAssertEqual(prompt.questions?.map(\.text), ["Which colour?", "Which sizes?"])
        XCTAssertEqual(prompt.questions?.first?.options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(prompt.questions?.first?.options.first?.detail, "Warmer")
        XCTAssertEqual(prompt.questions?.map(\.multiSelect), [false, true])
        XCTAssertEqual(prompt.detail, "Which colour?")
        let reply = PermissionBridge.Reply(.allow, answers: ["Which colour?": "Red", "Which sizes?": PermissionQuestion.answer(["S", "L"])])
        let text = try XCTUnwrap(PermissionBridge.output(for: reply, payload: object))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let decision = try XCTUnwrap((root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual((input["questions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(input["answers"] as? [String: String], ["Which colour?": "Red", "Which sizes?": "S, L"])
        for plain in [PermissionBridge.Reply.allow, .always, .deny, .ask] {
            XCTAssertNil(PermissionBridge.output(for: plain, payload: object), "Without its options a question stays in the session")
        }
        // The line on the socket keeps the answers.
        XCTAssertEqual(PermissionBridge.Reply(line: reply.line), reply)
        XCTAssertEqual(PermissionBridge.Reply(line: "deny\n"), .deny)
        XCTAssertNil(PermissionBridge.Reply(line: "{\"answer\":\"allow\"}"))
    }

    func testQuestionsTheIslandCannotOfferStayInTheSession() {
        var one = colour; one["options"] = [["label": "Only"]]
        var unlabelled = colour; unlabelled["options"] = [["label": "Red"], ["description": "no label"]]
        for object in [question([one]), question([unlabelled]), question([colour, colour]), question(Array(repeating: sizes, count: 5)), question([])] {
            XCTAssertFalse(PermissionBridge.waits(for: object))
            XCTAssertNil(PermissionPrompt(payload: object))
        }
    }

    func testChosenOptionsReachTheWaitingHelper() throws {
        let url = socketURL()
        var server: PermissionBridgeServer!
        server = PermissionBridgeServer(url: url, wait: 5, onPrompt: { prompt in
            server.answer(prompt.id, PermissionBridge.Reply(.allow, answers: ["Which colour?": "Blue"]))
        }, onEnd: { _ in })
        try server.start()
        defer { server.stop() }
        let box = Box(), answered = expectation(description: "helper answered")
        let object = question([colour])
        DispatchQueue.global().async {
            box.answer = PermissionBridge.ask(payload: object, socket: url, wait: 5)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(box.answer, PermissionBridge.Reply(.allow, answers: ["Which colour?": "Blue"]))
    }

    /// Owner's report 18.11.2026 (R1538): sessions opened before the change keep the
    /// three-second limit, so they are not held for the island.
    func testSessionStartedBeforeTheSettingsChangeAsksInItsDialog() {
        let change = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(PermissionBridge.sessionSeesWait(processStart: change - 60, settingsChanged: change))
        XCTAssertTrue(PermissionBridge.sessionSeesWait(processStart: change + 5, settingsChanged: change))
        XCTAssertTrue(PermissionBridge.sessionSeesWait(processStart: nil, settingsChanged: change))
    }

    func testWithoutTheAppTheHelperLeavesTheDialogToClaudeCodeAtOnce() {
        let started = Date()
        XCTAssertEqual(PermissionBridge.ask(payload: payload(), socket: socketURL(), wait: 5), .ask)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testOwnersAnswerReachesTheWaitingHelper() throws {
        let url = socketURL()
        var server: PermissionBridgeServer!
        var shown: PermissionPrompt?
        server = PermissionBridgeServer(url: url, wait: 5, onPrompt: { prompt in
            shown = prompt
            server.answer(prompt.id, .allow)
        }, onEnd: { _ in })
        try server.start()
        defer { server.stop() }
        let box = Box(), answered = expectation(description: "helper answered")
        let object = payload()
        DispatchQueue.global().async {
            box.answer = PermissionBridge.ask(payload: object, socket: url, wait: 5)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(box.answer, .allow)
        XCTAssertEqual(shown?.detail, "touch /tmp/x")
    }

    func testUnansweredRequestReturnsToTheSessionBeforeTheHelperGivesUp() throws {
        let url = socketURL()
        let ended = expectation(description: "island card removed")
        let server = PermissionBridgeServer(url: url, wait: 0.5, onPrompt: { _ in }, onEnd: { _ in ended.fulfill() })
        try server.start()
        defer { server.stop() }
        let box = Box(), answered = expectation(description: "helper answered")
        let object = payload()
        DispatchQueue.global().async {
            box.answer = PermissionBridge.ask(payload: object, socket: url, wait: 5)
            answered.fulfill()
        }
        wait(for: [answered, ended], timeout: 4)
        XCTAssertEqual(box.answer, .ask)
    }

    /// The session was interrupted: Claude Code ended the hook, so the card leaves the island.
    func testInterruptedRequestLeavesTheIsland() throws {
        let url = socketURL()
        let ended = expectation(description: "island card removed")
        let server = PermissionBridgeServer(url: url, wait: 5, onPrompt: { _ in }, onEnd: { _ in ended.fulfill() })
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(PermissionBridge.withAddress(url) { connect(fd, $0, $1) }, 0)
        var line = try JSONSerialization.data(withJSONObject: payload()); line.append(0x0A)
        XCTAssertTrue(PermissionBridge.writeAll(fd, line))
        usleep(200_000)
        close(fd)
        wait(for: [ended], timeout: 3)
    }

    func testLaunchRepairGivesOnlyThePermissionHandlerTimeToWait() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let helper = "/Applications/Lunavect.app/Contents/Helpers/LunavectHook"
        let command = SessionHooks.command(.claude, executable: helper)
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": 3]
        let root: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [handler]]], "Stop": [["hooks": [handler]]]]]
        try JSONSerialization.data(withJSONObject: root).write(to: settings)
        XCTAssertTrue(try SessionHooks.retarget(provider: .claude, executable: helper, configURL: settings,
                                                backupDirectory: directory.appendingPathComponent("backups")))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try XCTUnwrap(saved["hooks"] as? [String: [[String: Any]]])
        func timeout(_ event: String) -> Int? { (hooks[event]?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int }
        XCTAssertEqual(timeout("PermissionRequest"), PermissionBridge.hookTimeout)
        XCTAssertEqual(timeout("Stop"), 3)
        XCTAssertEqual(SessionHooks.timeout(.codex, event: "PermissionRequest"), 3, "Codex requests are not held")
    }
}
