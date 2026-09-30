import AppKit
import Foundation
import os
import UserNotifications
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SessionControlMode: String, Identifiable { case limit, later; var id: String { rawValue } }

/// Stops a session the user limited when the week reaches their level, and continues
/// sessions later with a message (owner decisions 30.09). Enforcement goes through the
/// Claude and Codex hooks Lunavect installs; the continuation is typed into the session's
/// own Terminal or iTerm2 tab, or offered with a notification elsewhere.
@MainActor final class SessionControlService: ObservableObject {
    @Published private(set) var controls: [SessionControl] = []

    struct Dependencies {
        var ledger: @MainActor () -> TokenLedger
        var snapshots: @MainActor () -> [UsageSnapshot]
        var sessions: @MainActor () -> [AgentSession]
        var type: @Sendable (String, String, String) async throws -> Bool = { text, tty, app in try await TerminalLocation.type(text, tty: tty, app: app) }
        var notify: @MainActor (String, String) -> Void = SessionControlService.postNotice
        var clock: () -> Date = Date.init
    }
    private let dependencies: Dependencies
    private let url: URL?
    private let limitURL: URL?
    private var loop: Task<Void, Never>?
    private var delivering: Set<String> = []
    private var writtenLimits: SessionLimitFile?
    private let logger = Logger(subsystem: "com.weekleft.app", category: "session-controls")

