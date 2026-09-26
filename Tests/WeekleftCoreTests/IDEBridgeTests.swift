import XCTest
@testable import WeekleftCore

final class IDEBridgeTests: XCTestCase {
    func testLegacyEditorLabelCannotGuessTerminalVersusProviderPanel() async throws {
        for provider in ProviderID.allCases {
            let row = AgentSession(provider: provider, sessionID: UUID().uuidString, title: "Fixture", cwd: "/tmp",
                                   client: .vscode, phase: .running, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            do {
                try await IDEBridge.open(row, activateApp: { _ in XCTFail("No guessed host"); return false },
                                         openURL: { _, _ in XCTFail("No guessed panel"); return false })
                XCTFail("Missing origin must remain unavailable")
            } catch { XCTAssertEqual(error as? SessionOpeningError, .ideSessionUnavailable("VS Code")) }
        }
    }
    func testEndpointIdentityRejectsForeignPathsAndStaleRecords() throws {
        let now = Date()
        let id = UUID().uuidString
        var object: [String: Any] = ["version": 1, "id": id, "editor": "vscode", "pid": 42,
            "appPath": "/Applications/Visual Studio Code.app", "bundleIdentifier": "com.microsoft.VSCode",
            "socketPath": "/tmp/lunavect-ide-\(getuid())/\(id).sock", "updatedAt": now.timeIntervalSince1970]
        func descriptor() throws -> IDEBridge.Descriptor {
            try JSONDecoder().decode(IDEBridge.Descriptor.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(IDEBridge.valid(try descriptor(), now: now))
        object["socketPath"] = "/tmp/some-other-service.sock"
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
        object["socketPath"] = "/tmp/lunavect-ide-\(getuid())/\(id).sock"
        object["updatedAt"] = now.addingTimeInterval(-91).timeIntervalSince1970
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
        object["updatedAt"] = now.timeIntervalSince1970
        object["bundleIdentifier"] = "com.apple.Terminal"
        XCTAssertFalse(IDEBridge.valid(try descriptor(), now: now))
    }

    func testCallbackCannotOpenFilesCommandsOrAnotherExtension() {
        let id = UUID().uuidString
        XCTAssertTrue(IDEBridge.validCallback(URL(string: "vscode://lovach.lunavect/focus/\(id)?windowId=3")!))
        for text in ["file:///tmp/a", "https://example.com", "vscode://another.extension/focus/\(id)",
                     "vscode://lovach.lunavect/focus/not-an-id", "vscode://user@lovach.lunavect/focus/\(id)",
                     "vscode://lovach.lunavect:80/focus/\(id)"] {
            XCTAssertFalse(IDEBridge.validCallback(URL(string: text)!), text)
        }
    }

    func testNavigationPayloadAllowsOnlyBoundedIdentifiers() {
        XCTAssertTrue(IDEBridge.Target(kind: "terminal", ancestors: [42, 30]).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: []).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: [1]).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "terminal", ancestors: Array(repeating: 42, count: 25)).valid)
        XCTAssertFalse(IDEBridge.Target(kind: "command", ancestors: [42]).valid)
        XCTAssertTrue(IDEBridge.Target(kind: "codex", sessionID: UUID().uuidString, cwd: "/tmp/project").valid)
        XCTAssertFalse(IDEBridge.Target(kind: "claude", sessionID: "../../other", cwd: "/tmp/project").valid)
        XCTAssertFalse(IDEBridge.Target(kind: "claude", sessionID: UUID().uuidString, cwd: "/tmp/project\ncommand").valid)
    }

    func testDescriptorDirectoryCannotBeSymlinked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertTrue(IDEBridge.descriptors(at: alias).isEmpty)
    }
}
