import XCTest
@testable import WeekleftCore

/// Owner decisions 29.09: a task runs within a share of the week, wraps up at 80 %, pauses at the
/// budget or the five-hour guard, keeps its work on its own branch and continues after the reset.
final class AgentTaskTests: XCTestCase {
    func testBudgetWrapsUpThenStopsAndTheFiveHourGuardPausesFirst() {
        XCTAssertEqual(TaskBudget.decide(spent: 5, budget: 10, fiveHourUsed: 40, fiveHourGuard: 90, limitReached: false, wrappingUp: false), .proceed)
        XCTAssertEqual(TaskBudget.decide(spent: 8, budget: 10, fiveHourUsed: 40, fiveHourGuard: 90, limitReached: false, wrappingUp: false), .wrapUp)
        XCTAssertEqual(TaskBudget.decide(spent: 8.5, budget: 10, fiveHourUsed: 40, fiveHourGuard: 90, limitReached: false, wrappingUp: true), .proceed,
                       "asked once; the agent finishes its step")
        XCTAssertEqual(TaskBudget.decide(spent: 10, budget: 10, fiveHourUsed: 40, fiveHourGuard: 90, limitReached: false, wrappingUp: true), .stop(.budget))
        XCTAssertEqual(TaskBudget.decide(spent: 1, budget: 10, fiveHourUsed: 91, fiveHourGuard: 90, limitReached: false, wrappingUp: false), .wrapUp)
        XCTAssertEqual(TaskBudget.decide(spent: 1, budget: 10, fiveHourUsed: 95, fiveHourGuard: 90, limitReached: false, wrappingUp: true), .stop(.fiveHour))
        XCTAssertEqual(TaskBudget.decide(spent: 1, budget: 10, fiveHourUsed: 95, fiveHourGuard: nil, limitReached: false, wrappingUp: false), .proceed)
        XCTAssertEqual(TaskBudget.decide(spent: 0, budget: 10, fiveHourUsed: nil, fiveHourGuard: 90, limitReached: true, wrappingUp: false), .stop(.limitReached))
    }

    func testCalibrationAndResumeDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = TokenLedger()
        ledger.record(TokenCounts(output: 1000), provider: .claude, session: "a", cwd: "/p/A", model: "m", subagent: false,
                      at: now.addingTimeInterval(-3600), now: now, calendar: Calendar(identifier: .gregorian))
        let week = try QuotaWindow(usedPercent: 50, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let five = try QuotaWindow(usedPercent: 100, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))
        // 1000 output tokens weigh 5000; 50 % of the week over 5000 is 0.01 % per unit.
        XCTAssertEqual(try XCTUnwrap(TaskBudget.percentPerWeight(ledger: ledger, provider: .claude, week: week, now: now)), 0.01, accuracy: 1e-9)
        XCTAssertNil(TaskBudget.percentPerWeight(ledger: ledger, provider: .codex, week: week, now: now))
        XCTAssertEqual(TaskBudget.resumeDate(for: .budget, week: week, fiveHour: five), week.resetsAt)
        XCTAssertEqual(TaskBudget.resumeDate(for: .fiveHour, week: week, fiveHour: five), five.resetsAt)
        XCTAssertEqual(TaskBudget.resumeDate(for: .limitReached, week: week, fiveHour: five), five.resetsAt, "the used-up window decides")
        XCTAssertNil(TaskBudget.resumeDate(for: .user, week: week, fiveHour: five))
    }

    func testCommandsFollowThePermissionTheUserChose() {
        var task = AgentTask(provider: .claude, prompt: "Fix the build\nand the tests", folder: "/Users/u/Lunavect")
        XCTAssertEqual(task.title, "Fix the build")
        let fresh = TaskCommands.claudeArguments(task, sessionID: "S", resume: false)
        XCTAssertTrue(fresh.contains("--session-id") && fresh.contains("acceptEdits") && fresh.contains("none"))
        task.permission = .full
        let resumed = TaskCommands.claudeArguments(task, sessionID: "S", resume: true)
        XCTAssertTrue(resumed.contains("--resume") && resumed.contains("bypassPermissions") && !resumed.contains("--session-id"))
        task.provider = .codex; task.permission = .careful; task.worktree = "/copy/Lunavect"
        let careful = TaskCommands.codexThreadParameters(task, resume: nil)
        XCTAssertEqual(careful["sandbox"] as? String, "workspace-write"); XCTAssertEqual(careful["cwd"] as? String, "/copy/Lunavect")
        XCTAssertEqual(careful["approvalPolicy"] as? String, "never")
        task.permission = .full
        XCTAssertEqual(TaskCommands.codexThreadParameters(task, resume: "T")["sandbox"] as? String, "danger-full-access")
        XCTAssertEqual(TaskCommands.codexThreadParameters(task, resume: "T")["threadId"] as? String, "T")
    }

    func testGitStepsStayOnTheTaskBranchAndKeepTheUsersIdentity() {
        let task = AgentTask(id: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!, provider: .codex,
                             prompt: "Добавить экспорт CSV!", folder: "/Users/u/capsule")
        XCTAssertEqual(TaskGit.branch(for: task), "lunavect/добавить-экспорт-csv-abcdef")
        XCTAssertTrue(TaskGit.worktreePath(for: task, repository: "/Users/u/capsule", root: URL(fileURLWithPath: "/W")).hasSuffix("/abcdef12/capsule"))
        let own = TaskGit.checkpoint(worktree: "/W/abcdef12/capsule", message: "m", hasIdentity: true)
        XCTAssertFalse(own[1].contains("user.name=Lunavect"))
        XCTAssertTrue(TaskGit.checkpoint(worktree: "/W", message: "m", hasIdentity: false)[1].contains("user.name=Lunavect"))
        XCTAssertEqual(TaskGit.addWorktree(repository: "/r", path: "/p", branch: "b"), ["-C", "/r", "worktree", "add", "-b", "b", "/p", "HEAD"])
    }

    func testTaskListRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var list = AgentTaskList()
        var task = AgentTask(provider: .claude, prompt: "p", folder: "/f", now: Date(timeIntervalSince1970: 1_800_000_000))
        task.checkpoints = [TaskCheckpoint(commit: "abc", date: Date(timeIntervalSince1970: 1_800_000_100), reason: "budget")]
        list.tasks = [task]
        try list.save(to: url)
        XCTAssertEqual(try AgentTaskList.load(from: url), list)
    }
}
