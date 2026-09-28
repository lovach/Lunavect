import XCTest
@testable import WeekleftCore

/// Terminal focus scripts another application, so its inputs are validated here.
final class TerminalLocationTests: XCTestCase {
    /// A launcher that detaches from the test host's terminal, then runs a
    /// `forkpty` client whose detached child plays the hook and prints its PID.
    private static let launcherSource = #"""
    #include <util.h>
    #include <unistd.h>
    #include <stdio.h>
    #include <string.h>
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
        /* Forward the hook's whole line, however the terminal splits it. */
        char bytes[128]; int used = 0;
        while (used < (int)sizeof(bytes)) {
            int n = read(master, bytes + used, sizeof(bytes) - used);
            if (n <= 0) break;
            used += n;
            if (memchr(bytes, '\n', used)) break;
        }
        if (used > 0) { write(STDOUT_FILENO, bytes, used); }
        for (;;) pause();
    }
    """#
    private static let natives = NativeFixtures(prefix: "terminal-location-fixture")
    override class func setUp() {
        super.setUp()
        // Compiled once per suite; the name makes every fixture process a `claude` runtime.
        _ = try? natives.compileOnce(launcherSource, as: "claude")
    }
    override class func tearDown() {
        natives.removeDirectory()
        super.tearDown()
    }
    override func tearDown() {
        // Runs after assertion failures and thrown errors too: no pause() fixture survives.
        Self.natives.stopAll()
        super.tearDown()
    }

    func testDetachedHookFindsItsClientsControllingTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try Self.natives.compileOnce(Self.launcherSource, as: "claude")
        let output = Pipe()
        let process = try Self.natives.launch(executable, in: root, output: output)
        let hook = try XCTUnwrap(Int32(NativeFixtures.readLine(from: output.fileHandleForReading)))
        Self.natives.track(hook)
        var launcher = proc_bsdinfo()
        if proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &launcher, Int32(MemoryLayout<proc_bsdinfo>.size))
            == Int32(MemoryLayout<proc_bsdinfo>.size), launcher.e_tdev != UInt32.max {
            throw XCTSkip("The fixture launcher could not detach from the test host's terminal; the folder fallback cannot be isolated here")
        }
        let client = try XCTUnwrap(SessionProcess.runtimeProcess(hook)).parentPID
        Self.natives.track(client)
        let expected = try XCTUnwrap(SessionProcess.terminalLocation(parentPID: client, termProgram: "Apple_Terminal"))
        let actual = SessionProcess.terminalLocation(parentPID: hook, termProgram: "Apple_Terminal")
        XCTAssertEqual(actual?.tty, expected.tty, "A detached hook has no controlling TTY; its live client still does")
        XCTAssertEqual(actual?.app, "Terminal")
        XCTAssertEqual(TerminalLocation.runningTarget(provider: .claude, cwd: root.path)?.tty, expected.tty)

        let otherOutput = Pipe()
        _ = try Self.natives.launch(executable, in: root, output: otherOutput)
        let otherHook = try XCTUnwrap(Int32(NativeFixtures.readLine(from: otherOutput.fileHandleForReading)))
        Self.natives.track(otherHook)
        let otherClient = try XCTUnwrap(SessionProcess.runtimeProcess(otherHook)).parentPID
        Self.natives.track(otherClient)
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

    /// Numeric AppleScript errors from the real osascript helper (no `tell
    /// application`, so no Apple event is sent) reach distinct recovery messages.
    func testAutomationDenialAndTimeoutHaveSpecificRecoveryMessages() async {
        var messages: Set<String> = []
        for (code, expected) in [(-1743, SessionOpeningError.terminalAutomationDenied("iTerm2")),
                                 (-1712, .terminalFocusTimedOut("iTerm2")), (-1708, .terminalFocusFailed("iTerm2"))] {
            do {
                _ = try await TerminalLocation.executeFocusScript("error \"localized text\" number \(code)", app: "iTerm2", timeout: TestDeadline.seconds)
                XCTFail("Expected error \(code)")
            } catch {
                XCTAssertEqual(error as? SessionOpeningError, expected)
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains("iTerm2"), "The message names the terminal: \(message)")
                messages.insert(message)
            }
        }
        XCTAssertEqual(messages.count, 3, "Denial, timeout and other failures ask for different recovery steps")
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
    func testFocusScriptsBoundEveryAppleEventAndStopAtTheFirstTimeout() async throws {
        // Pins a documented relation, not behavior: Keep Awake holds a 30 s lease.
        XCTAssertLessThanOrEqual(TerminalLocation.focusTimeout, 10, "Stays well inside Keep Awake's 30 s lease")
        // Kept as text: `with timeout` only acts on a real Apple event, which this suite never sends.
        for app in ["Terminal", "iTerm2"] {
            let script = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: app))
            let lines = script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(lines.first, "with timeout of \(TerminalLocation.focusTimeout) seconds", app)
            XCTAssertEqual(lines.suffix(2), ["end timeout", "return false"], app)
        }
        // Kept as text: iTerm2's `select` exists only in its dictionary, so its script cannot run on a stand-in.
        let iTerm = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: "iTerm2"))
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(iTerm.filter { $0 == "if errorNumber is -1712 or errorNumber is -1743 then error errorMessage number errorNumber" }.count,
                       iTerm.filter { $0 == "try" }.count, "iTerm2: a per-tab error handler must not swallow a timeout or Automation denial")

        // Terminal's script runs through the real osascript helper against an
        // in-script stand-in instead of Terminal: two windows, each with a tab on
        // the device. Its `activate` fails once with the given error number.
        let generated = try XCTUnwrap(TerminalLocation.focusScript(tty: "/dev/ttys003", app: "Terminal"))
        let target = "tell application \"Terminal\"", windows = "repeat with w in windows"
        XCTAssertEqual(generated.components(separatedBy: target).count, 2, "The stand-in replaces exactly one application target")
        XCTAssertEqual(generated.components(separatedBy: windows).count, 2, "The stand-in replaces exactly one window query")
        func run(failingOnce error: Int) async throws -> Bool {
            let standIn = """
            set standInWindows to {{miniaturized:false, index:2, tabs:{{tty:"/dev/ttys001", processes:{1}, selected:false}, \
            {tty:"/dev/ttys003", processes:{1}, selected:false}}}, {miniaturized:true, index:3, tabs:{{tty:"/dev/ttys003", processes:{1}, selected:false}}}}
            script standInTerminal
                property activations : 0
                on activate
                    set activations to activations + 1
                    if activations is 1 and \(error) is not 0 then error "stand-in failure" number \(error)
                end activate
            end script

            """
            let script = standIn + generated.replacingOccurrences(of: target, with: "tell standInTerminal")
                .replacingOccurrences(of: windows, with: "repeat with w in standInWindows")
            // Never run a script that could still address an application.
            guard !script.contains("tell application"), !script.contains(" windows") else {
                throw FixtureError(description: "The stand-in did not replace the application target; the script was not run")
            }
            return try await TerminalLocation.executeFocusScript(script, app: "Terminal", timeout: TestDeadline.seconds)
        }
        let focused = try await run(failingOnce: 0)
        XCTAssertTrue(focused, "The first tab on the device is focused")
        let skipped = try await run(failingOnce: -1728)
        XCTAssertTrue(skipped, "An ordinary per-tab error (a closed tab) moves on to the next match")
        for (code, expected) in [(-1712, SessionOpeningError.terminalFocusTimedOut("Terminal")), (-1743, .terminalAutomationDenied("Terminal"))] {
            do {
                let result = try await run(failingOnce: code)
                XCTFail("Error \(code) was swallowed and the search continued to another tab (result \(result))")
            } catch { XCTAssertEqual(error as? SessionOpeningError, expected, "Error \(code) must stop the search") }
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
        // R2-10: a login whose path is hidden still names its parent; the walk continues to the host.
        XCTAssertEqual(locate(login)?.app, "Terminal", "The catalog names the host behind a hidden login")
        login[25] = nil
        XCTAssertEqual(locate(login)?.app, "", "Unreadable login")
        XCTAssertEqual(locate(login, termProgram: "iTerm.app")?.app, "iTerm2")
    }

    /// R2-10: macOS does not disclose another user's BSD info, so Terminal's
    /// root-owned login used to end the walk with an empty host, and every catalog
    /// row (no TERM_PROGRAM) or emulator without it (Alacritty) had no host name.
    /// The short BSD record still names the parent; the walk continues through login.
    func testRootOwnedLoginIsWalkedThroughToTheRealHost() {
        let tty = "/dev/ttys012"
        func chain(_ host: String, loginPath: String?) -> Table {
            [40: proc(30, "/Users/u/.local/bin/claude", tty: tty), 30: proc(25, "/bin/zsh", tty: tty),
             25: proc(20, loginPath), 20: proc(1, host)]
        }
        for loginPath in ["/usr/bin/login", nil] as [String?] {
            XCTAssertEqual(locate(chain("/Applications/Alacritty.app/Contents/MacOS/alacritty", loginPath: loginPath))?.app, "Alacritty",
                           "Alacritty sets no TERM_PROGRAM (login path \(loginPath ?? "hidden"))")
            XCTAssertEqual(locate(chain(Self.terminalApp, loginPath: loginPath))?.app, "Terminal",
                           "A catalog row has no TERM_PROGRAM (login path \(loginPath ?? "hidden"))")
            XCTAssertEqual(locate(chain(Self.terminalApp, loginPath: loginPath))?.tty, tty)
        }
        // A process on another known device whose path is hidden still ends the walk.
        var foreign = chain(Self.terminalApp, loginPath: nil)
        foreign[25] = proc(20, nil, tty: "/dev/ttys099")
        XCTAssertEqual(locate(foreign)?.app, "", "An unknown process on another device is not looked through")
        // The live record of another user's process (launchd) keeps its parent.
        XCTAssertNotNil(SessionProcess.terminalProcess(1)?.parentPID, "The short BSD record needs no same-user access")
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
        // Audit 02 §5.11 (from WP-2): the Codex CLI bundled in a desktop app, run from
        // a Terminal tab, belongs to Terminal, not to the app that ships it.
        let bundled: Table = [40: proc(30, "/Applications/ChatGPT.app/Contents/Resources/codex", tty: tty),
                              30: proc(20, "/bin/zsh", tty: tty), 20: proc(10, "/usr/bin/login", tty: tty),
                              10: proc(1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")]
        XCTAssertEqual(client(bundled), .terminal)
        XCTAssertEqual(client(bundled, terminal: "Apple_Terminal"), .terminal)
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
        // A regression that runs `$(touch pwned)` must do so inside this fixture (checked
        // below), not in the directory the suite was started from.
        zsh.environment = ["PATH": "/usr/bin:/bin"]; zsh.currentDirectoryURL = root
        try zsh.run(); zsh.waitUntilExit()
        XCTAssertEqual(zsh.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), project.path + "\n--resume\n01234567-89ab-cdef-0123-456789abcdef\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("pwned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pwned").path))
    }

    /// Fixed-seed SplitMix64: the same inputs on every run and machine.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// N-I4 / L9, bounded fuzz with a fixed seed: whatever a project folder or CLI
    /// folder is called (quotes, backslashes, `$()`, backticks, globs, newlines,
    /// control and bidi characters, emoji), the resume launcher reaches exactly that
    /// folder and passes exactly the session ID; nothing in a name is executed. Runs
    /// zsh on the generated script with a fake CLI in a temporary folder, never Terminal.
    func testResumeLauncherKeepsArbitraryFolderNamesInert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-N-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pieces = ["'", "\"", "\\", "$", "`", "(", ")", ";", "&", "|", "*", "?", "~", "!", "#", " ", "\n", "\t", "\r", "{", "}",
                      "[", "]", "<", ">", "%", "^", "=", ",", "-", ".", "é", "проект", "🐶", "a", "Z", "0", "$(touch pwned)",
                      "`touch pwned`", "'$HOME'", "\u{202E}", "\u{1B}[31m", "--resume"]
        var random = Seeded(state: 0x4C55_4E41_5645_4354)
        func name() -> String {
            var text = ""
            for _ in 0..<Int.random(in: 1...6, using: &random) { text += pieces.randomElement(using: &random)! }
            return text == "." || text == ".." ? text + "x" : text
        }
        let output = root.appendingPathComponent("out.txt")
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        for index in 0..<16 {
            let case_ = root.appendingPathComponent("\(index)")
            let project = case_.appendingPathComponent(name()), bin = case_.appendingPathComponent(name())
            guard project.lastPathComponent != bin.lastPathComponent else { continue }
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let fake = bin.appendingPathComponent("claude")
            try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > \(SessionHooks.quote(output.path))\n".write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let row = AgentSession(provider: .claude, sessionID: id, title: "Fixture", cwd: project.path, client: .terminal,
                                   phase: .finished, updatedAt: Date(), observedAt: Date(), evidence: .hook)
            let script = try XCTUnwrap(row.terminalScript(executable: fake.path), project.path)
            let launcher = case_.appendingPathComponent("open.command")
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: output)
            let zsh = Process(); zsh.executableURL = URL(fileURLWithPath: "/bin/zsh"); zsh.arguments = ["-f", launcher.path]
            zsh.environment = ["PATH": "/usr/bin:/bin"]; zsh.currentDirectoryURL = root
            zsh.standardOutput = FileHandle.nullDevice; zsh.standardError = FileHandle.nullDevice
            try zsh.run(); zsh.waitUntilExit()
            XCTAssertEqual(zsh.terminationStatus, 0, project.lastPathComponent.debugDescription)
            XCTAssertEqual(try? String(contentsOf: output, encoding: .utf8), project.path + "\n--resume\n" + id + "\n",
                           project.lastPathComponent.debugDescription + " / " + bin.lastPathComponent.debugDescription)
        }
        let pwned = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix("/pwned") || $0 == "pwned" } ?? []
        XCTAssertEqual(pwned, [], "No command in a folder name ran")
    }

    /// N-I4, bounded fuzz with a fixed seed: only a plain `/dev/ttysN` (1-4 digits)
    /// ever reaches an AppleScript source. The oracle is written independently of the regex.
    func testOnlyPlainDevicesReachAppleScriptUnderFuzz() {
        func plain(_ text: String) -> Bool {
            guard text.hasPrefix("/dev/ttys") else { return false }
            let digits = text.utf8.dropFirst("/dev/ttys".utf8.count)
            return (1...4).contains(digits.count) && digits.allSatisfy { (0x30...0x39).contains($0) }
        }
        let pieces = ["/dev/ttys", "/dev/tty", "0", "7", "12", "\n", "\r", "\"", "\\", " ", "& quit", "\u{0}", "٣", "１", "\u{200B}", "/", "s"]
        var random = Seeded(state: 0x7474_7973)
        var accepted = 0
        for _ in 0..<2_000 {
            var text = ""
            for _ in 0..<Int.random(in: 1...5, using: &random) { text += pieces.randomElement(using: &random)! }
            for app in ["Terminal", "iTerm2"] {
                let script = TerminalLocation.focusScript(tty: text, app: app)
                XCTAssertEqual(script != nil, plain(text), text.debugDescription)
                if let script { XCTAssertTrue(script.contains("is \"" + text + "\""), text.debugDescription); accepted += 1 }
            }
        }
        XCTAssertGreaterThan(accepted, 0, "The generator also produces valid devices")
    }

    func testRuntimeClassificationIgnoresInterpreters() {
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/.local/share/claude/versions/2.1.280"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex"), .codex)
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/node"), "A dev server in the same folder is not Claude")
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/versions/2.1.280"))
    }
}
