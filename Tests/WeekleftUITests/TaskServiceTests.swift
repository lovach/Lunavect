import XCTest
import WeekleftCore
@testable import Weekleft

/// A task's life with a fake agent and a fake git: budget, wrap-up, pause with saved work, resume after the reset.
@MainActor final class TaskServiceTests: XCTestCase {
    final class FakeDriver: TaskDriver {
        var onEvent: ((TaskDriverEvent) -> Void)?
        var started: [(message: String, resume: Bool)] = []
        var steered: [String] = []
        var interrupts = 0, closes = 0
        func start(_ task: AgentTask, message: String, resume: Bool) throws { started.append((message, resume)); onEvent?(.session(task.sessionID ?? "thread-1")) }
        func steer(_ text: String) { steered.append(text) }
        func interrupt() { interrupts += 1 }
        func close() { closes += 1 }
    }
    final class GitLog: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [[String]] = []
        var commands: [[String]] { lock.lock(); defer { lock.unlock() }; return value }
        func add(_ command: [String]) { lock.lock(); value.append(command); lock.unlock() }
    }

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var drivers: [FakeDriver] = []
    private var notices: [String] = []
    private let git = GitLog()

    private func service(week: Double = 50, weekReset: TimeInterval = 86400, five: Double = 10) throws -> TaskService {
        let reset = now.addingTimeInterval(weekReset), fiveReset = now.addingTimeInterval(3600)
        let snapshots = [UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: week, durationMinutes: 10080, resetsAt: reset),
                                       fiveHour: try QuotaWindow(usedPercent: five, durationMinutes: 300, resetsAt: fiveReset), fetchedAt: now)]
        var ledger = TokenLedger()
        // 50 % of the week over 100,000 weighted tokens: 0.0005 % per unit.
        ledger.record(TokenCounts(output: 20_000), provider: .claude, session: "other", cwd: "/p", model: "m", subagent: false,
                      at: now.addingTimeInterval(-3600), now: now, calendar: Calendar(identifier: .gregorian))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = self.git
        return TaskService(url: nil, dependencies: .init(
            ledger: { ledger }, snapshots: { snapshots },
            resolver: { ClientExecutableResolver(discoverClaude: { "/bin/echo" }, isExecutable: { _ in true }) },
            makeDriver: { [unowned self] _, _ in let driver = FakeDriver(); self.drivers.append(driver); return driver },
            git: { arguments in
                git.add(arguments)
                if arguments.contains("--show-toplevel") { return (0, "/repo\n") }
                if arguments.contains("--porcelain") { return (0, " M file.swift\n") }
                if arguments.contains("user.email") { return (0, "me@example.com\n") }
                if arguments.last == "HEAD" && arguments.contains("rev-parse") { return (0, "abc123\n") }
                return (0, "")
            },
            notify: { [unowned self] title, _ in self.notices.append(title) },
            clock: { [unowned self] in self.now }, worktrees: root))
    }

    func testBudgetWrapsUpPausesWithSavedWorkAndResumesAfterTheReset() async throws {
        let tasks = try service()
        let folder = FileManager.default.temporaryDirectory.path
        tasks.add(AgentTask(provider: .claude, prompt: "Refactor the parser", folder: folder, weekBudget: 10, now: now))
        for _ in 0..<50 where drivers.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let driver = try XCTUnwrap(drivers.first)
        await tasks.tick()
        XCTAssertEqual(drivers.count, 1, "a second tick while the copy is prepared must not start the task twice")
        var task = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(driver.started.first?.message, "Refactor the parser")
        XCTAssertEqual(task.branch?.hasPrefix("lunavect/refactor-the-parser-"), true)
        XCTAssertTrue(git.commands.contains { $0.contains("worktree") && $0.contains("add") }, "the task works in its own copy")

        // 16,000 weighted units = 8 % of the week: past 80 % of a 10 % budget.
        driver.onEvent?(.usage(TokenCounts(output: 3_200)))
        task = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(task.state, .wrappingUp)
        XCTAssertEqual(driver.steered.count, 1)
        driver.onEvent?(.usage(TokenCounts(output: 1_000)))
        XCTAssertEqual(driver.interrupts, 1, "stopped at the budget")
        driver.onEvent?(.turnEnded(.interrupted))
        for _ in 0..<50 where tasks.tasks.first?.checkpoints.isEmpty != false { try await Task.sleep(for: .milliseconds(20)) }
        task = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(task.state, .paused); XCTAssertEqual(task.pause, .budget)
        XCTAssertEqual(task.checkpoints.first?.commit, "abc123", "the work is committed on the task branch")
        XCTAssertEqual(task.resumeAt, now.addingTimeInterval(86400))
        XCTAssertTrue(notices.contains(L("Задача на паузе, работа сохранена")))

        // The week resets: the budget comes back and the same conversation continues.
        now = now.addingTimeInterval(86401)
        await tasks.tick()
        task = try XCTUnwrap(tasks.tasks.first)
        XCTAssertEqual(task.state, .running)
        XCTAssertEqual(task.spent, 0)
        XCTAssertEqual(drivers.last?.started.first?.resume, true)
        XCTAssertEqual(drivers.last?.started.first?.message, TaskMessages.resume)
    }

    func testCompletedTaskIsDoneAndAUserPauseWaitsForTheUser() async throws {
        let tasks = try service()
        tasks.add(AgentTask(provider: .claude, prompt: "Write docs", folder: FileManager.default.temporaryDirectory.path, isolate: false, now: now))
        for _ in 0..<50 where drivers.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let id = try XCTUnwrap(tasks.tasks.first?.id)
        tasks.pause(id)
        XCTAssertEqual(drivers.first?.interrupts, 1)
        drivers.first?.onEvent?(.turnEnded(.interrupted))
        for _ in 0..<50 where tasks.tasks.first?.state.isActive == true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tasks.tasks.first?.pause, .user)
        now = now.addingTimeInterval(7 * 86400)
        await tasks.tick()
        XCTAssertEqual(tasks.tasks.first?.state, .paused, "a user pause is never resumed by itself")
        tasks.resume(id)
        for _ in 0..<50 where drivers.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        drivers.last?.onEvent?(.turnEnded(.completed))
        for _ in 0..<50 where tasks.tasks.first?.state != .done { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tasks.tasks.first?.state, .done)
        XCTAssertTrue(notices.contains(L("Задача готова")))
    }

    func testNoWeeklyLimitMeansNoBudgetAndNoStart() async throws {
        let tasks = TaskService(url: nil, dependencies: .init(ledger: { TokenLedger() }, snapshots: { [] },
                                                             resolver: { ClientExecutableResolver(discoverClaude: { "/bin/echo" }) },
                                                             makeDriver: { _, _ in FakeDriver() }, git: { _ in (0, "") }, notify: { _, _ in },
                                                             clock: { [unowned self] in self.now }))
        tasks.add(AgentTask(provider: .claude, prompt: "p", folder: FileManager.default.temporaryDirectory.path, isolate: false, now: now))
        await tasks.tick()
        XCTAssertEqual(tasks.tasks.first?.state, .needsYou)
    }

    func testLeftoverAtTheEndOfTheWeekIsSuggestedOnce() async throws {
        let tasks = try service(week: 60, weekReset: 3 * 3600)
        tasks.add(AgentTask(provider: .claude, prompt: "Later", folder: FileManager.default.temporaryDirectory.path, start: .afterWeeklyReset, isolate: false, now: now))
        await tasks.tick(); await tasks.tick()
        XCTAssertEqual(notices.filter { $0 == L("Можно добрать остаток недели") }.count, 1)
        XCTAssertEqual(tasks.tasks.first?.state, .queued, "only suggested; the user starts it")
    }
}
