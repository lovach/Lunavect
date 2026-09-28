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

    /// `npm i -g @anthropic-ai/claude-code`: current releases link the native binary into the
    /// package as bin/claude.exe; earlier ones run `node <prefix>/bin/claude` (cli.js).
    func testNpmInstalledClaudeIsRecognizedOnlyFromItsPackage() {
        let package = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code"
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: package + "/bin/claude.exe"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Users/u/.nvm/versions/node/v22.1.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"), .claude)
        for path in ["/tmp/claude.exe", "/opt/homebrew/lib/node_modules/@anthropic-ai/other/bin/claude.exe",
                     "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.exe", "/opt/homebrew/bin/node"] {
            XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: path), path)
        }
        let links = ["/opt/homebrew/bin/claude": package + "/cli.js", "/Users/u/.npm/_npx/1f2e/node_modules/.bin/claude": "/Users/u/.npm/_npx/1f2e/node_modules/@anthropic-ai/claude-code/cli.js",
                     "/usr/local/bin/claude": "/usr/local/lib/node_modules/other-tool/index.js"]
        func provider(_ executable: String, _ argv: [String]?) -> ProviderID? {
            SessionProcess.runtimeProvider(pid: 42, executable: executable, arguments: { _ in argv }, resolve: { links[$0] })
        }
        XCTAssertEqual(provider("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude", "--resume", "x"]), .claude, "The bin link node was given")
        XCTAssertEqual(provider("/opt/homebrew/Cellar/node/22.1.0/bin/node", ["node", "--no-warnings", package + "/cli.js"]), .claude)
        XCTAssertEqual(provider("/Users/u/.nvm/versions/node/v22.1.0/bin/node", ["node", "/Users/u/.npm/_npx/1f2e/node_modules/.bin/claude"]), .claude, "npx")
        XCTAssertEqual(provider("/Users/u/.bun/bin/bun", ["bun", "run", package + "/cli.js"]), .claude)
        XCTAssertEqual(provider("/usr/local/bin/node", ["node", "--require", package + "/cli.js", "/Users/u/app/server.js"]), nil,
                       "A preloaded module is not the program")
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "/Users/u/app/server.js"]), "Any other node program is not a session")
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "-e", "require('\(package)/cli.js')"]))
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "node_modules/@anthropic-ai/claude-code/cli.js"]), "Relative scripts are not resolved")
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "/x/node_modules/@anthropic-ai/claude-code-extra/cli.js"]))
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", package + "/other.js"]))
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "/usr/local/bin/claude"]), "A link named claude must lead into the package")
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["node", "/tmp/unresolvable/claude"]))
        XCTAssertNil(provider("/opt/homebrew/bin/node", nil), "Unreadable arguments identify nothing")
        XCTAssertNil(provider("/usr/bin/python3", ["python3", package + "/cli.js"]), "Only node and bun run the npm package")
        XCTAssertNil(provider("/opt/homebrew/bin/node", ["claude", "", ""]), "A title written over argv no longer names the package")
        XCTAssertNil(SessionProcess.runtimeProvider(pid: 42, executable: "/opt/homebrew/bin/node", arguments: { _ in ["node", "/Users/u/.local/lib/node_modules/@openai/codex/bin/codex.js"] }),
                     "The Codex npm wrapper is identified by its native child, not as Claude")
    }

    /// The kernel layout as `sysctl(KERN_PROCARGS2)` returns it (checked on macOS 26 with
    /// every executable path length): the path is NUL-padded to an 8-byte boundary of the
    /// string area, and argv[0] starts there even when it is empty.
    func testProcessArgumentsLayoutIsParsedWithoutTheEnvironment() {
        func bytes(argc: Int32, _ strings: [String], path: String = "/opt/homebrew/bin/node") -> [UInt8] {
            let padded = (path.utf8.count + 1 + 7) / 8 * 8
            var result = withUnsafeBytes(of: argc) { Array($0) } + Array(path.utf8) + [UInt8](repeating: 0, count: padded - path.utf8.count)
            for string in strings { result += Array(string.utf8) + [0] }
            return result
        }
        XCTAssertEqual(SessionProcess.parseProcessArguments(bytes(argc: 2, ["node", "/bin/claude", "SECRET=1"])), ["node", "/bin/claude"])
        XCTAssertEqual(SessionProcess.parseProcessArguments(bytes(argc: 3, ["claude", "", ""])), ["claude", "", ""])
        for path in ["/bin/node", "/usr/bin/node", "/opt/homebrew/bin/node", "/Users/u/.bun/bin/bun", "/a/b/c/d/nodejs1"] {
            XCTAssertEqual(SessionProcess.parseProcessArguments(bytes(argc: 2, ["", "/x/cli.js", "SECRET=1"], path: path)), ["", "/x/cli.js"],
                           "R26-V2-03: an empty argv[0] is not padding (\(path.utf8.count + 1) path bytes)")
            XCTAssertEqual(SessionProcess.parseProcessArguments(bytes(argc: 2, ["", "", "SECRET=1"], path: path)), ["", ""])
        }
        XCTAssertNil(SessionProcess.parseProcessArguments(bytes(argc: 4, ["node", "/bin/claude"])), "A truncated vector is unknown")
        XCTAssertNil(SessionProcess.parseProcessArguments(bytes(argc: 0, [])))
        XCTAssertNil(SessionProcess.parseProcessArguments([1, 0]))
    }

    /// The same npm Claude in a JetBrains or VS Code terminal: the node runtime is the
    /// session's identity, so the companion can match its terminal tab.
    func testNpmClaudeInAnEditorTerminalHasARuntimeIdentity() throws {
        let processes: [Int32: IDEProcessLocation.ProcessInfo] = [
            50: process(50, parent: 42, path: "/bin/sh"),
            42: process(42, parent: 30, path: "/opt/homebrew/Cellar/node/22.1.0/bin/node", tty: true),
            30: process(30, parent: 20, path: "/bin/zsh", tty: true),
            20: process(20, parent: 1, path: "/Applications/PyCharm.app/Contents/MacOS/pycharm")
        ]
        let claude = ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        let result = try XCTUnwrap(IDEProcessLocation.locate(parentPID: 50, provider: .claude, read: { processes[$0] },
                                                            bundle: { _ in "com.jetbrains.pycharm" }, arguments: { $0 == 42 ? claude : nil }))
        XCTAssertEqual(result.runtime.pid, 42)
        XCTAssertTrue(result.usesTerminal)
        XCTAssertNil(IDEProcessLocation.locate(parentPID: 50, provider: .claude, read: { processes[$0] }, bundle: { _ in "com.jetbrains.pycharm" },
                                               arguments: { _ in ["node", "/Users/u/app/server.js"] }), "A dev server is not Claude")
        XCTAssertNil(IDEProcessLocation.locate(parentPID: 50, provider: .codex, read: { processes[$0] }, bundle: { _ in "com.jetbrains.pycharm" },
                                               arguments: { _ in claude }))
        var native = processes
        native[42] = process(42, parent: 30, path: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", tty: true)
        XCTAssertEqual(IDEProcessLocation.locate(parentPID: 50, provider: .claude, read: { native[$0] },
                                                 bundle: { _ in "com.microsoft.VSCode" })?.editor, .vscode)
        // A native Claude started by the Bash tool of an npm Claude is nested; the outer one is not.
        typealias Node = SessionProcess.RuntimeProcess
        let chain: [Int32: Node] = [
            90: Node(parentPID: 80, executable: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"),
            80: Node(parentPID: 70, executable: "/bin/zsh"),
            70: Node(parentPID: 60, executable: "/opt/homebrew/bin/node"),
            60: Node(parentPID: 50, executable: "/bin/zsh"),
            50: Node(parentPID: 1, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")]
        XCTAssertEqual(SessionProcess.nestedClaudeRuntime(startPID: 90, read: { chain[$0] }, arguments: { $0 == 70 ? claude : nil }), true)
        XCTAssertEqual(SessionProcess.nestedClaudeRuntime(startPID: 70, read: { chain[$0] }, arguments: { $0 == 70 ? claude : nil }), false)
        XCTAssertNil(SessionProcess.nestedClaudeRuntime(startPID: 70, read: { chain[$0] }, arguments: { _ in nil }), "Without its arguments node is unknown, as before")
    }

    /// Owner's case 28.09: `claude` in the embedded terminal of Claude Desktop is a catalog
    /// row with neither an editor nor a Terminal/iTerm2 tab. Its host is named instead.
    func testLaunchHostNamesPlacesWithoutARouteFromTheRuntimeAncestry() {
        typealias Node = SessionProcess.TerminalProcess
        let tty = "/dev/ttys007"
        func host(_ tree: [Int32: Node], bundle: String? = nil) -> SessionLaunchHost? {
            SessionProcess.launchHost(runtimePID: 90, read: { tree[$0] }, bundle: { _ in bundle })
        }
        let desktopTerminal: [Int32: Node] = [
            90: Node(parentPID: 80, tty: tty, executable: "/Users/u/.local/share/claude/versions/2.1.283"),
            80: Node(parentPID: 70, tty: tty, executable: "/bin/zsh"),
            70: Node(parentPID: 60, tty: nil, executable: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            60: Node(parentPID: 1, tty: nil, executable: "/Applications/Claude.app/Contents/MacOS/Claude")]
        XCTAssertEqual(host(desktopTerminal, bundle: "com.anthropic.claudefordesktop"), .init(kind: .embeddedTerminal, name: "Claude"))
        var desktopTask = desktopTerminal
        desktopTask[90] = Node(parentPID: 60, tty: nil, executable: "/Users/u/Library/Application Support/Claude/claude-code/2.1.283/claude.app/Contents/MacOS/claude")
        XCTAssertNil(host(desktopTask), "A Claude Desktop task without a terminal keeps its Desktop link")
        var codex = desktopTerminal
        codex[70] = Node(parentPID: 1, tty: nil, executable: "/Applications/Codex.app/Contents/MacOS/Codex")
        XCTAssertEqual(host(codex, bundle: "com.openai.codex"), .init(kind: .embeddedTerminal, name: "Codex"))
        var fork = desktopTerminal
        fork[90] = Node(parentPID: 70, tty: nil, executable: "/Users/u/.cursor/extensions/anthropic.claude-code/resources/native-binary/claude")
        fork[70] = Node(parentPID: 1, tty: nil, executable: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        XCTAssertEqual(host(fork, bundle: "com.todesktop.230313mzl4w4u92"), .init(kind: .application, name: "Cursor"))
        var ghostty = desktopTerminal
        ghostty[70] = Node(parentPID: 1, tty: nil, executable: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        XCTAssertEqual(host(ghostty, bundle: "com.mitchellh.ghostty"), .init(kind: .terminal, name: "Ghostty"))
        var bundledCLI = desktopTerminal
        bundledCLI[80] = Node(parentPID: 70, tty: tty, executable: "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertEqual(host(bundledCLI, bundle: "com.anthropic.claudefordesktop"), .init(kind: .embeddedTerminal, name: "Claude"),
                       "A CLI in an app's Resources is not the host")
        var terminal = desktopTerminal
        terminal[70] = Node(parentPID: 1, tty: nil, executable: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        XCTAssertNil(host(terminal), "Terminal has its own route")
        var editor = desktopTerminal
        editor[70] = Node(parentPID: 1, tty: nil, executable: "/Applications/PyCharm.app/Contents/MacOS/pycharm")
        XCTAssertNil(host(editor, bundle: "com.jetbrains.pycharm"), "A JetBrains IDE has the companion route")
        var detached = desktopTerminal
        detached[80] = Node(parentPID: 1, tty: tty, executable: "/bin/zsh")
        XCTAssertNil(host(detached), "An ancestry that ends at launchd names nothing")
        XCTAssertNil(host([:]))
        XCTAssertNil(host([90: Node(parentPID: 90, tty: tty, executable: "/bin/zsh")]), "A cycle ends the walk")
        let rows: [[String: Any]] = [["pid": 90, "cwd": "/Users/u", "kind": "interactive", "sessionId": "2f0c7c52-6a55-4f0e-9d1b-3a1f0c9e2d77", "status": "waiting"]]
        let parsed = try? SessionParser.claude(JSONSerialization.data(withJSONObject: rows), terminal: { _ in nil }, ide: { _ in nil },
                                               host: { pid in pid == 90 ? host(desktopTerminal, bundle: "com.anthropic.claudefordesktop") : nil })
        XCTAssertEqual(parsed?.first?.launchHost, .init(kind: .embeddedTerminal, name: "Claude"))
        XCTAssertEqual(parsed?.first?.launchHostRefusal, .embeddedTerminal("Claude"))
        let routed = try? SessionParser.claude(JSONSerialization.data(withJSONObject: rows), terminal: { _ in .init(tty: tty, app: "Terminal") },
                                               host: { _ in XCTFail("A row with a route needs no host"); return nil })
        XCTAssertNil(routed?.first?.launchHost)
    }

    /// N-08 / §4 item 10: every JetBrains IDE product and its EAP build, not a fixed list;
    /// JetBrains apps that cannot host the companion are not editors.
    func testJetBrainsProductsAndEAPBuildsAreRecognizedByPrefix() {
        for identifier in ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.intellij-EAP", "com.jetbrains.pycharm.ce",
                           "com.jetbrains.WebStorm-EAP", "com.jetbrains.CLion", "com.jetbrains.dataspell", "com.jetbrains.aqua",
                           "com.jetbrains.writerside", "com.jetbrains.rustrover-EAP"] {
            XCTAssertEqual(SessionIDE.identify(bundleIdentifier: identifier), .jetbrains, identifier)
        }
        for identifier in ["com.jetbrains.toolbox", "com.jetbrains.gateway", "com.jetbrains.fleet", "com.jetbrains.unrelated-service",
                           "com.jetbrains.", "com.jetbrains.intellij-EAP-helper", "com.google.android.studio", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertNil(SessionIDE.identify(bundleIdentifier: identifier), identifier)
        }
        XCTAssertEqual(SessionIDE.identify(bundleIdentifier: "com.microsoft.VSCodeInsiders"), .vscode)
    }

    /// Every JetBrains product goes through the same origin, descriptor and routing path
    /// as IntelliJ IDEA; only IntelliJ IDEA was exercised live.
    func testOtherJetBrainsProductsUseTheSameOriginAndCompanionPath() throws {
        for (bundle, app) in [("com.jetbrains.WebStorm", "WebStorm"), ("com.jetbrains.pycharm.ce", "PyCharm CE"), ("com.jetbrains.goland", "GoLand"),
                              ("com.jetbrains.rustrover-EAP", "RustRover"), ("com.jetbrains.PhpStorm", "PhpStorm"), ("com.jetbrains.rider", "Rider")] {
            let processes: [Int32: IDEProcessLocation.ProcessInfo] = [
                42: process(42, parent: 30, path: "/Users/u/.local/bin/claude", tty: true),
                30: process(30, parent: 20, path: "/bin/zsh", tty: true),
                20: process(20, parent: 1, path: "/Applications/\(app).app/Contents/MacOS/\(app.lowercased())")]
            let location = try XCTUnwrap(IDEProcessLocation.locate(parentPID: 42, provider: .claude, read: { processes[$0] }, bundle: { _ in bundle }), bundle)
            XCTAssertEqual(location.editor, .jetbrains, bundle)
            XCTAssertEqual(location.appPath, "/Applications/\(app).app")
            let id = UUID().uuidString
            let descriptor = IDEBridge.Descriptor(version: 1, id: id, editor: .jetbrains, pid: 20, appPath: location.appPath, bundleIdentifier: bundle,
                                                  socketPath: "/tmp/lunavect-ide-\(getuid())/\(id).sock", updatedAt: Date().timeIntervalSince1970, companion: "0.1.2")
            XCTAssertTrue(IDEBridge.valid(descriptor), "\(bundle): its companion descriptor is accepted")
        }
        let processes: [Int32: IDEProcessLocation.ProcessInfo] = [
            42: process(42, parent: 20, path: "/Users/u/.local/bin/claude", tty: true),
            20: process(20, parent: 1, path: "/Applications/Android Studio.app/Contents/MacOS/studio")]
        XCTAssertNil(IDEProcessLocation.locate(parentPID: 42, provider: .claude, read: { processes[$0] }, bundle: { _ in "com.google.android.studio" }),
                     "Android Studio is not a com.jetbrains product; the companion refuses it too")
    }

    /// Messages name the actual JetBrains product from its bundle, not the vendor.
    func testEditorMessagesNameTheProductFromItsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("PyCharm CE.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.jetbrains.pycharm.ce", "CFBundleName": "PyCharm CE"],
                                                       format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let jetbrains = IDESessionLocation(editor: .jetbrains, bundleIdentifier: "com.jetbrains.pycharm.ce", appPath: app.path,
                                           runtime: .init(pid: 42, startedAtMicroseconds: 1), usesTerminal: true)
        XCTAssertEqual(IDEBridge.Environment.live.displayName(jetbrains), "PyCharm CE")
        let missing = IDESessionLocation(editor: .jetbrains, bundleIdentifier: "com.jetbrains.goland", appPath: root.appendingPathComponent("GoLand.app").path,
                                         runtime: .init(pid: 42, startedAtMicroseconds: 1), usesTerminal: true)
        XCTAssertEqual(IDEBridge.Environment.live.displayName(missing), "GoLand", "Without Info.plist the bundle folder names the product")
        XCTAssertEqual(IDEBridge.Environment.live.displayName(location(.vscode)), "VS Code")
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
