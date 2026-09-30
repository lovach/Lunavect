import AppKit
import Foundation
import os
import UserNotifications
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SessionControlMode: String, Identifiable { case limit, later; var id: String { rawValue } }

/// What Lunavect does when the provider's limit cuts a session off mid-answer (setting, owner 30.09).
enum SessionCutOffAction: String, CaseIterable, Identifiable {
    case ask, auto, off
    static let key = "sessionCutOff"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: return L("Спрашивать")
        case .auto: return L("Продолжать без вопроса")
        case .off: return L("Ничего не делать")
        }
    }
}

/// Stops a session the user limited when the week reaches their level, rests it before the
/// 5-hour window runs out, offers to continue a session the provider's limit cut off, and
/// continues sessions later with a message (owner decisions 30.09). Enforcement goes through
/// the Claude and Codex hooks Lunavect installs; the continuation is typed into the session's
/// own Terminal or iTerm2 tab, resumed in a new window when the tab is gone, or offered with
/// a notification elsewhere.
@MainActor final class SessionControlService: ObservableObject {
    @Published private(set) var controls: [SessionControl] = []

    struct Notice: Equatable {
        var title: String
        var body: String
        var category: String?
        var controlID: String?
    }
    struct Dependencies {
        var ledger: @MainActor () -> TokenLedger
        var snapshots: @MainActor () -> [UsageSnapshot]
        var sessions: @MainActor () -> [AgentSession]
        /// Types into the session's tab (text, tty, app, resume command, agent pid, provider): the message while
        /// the agent runs there, the resume command at a shell prompt.
        var type: @Sendable (String, String, String, String?, Int32?, ProviderID) async throws -> Bool = { text, tty, app, command, pid, provider in
            try await TerminalLocation.type(text, tty: tty, app: app, command: command, agentPID: pid, provider: provider)
        }
        /// A new window running the resume command.
        var open: @Sendable (String, String) async throws -> Bool = { command, app in try await TerminalLocation.open(command, app: app) }
        var notify: @MainActor (Notice) -> Void = SessionControlService.postNotice
        var cutOff: @MainActor () -> SessionCutOffAction = { .ask }
        /// The session's own log, and the agent's last reply in it.
        var transcript: @MainActor (TokenLedger, ProviderID, String) -> URL? = { $0.transcript($1, sessionID: $2) }
        var reply: @Sendable (URL, ProviderID) -> String? = { SessionReply.last(in: $0, provider: $1) }
        /// Claude Code continues by itself after a usage limit unless its setting is off.
        var claudeAutoContinue: () -> Bool = { ClaudeAutoContinue.enabled() }
        var clock: () -> Date = Date.init
    }
    private let dependencies: Dependencies
    private let url: URL?
    private let limitURL: URL?
    private var loop: Task<Void, Never>?
    private var delivering: Set<String> = []
    private var reading: Set<String> = []
    private var declined: [String: Date] = [:]
    private var autoContinue: (value: Bool, at: Date)?
    private var writtenLimits: SessionLimitFile?
    private let logger = Logger(subsystem: "com.weekleft.app", category: "session-controls")

    init(url: URL? = SessionControlService.defaultURL, limitURL: URL? = SessionControlService.defaultLimitURL, dependencies: Dependencies) {
        self.url = url; self.limitURL = limitURL; self.dependencies = dependencies
        let list = url.flatMap { try? SessionControlList.load(from: $0) }
        controls = list?.controls ?? []
        declined = list?.declined ?? [:]
    }
    nonisolated static var defaultURL: URL? { LiveWriteGuard.underTestsForStores ? nil : SessionControlList.fileURL }
    nonisolated static var defaultLimitURL: URL? { LiveWriteGuard.underTestsForStores ? nil : SessionLimitFile.fileURL }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    var cutOffAction: SessionCutOffAction { dependencies.cutOff() }
    /// Claude Code's own setting, read at most once a minute.
    private var claudeContinues: Bool {
        let now = dependencies.clock()
        if let autoContinue, now.timeIntervalSince(autoContinue.at) < 60 { return autoContinue.value }
        let value = dependencies.claudeAutoContinue(); autoContinue = (value, now)
        return value
    }
    /// For the session notices: whether these controls answer a Claude cut-off themselves,
    /// or a line saying Claude Code will continue by itself.
    func limitCutOff(_ session: AgentSession) -> (handled: Bool, note: String?) {
        guard session.provider == .claude else { return (false, nil) }
        if claudeContinues { return (false, session.client == .terminal ? L("Claude Code продолжит сам после сброса") : nil) }
        return (cutOffAction != .off, nil)
    }
    func control(for session: AgentSession) -> SessionControl? { controls.first { $0.id == TokenLedger.sessionKey(session.provider, session.sessionID) } }
    func snapshot(_ provider: ProviderID) -> UsageSnapshot? { dependencies.snapshots().first { $0.provider == provider } }

