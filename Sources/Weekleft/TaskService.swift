import AppKit
import Foundation
import os
import UserNotifications
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// Runs the user's tasks within their share of the weekly limit (owner decisions 29.09):
/// wrap up at 80 %, pause at the budget or the five-hour guard, save the work on the
/// task's own branch, and continue after the limit resets.
@MainActor final class TaskService: ObservableObject {
    @Published private(set) var tasks: [AgentTask] = []
    @Published var issue: String?

    struct Dependencies {
        var ledger: @MainActor () -> TokenLedger
        var snapshots: @MainActor () -> [UsageSnapshot]
        var resolver: @MainActor () -> ClientExecutableResolver
        var makeDriver: @MainActor (ProviderID, String) -> TaskDriver = { provider, executable in
            provider == .claude ? ClaudeTaskDriver(executable: executable) : CodexTaskDriver(executable: executable)
        }
        var git: @Sendable ([String]) async -> (status: Int32, output: String) = TaskService.runGit
        var notify: @MainActor (String, String) -> Void = TaskService.postNotice
        var clock: () -> Date = Date.init
        /// Where the copies of projects live; tests pass a temporary folder.
        var worktrees: URL = AgentTaskList.worktreesURL
    }
    private let dependencies: Dependencies
    private let url: URL?
    private var drivers: [UUID: TaskDriver] = [:]
    /// Percent of the week per weighted token, per provider, refreshed each tick.
    private var ratios: [ProviderID: Double] = [:]
    /// Codex reports the five-hour window with every turn; newer than the saved snapshot.
    private var liveFiveHour: [ProviderID: Double] = [:]
    /// Why a running task is being stopped, applied when its turn ends.
    private var stopping: [UUID: TaskPause?] = [:]
    private var loop: Task<Void, Never>?
    /// Tasks being prepared (copy, executable) right now: a second tick must not start them twice.
    private var launching: Set<UUID> = []
    private let logger = Logger(subsystem: "com.weekleft.app", category: "tasks")

    init(url: URL? = TaskService.defaultURL, dependencies: Dependencies) {
        self.url = url; self.dependencies = dependencies
        tasks = url.flatMap { try? AgentTaskList.load(from: $0).tasks } ?? []
        // Lunavect quit while a task ran: its agent stopped with the app. It continues like a user pause.
        for index in tasks.indices where tasks[index].state.isActive {
            tasks[index].state = .paused; tasks[index].pause = .user
            tasks[index].message = L("Lunavect был закрыт, пока задача работала. Работа сохранена; продолжите её кнопкой.")
        }
    }
    nonisolated static var defaultURL: URL? { LiveWriteGuard.underTestsForStores ? nil : AgentTaskList.fileURL }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    /// At quit: every running agent is stopped softly, its work saved.
    func stop() {
        loop?.cancel(); loop = nil
        for (id, driver) in drivers { stopping[id] = .user; driver.interrupt(); driver.close() }
        save()
    }

