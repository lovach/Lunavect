import XCTest
@testable import WeekleftCore

/// Client settings files in the shapes users actually have (audit 05 §5 items
/// 1, 3-6 and 17, H-06-H-08, matrix P2). Every path is inside a temporary folder.
final class ConnectionFileSafetyTests: XCTestCase {
    private var root: URL!
    private var helper: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect file safety " + UUID().uuidString).resolvingSymlinksInPath()
        let url = root.appendingPathComponent("App/Lunavect.app/Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '{}'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        helper = url.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func setup(_ provider: ProviderID = .claude, config: URL) -> ClientConnection.LocalSetup {
        ClientConnection.LocalSetup(provider: provider, executable: helper, configURL: config,
                                    bridgeDirectory: root.appendingPathComponent("bridge"), backupDirectory: root.appendingPathComponent("backups"))
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func foreignGroups(_ root: [String: Any], _ provider: ProviderID) -> NSDictionary {
        let marker = "lunavect-session-monitor:" + provider.rawValue
        return (root["hooks"] as? [String: [[String: Any]]] ?? [:]).mapValues { groups in
            groups.filter { !(($0["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true } }
        }.filter { !$0.value.isEmpty } as NSDictionary
    }
    private var backupNames: [String] {
        ["backups", "bridge"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent($0).path)) ?? [] }.sorted()
    }

    /// §5 item 1: foreign groups in all 13 events, non-command types and extra keys.
    func testForeignGroupsInEveryEventSurviveConnectAndDisconnectInOrder() throws {
        let config = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hooks: [String: [[String: Any]]] = [:]
        for event in SessionHooks.events(.claude) {
            hooks[event] = [["matcher": "Bash", "hooks": [["type": "command", "command": "orca hook " + event, "timeout": 30]]],
                            ["hooks": [["type": "prompt", "prompt": "Review " + event]], "description": "mine", "priority": 2],
                            ["matcher": "*", "hooks": [["type": "command", "command": "jq . >/dev/null"], ["type": "command", "command": "node hud.js"]]]]
        }
        let original: [String: Any] = ["hooks": hooks, "model": "opus", "env": ["A": "1"]]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        let setup = setup(config: config)
        XCTAssertTrue(try setup.apply(.connect).connected)
        let connected = try object(config)
        XCTAssertEqual(foreignGroups(connected, .claude), foreignGroups(original, .claude))
        for event in SessionHooks.events(.claude) {
            let groups = try XCTUnwrap((connected["hooks"] as? [String: [[String: Any]]])?[event])
            XCTAssertEqual(groups.count, 4, event)
            XCTAssertTrue(((groups.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.hasSuffix("lunavect-session-monitor:claude") == true, "Lunavect is last in \(event)")
        }
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        XCTAssertEqual(try object(config) as NSDictionary, original as NSDictionary)
    }

    /// §5 item 6: the owner's Codex shape, 8 events with 2-3 foreign groups each.
    func testCodexGroupIsAppendedLastAndDisconnectRemovesOnlyIt() throws {
        let config = root.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hooks: [String: [[String: Any]]] = [:]
        for (index, event) in SessionHooks.events(.codex).enumerated() {
            hooks[event] = (0..<(2 + index % 2)).map { ["hooks": [["type": "command", "command": "tool-\($0) " + event]]] }
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: config)
        let setup = setup(.codex, config: config)
        XCTAssertTrue(try setup.apply(.connect).connected)
        let connected = try XCTUnwrap(try object(config)["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(connected.keys), Set(SessionHooks.events(.codex)))
        for (event, groups) in connected {
            XCTAssertEqual(groups.count, hooks[event]!.count + 1)
            XCTAssertEqual(((groups.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String), SessionHooks.command(.codex, executable: helper))
        }
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        XCTAssertEqual(try object(config)["hooks"] as? NSDictionary, hooks as NSDictionary)
    }

    /// §5 item 3: settings Lunavect cannot parse are never rewritten or backed up.
    func testLenientJSONIsRecognizedOutsideStringsOnly() {
        for text in [#"{"a":1 // x"#, #"{"a":1 /* x */}"#, #"{"a":[1,],"b":2}"#, "{\"a\":1,\n}"] {
            XCTAssertTrue(SessionHooks.isLenientJSON(Data(text.utf8)), text)
        }
        for text in [#"{"url":"https://x//y","c":"a,}","d":"\\","e":"/*"}"#, #"{"a":[1,2],"b":{}}"#, "{\"a\" : 1 ,\n \"b\": 2}"] {
            XCTAssertFalse(SessionHooks.isLenientJSON(Data(text.utf8)), text)
        }
    }
    func testCommentedSettingsAreReportedUnreadableAndLeftAlone() throws {
        let config = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["{\n  // personal\n  \"model\": \"opus\"\n}\n", "{\"model\": \"opus\",}\n"] {
            try Data(text.utf8).write(to: config)
            let setup = setup(config: config)
            XCTAssertEqual(setup.inspect(), ClientConnection.LocalState(statusLine: .unavailable, hooks: .unavailable))
            XCTAssertThrowsError(try setup.apply(.connect))
            XCTAssertThrowsError(try setup.apply(.disconnect))
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), text)
            XCTAssertEqual(backupNames, [])
        }
    }

    /// §5 item 4 and matrix P2: dotfile managers keep settings.json as a link.
    func testLinkedSettingsAreWrittenThroughTheLinkIncludingADanglingOne() throws {
        let dotfiles = root.appendingPathComponent("dotfiles"), claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("settings.json"), link = claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let setup = setup(config: link)
        XCTAssertTrue(try setup.apply(.connect).connected, "a link whose file does not exist yet")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertTrue(try setup.apply(.connect).connected)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    /// §5 item 5, H-06, H-08: a missing ~/.claude is created; disconnecting keeps a
    /// cleaned settings file instead of deleting it, and every write ends in a newline.
    func testMissingFolderIsCreatedAndDisconnectKeepsACleanFile() throws {
        let config = root.appendingPathComponent("no folder yet/.claude/settings.json")
        let setup = setup(config: config)
        XCTAssertEqual(setup.inspect().hooks, .absent)
        XCTAssertTrue(try setup.apply(.connect).connected)
        XCTAssertEqual(try Data(contentsOf: config).last, 0x0A, "H-06: a trailing newline")
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path), "H-08: the file Lunavect created stays")
        XCTAssertEqual(try object(config) as NSDictionary, [:] as NSDictionary)
        XCTAssertEqual(try Data(contentsOf: config).last, 0x0A)
        // A pre-existing file keeps its exact original bytes after a round trip.
        let original = Data("{\"model\":\"opus\"}".utf8)
        try original.write(to: config)
        XCTAssertTrue(try setup.apply(.connect).connected)
        XCTAssertTrue(try setup.apply(.disconnect).disconnected)
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    /// H-07: the new bytes are flushed to disk before they replace the settings.
    func testConfigurationIsFlushedBeforeItReplacesTheOriginal() throws {
        let config = root.appendingPathComponent("settings.json")
        try Data("old".utf8).write(to: config)
        var flushed: [(target: Data, pending: Data)] = []
        try SessionHooks.writeConfigurationVerified(Data("new\n".utf8), to: config) { descriptor in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertNotEqual(fcntl(descriptor, F_GETPATH, &path), -1)
            flushed.append((try Data(contentsOf: config), try Data(contentsOf: URL(fileURLWithPath: String(cString: path)))))
        }
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first?.target, Data("old".utf8), "flushed before the rename")
        XCTAssertEqual(flushed.first?.pending, Data("new\n".utf8))
        XCTAssertEqual(try Data(contentsOf: config), Data("new\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".lunavect-") }, [])
    }

    /// §5 item 17: a saved previous status line that is Lunavect's own command
    /// would make the bridge call itself. Disconnect fails closed, settings intact.
    func testSelfReferencingPreviousStatusLineFailsClosed() throws {
        let config = root.appendingPathComponent(".claude/settings.json"), bridge = root.appendingPathComponent("bridge")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"my-hud"}}"#.utf8).write(to: config)
        try ClaudeProvider.installStatusLine(executable: helper, settingsURL: config, bridgeDirectory: bridge)
        let own = ["type": "command", "command": SessionHooks.quote("/old/Lunavect.app/Contents/Helpers/LunavectHook") + " --claude-statusline"]
        try JSONSerialization.data(withJSONObject: own).write(to: bridge.appendingPathComponent("previous-statusline.json"))
        let bytes = try Data(contentsOf: config)
        XCTAssertThrowsError(try ClaudeProvider.removeStatusLine(settingsURL: config, bridgeDirectory: bridge))
        XCTAssertThrowsError(try ClaudeProvider.installStatusLine(executable: helper, settingsURL: config, bridgeDirectory: bridge))
        XCTAssertEqual(try Data(contentsOf: config), bytes)
        XCTAssertEqual(setup(config: config).inspect().statusLine, .partial, "reported as needing setup, never as ready")
    }
}