    /// The week's level for a provider now, estimated past the last reading.
    func weekLevel(_ provider: ProviderID) -> Double? {
        WeekLevel.estimate(snapshot: snapshot(provider), ledger: dependencies.ledger(), now: dependencies.clock())
    }
    func fiveHourLevel(_ provider: ProviderID) -> Double? {
        let snapshot = snapshot(provider)
        return WeekLevel.estimate(snapshot: snapshot, window: snapshot?.fiveHour, ledger: dependencies.ledger(), now: dependencies.clock())
    }

    // MARK: User actions

    func setLimit(for session: AgentSession, stopAtWeek: Double, fiveHourGuard: Bool = false, continueAfterReset: Bool, message: String?) {
        let now = dependencies.clock()
        var control = control(for: session) ?? newControl(session, now: now)
        control.stopAtWeek = min(100, max(1, stopAtWeek)); control.startLevel = weekLevel(session.provider)
        control.fiveHourGuard = fiveHourGuard ? true : nil; control.guardOffUntil = nil
        control.continueAfterWeek = continueAfterReset ? true : nil
        control.message = Self.message(message)
        control.resumeAt = nil; control.resume = nil; control.state = .watching; control.reason = nil; control.note = nil; control.updatedAt = now
        upsert(control)
        Task { await tick() }
    }
    func continueLater(_ session: AgentSession, when: SessionControl.Resume, at date: Date?, message: String?) {
        let now = dependencies.clock()
        let snapshot = snapshot(session.provider)
        var control = control(for: session) ?? newControl(session, now: now)
        control.message = Self.message(message); control.resume = when
        switch when {
        case .afterWeeklyReset: control.resumeAt = snapshot?.weekly?.resetsAt.map(Self.afterReset)
        case .afterFiveHourReset: control.resumeAt = snapshot?.fiveHour?.resetsAt.map(Self.afterReset)
        case .afterLimitReset: control.resumeAt = WeekLevel.limitReset(snapshot, now: now).map(Self.afterReset)
        case .at: control.resumeAt = date
        }
        control.pressEnter = nil
        if [.continued, .needsYou, .offered].contains(control.state) { control.state = .watching }
        control.note = nil; control.updatedAt = now
        upsert(control)
    }
    func remove(_ id: String) {
        // The cut-off it answered stays in the logs for hours: it is not offered again.
        if let cut = controls.first(where: { $0.id == id })?.cutOffAt { declined[id] = max(declined[id] ?? cut, cut) }
        controls.removeAll { $0.id == id }
        save(); writeLimits()
    }
    /// Continues now: lifts the week's limit, or lets a resting session go until the next 5-hour window.
    func continueNow(_ id: String) {
        guard var control = controls.first(where: { $0.id == id }) else { return }
        let now = dependencies.clock()
        switch control.state {
        case .resting: control.guardOffUntil = snapshot(control.provider)?.fiveHour?.resetsAt ?? now.addingTimeInterval(5 * 3600)
        case .stopped: control.stopAtWeek = nil
        default: if control.reason == .week { control.stopAtWeek = nil }
        }
        control.state = .watching; control.reason = nil; control.resumeAt = now; control.updatedAt = now
        upsert(control)
        Task { await tick() }
    }
    /// Raises the week's limit by `points` and continues a session the old limit stopped.
    func raise(_ id: String, by points: Double = 5) {
        guard var control = controls.first(where: { $0.id == id }) else { return }
        let now = dependencies.clock(), level = weekLevel(control.provider)
        let wasStopped = control.state == .stopped
        control.stopAtWeek = min(100, max(control.stopAtWeek ?? 0, (level ?? 0).rounded(.up)) + points)
        control.startLevel = level
        if wasStopped { control.state = .watching; control.reason = nil; control.resumeAt = now }
        control.updatedAt = now
        upsert(control)
        Task { await tick() }
    }
    /// Yes to «continue after the reset» for a session the limit cut off.
    func accept(_ id: String) {
        guard var control = controls.first(where: { $0.id == id }), control.state == .offered else { return }
        control.state = .watching; control.updatedAt = dependencies.clock()
        upsert(control)
    }
    /// No to it: the cut-off is not offered again; a limit the user set stays.
    func decline(_ id: String) {
        guard var control = controls.first(where: { $0.id == id }) else { return }
        declined[id] = control.cutOffAt ?? dependencies.clock()
        if control.stopAtWeek == nil && control.fiveHourGuard != true { remove(id); return }
        if control.state == .offered { control.state = .watching }
        control.resumeAt = nil; control.resume = nil; control.updatedAt = dependencies.clock()
        upsert(control)
    }
    /// Resumes the session in a new Terminal window when it could not be typed into.
    func openInTerminal(_ id: String) {
        // Claude Code waiting for Enter still runs: a second process would write the same transcript.
        guard let control = controls.first(where: { $0.id == id }), control.pressEnter != true,
              let command = TerminalLocation.resumeCommand(provider: control.provider, sessionID: control.sessionID, text: control.text, cwd: control.cwd) else { return }
        let app = control.terminalApp == "iTerm2" ? "iTerm2" : "Terminal"
        Task {
            let opened = (try? await dependencies.open(command, app)) == true
            guard opened, var current = controls.first(where: { $0.id == id }) else { return }
            current.state = current.stopAtWeek == nil && current.fiveHourGuard != true ? .continued : .watching
            current.note = L("Продолжена {0}.", Self.date(dependencies.clock())); current.updatedAt = dependencies.clock()
            upsert(current)
        }
    }
    /// A button in one of Lunavect's notifications.
    func handle(action: String, controlID: String) {
        switch action {
        case Self.Action.continueNow: continueNow(controlID)
        case Self.Action.raise: raise(controlID)
        case Self.Action.accept: accept(controlID)
        case Self.Action.decline: decline(controlID)
        case Self.Action.terminal: openInTerminal(controlID)
        default: break
        }
    }

