import XCTest
@testable import WeekleftCore

/// Terminal focus scripts another application, so its inputs are validated here.
final class TerminalLocationTests: XCTestCase {
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

    func testRuntimeClassificationIgnoresInterpreters() {
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/.local/share/claude/versions/2.1.280"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(SessionProcess.runtimeProvider(ofExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex"), .codex)
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/opt/homebrew/bin/node"), "A dev server in the same folder is not Claude")
        XCTAssertNil(SessionProcess.runtimeProvider(ofExecutable: "/Users/test/versions/2.1.280"))
    }
}