    init(url: URL? = SessionControlService.defaultURL, limitURL: URL? = SessionControlService.defaultLimitURL, dependencies: Dependencies) {
        self.url = url; self.limitURL = limitURL; self.dependencies = dependencies
        controls = url.flatMap { try? SessionControlList.load(from: $0).controls } ?? []
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

    func control(for session: AgentSession) -> SessionControl? { controls.first { $0.id == TokenLedger.sessionKey(session.provider, session.sessionID) } }

    /// The week's level for a provider now, estimated past the last reading.
    func weekLevel(_ provider: ProviderID) -> Double? {
        WeekLevel.estimate(snapshot: dependencies.snapshots().first { $0.provider == provider }, ledger: dependencies.ledger(), now: dependencies.clock())
    }

    // MARK: User actions

    func setLimit(for session: AgentSession, stopAtWeek: Double, continueAfterReset: Bool, message: String?) {
        let now = dependencies.clock()
        var control = control(for: session) ?? SessionControl(provider: session.provider, sessionID: session.sessionID,
                                                                title: session.displayTitle, cwd: session.cwd, now: now)
        control.stopAtWeek = min(100, max(1, stopAtWeek)); control.startLevel = weekLevel(session.provider)
        control.message = continueAfterReset ? Self.message(message) : nil
        control.resume = continueAfterReset ? .afterWeeklyReset : nil
        control.resumeAt = nil; control.state = .watching; control.note = nil; control.updatedAt = now
        upsert(control)
        Task { await tick() }
    }
    func continueLater(_ session: AgentSession, when: SessionControl.Resume, at date: Date?, message: String?) {
        let now = dependencies.clock()
        let snapshot = dependencies.snapshots().first { $0.provider == session.provider }
        var control = control(for: session) ?? SessionControl(provider: session.provider, sessionID: session.sessionID,
                                                                title: session.displayTitle, cwd: session.cwd, now: now)
        control.message = Self.message(message); control.resume = when
        switch when {
        case .afterWeeklyReset: control.resumeAt = snapshot?.weekly?.resetsAt
        case .afterFiveHourReset: control.resumeAt = snapshot?.fiveHour?.resetsAt
        case .at: control.resumeAt = date
        }
        control.state = control.stopAtWeek == nil ? .watching : control.state
        control.note = nil; control.updatedAt = now
        upsert(control)
    }
    func remove(_ id: String) {
        controls.removeAll { $0.id == id }
        save(); writeLimits()
    }
    /// Lifts the limit and types the message now.
    func continueNow(_ id: String) {
        guard var control = controls.first(where: { $0.id == id }) else { return }
        control.stopAtWeek = nil; control.state = .watching; control.resumeAt = dependencies.clock()
        if control.message == nil { control.message = SessionControl.defaultMessage }
        upsert(control)
        Task { await tick() }
    }

    private static func message(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SessionControl.defaultMessage : trimmed
    }

    // MARK: Watching

    func tick() async {
        let now = dependencies.clock(), sessions = dependencies.sessions()
        for id in controls.map(\.id) {
            guard var control = controls.first(where: { $0.id == id }) else { continue }
            let snapshot = dependencies.snapshots().first { $0.provider == control.provider }
            if control.stopAtWeek != nil, let level = weekLevel(control.provider) {
                let next = control.decide(weekLevel: level)
                if next != control.state, control.state != .needsYou {
                    if next == .stopped {
                        if control.message != nil, control.resumeAt == nil { control.resumeAt = snapshot?.weekly?.resetsAt }
                        let when = control.resumeAt.map { L("Продолжит {0}.", Self.date($0)) } ?? L("Снимите ограничение в Lunavect, чтобы продолжить.")
                        dependencies.notify(L("Сессия остановлена на пределе"), control.title + "\n" + when)
                    }
                    control.state = next; control.updatedAt = now
                    upsert(control, write: false)
                }
            }
            // A continuation is due: typed into the session's own tab once it is idle.
            if let at = control.resumeAt, at <= now, control.message != nil, control.state != .needsYou, control.state != .continued,
               !(control.stopAtWeek != nil && control.state == .stopped), !delivering.contains(id) {
                let row = sessions.first { TokenLedger.sessionKey($0.provider, $0.sessionID) == id }
                if row?.effectivePhase(now: now) == .running { continue }
                delivering.insert(id)
                await deliver(id, row: row)
                delivering.remove(id)
            }
        }
        writeLimits()
    }

    private func deliver(_ id: String, row: AgentSession?) async {
        guard var control = controls.first(where: { $0.id == id }), let message = control.message else { return }
        let now = dependencies.clock()
        var typed = false
        if let row, row.client == .terminal, let tty = row.terminalTTY, let app = row.terminalApp, ["Terminal", "iTerm2"].contains(app) {
            typed = (try? await dependencies.type(message, tty, app)) == true
        }
        control.message = nil; control.resumeAt = nil; control.resume = nil; control.updatedAt = now
        if typed {
            control.state = control.stopAtWeek == nil ? .continued : .watching
            control.note = L("Продолжена {0}.", Self.date(now))
            dependencies.notify(L("Сессия продолжается"), control.title)
        } else {
            control.state = .needsYou
            control.note = L("Напишите агенту: «{0}»", message)
            dependencies.notify(L("Лимит сброшен: сессию можно продолжить"), control.title + "\n" + L("Откройте её и напишите агенту «{0}».", message))
        }
        upsert(control)
    }

    /// Only limited sessions near or at their level reach the hooks.
    private func writeLimits() {
        var file = SessionLimitFile()
        for control in controls where control.state == .wrappingUp || control.state == .stopped {
            guard let stop = control.stopAtWeek else { continue }
            let level = PercentText.format(Int(stop.rounded()))
            file.entries[control.id] = .init(
                state: control.state,
                agent: control.state == .stopped
                    ? L("Lunavect: неделя дошла до {0}, эта сессия остановлена до сброса лимита. Не выполняй новых действий; коротко напиши, что сделано и что осталось.", level)
                    : L("Lunavect: неделя почти дошла до {0} — предела этой сессии. Закончи текущий шаг, не начинай новую работу и коротко напиши, что сделано, что осталось и откуда продолжить.", level),
                user: L("Lunavect остановил эту сессию: неделя дошла до {0}. Чтобы продолжить сейчас, снимите ограничение в Lunavect (меню сессии или вкладка «Задачи»).", level))
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
        var list = SessionControlList(); list.controls = controls
        do { try list.save(to: url) } catch { logger.error("Session controls not saved: \((error as NSError).code)") }
    }
    nonisolated static func date(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale)) }

    @MainActor static func postNotice(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lunavect-control-" + UUID().uuidString, content: content, trigger: nil))
    }
}