    private func newControl(_ session: AgentSession, now: Date) -> SessionControl {
        var control = SessionControl(provider: session.provider, sessionID: session.sessionID, title: session.displayTitle, cwd: session.cwd, now: now)
        control.client = session.client; control.terminalApp = session.terminalApp
        return control
    }
    private static func message(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == SessionControl.defaultMessage ? nil : trimmed
    }
    /// A minute after the reset, so the provider has let the account go again.
    private static func afterReset(_ date: Date) -> Date { date.addingTimeInterval(60) }
    /// When a continuation chosen before its reset was known is due, once a reading shows it.
    /// A cut-off whose used-up window no reading after it shows (a lagging reading, a model or
    /// credit limit) continues after five hours, when any 5-hour window has reset.
    static func resumeDate(_ resume: SessionControl.Resume, cutOffAt: Date?, snapshot: UsageSnapshot?, now: Date) -> Date? {
        switch resume {
        case .afterWeeklyReset: return snapshot?.weekly?.resetsAt.map(afterReset)
        case .afterFiveHourReset: return snapshot?.fiveHour?.resetsAt.map(afterReset)
        case .at: return nil
        case .afterLimitReset:
            if let reset = WeekLevel.limitReset(snapshot, now: now) { return afterReset(reset) }
            guard let cut = cutOffAt, let fetched = snapshot?.fetchedAt, fetched.timeIntervalSince(cut) > 60 else { return nil }
            return afterReset(cut.addingTimeInterval(5 * 3600))
        }
    }

    // MARK: Watching