    /// Session keys of tasks, so the session list shows them as tasks rather than background runs.
    var sessionTitles: [String: String] {
        Dictionary(tasks.compactMap { task in task.sessionID.map { (TokenLedger.sessionKey(task.provider, $0), task.title) } },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: User actions

    func add(_ task: AgentTask) {
        var task = task
        let snapshot = dependencies.snapshots().first { $0.provider == task.provider }
        switch task.start {
        case .now: task.resumeAt = nil
        case .afterFiveHourReset: task.resumeAt = snapshot?.fiveHour?.resetsAt
        case .afterWeeklyReset: task.resumeAt = snapshot?.weekly?.resetsAt
        }
        tasks.insert(task, at: 0); save()
        Task { await tick() }
    }
    func pause(_ id: UUID) {
        guard let task = task(id) else { return }
        if task.state.isActive { stopping[id] = .user; drivers[id]?.interrupt() }
        else if task.state == .queued { update(id) { $0.state = .paused; $0.pause = .user } }
    }
    func resume(_ id: UUID) {
        guard let task = task(id), task.state == .paused || task.state == .needsYou || task.state == .failed || task.state == .queued else { return }
        Task { await launch(task.id, resume: task.sessionID != nil) }
    }
    /// More of the week for a task that used its budget, then it continues.
    func extendBudget(_ id: UUID, by percent: Double = 5) {
        update(id) { $0.weekBudget = max($0.weekBudget, $0.spent) + percent }
        resume(id)
    }
    func cancel(_ id: UUID) {
        guard let task = task(id) else { return }
        if task.state.isActive { stopping[id] = .some(nil); drivers[id]?.interrupt() }
        else { update(id) { $0.state = .cancelled; $0.resumeAt = nil } }
    }
    func remove(_ id: UUID) {
        guard let task = task(id), !task.state.isActive else { return }
        tasks.removeAll { $0.id == id }; save()
    }

    /// Merges the task's branch into the folder's current branch. The folder must have no unsaved changes.
    func accept(_ id: UUID) async {
        guard let task = task(id), !task.state.isActive, let repository = task.repository, let branch = task.branch else { return }
        await checkpoint(id, reason: "accept")
        let status = await dependencies.git(["-C", repository, "status", "--porcelain"])
        guard status.status == 0, status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update(id) { $0.message = L("В папке проекта есть несохранённые изменения. Сохраните их, затем примите результат.") }; return
        }
        let identity = await hasIdentity(repository)
        let merge = await dependencies.git(TaskGit.merge(repository: repository, branch: branch, title: task.title, hasIdentity: identity))
        guard merge.status == 0 else {
            _ = await dependencies.git(["-C", repository, "merge", "--abort"])
            update(id) { $0.message = L("Изменения задачи не удалось соединить с проектом автоматически. Ветка {0} сохранена.", branch) }; return
        }
        if let root = worktreeRoot(task) { for step in TaskGit.removeWorktree(repository: repository, path: root) { _ = await dependencies.git(step) } }
        update(id) { $0.message = L("Результат принят в проект."); $0.worktree = nil; if !$0.state.isFinished { $0.state = .done } }
    }

    /// Opens the task's conversation in Terminal to continue by hand; the agent is paused first.
    func openInTerminal(_ id: UUID) {
        guard let task = task(id), let sessionID = task.sessionID else { return }
        if task.state.isActive { pause(id) }
        do {
            let executable = try dependencies.resolver().resolve(task.provider)
            let command = task.provider == .claude ? [executable, "--resume", sessionID] : [executable, "resume", sessionID]
            let script = "#!/bin/zsh\ncd " + Self.quote(task.workingDirectory) + " && exec " + command.map(Self.quote).joined(separator: " ") + "\n"
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            let directory = SessionHooks.directory.appendingPathComponent("Openers")
            try LiveWriteGuard.check(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("task-" + task.id.uuidString.prefix(8) + ".command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch { issue = L("Не удалось открыть задачу в Терминале.") }
    }
    func revealCopy(_ id: UUID) {
        guard let task = task(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.workingDirectory)])
    }

    // MARK: Scheduling

    /// Weeks already suggested for using what is left before the reset, by provider.
    private var suggestedLeftover: [ProviderID: Date] = [:]
    /// Near the end of a week with much left, tasks waiting for the reset could run now: one notice per week.
    private func suggestLeftover(snapshots: [UsageSnapshot], now: Date) {
        for provider in ProviderID.allCases {
            guard let week = snapshots.first(where: { $0.provider == provider })?.weekly, let resets = week.resetsAt,
                  resets > now, resets.timeIntervalSince(now) <= 6 * 3600, week.remaining >= 20, suggestedLeftover[provider] != resets,
                  tasks.contains(where: { $0.provider == provider && $0.state == .queued && $0.start == .afterWeeklyReset }) else { continue }
            suggestedLeftover[provider] = resets
            let hours = max(1, Int((resets.timeIntervalSince(now) / 3600).rounded()))
            dependencies.notify(L("Можно добрать остаток недели"),
                                L("До сброса {0}: {1} ч, свободно {2}. Задачи, ждущие сброса, можно запустить сейчас во вкладке «Задачи».",
                                  provider.title, String(hours), PercentText.format(Int(week.remaining.rounded()))))
        }
    }

    func tick() async {
        let now = dependencies.clock(), ledger = dependencies.ledger(), snapshots = dependencies.snapshots()
        suggestLeftover(snapshots: snapshots, now: now)
        for provider in ProviderID.allCases {
            let week = snapshots.first { $0.provider == provider }?.weekly
            if let ratio = TaskBudget.percentPerWeight(ledger: ledger, provider: provider, week: week, now: now) { ratios[provider] = ratio }
        }
        for id in tasks.map(\.id) {
            guard var task = task(id) else { continue }
            let snapshot = snapshots.first { $0.provider == task.provider }
            // A new week gives the task its budget again.
            if let ends = task.spentWeekEnds, now >= ends {
                update(id) { $0.spent = 0; $0.spentWeekEnds = snapshot?.weekly?.resetsAt.flatMap { $0 > now ? $0 : nil } }
                task = self.task(id) ?? task
            }
            switch task.state {
            case .queued where (task.resumeAt ?? .distantPast) <= now:
                await launch(task.id, resume: false)
            case .paused where task.autoResume && task.pause != .user:
                guard let at = task.resumeAt, at <= now, !(snapshot?.weekly?.isUsedUp ?? false), !(snapshot?.fiveHour?.isUsedUp ?? false) else { continue }
                if task.pause == .budget, task.spent >= task.weekBudget { continue }
                await launch(task.id, resume: task.sessionID != nil)
            case .running, .wrappingUp:
                evaluate(task.id)
            default: break
            }
        }
    }

    private func launch(_ id: UUID, resume: Bool) async {
        guard var task = task(id), drivers[id] == nil, !launching.contains(id) else { return }
        launching.insert(id)
        defer { launching.remove(id) }
        let snapshot = dependencies.snapshots().first { $0.provider == task.provider }
        guard ratios[task.provider] != nil || snapshot?.weekly != nil else {
            update(id) { $0.state = .needsYou; $0.message = L("Lunavect ещё не знает недельный лимит {0}: без него бюджет не посчитать. Проверьте подключение в настройках.", task.provider.title) }
            return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: task.folder, isDirectory: &directory), directory.boolValue else {
            update(id) { $0.state = .failed; $0.message = L("Папка проекта недоступна.") }; return
        }
        if task.isolate, task.worktree == nil {
            await prepareCopy(&task)
            guard self.task(id) != nil else { return }
            update(id) { [task] in $0 = task }
            if task.state == .failed { return }
        }
        let executable: String
        do { executable = try dependencies.resolver().resolve(task.provider) }
        catch { update(id) { $0.state = .failed; $0.message = L("Не найден {0}. Установите его или укажите путь в настройках подключений.", task.provider.title) }; return }
        if task.provider == .claude, task.sessionID == nil { task.sessionID = UUID().uuidString.lowercased(); update(id) { [task] in $0.sessionID = task.sessionID } }
        let driver = dependencies.makeDriver(task.provider, executable)
        driver.onEvent = { [weak self] event in self?.handle(event, for: id) }
        do { try driver.start(task, message: resume ? TaskMessages.resume : task.prompt, resume: resume) }
        catch { update(id) { $0.state = .failed; $0.message = L("Не удалось запустить задачу.") }; return }
        drivers[id] = driver
        let now = dependencies.clock()
        update(id) {
            $0.state = .running; $0.pause = nil; $0.resumeAt = nil; $0.message = nil
            if $0.startedAt == nil { $0.startedAt = now }
            if $0.spentWeekEnds == nil { $0.spentWeekEnds = snapshot?.weekly?.resetsAt }
        }
        if resume { dependencies.notify(L("Задача продолжается"), task.title) }
    }

    /// A git repository gets a separate copy on the task's branch; any other folder is used as it is.
    private func prepareCopy(_ task: inout AgentTask) async {
        let top = await dependencies.git(["-C", task.folder, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else {
            task.isolate = false
            task.message = L("Папка не под git: задача меняет файлы прямо в ней, отдельной копии нет.")
            return
        }
        let repository = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = TaskGit.branch(for: task), root = TaskGit.worktreePath(for: task, repository: repository, root: dependencies.worktrees)
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent()
        do { try LiveWriteGuard.check(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { task.state = .failed; task.message = L("Не удалось создать отдельную копию проекта: {0}", error.localizedDescription); return }
        let head = await dependencies.git(["-C", repository, "rev-parse", "HEAD"])
        let added = await dependencies.git(TaskGit.addWorktree(repository: repository, path: root, branch: branch))
        guard added.status == 0 else {
            task.state = .failed; task.message = L("Не удалось создать отдельную копию проекта: {0}", added.output.split(separator: "\n").last.map(String.init) ?? "")
            return
        }
        // The same subfolder inside the copy, when the user chose one below the repository root.
        let relative = task.folder.hasPrefix(repository) ? String(task.folder.dropFirst(repository.count)) : ""
        task.repository = repository; task.branch = branch
        task.baseCommit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        task.worktree = root + relative
        let dirty = await dependencies.git(["-C", repository, "status", "--porcelain"])
        if !dirty.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.message = L("Задача начала с последнего коммита: несохранённые изменения в папке проекта в её копию не попали.")
        }
    }

    // MARK: Agent events

    private func handle(_ event: TaskDriverEvent, for id: UUID) {
        guard let task = task(id) else { return }
        switch event {
        case .session(let session): if task.sessionID != session { update(id) { $0.sessionID = session } }
        case .usage(let added):
            let ratio = ratios[task.provider] ?? 0
            update(id) {
                $0.tokens += added; let weight = added.weight($0.provider)
                $0.weight += weight; $0.spent += weight * ratio
            }
            evaluate(id)
        case .limits(let five, _):
            if let five { liveFiveHour[task.provider] = five }
            evaluate(id)
        case .text(let text): update(id, persist: false) { $0.handoff = String(text.prefix(4000)) }
        case .turnEnded(let end): Task { await finishTurn(id, end) }
        case .exited:
            drivers[id] = nil
            if let current = self.task(id), current.state.isActive {
                Task { await finishTurn(id, .failed(L("Процесс агента завершился раньше времени."))) }
            }
        }
    }

    private func evaluate(_ id: UUID) {
        guard let task = task(id), task.state.isActive, stopping[id] == nil else { return }
        let snapshot = dependencies.snapshots().first { $0.provider == task.provider }
        let five = liveFiveHour[task.provider] ?? snapshot?.fiveHour?.usedPercent
        switch TaskBudget.decide(spent: task.spent, budget: task.weekBudget, fiveHourUsed: five, fiveHourGuard: task.fiveHourGuard,
                                 limitReached: false, wrappingUp: task.state == .wrappingUp) {
        case .proceed: break
        case .wrapUp:
            let reason: TaskPause = (task.fiveHourGuard.map { (five ?? 0) >= $0 } ?? false) ? .fiveHour : .budget
            update(id) { $0.state = .wrappingUp; $0.pause = reason }
            drivers[id]?.steer(TaskMessages.wrapUp(reason))
        case .stop(let reason):
            stopping[id] = reason
            drivers[id]?.interrupt()
        }
    }

    private func finishTurn(_ id: UUID, _ end: TaskTurnEnd) async {
        guard let task = task(id) else { return }
        let requested = stopping.removeValue(forKey: id)
        let snapshot = dependencies.snapshots().first { $0.provider == task.provider }
        let state: TaskState, pause: TaskPause?, message: String?
        switch (end, requested) {
        case (_, .some(.none)): state = .cancelled; pause = nil; message = nil
        case (.limitReached, _): state = .paused; pause = .limitReached; message = L("Лимит {0} исчерпан. Задача продолжит после сброса.", task.provider.title)
        case (_, .some(.some(let reason))): state = .paused; pause = reason; message = nil
        case (.completed, nil) where task.state == .wrappingUp: state = .paused; pause = task.pause ?? .budget; message = nil
        case (.completed, nil): state = .done; pause = nil; message = nil
        case (.interrupted, nil): state = .paused; pause = .user; message = nil
        case (.failed(let text), nil): state = .failed; pause = nil; message = text
        }
        drivers[id]?.close(); drivers[id] = nil
        let resumeAt = pause.flatMap { TaskBudget.resumeDate(for: $0, week: snapshot?.weekly, fiveHour: snapshot?.fiveHour) }
        update(id) { $0.state = state; $0.pause = pause; $0.resumeAt = resumeAt; if let message { $0.message = message } }
        await checkpoint(id, reason: pause?.rawValue ?? state.rawValue)
        guard let final = self.task(id) else { return }
        switch state {
        case .done: dependencies.notify(L("Задача готова"), final.title)
        case .paused where pause != .user:
            let when = resumeAt.map { L("Продолжит {0}.", $0.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale))) } ?? ""
            dependencies.notify(L("Задача на паузе, работа сохранена"), final.title + (when.isEmpty ? "" : "\n" + when))
        case .failed: dependencies.notify(L("Задача остановилась с ошибкой"), final.title)
        default: break
        }
    }

    /// Saves what the agent changed as a commit on the task's branch; the user's own branch is never touched.
    private func checkpoint(_ id: UUID, reason: String) async {
        guard let task = task(id), let worktree = task.worktree else { return }
        let changes = await dependencies.git(["-C", worktree, "status", "--porcelain"])
        guard changes.status == 0, !changes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let identity = await hasIdentity(worktree)
        for step in TaskGit.checkpoint(worktree: worktree, message: "Lunavect: " + task.title + " (" + reason + ")", hasIdentity: identity) {
            let result = await dependencies.git(step)
            guard result.status == 0 else { logger.error("Task checkpoint failed: \(result.status)"); return }
        }
        let head = await dependencies.git(["-C", worktree, "rev-parse", "HEAD"])
        let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = dependencies.clock()
        update(id) { $0.checkpoints.append(TaskCheckpoint(commit: commit, date: now, reason: reason)) }
    }

    private func hasIdentity(_ directory: String) async -> Bool {
        let email = await dependencies.git(["-C", directory, "config", "user.email"])
        return email.status == 0 && !email.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func worktreeRoot(_ task: AgentTask) -> String? {
        guard let repository = task.repository else { return nil }
        return TaskGit.worktreePath(for: task, repository: repository, root: dependencies.worktrees)
    }

    // MARK: State

    func task(_ id: UUID) -> AgentTask? { tasks.first { $0.id == id } }
    private func update(_ id: UUID, persist: Bool = true, _ change: (inout AgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var value = tasks[index]
        change(&value)
        value.updatedAt = dependencies.clock()
        guard value != tasks[index] else { return }
        tasks[index] = value
        if persist { save() }
    }
    private func save() {
        guard let url else { return }
        var list = AgentTaskList(); list.tasks = tasks
        do { try list.save(to: url) } catch { logger.error("Tasks not saved: \((error as NSError).code)") }
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    nonisolated static let runGit: @Sendable ([String]) async -> (status: Int32, output: String) = { arguments in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                do { try process.run() } catch { continuation.resume(returning: (-1, "")); return }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    @MainActor static func postNotice(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lunavect-task-" + UUID().uuidString, content: content, trigger: nil))
    }
}
