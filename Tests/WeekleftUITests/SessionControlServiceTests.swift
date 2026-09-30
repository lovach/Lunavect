import XCTest
import WeekleftCore
@testable import Weekleft

@MainActor final class SessionControlServiceTests: XCTestCase {
    final class Typed: @unchecked Sendable {
        var calls: [(text: String, tty: String, app: String, command: String?)] = []
        var opened: [(command: String, app: String)] = []
        var result = true
    }
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var notices: [SessionControlService.Notice] = []
    private var level = 75.0
    private var fiveHour = 20.0
    private var reset: TimeInterval = 86400
    private var fiveReset: TimeInterval = 3600
    private var ledger = TokenLedger()
    private var cutOff = SessionCutOffAction.ask
    private var claudeContinues = true
    private var titles: [String] { notices.map(\.title) }

    private func service(_ typed: Typed, rows: @escaping () -> [AgentSession], limits: URL) -> SessionControlService {
        SessionControlService(url: nil, limitURL: limits, dependencies: .init(
            ledger: { [unowned self] in self.ledger },
            snapshots: { [unowned self] in [UsageSnapshot(provider: .claude,
                weekly: try! QuotaWindow(usedPercent: self.level, durationMinutes: 10080, resetsAt: self.now.addingTimeInterval(self.reset)),
                fiveHour: try! QuotaWindow(usedPercent: self.fiveHour, durationMinutes: 300, resetsAt: self.now.addingTimeInterval(self.fiveReset)), fetchedAt: self.now),
                UsageSnapshot(provider: .codex, fiveHour: try! QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: self.now.addingTimeInterval(self.fiveReset)),
                              fetchedAt: self.now)] },
            sessions: rows,
            type: { text, tty, app, command, _, _ in typed.calls.append((text, tty, app, command)); return typed.result },
            open: { command, app in typed.opened.append((command, app)); return true },
            notify: { [unowned self] notice in self.notices.append(notice) },
            cutOff: { [unowned self] in self.cutOff },
            transcript: { _, _, id in URL(fileURLWithPath: "/tmp/fixture/" + id + ".jsonl") },
            reply: { _, _ in "Сделано: экспорт. Осталось: тесты." },
            claudeAutoContinue: { [unowned self] in self.claudeContinues },
            clock: { [unowned self] in self.now }))
    }
    private func service(_ typed: Typed, rows: [AgentSession], limits: URL) -> SessionControlService { service(typed, rows: { rows }, limits: limits) }
    private func row(_ provider: ProviderID = .claude, client: SessionClient = .terminal, id: String = "S1") -> AgentSession {
        var row = AgentSession(provider: provider, sessionID: id, title: "Refactor", cwd: "/p/Lunavect", phase: .idle, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        row.client = client; row.terminalTTY = "/dev/ttys004"; row.terminalApp = "Terminal"
        return row
    }
    private func limits() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStopsAtTheLevelThenContinuesInTheSameTabAfterTheReset() async throws {
        let limits = limits(), typed = Typed(), session = row()
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
        XCTAssertEqual(notices.last?.category, SessionControlService.Category.stopped, "the notice carries Continue now and +5 %")
        XCTAssertTrue(typed.calls.isEmpty)
        for _ in 0..<20 where controls.controls.first?.summary == nil { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controls.controls.first?.summary, "Сделано: экспорт. Осталось: тесты.", "the agent's own summary is kept for the card")

        // The week resets: the level falls, the hooks let it go, and «продолжай» is typed into its tab.
        now = now.addingTimeInterval(86461); level = 2; reset = 7 * 86400
        await controls.tick()
        XCTAssertEqual(typed.calls.first?.text, SessionControl.defaultMessage)
        XCTAssertEqual(typed.calls.first?.tty, "/dev/ttys004")
        XCTAssertNil(typed.calls.first?.command, "S1 is not a real session id: no resume command is built from it")
        XCTAssertEqual(controls.controls.first?.state, .watching, "the limit stays for the new week")
        XCTAssertNil(controls.controls.first?.resumeAt)
        XCTAssertTrue(SessionLimitFile.load(from: limits).entries.isEmpty)
    }

    func testRestsBeforeTheFiveHourCutOffAndContinuesAfterItsReset() async throws {
        let limits = limits(), typed = Typed(), session = row(id: "0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21")
        let controls = service(typed, rows: [session], limits: limits)
        controls.setLimit(for: session, stopAtWeek: 95, fiveHourGuard: true, continueAfterReset: false, message: "дальше")
        fiveHour = 90; await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .wrappingUp)
        XCTAssertEqual(controls.controls.first?.reason, .fiveHour)
        fiveHour = 97; await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .resting)
        XCTAssertEqual(SessionLimitFile.load(from: limits).entries.first?.value.state, .stopped, "a rest refuses actions like a stop")
        XCTAssertEqual(titles.last, L("Сессия ждёт сброса окна 5 часов"))
        XCTAssertTrue(typed.calls.isEmpty)

        now = now.addingTimeInterval(3661); fiveHour = 3; fiveReset = 5 * 3600
        await controls.tick()
        XCTAssertEqual(typed.calls.map(\.text), ["дальше"])
        XCTAssertEqual(typed.calls.first?.command, "claude --resume 0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21 'дальше'", "at a shell prompt the tab resumes the session")
        XCTAssertEqual(controls.controls.first?.state, .watching, "the next window is guarded too")
        XCTAssertEqual(controls.controls.first?.message, "дальше", "the text stays for the next rest")
    }

    func testClaudeCutOffWhileRestingIsLeftToClaudeCode() async throws {
        let limits = limits(), typed = Typed()
        var session = row(id: "0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21")
        var rows = [session]
        let controls = service(typed, rows: { rows }, limits: limits)
        controls.setLimit(for: session, stopAtWeek: 95, fiveHourGuard: true, continueAfterReset: false, message: nil)
        fiveHour = 97; await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .resting)
        // The real limit came first: Claude Code waits for the reset and continues on its own.
        session.phase = .failed; session.failure = .limit; rows = [session]
        await controls.tick()
        XCTAssertNil(controls.controls.first?.resumeAt)
        now = now.addingTimeInterval(3661); fiveHour = 0; fiveReset = 5 * 3600
        session.phase = .idle; rows = [session]
        await controls.tick()
        XCTAssertTrue(typed.calls.isEmpty, "no second «continue» after Claude Code's own")
        XCTAssertEqual(controls.controls.first?.state, .watching)
    }

    func testAClosedTabIsResumedInANewWindowFromTheSessionFolder() async throws {
        let limits = limits(), typed = Typed(); typed.result = false
        let session = row(id: "0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21")
        let controls = service(typed, rows: [session], limits: limits)
        controls.continueLater(session, when: .at, at: now.addingTimeInterval(-1), message: "it's fine")
        await controls.tick()
        XCTAssertEqual(typed.opened.first?.command, "cd '/p/Lunavect' && claude --resume 0f3c2a51-5e2b-4d7e-9a57-7d7b0c1f9e21 'it'\\''s fine'")
        XCTAssertEqual(controls.controls.first?.state, .continued)
        XCTAssertTrue(notices.last?.body.contains(L("Вкладку закрыли: Lunavect открыл новую в Терминале.")) == true)
    }

    func testOutsideTerminalTheUserIsToldAndABusySessionIsNotInterrupted() async throws {
        let limits = limits(), typed = Typed()
        var busy = row(); busy.phase = .running; busy.turnStartedAt = now
        let controls = service(typed, rows: [busy], limits: limits)
        controls.continueLater(busy, when: .at, at: now.addingTimeInterval(-1), message: "дальше")
        await controls.tick()
        XCTAssertTrue(typed.calls.isEmpty, "a working agent is not typed into")

        var asking = row(); asking.phase = .permission
        let dialog = service(typed, rows: [asking], limits: limits)
        dialog.continueLater(asking, when: .at, at: now.addingTimeInterval(-1), message: "1")
        await dialog.tick()
        XCTAssertTrue(typed.calls.isEmpty, "text never lands in a permission dialog")

        let vscode = row(client: .vscode)
        let other = service(typed, rows: [vscode], limits: limits)
        other.continueLater(vscode, when: .at, at: now.addingTimeInterval(-1), message: "дальше")
        await other.tick()
        XCTAssertTrue(typed.calls.isEmpty)
        XCTAssertTrue(typed.opened.isEmpty)
        XCTAssertEqual(other.controls.first?.state, .needsYou)
        XCTAssertTrue(titles.contains(L("Лимит сброшен: сессию можно продолжить")))
    }

    func testACodexCutOffIsOfferedOnceAndContinuedAfterTheResetWhenAccepted() async throws {
        let limits = limits(), typed = Typed(), id = "019a0c0a-96ca-7cf2-9f85-caba5f66eed7", session = row(.codex, id: id)
        ledger.limitHits = ["codex:" + id: now.addingTimeInterval(-30)]
        let controls = service(typed, rows: [session], limits: limits)
        await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .offered)
        XCTAssertEqual(notices.last?.category, SessionControlService.Category.offer)
        XCTAssertEqual(controls.controls.first?.resumeAt, now.addingTimeInterval(3660), "a minute after the used-up window resets")
        await controls.tick()
        XCTAssertEqual(notices.count, 1, "asked once")

        controls.handle(action: SessionControlService.Action.accept, controlID: "codex:" + id)
        await controls.tick()
        XCTAssertTrue(typed.calls.isEmpty, "not before the reset")
        now = now.addingTimeInterval(3700)
        await controls.tick()
        XCTAssertEqual(typed.calls.first?.text, SessionControl.defaultMessage)
        XCTAssertEqual(typed.calls.first?.command, "codex resume " + id + " '" + SessionControl.defaultMessage + "'")
    }

    func testADeclinedCutOffIsNotOfferedAgainAndOffAsksNothing() async throws {
        let limits = limits(), typed = Typed(), id = "019a0c0a-96ca-7cf2-9f85-caba5f66eed7", session = row(.codex, id: id)
        ledger.limitHits = ["codex:" + id: now.addingTimeInterval(-30)]
        let controls = service(typed, rows: [session], limits: limits)
        await controls.tick()
        controls.handle(action: SessionControlService.Action.decline, controlID: "codex:" + id)
        XCTAssertTrue(controls.controls.isEmpty)
        await controls.tick()
        XCTAssertTrue(controls.controls.isEmpty, "the same cut-off is not offered again")

        cutOff = .off; notices = []
        let quiet = service(typed, rows: [session], limits: limits)
        await quiet.tick()
        XCTAssertTrue(quiet.controls.isEmpty); XCTAssertTrue(notices.isEmpty)
    }

    func testClaudeContinuesByItselfSoOnlyTheEndsOfItsWaitAreAnswered() async throws {
        let limits = limits(), typed = Typed()
        var failed = row(); failed.phase = .failed; failed.failure = .limit
        var rows = [failed]
        let controls = service(typed, rows: { rows }, limits: limits)
        await controls.tick()
        XCTAssertTrue(controls.controls.isEmpty, "Claude Code waits for the reset and continues by itself")
        XCTAssertEqual(controls.limitCutOff(failed).handled, false)
        XCTAssertEqual(controls.limitCutOff(failed).note, L("Claude Code продолжит сам после сброса"))

        // The Mac slept through the reset: Claude Code waits for Enter, and Lunavect presses only Enter.
        var stale = failed; stale.limitWait = "stale"; stale.limitWaitAt = now
        rows = [stale]; cutOff = .auto
        await controls.tick()
        XCTAssertEqual(typed.calls.map(\.text), [""])
        XCTAssertNil(typed.calls.first?.command, "never a resume command into the shell for Enter")
        XCTAssertEqual(titles.first, L("Лимит сбросился, пока Mac спал"))

        // With Claude's own continue off, a limit failure is Lunavect's to offer.
        claudeContinues = false; cutOff = .ask
        var other = row(id: "S2"); other.phase = .failed; other.failure = .limit
        let offering = service(typed, rows: [other], limits: limits)
        await offering.tick()
        XCTAssertEqual(offering.controls.first?.state, .offered)
        XCTAssertEqual(offering.limitCutOff(failed).handled, true)
    }

    func testRaiseLiftsTheStopByFivePointsAndContinues() async throws {
        let limits = limits(), typed = Typed(), session = row()
        let controls = service(typed, rows: [session], limits: limits)
        controls.setLimit(for: session, stopAtWeek: 80, continueAfterReset: false, message: nil)
        level = 81; await controls.tick()
        XCTAssertEqual(controls.controls.first?.state, .stopped)
        controls.raise("claude:S1")
        XCTAssertEqual(controls.controls.first?.stopAtWeek, 86, "five points over the level now")
        await controls.tick()
        XCTAssertEqual(typed.calls.count, 1)
        XCTAssertEqual(controls.controls.first?.state, .watching)
    }
}