    func tick() async {
        let now = dependencies.clock(), sessions = dependencies.sessions()
        noticeCutOffs(sessions, now: now)
        for id in controls.map(\.id) {
            guard var control = controls.first(where: { $0.id == id }) else { continue }
            let snapshot = snapshot(control.provider)
            let row = sessions.first { TokenLedger.sessionKey($0.provider, $0.sessionID) == id }
            // A reset unknown when the continuation was chosen is filled in once a reading shows it.
            if control.resumeAt == nil, control.state != .continued, let resume = control.resume,
               let due = Self.resumeDate(resume, cutOffAt: control.cutOffAt, snapshot: snapshot, now: now) {
                control.resumeAt = due; upsert(control, write: false)
            }
            if ![.offered, .needsYou, .continued].contains(control.state), control.stopAtWeek != nil || control.fiveHourGuard == true {
                let week = control.stopAtWeek == nil ? nil : weekLevel(control.provider)
                // The week's level is unknown: keep the state rather than let a stopped session go.
                if control.stopAtWeek == nil || week != nil {
                    let five = control.fiveHourGuard == true ? fiveHourLevel(control.provider) : nil
                    var next = control.decide(weekLevel: week, fiveHourLevel: five, now: now)
                    // The 5-hour level is unknown: keep the rest or wrap-up it caused until its own time.
                    if control.fiveHourGuard == true, five == nil, control.reason == .fiveHour, next.state != .stopped,
                       control.resumeAt.map({ $0 > now }) ?? true { next = (control.state, control.reason) }
                    if next.state != control.state || next.reason != control.reason {
                        enter(next.state, reason: next.reason, control: &control, snapshot: snapshot, now: now)
                        upsert(control, write: false)
                    }
                }
            }
            // Claude Code hit the real limit while resting and waits for the reset itself: typing too would ask twice.
            if control.provider == .claude, control.state == .resting, control.nativeContinue != true, let row,
               row.phase == .failed, row.failure == .limit, claudeContinues {
                control.nativeContinue = true; control.resumeAt = nil
                control.note = L("Claude Code продолжит сам после сброса"); upsert(control, write: false)
            }
            if [.stopped, .resting, .offered, .needsYou].contains(control.state) { readSummary(control, row: row, now: now) }
            // A continuation is due: typed into the session's own tab once it is idle.
            if let at = control.resumeAt, at <= now, ![.stopped, .resting, .offered, .needsYou, .continued].contains(control.state),
               !delivering.contains(id) {
                if let phase = row?.effectivePhase(now: now), phase == .running || phase == .permission { continue }
                delivering.insert(id)
                // The hooks read the new state before anything is typed: an old stop would block the message.
                writeLimits()
                await deliver(id, row: row)
                delivering.remove(id)
            }
        }
        writeLimits()
    }

    private func enter(_ state: SessionControl.State, reason: SessionControl.Reason?, control: inout SessionControl, snapshot: UsageSnapshot?, now: Date) {
        if state == .stopped, control.state != .stopped {
            if control.continueAfterWeek == true { control.resumeAt = snapshot?.weekly?.resetsAt.map(Self.afterReset) }
            let when = control.resumeAt.map { L("Продолжит {0}.", Self.date($0)) } ?? L("Снимите ограничение в Lunavect, чтобы продолжить.")
            let level = PercentText.format(Int((control.stopAtWeek ?? 0).rounded()))
            dependencies.notify(Notice(title: L("Сессия остановлена на {0} недели", level), body: control.title + "\n" + when,
                                       category: Self.Category.stopped, controlID: control.id))
            control.summary = nil; control.summaryAt = nil
        }
        if state == .resting, control.state != .resting {
            control.resumeAt = snapshot?.fiveHour?.resetsAt.map(Self.afterReset)
            let when = control.resumeAt.map { L("Продолжит {0}.", Self.date($0)) } ?? L("Продолжит после сброса окна.")
            dependencies.notify(Notice(title: L("Сессия ждёт сброса окна 5 часов"), body: control.title + "\n" + when,
                                       category: Self.Category.resting, controlID: control.id))
            control.summary = nil; control.summaryAt = nil
        }
        // Out of the rest without a known reset: continue on this tick, unless Claude Code continues by itself.
        if control.state == .resting, state != .resting {
            if control.resumeAt == nil, control.nativeContinue != true { control.resumeAt = now }
            if control.nativeContinue == true { control.nativeContinue = nil; control.note = nil }
        }
        control.state = state; control.reason = reason; control.updatedAt = now
    }

