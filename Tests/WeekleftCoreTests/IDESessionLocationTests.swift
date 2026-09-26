import XCTest
@testable import WeekleftCore

final class IDESessionLocationTests: XCTestCase {
    func testMovingAnIDESessionToDesktopOrTerminalClearsItsOldEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(#"{"session_id":"fixture","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}"#.utf8)
        for client in [SessionClient.desktop, .terminal, .background] {
            try SessionHooks.capture(payload, provider: .claude, at: directory, client: .vscode, ide: location())
            XCTAssertNotNil(SessionHooks.load(at: directory).first?.ideLocation)
            try SessionHooks.capture(payload, provider: .claude, at: directory, client: client)
            let moved = try XCTUnwrap(SessionHooks.load(at: directory).first)
            XCTAssertEqual(moved.client, client)
            XCTAssertNil(moved.ideLocation)
        }
    }
    private func process(_ pid: Int32, parent: Int32, path: String, tty: Bool = false,
                         birth: UInt64 = 123) -> IDEProcessLocation.ProcessInfo {
        .init(identity: .init(pid: pid, startedAtMicroseconds: birth), parentPID: parent,
              executable: path, hasTerminal: tty)
    }

    private func location(_ editor: SessionIDE = .vscode) -> IDESessionLocation {
        .init(editor: editor, bundleIdentifier: editor == .vscode ? "com.microsoft.VSCode" : "com.jetbrains.pycharm",
              appPath: editor == .vscode ? "/Applications/Visual Studio Code.app" : "/Applications/PyCharm.app",
              runtime: .init(pid: 42, startedAtMicroseconds: 123), usesTerminal: true)
    }

    func testDetachedHooksRetainTheirIDEAndTerminalOriginForBothProviders() throws {
        for provider in ProviderID.allCases {
            for (bundle, path, kind) in [
                ("com.microsoft.VSCode", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", SessionIDE.vscode),
                ("com.jetbrains.pycharm", "/Applications/PyCharm.app/Contents/MacOS/pycharm", .jetbrains)
            ] {
                let processes: [Int32: IDEProcessLocation.ProcessInfo] = [
                    50: process(50, parent: 42, path: "/usr/bin/hook"),
                    42: process(42, parent: 30, path: "/usr/local/bin/" + provider.rawValue, tty: true),
                    30: process(30, parent: 20, path: "/bin/zsh", tty: true),
                    20: process(20, parent: 1, path: path)
                ]
                let result = try XCTUnwrap(IDEProcessLocation.locate(parentPID: 50, provider: provider,
                                                                      read: { processes[$0] }, bundle: { _ in bundle }))
                XCTAssertEqual(result.editor, kind)
                XCTAssertEqual(result.runtime.pid, 42)
                XCTAssertTrue(result.usesTerminal)
            }
        }
    }

    func testProviderPanelDoesNotInheritTheEditorsLaunchTerminal() throws {
        let processes: [Int32: IDEProcessLocation.ProcessInfo] = [
            42: process(42, parent: 20, path: "/extensions/claude"),
            20: process(20, parent: 1, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", tty: true)
        ]
        let result = try XCTUnwrap(IDEProcessLocation.locate(parentPID: 42, provider: .claude,
                                                            read: { processes[$0] }, bundle: { _ in "com.microsoft.VSCode" }))
        XCTAssertFalse(result.usesTerminal)
    }

    func testBundledRuntimeStillUsesItsParentHostAndNeverGuessesFromAnInterpreter() throws {
        var processes: [Int32: IDEProcessLocation.ProcessInfo] = [
            42: process(42, parent: 20, path: "/Applications/Codex.app/Contents/Resources/codex", tty: true),
            20: process(20, parent: 1, path: "/Applications/PyCharm.app/Contents/MacOS/pycharm")
        ]
        let result = try XCTUnwrap(IDEProcessLocation.locate(parentPID: 42, provider: .codex, read: { processes[$0] },
                                                            bundle: { $0.contains("PyCharm") ? "com.jetbrains.pycharm" : "com.openai.codex" }))
        XCTAssertEqual(result.editor, .jetbrains)
        processes[42] = process(42, parent: 20, path: "/usr/bin/node")
        XCTAssertNil(IDEProcessLocation.locate(parentPID: 42, provider: .codex, read: { processes[$0] }, bundle: { _ in "com.jetbrains.pycharm" }))
        XCTAssertNil(SessionIDE.identify(bundleIdentifier: "com.jetbrains.unrelated-service"))
    }

    func testReusedProcessIdentityCannotSelectAnotherTerminal() {
        let original = SessionProcessIdentity(pid: 42, startedAtMicroseconds: 123)
        let replacement = process(42, parent: 30, path: "/usr/local/bin/claude", tty: true, birth: 999)
        XCTAssertTrue(IDEProcessLocation.liveAncestry(of: original, read: { _ in replacement }).isEmpty)
        XCTAssertTrue(IDEProcessLocation.liveAncestry(of: original, read: { _ in nil }).isEmpty)
    }

    func testCurrentCatalogIDEOriginWinsOverOldTerminalHook() throws {
        let now = Date()
        let data = Data(#"[{"sessionId":"session","pid":42,"kind":"interactive","status":"busy"}]"#.utf8)
        let rows = try SessionParser.claude(data, now: now, terminal: { _ in
            XCTFail("An identified IDE must not become Terminal"); return nil
        }, ide: { _ in self.location(.jetbrains) })
        var old = try XCTUnwrap(rows.first)
        old.ideLocation = nil; old.client = .terminal; old.terminalTTY = "/dev/ttys003"; old.terminalApp = "Terminal"
        old.evidence = .hook; old.observedAt = now.addingTimeInterval(-60)
        let merged = try XCTUnwrap(SessionList.merge(catalog: rows, events: [old], now: now).first)
        XCTAssertEqual(merged.client, .jetbrains)
        XCTAssertNotNil(merged.ideLocation)
        XCTAssertNil(merged.terminalTTY)
        XCTAssertFalse(merged.terminalFocusCandidate)
    }

    func testCurrentTerminalOriginWinsOverOldIDEHookAndLegacyRecordsStillDecode() throws {
        let now = Date()
        let data = Data(#"[{"sessionId":"session","pid":42,"kind":"interactive","status":"busy"}]"#.utf8)
        let rows = try SessionParser.claude(data, now: now, terminal: { _ in .init(tty: "/dev/ttys004", app: "Terminal") })
        var old = try XCTUnwrap(rows.first)
        old.ideLocation = location(); old.client = .vscode; old.terminalTTY = nil; old.terminalApp = nil
        old.evidence = .hook; old.observedAt = now.addingTimeInterval(-60)
        let merged = try XCTUnwrap(SessionList.merge(catalog: rows, events: [old], now: now).first)
        XCTAssertEqual(merged.client, .terminal)
        XCTAssertNil(merged.ideLocation)
        XCTAssertTrue(merged.terminalFocusCandidate)
        let encoded = try JSONEncoder().encode(merged)
        XCTAssertEqual(try JSONDecoder().decode(AgentSession.self, from: encoded), merged)
    }
}
