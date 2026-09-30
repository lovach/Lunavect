import XCTest
import WeekleftCore
@testable import Weekleft

@MainActor final class SessionControlServiceTests: XCTestCase {
    final class Typed: @unchecked Sendable { var calls: [(String, String, String)] = []; var result = true }
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var notices: [String] = []
    private var level = 75.0
    private var reset: TimeInterval = 86400

    private func service(_ typed: Typed, rows: [AgentSession], limits: URL) -> SessionControlService {
        SessionControlService(url: nil, limitURL: limits, dependencies: .init(
            ledger: { TokenLedger() },
            snapshots: { [unowned self] in [UsageSnapshot(provider: .claude, weekly: try! QuotaWindow(usedPercent: self.level, durationMinutes: 10080, resetsAt: self.now.addingTimeInterval(self.reset)), fetchedAt: self.now)] },
            sessions: { rows },
            type: { text, tty, app in typed.calls.append((text, tty, app)); return typed.result },
            notify: { [unowned self] title, _ in self.notices.append(title) },
            clock: { [unowned self] in self.now }))
    }
    private func row(client: SessionClient = .terminal) -> AgentSession {
        var row = AgentSession(provider: .claude, sessionID: "S1", title: "Refactor", cwd: "/p/Lunavect", phase: .idle, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        row.client = client; row.terminalTTY = "/dev/ttys004"; row.terminalApp = "Terminal"
        return row
    }

    func testStopsAtTheLevelThenContinuesInTheSameTabAfterTheReset() async throws {
        let limits = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: limits) }
        let typed = Typed(), session = row()
        let controls = service(typed, rows: [session], limits: limits)
        controls.setLimit(for: session, stopAtWeek: 85, continueAfterReset: true, message: "")
        await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .watching)
        XCTAssertTrue(SessionLimitFile.load(from: limits).entries.isEmpty)

        level = 83; await controls.tick()
        XCTAssertEqual(SessionLimitFile.load(from: limits).entries["claude:S1"]?.state, .wrappingUp)
        level = 86; await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .stopped)
        XCTAssertEqual(SessionLimitFile.load(from: limits).entries["claude:S1"]?.state, .stopped, "hooks now refuse its actions")
        XCTAssertTrue(notices.contains(L("Сессия остановлена на пределе")))
        XCTAssertTrue(typed.calls.isEmpty)

        // The week resets: the level falls, the hooks let it go, and «продолжай» is typed into its tab.
        now = now.addingTimeInterval(86401); level = 2; reset = 7 * 86400
        await controls.tick()
        XCTAssertEqual(typed.calls.first?.0, SessionControl.defaultMessage)
        XCTAssertEqual(typed.calls.first?.1, "/dev/ttys004")
        XCTAssertEqual(controls.controls.first?.state, .watching, "the limit stays for the new week")
        XCTAssertNil(controls.controls.first?.message)
        XCTAssertTrue(SessionLimitFile.load(from: limits).entries.isEmpty)
    }

    func testOutsideTerminalTheUserIsToldAndABusySessionIsNotInterrupted() async throws {
        let limits = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: limits) }
        let typed = Typed()
        var busy = row(); busy.phase = .running; busy.turnStartedAt = now
        let controls = service(typed, rows: [busy], limits: limits)
        controls.continueLater(busy, when: .at, at: now.addingTimeInterval(-1), message: "дальше")
        await controls.tick()
        XCTAssertTrue(typed.calls.isEmpty, "a working agent is not typed into")

        let vscode = row(client: .vscode)
        let other = service(typed, rows: [vscode], limits: limits)
        other.continueLater(vscode, when: .at, at: now.addingTimeInterval(-1), message: "дальше")
        await other.tick()
        XCTAssertTrue(typed.calls.isEmpty)
        XCTAssertEqual(other.controls.first?.state, .needsYou)
        XCTAssertTrue(notices.contains(L("Лимит сброшен: сессию можно продолжить")))
    }
}