    /// A turn the provider's limit ended. Codex writes it into its log (`usage_limit_exceeded`);
    /// Claude Code waits for the reset and continues by itself, so for Claude only the ends of that
    /// wait count: `stale` (the Mac slept through the reset, Claude waits for Enter) and `disabled`,
    /// or a `rate_limit` failure when its automatic continue is off.
    private func noticeCutOffs(_ sessions: [AgentSession], now: Date) {
        let action = dependencies.cutOff()
        guard action != .off else { return }
        let hits = dependencies.ledger().limitHits ?? [:]
        for row in sessions {
            let id = TokenLedger.sessionKey(row.provider, row.sessionID)
            let at: Date?, enter: Bool
            switch row.provider {
            case .claude:
                if row.limitWait == "stale", let wait = row.limitWaitAt, row.client == .terminal { at = wait; enter = true }
                else if row.limitWait == "disabled", let wait = row.limitWaitAt { at = wait; enter = false }
                else if row.phase == .failed, row.failure == .limit, !claudeContinues { at = row.updatedAt; enter = false }
                else { continue }
            case .codex:
                guard let hit = hits[id] else { continue }
                at = hit; enter = false
            default: continue
            }
            guard let at, now.timeIntervalSince(at) < 6 * 3600 else { continue }
            if let no = declined[id], no >= at { continue }
            let existing = controls.first { $0.id == id }
            if let existing {
                if let seen = existing.cutOffAt, seen >= at { continue }
                if [.stopped, .resting, .offered].contains(existing.state) || existing.resumeAt != nil { continue }
            }
            var control = existing ?? newControl(row, now: now)
            control.cutOffAt = at; control.pressEnter = enter ? true : nil
            control.resume = enter ? .at : .afterLimitReset
            // Automatic Enter waits a minute, so the notice's «Не продолжать» can still stop it.
            control.resumeAt = enter ? (action == .auto ? now.addingTimeInterval(60) : now)
                : WeekLevel.limitReset(snapshot(row.provider), now: now).map(Self.afterReset)
            control.state = action == .ask ? .offered : .watching; control.note = nil; control.updatedAt = now
            control.summary = nil; control.summaryAt = nil
            let when = control.resumeAt.map(Self.date)
            let notice: Notice
            switch (enter, action) {
            case (true, .ask):
                notice = Notice(title: L("Лимит сбросился, пока Mac спал"), body: control.title + "\n" + L("Claude Code ждёт Enter, чтобы продолжить."),
                                category: Self.Category.enter, controlID: id)
            case (true, _):
                notice = Notice(title: L("Лимит сбросился, пока Mac спал"), body: control.title + "\n" + L("Lunavect нажмёт Enter, и Claude Code продолжит."),
                                category: Self.Category.auto, controlID: id)
            case (false, .ask):
                notice = Notice(title: L("Лимит закончился посреди работы"),
                                body: control.title + "\n" + (when.map { L("Продолжить после сброса в {0}?", $0) } ?? L("Продолжить после сброса лимита?")),
                                category: Self.Category.offer, controlID: id)
            default:
                notice = Notice(title: L("Лимит закончился посреди работы"),
                                body: control.title + "\n" + (when.map { L("Lunavect продолжит её после сброса в {0}.", $0) } ?? L("Lunavect продолжит её после сброса лимита.")),
                                category: Self.Category.auto, controlID: id)
            }
            dependencies.notify(notice)
            upsert(control)
        }
    }

    /// The agent's last reply once it stopped: read from its own log off the main thread.
    private func readSummary(_ control: SessionControl, row: AgentSession?, now: Date) {
        let id = control.id
        guard !reading.contains(id), row?.effectivePhase(now: now) != .running,
              control.summaryAt == nil || (row?.updatedAt ?? .distantPast) > control.summaryAt!,
              let url = dependencies.transcript(dependencies.ledger(), control.provider, control.sessionID) else { return }
        reading.insert(id)
        let read = dependencies.reply, provider = control.provider
        Task {
            let text = await Task.detached(priority: .utility) { read(url, provider) }.value
            reading.remove(id)
            guard var current = controls.first(where: { $0.id == id }) else { return }
            current.summary = text; current.summaryAt = dependencies.clock()
            upsert(current, write: false)
        }
    }

