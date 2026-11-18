import XCTest
import Darwin
@testable import WeekleftCore

/// Owner's yes, 18.11.2026 (R1537): a Claude permission request waits up to a
/// minute for her answer in the island; without the app Claude Code asks as before.
final class PermissionBridgeTests: XCTestCase {
    private final class Box: @unchecked Sendable { var answer: PermissionBridge.Answer? }

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
        XCTAssertNil(PermissionPrompt(payload: payload("AskUserQuestion")), "A question needs typed answers in the session")
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
