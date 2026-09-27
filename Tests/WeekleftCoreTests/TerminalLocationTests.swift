import XCTest
@testable import WeekleftCore

/// Terminal focus scripts another application, so its inputs are validated here.
final class TerminalLocationTests: XCTestCase {
    func testDetachedHookFindsItsClientsControllingTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c"), executable = root.appendingPathComponent("claude")
        try #"""
        #include <util.h>
        #include <unistd.h>
        #include <stdio.h>
        #include <signal.h>
        #include <fcntl.h>
        #include <sys/ioctl.h>
        int main(void) {
            /* Run from a Terminal tab, this launcher inherits the test host's
               controlling terminal and is itself a `claude` process in the same
               folder, so the folder fallback would rightly see two sessions.
               Detach it; only the forkpty client may own a terminal. */
            if (setsid() < 0) {
                int tty = open("/dev/tty", O_RDWR | O_NOCTTY);
                if (tty >= 0) { ioctl(tty, TIOCNOTTY); close(tty); }
            }
            int master; pid_t client = forkpty(&master, NULL, NULL, NULL);
            if (client < 0) return 1;
            if (client == 0) {
                if (fork() == 0) {
                    if (setsid() < 0) _exit(2);
                    printf("%d\n", getpid()); fflush(stdout);
                }
                for (;;) pause();
            }
            char bytes[128]; int n = read(master, bytes, sizeof(bytes));
            if (n > 0) { write(STDOUT_FILENO, bytes, n); }
            for (;;) pause();
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]; try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let output = Pipe(), process = Process(); process.executableURL = executable; process.standardOutput = output
        process.currentDirectoryURL = root
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let hook = try XCTUnwrap(Int32(line))
        defer { _ = kill(hook, SIGTERM) }
        var launcher = proc_bsdinfo()
        if proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &launcher, Int32(MemoryLayout<proc_bsdinfo>.size))
            == Int32(MemoryLayout<proc_bsdinfo>.size), launcher.e_tdev != UInt32.max {
            throw XCTSkip("The fixture launcher could not detach from the test host's terminal; the folder fallback cannot be isolated here")
        }
        let client = try XCTUnwrap(SessionProcess.runtimeProcess(hook)).parentPID
        defer { _ = kill(client, SIGTERM) }
        let expected = try XCTUnwrap(SessionProcess.terminalLocation(parentPID: client, termProgram: "Apple_Terminal"))
        let actual = SessionProcess.terminalLocation(parentPID: hook, termProgram: "Apple_Terminal")
        XCTAssertEqual(actual?.tty, expected.tty, "A detached hook has no controlling TTY; its live client still does")
        XCTAssertEqual(actual?.app, "Terminal")
        XCTAssertEqual(TerminalLocation.runningTarget(provider: .claude, cwd: root.path)?.tty, expected.tty)

        let otherOutput = Pipe(), other = Process(); other.executableURL = executable
        other.currentDirectoryURL = root; other.standardOutput = otherOutput
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        let otherLine = String(decoding: otherOutput.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let otherHook = try XCTUnwrap(Int32(otherLine))
        defer { _ = kill(otherHook, SIGTERM) }
        let otherClient = try XCTUnwrap(SessionProcess.runtimeProcess(otherHook)).parentPID
        defer { _ = kill(otherClient, SIGTERM) }
        XCTAssertNil(TerminalLocation.runningTarget(provider: .claude, cwd: root.path),
                     "Two sessions in one folder cannot be distinguished by folder alone")
    }

    func testCatalogAssociatesEachSessionWithItsOwnProcessAndPreservesLiveLocation() throws {
        let data = Data(#"[{"sessionId":"first","pid":10,"cwd":"/tmp/project","kind":"interactive","status":"busy"},{"sessionId":"second","pid":20,"cwd":"/tmp/project","kind":"interactive","status":"busy"},{"sessionId":"background","pid":30,"kind":"background","status":"busy"},{"sessionId":"bad-pid","pid":-2,"kind":"interactive"}]"#.utf8)
        var reads: [Int32] = []
        let now = Date()
        let catalog = try SessionParser.claude(data, now: now, terminal: { pid in
            reads.append(pid)
            return TerminalLocation.Target(tty: pid == 10 ? "/dev/ttys003" : "/dev/ttys004", app: "Terminal")
        })
        XCTAssertEqual(reads, [10, 20], "Background tasks use attach; invalid PIDs never reach libproc")
        XCTAssertEqual(catalog[0].client, .terminal)
        XCTAssertEqual(catalog[0].terminalTTY, "/dev/ttys003")
        XCTAssertEqual(catalog[1].terminalTTY, "/dev/ttys004")
        var old = catalog[0]; old.evidence = .hook
        old.observedAt = now.addingTimeInterval(-60); old.terminalTTY = "/dev/ttys099"
        let merged = SessionList.merge(catalog: catalog, events: [old], now: now)
        XCTAssertEqual(merged.first { $0.sessionID == "first" }?.terminalTTY, "/dev/ttys003",
                       "A hook from an earlier terminal must not overwrite the current process")
        let unlocated = try SessionParser.claude(data, now: now)
        XCTAssertEqual(SessionList.merge(catalog: unlocated, events: [old], now: now).first { $0.sessionID == "first" }?.terminalTTY,
                       "/dev/ttys099", "Hooks still recover a location when the catalog cannot")
    }

    func testAutomationDenialAndTimeoutHaveSpecificRecoveryMessages() {
        XCTAssertEqual(TerminalLocation.focusError(code: -1743, app: "Terminal"), .terminalAutomationDenied("Terminal"))
        XCTAssertEqual(TerminalLocation.focusError(code: -1712, app: "iTerm2"), .terminalFocusTimedOut("iTerm2"))
        XCTAssertEqual(TerminalLocation.focusError(code: -1708, app: "Terminal"), .terminalFocusFailed("Terminal"))
    }

    private func session(client: SessionClient, tty: String? = nil, app: String? = nil, phase: SessionPhase = .running) -> AgentSession {
        var row = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                               cwd: "/tmp/project", client: client, phase: phase, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.terminalTTY = tty; row.terminalApp = app
        return row
    }

    func testOnlyPlainTerminalDevicesReachTheScript() {
        XCTAssertTrue(TerminalLocation.valid("/dev/ttys003"))
        for value in ["/dev/ttys003\n", "/dev/ttys", "/dev/ttys12345", "/dev/console", "/dev/ttys1\" & quit", " /dev/ttys1"] {
            XCTAssertFalse(TerminalLocation.valid(value), value)
            XCTAssertNil(TerminalLocation.focusScript(tty: value, app: "Terminal"), value)
        }
        XCTAssertNil(TerminalLocation.focusScript(tty: "/dev/ttys003", app: "Warp"), "Unknown terminals are not scripted")
        for app in ["Terminal", "iTerm2"] {
            let script = TerminalLocation.focusScript(tty: "/dev/ttys003", app: app)
            XCTAssertTrue(script?.contains("tell application \"\(app)\"") == true, app)
            XCTAssertTrue(script?.contains("is \"/dev/ttys003\"") == true, app)
            XCTAssertNotNil(TerminalLocation.bundleIdentifier(forApp: app))
        }
    }

    /// The helper also bounds each Apple event and stops on its first timeout;
    /// the process runner separately enforces the overall navigation budget.
    func testFocusScriptsBoundEveryAppleEventAndStopAtTheFirstTimeout() throws {
        XCTAssertLessThanOrEqual(TerminalLocation.focusTimeout, 10, "Stays well inside Keep Awake's 30 s lease")
        for app in ["Terminal", "iTerm2"] {
            let script = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: app))
            let lines = script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(lines.first, "with timeout of \(TerminalLocation.focusTimeout) seconds", app)
            XCTAssertEqual(lines.suffix(2), ["end timeout", "return false"], app)
            let guarded = lines.filter { $0 == "try" }.count
            XCTAssertGreaterThan(guarded, 0, app)
            XCTAssertEqual(lines.filter { $0 == "if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber" }.count, guarded,
                           "\(app): a per-tab error handler must not swallow a timeout or Automation denial")
        }
    }

    func testRecordedDeviceWinsAndOnlyTerminalSessionsSearchProcesses() {
        var searches: [(ProviderID, String)] = []
        let running: (ProviderID, String) -> TerminalLocation.Target? = { provider, cwd in
            searches.append((provider, cwd)); return TerminalLocation.Target(tty: "/dev/ttys009", app: "Terminal")
        }
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal, tty: "/dev/ttys004", app: "iTerm2"), running: running),
                       TerminalLocation.Target(tty: "/dev/ttys004", app: "iTerm2"))
        XCTAssertTrue(searches.isEmpty)
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal), running: running)?.tty, "/dev/ttys009")
        XCTAssertEqual(searches.map(\.1), ["/tmp/project"])
        for client in [SessionClient.desktop, .vscode, .background, .unknown] {
            XCTAssertNil(TerminalLocation.focusTarget(for: session(client: client), running: running), client.rawValue)
        }
        XCTAssertEqual(searches.count, 1, "Desktop, editor and background sessions never match a CLI in the same folder")
        XCTAssertNil(TerminalLocation.focusTarget(for: session(client: .terminal, phase: .finished), running: running),
                     "An exited CLI is resumed instead")
        XCTAssertEqual(TerminalLocation.focusTarget(for: session(client: .terminal, tty: "/dev/ttys004\n"), running: running)?.tty,
                       "/dev/ttys009", "An invalid recorded device falls back to the process search")
    }

    // MARK: Process tables (no live processes)

    private typealias Table = [Int32: SessionProcess.TerminalProcess]
    private static let terminalApp = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    private func proc(_ parent: Int32?, _ executable: String?, tty: String? = nil) -> SessionProcess.TerminalProcess {
        .init(parentPID: parent, tty: tty, executable: executable)
    }
    private func bundles(_ path: String) -> String? {
        ["/Applications/Ghostty.app": "com.mitchellh.ghostty", "/Applications/kitty.app": "net.kovidgoyal.kitty",
         "/Applications/Cursor.app": "com.todesktop.230313mzl4w4u92", "/Applications/Visual Studio Code.app": "com.microsoft.VSCode",
         "/Applications/Warp.app": "dev.warp.Warp-Stable", "/Applications/PyCharm.app": "com.jetbrains.pycharm"][path]
    }
    private func locate(_ table: Table, from pid: Int32 = 40, termProgram: String = "") -> (tty: String, app: String)? {
        SessionProcess.terminalLocation(parentPID: pid, termProgram: termProgram, read: { table[$0] }, bundle: bundles)
    }

    /// §4 item 5: both Terminal profiles, with and without a root-owned login.
    func testLoginAndNonLoginShellProfilesBothReachTheirTerminal() {
        let shell: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: "/dev/ttys004"),
                            30: proc(20, "/bin/zsh", tty: "/dev/ttys004"), 20: proc(1, Self.terminalApp)]
        XCTAssertEqual(locate(shell)?.tty, "/dev/ttys004")
        XCTAssertEqual(locate(shell)?.app, "Terminal", "A non-login shell is a direct child of Terminal")
        var login = shell
        login[30] = proc(25, "/bin/zsh", tty: "/dev/ttys004")
        login[25] = proc(20, "/usr/bin/login", tty: "/dev/ttys004")
        XCTAssertEqual(locate(login)?.app, "Terminal", "An inspectable login is walked through")
        login[25] = proc(20, nil, tty: "/dev/ttys004")
        XCTAssertEqual(locate(login, termProgram: "Apple_Terminal")?.app, "Terminal", "Hooks know the host from TERM_PROGRAM")
        XCTAssertEqual(locate(login)?.tty, "/dev/ttys004")
        XCTAssertEqual(locate(login)?.app, "", "The catalog cannot name a host hidden by login; the device is kept")
        login[25] = nil
        XCTAssertEqual(locate(login)?.app, "", "Unreadable login")
        XCTAssertEqual(locate(login, termProgram: "iTerm.app")?.app, "iTerm2")
    }

    /// N-07 / §4 items 6 and 8: the device survives to launchd and the actual host is named.
    func testUnsupportedHostsKeepTheirDeviceAndName() {
        let tty = "/dev/ttys010"
        let ghostty: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                              20: proc(1, "/Applications/Ghostty.app/Contents/MacOS/ghostty")]
        XCTAssertEqual(locate(ghostty)?.tty, tty)
        XCTAssertEqual(locate(ghostty)?.app, "Ghostty")
        XCTAssertEqual(locate(ghostty, termProgram: "ghostty")?.app, "Ghostty")
        let kitty: Table = [40: proc(30, "/Users/u/.local/bin/codex", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                            20: proc(1, "/Applications/kitty.app/Contents/MacOS/kitty")]
        XCTAssertEqual(locate(kitty)?.app, "kitty", "kitty sets no TERM_PROGRAM")
        let tmux: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                           20: proc(1, "/opt/homebrew/bin/tmux")]
        XCTAssertEqual(locate(tmux, termProgram: "tmux")?.app, "tmux")
        XCTAssertEqual(locate(tmux)?.app, "tmux")
        let screen: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                             20: proc(1, "/opt/homebrew/bin/screen")]
        XCTAssertEqual(locate(screen, termProgram: "Apple_Terminal")?.app, "screen",
                       "screen inherits TERM_PROGRAM; its pane is not a Terminal tab")
        let cursor: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                             20: proc(10, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
                             10: proc(1, "/Applications/Cursor.app/Contents/MacOS/Cursor")]
        XCTAssertEqual(locate(cursor, termProgram: "vscode")?.app, "Cursor")
        let restored: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(25, "/bin/zsh", tty: tty),
                               25: proc(20, "/usr/bin/login", tty: tty),
                               20: proc(1, "/Users/u/Library/Application Support/iTerm2/iTermServer-3.5.10")]
        XCTAssertEqual(locate(restored)?.app, "iTerm2", "iTerm2 session restoration hosts shells in iTermServer")
        let nested: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                             20: proc(15, "/Applications/Alacritty.app/Contents/MacOS/alacritty", tty: "/dev/ttys002"),
                             15: proc(12, "/bin/zsh", tty: "/dev/ttys002"), 12: proc(1, Self.terminalApp)]
        XCTAssertEqual(locate(nested)?.app, "Alacritty", "The nearest terminal emulator owns the device, not the Terminal that started it")
        let editor: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                             20: proc(1, "/Applications/PyCharm.app/Contents/MacOS/pycharm")]
        XCTAssertNil(locate(editor), "Editor terminals use the IDE route")
    }

    /// N-08 / §4 items 7 and 8: forks, ssh and terminals without TERM_PROGRAM
    /// are terminal sessions, not VS Code or Codex Desktop.
    func testClientDetectionForForksRemoteShellsAndUnlabelledTerminals() {
        let tty = "/dev/ttys010"
        func client(_ table: Table, terminal: String = "", entrypoint: String = "") -> SessionClient {
            SessionProcess.client(parentPID: 40, entrypoint: entrypoint, terminal: terminal, read: { table[$0] }, bundle: bundles)
        }
        let cursor: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                             20: proc(1, "/Applications/Cursor.app/Contents/MacOS/Cursor")]
        XCTAssertEqual(client(cursor, terminal: "vscode"), .terminal, "A VS Code fork is not VS Code")
        let official: Table = [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                               20: proc(1, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")]
        XCTAssertEqual(client(official, terminal: "vscode"), .vscode)
        let ssh: Table = [40: proc(30, "/Users/u/.local/bin/codex", tty: tty), 30: proc(20, "/bin/zsh", tty: tty), 20: proc(nil, nil)]
        XCTAssertEqual(client(ssh), .terminal, "A Codex CLI over ssh must not open Codex Desktop")
        let kitty: Table = [40: proc(30, "/Users/u/.local/bin/codex", tty: tty), 30: proc(20, "/bin/zsh", tty: tty),
                            20: proc(1, "/Applications/kitty.app/Contents/MacOS/kitty")]
        XCTAssertEqual(client(kitty), .terminal)
        let desktop: Table = [40: proc(20, "/Applications/Codex.app/Contents/Resources/codex"),
                              20: proc(1, "/Applications/Codex.app/Contents/MacOS/Codex")]
        XCTAssertEqual(client(desktop), .desktop)
        let agent: Table = [40: proc(1, "/Users/u/.local/bin/codex")]
        XCTAssertEqual(client(agent), .unknown, "No terminal, no host: still unknown")
    }

    /// §4 item 14: the launcher for a finished session survives quotes, newlines
    /// and non-ASCII project paths. Runs zsh directly, never Terminal.
    func testResumeLauncherQuotesUnusualProjectPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let project = root.appendingPathComponent("Wet Dog's \"проект\"\nnext $(touch pwned)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out.txt")
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > \(SessionHooks.quote(output.path))\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        var row = AgentSession(provider: .claude, sessionID: "01234567-89ab-cdef-0123-456789abcdef", title: "Fixture",
                               cwd: project.path, client: .terminal, phase: .finished, updatedAt: Date(), observedAt: Date(), evidence: .hook)
        row.terminalTTY = nil
        let script = try XCTUnwrap(row.terminalScript(executable: fake.path))
        let launcher = root.appendingPathComponent("open.command")
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        let zsh = Process(); zsh.executableURL = URL(fileURLWithPath: "/bin/zsh"); zsh.arguments = ["-f", launcher.path]
        zsh.environment = ["PATH": "/usr/bin:/bin"]
        try zsh.run(); zsh.waitUntilExit()
        XCTAssertEqual(zsh.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), project.path + "\n--resume\n01234567-89ab-cdef-0123-456789abcdef\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("pwned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pwned").path))
    }

    func testRuntimeClassificationIgnoresInterpreters() {
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/.local/share/claude/versions/2.1.280"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex"), .codex)
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/node"), "A dev server in the same folder is not Claude")
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/versions/2.1.280"))
    }
}