    private func deliver(_ id: String, row: AgentSession?) async {
        guard let due = controls.first(where: { $0.id == id }) else { return }
        let text = due.text
        let app = row?.terminalApp ?? due.terminalApp, client = row?.client ?? due.client
        // Enter alone belongs to the waiting Claude Code; a shell or a new window gets nothing.
        let enter = due.pressEnter == true
        // From the session's folder also in its tab: macOS may have given the tab's device to another project.
        let command = enter ? nil : TerminalLocation.resumeCommand(provider: due.provider, sessionID: due.sessionID, text: text, cwd: due.cwd)
        var typed = false, opened = false
        if client == .terminal, let app, ["Terminal", "iTerm2"].contains(app) {
            if let tty = row?.terminalTTY { typed = (try? await dependencies.type(text, tty, app, command, row?.runtimePID, due.provider)) == true }
            if !typed, let command { opened = (try? await dependencies.open(command, app)) == true }
        }
        // The user may have removed or changed the control while the script ran.
        guard var control = controls.first(where: { $0.id == id }) else { return }
        let now = dependencies.clock()
        if control.resumeAt == due.resumeAt { control.resumeAt = nil; control.resume = nil }
        control.updatedAt = now
        if typed || opened {
            control.pressEnter = nil
            control.state = control.stopAtWeek == nil && control.fiveHourGuard != true ? .continued : .watching
            control.note = L("Продолжена {0}.", Self.date(now))
            dependencies.notify(Notice(title: L("Сессия продолжается"),
                                       body: control.title + (opened ? "\n" + (app == "iTerm2" ? L("Вкладка недоступна: Lunavect продолжил сессию в новом окне iTerm2.")
                                                                            : L("Вкладка недоступна: Lunavect продолжил сессию в новом окне Терминала.")) : ""),
                                       category: nil, controlID: id))
        } else {
            control.state = .needsYou
            control.note = enter ? L("Откройте сессию и нажмите Enter.") : L("Напишите агенту: «{0}»", text)
            dependencies.notify(Notice(title: L("Лимит сброшен: сессию можно продолжить"),
                                       body: control.title + "\n" + (enter ? L("Откройте сессию и нажмите Enter.") : L("Откройте её и напишите агенту «{0}».", text)),
                                       category: command == nil ? nil : Self.Category.needsYou, controlID: id))
        }
        upsert(control)
    }

    /// Only limited sessions near or at their level reach the hooks.
    private func writeLimits() {
        var file = SessionLimitFile()
        let format = L("Коротко напиши двумя строками: «{0} …» и «{1} …».", L("Сделано:"), L("Осталось:"))
        for control in controls where [.wrappingUp, .stopped, .resting].contains(control.state) {
            let level = PercentText.format(Int((control.stopAtWeek ?? 0).rounded()))
            let reset = control.resumeAt.map(Self.date) ?? L("после сброса")
            // The entry lapses five minutes after its window resets, also when Lunavect is not running then.
            let snapshot = snapshot(control.provider)
            let window = control.reason == .fiveHour || control.state == .resting ? snapshot?.fiveHour : snapshot?.weekly
            let until = window?.resetsAt.map { $0.addingTimeInterval(300) }
            switch (control.state, control.reason) {
            case (.stopped, _):
                file.entries[control.id] = .init(state: .stopped,
                    agent: L("Lunavect: неделя дошла до {0}, эта сессия остановлена до сброса лимита. Не выполняй новых действий.", level) + " " + format,
                    user: L("Lunavect остановил эту сессию: неделя дошла до {0}. Чтобы продолжить сейчас, снимите ограничение в Lunavect (меню сессии или вкладка «Задачи»).", level), until: until)
            case (.resting, _):
                file.entries[control.id] = .init(state: .stopped,
                    agent: L("Lunavect: окно 5 часов почти исчерпано, эта сессия ждёт его сброса ({0}). Не выполняй новых действий: Lunavect сам попросит продолжить.", reset) + " " + format,
                    user: L("Lunavect поставил эту сессию на паузу до сброса окна 5 часов ({0}) и потом продолжит её сам. Чтобы продолжить сейчас, нажмите «Продолжить сейчас» во вкладке «Задачи».", reset), until: until)
            case (.wrappingUp, .fiveHour):
                file.entries[control.id] = .init(state: .wrappingUp,
                    agent: L("Lunavect: окно 5 часов почти исчерпано. Закончи текущий шаг и не начинай новую работу: после сброса окна Lunavect попросит продолжить.") + " " + format,
                    user: "", until: until)
            default:
                guard control.stopAtWeek != nil else { continue }
                file.entries[control.id] = .init(state: .wrappingUp,
                    agent: L("Lunavect: неделя почти дошла до {0}, предела этой сессии. Закончи текущий шаг и не начинай новую работу.", level) + " " + format,
                    user: "", until: until)
            }
        }
        guard file != writtenLimits, let limitURL else { return }
        do { try file.save(to: limitURL); writtenLimits = file }
        catch { logger.error("Session limits not written: \((error as NSError).code)") }
    }

    private func upsert(_ control: SessionControl, write: Bool = true) {
        if let index = controls.firstIndex(where: { $0.id == control.id }) { controls[index] = control } else { controls.insert(control, at: 0) }
        save()
        if write { writeLimits() }
    }
    private func save() {
        guard let url else { return }
        let now = dependencies.clock()
        declined = declined.filter { now.timeIntervalSince($0.value) < 2 * 86400 }
        var list = SessionControlList(); list.controls = controls; list.declined = declined.isEmpty ? nil : declined
        do { try list.save(to: url) } catch { logger.error("Session controls not saved: \((error as NSError).code)") }
    }
    /// "15:00" today, otherwise the weekday with the time.
    nonisolated static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "EEEjmm")
        return formatter.string(from: date)
    }

    // MARK: Notifications

    enum Category {
        static let stopped = "lunavect.control.stopped", resting = "lunavect.control.resting", offer = "lunavect.control.offer"
        static let auto = "lunavect.control.auto", needsYou = "lunavect.control.needsYou", enter = "lunavect.control.enter"
    }
    enum Action {
        static let continueNow = "lunavect.control.continueNow", raise = "lunavect.control.raise", accept = "lunavect.control.accept"
        static let decline = "lunavect.control.decline", terminal = "lunavect.control.terminal"
    }
    /// The buttons of each notice; registered again before each notice so their titles follow the app's language.
    static var categories: Set<UNNotificationCategory> {
        let continueNow = UNNotificationAction(identifier: Action.continueNow, title: L("Продолжить сейчас"))
        let raise = UNNotificationAction(identifier: Action.raise, title: "+" + PercentText.format(5))
        let accept = UNNotificationAction(identifier: Action.accept, title: L("Продолжить после сброса"))
        let decline = UNNotificationAction(identifier: Action.decline, title: L("Не надо"))
        let skip = UNNotificationAction(identifier: Action.decline, title: L("Не продолжать"))
        let terminal = UNNotificationAction(identifier: Action.terminal, title: L("Продолжить в Терминале"))
        let proceed = UNNotificationAction(identifier: Action.accept, title: L("Продолжить"))
        return [UNNotificationCategory(identifier: Category.stopped, actions: [continueNow, raise], intentIdentifiers: []),
                UNNotificationCategory(identifier: Category.resting, actions: [continueNow], intentIdentifiers: []),
                UNNotificationCategory(identifier: Category.offer, actions: [accept, decline], intentIdentifiers: []),
                UNNotificationCategory(identifier: Category.auto, actions: [skip], intentIdentifiers: []),
                UNNotificationCategory(identifier: Category.needsYou, actions: [terminal], intentIdentifiers: []),
                UNNotificationCategory(identifier: Category.enter, actions: [proceed, decline], intentIdentifiers: [])]
    }
    @MainActor static func postNotice(_ notice: Notice) {
        guard !LiveProcessGuard.refuses("notification") else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(categories)
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body
        if let category = notice.category { content.categoryIdentifier = category }
        if let id = notice.controlID { content.userInfo = ["controlID": id, "sessionID": id]; content.threadIdentifier = id }
        center.add(UNNotificationRequest(identifier: "lunavect-control-" + UUID().uuidString, content: content, trigger: nil))
    }
}
