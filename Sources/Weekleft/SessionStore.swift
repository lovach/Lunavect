import OSLog
import AppKit
import SwiftUI
import Combine
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class SessionStore: ObservableObject {
    typealias CatalogResult = (rows: [AgentSession], incomplete: Bool)
    /// Defaults are inert. Live access is selected only by the production initializer.
    struct Dependencies {
        var catalog: (ProviderID, ClientExecutableResolver, [AgentSession], [String]) async throws -> CatalogResult = { _, _, _, _ in ([], false) }
        var events: ([AgentSession], [ProviderID], Date) async throws -> [AgentSession] = { _, _, _ in [] }
        var titles: ([AgentSession], [String], [ProviderID]) async throws -> [String: String] = { _, _, _ in [:] }
        var hooksState: @Sendable () -> [ProviderID: Bool] = { [:] }
        var initialEvents: (URL) -> [AgentSession] = { _ in [] }
        /// Inert default: no process is ever declared gone.
        var isProcessAlive: (Int32) -> Bool = { _ in true }
        var schedulesTimers = false
        var watchesEvents = false
        var allowsClientConfiguration = false
        /// Hands a manually selected client executable to runtime observation.
        var configureRuntime: (ClientExecutableResolver) async -> Void = { _ in }
        /// Client configuration of one provider; nil keeps connection maintenance inert.
        var clientSetup: (ProviderID) -> ClientConnection.LocalSetup? = { _ in nil }
        /// The stable hook helper link refreshed at launch (owner decision 18).
        var helperLocation: HookHelperLocation?
        /// Other installed copies of Lunavect, reported at launch (matrix P4).
        var installedCopies: () -> [URL] = { [] }

        static func live(directory: URL) -> Self {
            Self(catalog: { provider, resolver, previous, priorityIDs in
                try Task.checkCancellation()
                if provider == .codex {
                    let result = try await SessionSources.codexCatalog(resolver: resolver, prioritySessionIDs: priorityIDs)
                    try Task.checkCancellation()
                    return (result.retainingKnownSessions(previous), !result.isComplete)
                }
                return (try await SessionSources.claude(path: resolver.resolve(.claude)), false)
            }, events: { rows, providers, now in
                var events = try await readLocal {
                    let legacy = SessionSources.legacyEvents(catalog: rows, now: now)
                    try Task.checkCancellation()
                    return CodexSessionMetadata.markingSubagents(in: legacy + SessionHooks.load(at: directory))
                }
                try Task.checkCancellation()
                if providers.contains(.codex) { events += await CodexActivityReader.shared.events(catalog: rows, now: now) }
                try Task.checkCancellation()
                return events
            }, titles: { rows, hidden, providers in
                try await readLocal {
                    var result: [String: String] = [:]
                    if providers.contains(.codex) {
                        let ids = Set(hidden.filter { $0.hasPrefix("codex:") }.map { String($0.dropFirst(6)) })
                        for (id, title) in CodexSessionMetadata.titles(for: ids) { result["codex:" + id] = title }
                    }
                    try Task.checkCancellation()
                    if providers.contains(.claude) {
                        let hiddenIDs = hidden.filter { $0.hasPrefix("claude:") }.map { String($0.dropFirst(7)) }
                        let ids = Set(rows.filter { $0.provider == .claude }.map(\.sessionID) + hiddenIDs)
                        for (id, title) in ClaudeSessionMetadata.titles(for: ids) { result["claude:" + id] = title }
                    }
                    return result
                }
            }, hooksState: { Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, SessionHooks.installed($0)) }) },
                 initialEvents: { CodexSessionMetadata.markingSubagents(in: SessionHooks.load(at: $0)) },
                 isProcessAlive: SessionSources.isProcessAlive, schedulesTimers: true, watchesEvents: true, allowsClientConfiguration: true,
                 configureRuntime: { resolver in
                     // Automatic discovery is already checked by the runtime reader itself.
                     await CodexActivityReader.shared.useExecutable(resolver.codexPath.isEmpty ? nil : resolver.codexPath)
                 }, clientSetup: { ClientConnection.LocalSetup(provider: $0) }, helperLocation: HookHelperLocation(),
                 installedCopies: { InstalledCopies.others(running: Bundle.main.bundleURL) })
        }
        private static func readLocal<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
            try Task.checkCancellation()
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let result = try operation()
                try Task.checkCancellation()
                return result
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
        }
    }

    @Published var sessions: [AgentSession] = []
    let observations = PassthroughSubject<(rows: [AgentSession], date: Date), Never>()
    @Published var refreshing = false
    @Published var issues: [ProviderID: String] = [:]
    @Published private(set) var typedIssues: [ProviderID: ClientIntegrationIssue] = [:]
    struct DiagnosticEntry: Equatable {
        let date: Date
        let issue: ClientIntegrationIssue
        /// A fact the hook helper recorded, such as a rejected SubagentStop count.
        var hook: HookDiagnostic? = nil
    }
    /// Fixed codes only; bounded and local to this store's lifetime.
    @Published private(set) var diagnosticEntries: [DiagnosticEntry] = []
    @Published var hooksInstalled: [ProviderID: Bool] = [:]
    /// Local configuration of each provider, read when connections are shown.
    @Published private(set) var connectionStates: [ProviderID: ClientConnection.LocalState] = [:]
    struct SetupNotice: Equatable {
        let message: String
        let warning: Bool
    }
    /// A launch finding shown on the session panel until dismissed.
    @Published var setupNotice: SetupNotice?
    /// Providers whose events the user turned off here (audit H-05). Kept in the
    /// store's defaults; connecting or turning events on again clears it.
    @Published private(set) var eventsDisabledByUser: Set<ProviderID> = [] {
        didSet { defaults.set(eventsDisabledByUser.map(\.rawValue).sorted(), forKey: Self.eventsDisabledKey) }
    }
    private static let eventsDisabledKey = "connection.eventsDisabledByUser"
    func eventsConnected(_ provider: ProviderID) { eventsDisabledByUser.remove(provider) }
    @Published var connectionMessage: String? {
        didSet { titleSaveOwnsConnectionMessage = false }
    }
    private var titleSaveOwnsConnectionMessage = false
    @Published var updatedAt: Date?
    @Published private(set) var providers = ProviderID.allCases
    func useProviders(_ providers: [ProviderID]) {
        guard self.providers != providers else { return }
        invalidateWork()
        self.providers = providers
        allSessions = allSessions.filter { providers.contains($0.provider) }
        catalog = catalog.filter { providers.contains($0.key) }
        catalogSettled.formIntersection(providers)
        issues = issues.filter { providers.contains($0.key) }
        typedIssues = typedIssues.filter { providers.contains($0.key) }
        if let row = lastHidden, !providers.contains(row.provider) { lastHidden = nil }
        publishVisible()
        watchEvents()
    }
    var onObservation: (([AgentSession], Date) -> Void)?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var lastHidden: AgentSession?
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 50
        return manager
    }()
    @Published private(set) var arrangement = SessionArrangement()
    @Published private(set) var hiddenIDs: [String] = []
    @Published private(set) var hiddenSessions: [SessionVisibility.Summary] = []
    @Published var autoHideMinutes: Int {
        didSet {
            defaults.set(autoHideMinutes, forKey: "sessionAutoHideMinutes")
            if autoHideMinutes == 0 { inactiveSince.removeAll() }
        }
    }
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private let now: () -> Date
    private let directory: URL
    // Retain observed inactivity beyond the source's status freshness window.
    // Poll timestamps are deliberately not activity timestamps.
    private var organizationCheckedAt: Date?
    /// Providers whose catalog read has answered at least once, successfully or not.
    /// The daily organization check waits for all of them (S-05).
    private var catalogSettled: Set<ProviderID> = []
    private var inactiveSince: [String: Date] = [:]
    private var arrangementURL: URL?
    private var arrangementLoadError: Error?
    private var visibility: SessionVisibility?
    private var allSessions: [AgentSession] = []
    // Missing origin never promotes a known internal task. Claude may explicitly
    // resume independently; Codex subagent origin is immutable for its thread ID.
    private var internalSessionIDs: Set<String> = []
    private var undoDismissTask: Task<Void, Never>?
    private let undoDelay: Duration
    init(directory: URL? = nil, undoDelay: Duration = .seconds(4), defaults: UserDefaults? = nil,
         isolated: Bool = false, now: @escaping () -> Date = Date.init, dependencies: Dependencies? = nil) {
        let defaults = defaults ?? (isolated ? UserDefaults(suiteName: "Lunavect.SessionFixture." + UUID().uuidString)! : .standard)
        let base = directory ?? (isolated ? FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect-preview-" + UUID().uuidString) : SessionHooks.directory)
        self.defaults = defaults; self.now = now; self.directory = base
        // Under XCTest a store never selects live client access, even without
        // `isolated`: no client process, settings file or helper link. It reads
        // only hook records in its own directory (LiveWriteGuard).
        self.dependencies = dependencies ?? (isolated ? Dependencies() : LiveWriteGuard.underTestsForStores
            ? Dependencies(initialEvents: { SessionHooks.load(at: $0) }) : .live(directory: base))
        if isolated { resolveClient = { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) } }
        eventsDisabledByUser = Set((defaults.stringArray(forKey: Self.eventsDisabledKey) ?? []).compactMap(ProviderID.init(rawValue:)))
        let savedMinutes = defaults.integer(forKey: "sessionAutoHideMinutes")
        autoHideMinutes = [5, 10, 20].contains(savedMinutes) ? savedMinutes : 0
        self.undoDelay = undoDelay
        arrangementURL = base.appendingPathComponent("arrangement.json")
        do {
            if let url = arrangementURL {
                let result = try SessionArrangement.loadRecovering(from: url)
                arrangement = result.value
                if result.backupURL != nil {
                    connectionMessage = L("Повреждённый порядок сессий сохранён отдельно. Закрепление и перемещение снова доступны.")
                }
            }
        } catch {
            arrangementLoadError = error
            connectionMessage = L("Не удалось прочитать порядок сессий. Исходный файл сохранён; закрепление и перемещение отключены до перезапуска.")
        }
        do {
            let file = base.appendingPathComponent("hidden-sessions.json")
            let result = try LocalStateRecovery.load(from: file, empty: Optional<SessionVisibility>.none) { try Optional(SessionVisibility(url: $0)) }
            visibility = try result.value ?? SessionVisibility(url: file, now: now())
            if result.backupURL != nil { connectionMessage = L("Повреждённый список скрытых сессий сохранён отдельно. Управление сессиями восстановлено.") }
            // Include old events outside the merge freshness window when repairing history.
            let initial = self.dependencies.initialEvents(base)
            try visibility?.removeUnstartedClaudeLifecycles(initial)
            internalSessionIDs.formUnion(initial.filter { $0.isCodexSubagent == true || $0.isNestedClaudeSession == true }.map(\.id))
            try removeHiddenInternalSessions()
            hiddenCount = visibility?.hidden.count ?? 0
            hiddenIDs = (visibility?.hidden ?? []).sorted()
            hiddenSessions = visibility?.summaries ?? []
        }
        catch { connectionMessage = SessionVisibilityError.unreadable.localizedDescription }
    }
    private func requireVisibility() throws {
        guard visibility == nil else { return }
        do { visibility = try SessionVisibility(url: directory.appendingPathComponent("hidden-sessions.json"), now: now()) }
        catch {
            connectionMessage = SessionVisibilityError.unreadable.localizedDescription
            throw SessionVisibilityError.unreadable
        }
        if connectionMessage == SessionVisibilityError.unreadable.localizedDescription { connectionMessage = nil }
        publishVisible()
    }
    func hide(_ session: AgentSession) throws {
        try requireVisibility()
        try visibility?.hide(session, now: now())
        registerVisibilityUndo(session, hidden: false)
        if allSessions.isEmpty { allSessions = sessions }
        lastHidden = session
        undoDismissTask?.cancel()
        let delay = undoDelay
        undoDismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.lastHidden = nil
        }
        publishVisible()
    }
    func undoHide(now: Date? = nil) throws {
        let now = now ?? self.now()
        guard let row = lastHidden else { return }
        if undoManager.canUndo { undoManager.undo() }
        else { try restore(row.id, now: now) }
    }
    func restoreHidden(now: Date? = nil) throws {
        try requireVisibility()
        let now = now ?? self.now()
        for id in hiddenIDs { inactiveSince[id] = now }
        try visibility?.restoreAll(); undoDismissTask?.cancel(); lastHidden = nil; publishVisible()
    }
    func restore(_ id: String, now: Date? = nil) throws {
        try requireVisibility()
        let now = now ?? self.now()
        let row = allSessions.first { $0.id == id }
        let wasHidden = hiddenIDs.contains(id)
        try visibility?.setHidden(id, false)
        if wasHidden, let row { registerVisibilityUndo(row, hidden: true) }
        inactiveSince[id] = now
        // A manual restore becomes the newest Undo action. Dismiss an older
        // hide toast so its button cannot undo a different visibility change.
        undoDismissTask?.cancel(); lastHidden = nil
        publishVisible()
    }
    func removeHidden(_ id: String? = nil) throws {
        try requireVisibility()
        let ids = id.map { Set([$0]) } ?? Set(hiddenIDs)
        try visibility?.removeHidden(ids)
        // A removed local record must not be recreated by an older Undo entry.
        undoManager.removeAllActions()
        if let lastHidden, ids.contains(lastHidden.id) { undoDismissTask?.cancel(); self.lastHidden = nil }
        publishVisible()
    }
    private func registerVisibilityUndo(_ row: AgentSession, hidden: Bool) {
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            // A new task supersedes the visibility decision for its previous turn.
            guard let current = store.allSessions.first(where: { $0.id == row.id }),
                  current.turnStartedAt == row.turnStartedAt,
                  store.providers.contains(current.provider) else { return }
            do {
                if hidden { try store.hide(current) }
                else { try store.restore(current.id) }
            } catch { store.connectionMessage = L("Не удалось сохранить изменение. Попробуйте ещё раз.") }
        }
        undoManager.setActionName(L(hidden ? "Возврат сессии" : "Скрытие сессии"))
        if grouped { undoManager.endUndoGrouping() }
    }
    func setPinned(_ id: String, _ pinned: Bool) throws {
        var next = arrangement
        if pinned { next.pinned.insert(id) } else { next.pinned.remove(id) }
        try saveArrangement(next)
    }
    func move(_ id: String, before target: String, after: Bool = false, visible: [String]) throws {
        var next = arrangement
        next.move(id, before: target, after: after, visible: visible)
        try saveArrangement(next)
    }
    private func saveArrangement(_ next: SessionArrangement) throws {
        guard let arrangementURL else { throw SessionError.unavailable }
        if let arrangementLoadError { throw arrangementLoadError }
        do { try next.save(to: arrangementURL); arrangement = next }
        catch let error as SessionArrangementRecoveryError {
            connectionMessage = L("Повреждённый порядок сессий сохранён отдельно. Повторите закрепление или перемещение.")
            throw error
        }
        catch { connectionMessage = error.localizedDescription; throw error }
    }
    private var publishedPhases: [SessionPhase] = []
    private func publishVisible(now: Date? = nil) {
        let now = now ?? self.now()
        let visible = (visibility?.visible(allSessions) ?? allSessions).filter { providers.contains($0.provider) }
        let phases = visible.map { $0.effectivePhase(now: now) }
        if sessions != visible || publishedPhases != phases { publishedPhases = phases; sessions = visible }
        let hidden = (visibility?.summaries ?? []).filter { $0.provider.map(providers.contains) ?? false }
        if hiddenSessions != hidden { hiddenSessions = hidden }
        let ids = hidden.map(\.id).sorted()
        if hiddenIDs != ids { hiddenIDs = ids }
        if hiddenCount != ids.count { hiddenCount = ids.count }
        updatePollingTimers()
    }
    private var catalog: [ProviderID: [AgentSession]] = [:]
    // A persisted Stop can outlive a new response when Desktop misses a prompt
    // hook. Once runtime confirms progress, that same inferred question is spent.
    private var resolvedClaudeQuestions: [String: Date] = [:]
    private var localTimer: Timer?
    private var sourceTimer: Timer?
    private var eventWatcher: DispatchSourceFileSystemObject?
    private var started = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var eventID: UUID?
    private var refreshDemand: SharedWorkDemand?
    private var eventDemand: SharedWorkDemand?
    /// A source changed while a read was already enumerating it.
    private var eventsChanged = false
    private var panelVisible = false
    private(set) var polling: SessionPolling?
    private var lastCatalogPollAt: Date?
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible; updatePollingTimers()
    }
    private func updatePollingTimers() {
        guard started, !stopped, dependencies.schedulesTimers else { return }
        let policy = SessionPolling(panelVisible: panelVisible, hasActiveSessions: allSessions.contains { $0.isCurrent(now: now()) && $0.effectivePhase(now: now()).isActive })
        guard polling != policy else { return }
        let previous = polling
        polling = policy
        let current = generation
        if previous?.events != policy.events {
            localTimer?.invalidate()
            localTimer = Timer.scheduledTimer(withTimeInterval: policy.events, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(current) else { return }
                    self.beginEvents()
                }
            }
            localTimer?.tolerance = 0.1
            if let localTimer { RunLoop.main.add(localTimer, forMode: .common) }
        }
        if previous?.catalog != policy.catalog {
            let deadline = SessionPolling.nextCatalogDeadline(now: now(), lastPoll: lastCatalogPollAt,
                                                             scheduled: sourceTimer?.fireDate, interval: policy.catalog)
            sourceTimer?.invalidate()
            sourceTimer = Timer(fire: deadline, interval: policy.catalog, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(current) else { return }
                    self.beginRefresh()
                }
            }
            sourceTimer?.tolerance = 1
            if let sourceTimer { RunLoop.main.add(sourceTimer, forMode: .common) }
        }
    }
    private func isCurrent(_ expected: UInt64) -> Bool { !stopped && generation == expected && !Task.isCancelled }
    private func cancelEventRead() {
        eventTask?.cancel(); eventTask = nil; eventID = nil; eventDemand = nil
        // The superseding read enumerates after any change seen so far.
        eventsChanged = false
    }
    private func invalidateWork() {
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil; refreshDemand = nil
        cancelEventRead()
        refreshing = false
        polling = nil
        localTimer?.invalidate(); localTimer = nil
        sourceTimer?.invalidate(); sourceTimer = nil
        eventWatcher?.cancel(); eventWatcher = nil
    }
    func stop() {
        stopped = true; started = false
        invalidateWork()
        undoDismissTask?.cancel(); undoDismissTask = nil
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver); self.clockObserver = nil }
    }
    isolated deinit {
        refreshTask?.cancel(); eventTask?.cancel(); undoDismissTask?.cancel()
        localTimer?.invalidate(); sourceTimer?.invalidate(); eventWatcher?.cancel()
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
    }
    private var clockObserver: NSObjectProtocol?
    /// Inactivity is measured on the wall clock. A correction (NTP step, a
    /// manual change) is not time without activity: running intervals restart
    /// instead of hiding every idle session at once (matrix S14).
    func systemClockChanged() {
        let now = now()
        for id in inactiveSince.keys { inactiveSince[id] = now }
    }
    private var desktopTitles: [String: String] = [:]
    private var titlesCheckedAt = Date.distantPast
    private var resolveClient: () -> ClientExecutableResolver = { ClientExecutableResolver() }
    var clientResolver: ClientExecutableResolver { resolveClient() }
    var currentSessions: [AgentSession] { sessions.filter { $0.isCurrent(now: now()) } }
    var activeCount: Int { currentSessions.filter { $0.effectivePhase(now: now()).isActive }.count }
    func start(codexPath: @escaping () -> String) {
        start(clientResolver: { ClientExecutableResolver(codexPath: codexPath()) })
    }
    func start(clientResolver: @escaping () -> ClientExecutableResolver) {
        guard !started, !Task.isCancelled else { return }
        stopped = false; started = true
        self.resolveClient = clientResolver
        repairMovedConnections()
        updateHookConfiguration()
        beginRefresh()
        updatePollingTimers()
        watchEvents()
        if dependencies.schedulesTimers, clockObserver == nil {
            clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.systemClockChanged() }
            }
        }
    }
    private func watchEvents() {
        guard started, !stopped, dependencies.watchesEvents, eventWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let current = generation
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .global(qos: .utility))
        watcher.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isCurrent(current) else { return }
                self.sourceChanged()
            }
        }
        watcher.setCancelHandler { close(fd) }
        eventWatcher = watcher; watcher.resume()
    }
    @discardableResult private func beginRefresh(requested: Bool = false) -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        if let refreshTask { return refreshTask }
        let current = generation, id = UUID()
        refreshing = true; refreshID = id
        refreshDemand = SharedWorkDemand(requested: requested)
        lastCatalogPollAt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: current)
            if self.refreshID == id { self.refreshTask = nil; self.refreshID = nil; self.refreshDemand = nil; self.refreshing = false }
        }
        refreshTask = task
        return task
    }
    func refresh() async {
        guard let task = beginRefresh(requested: true), let demand = refreshDemand else { return }
        await Self.wait(for: task, demand: demand)
    }
    /// A caller that joined shared work stops only its own interest: the work is
    /// cancelled once no caller that requested it still waits for the result.
    private static func wait(for task: Task<Void, Never>, demand: SharedWorkDemand) async {
        demand.join()
        await withTaskCancellationHandler { await task.value } onCancel: { if demand.leave() { task.cancel() } }
    }
    private func performRefresh(generation expected: UInt64) async {
        guard isCurrent(expected) else { return }
        let resolver = clientResolver
        await dependencies.configureRuntime(resolver)
        guard isCurrent(expected) else { return }
        async let codex = fetchIfEnabled(.codex, resolver: resolver, generation: expected)
        async let claude = fetchIfEnabled(.claude, resolver: resolver, generation: expected)
        for (provider, result) in await [(ProviderID.codex, codex), (.claude, claude)] {
            guard isCurrent(expected) else { return }
            guard providers.contains(provider), let result else { continue }
            if case .failure(let error) = result, error is CancellationError { return }
            catalogSettled.insert(provider)
            switch result {
            case .success(let result):
                catalog[provider] = result.rows
                typedIssues.removeValue(forKey: provider)
                if result.incomplete {
                    typedIssues[provider] = ClientIntegrationIssue(provider: provider, capability: .sessionCatalog, reason: .incompleteCatalog)
                    issues[provider] = L("Каталог Codex получен не полностью. Известные активные сессии сохранены; свежий статус появится после подтверждения клиентом.")
                } else { issues.removeValue(forKey: provider) }
            case .failure(let error):
                if error is CancellationError { return }
                record(error, provider: provider)
                // A failed poll is not evidence that sessions ended. Keep the last
                // observations; their own freshness lifetime expires them if the
                // source stays unavailable, so one timeout cannot blank the list.
            }
        }
        guard isCurrent(expected) else { return }
        // An in-flight local poll captured the previous catalog. Supersede its
        // owned task before starting a read of this catalog; late event/title
        // completions fail the existing cancellation guards and cannot publish.
        cancelEventRead()
        updatedAt = now()
        await readEvents()
        guard isCurrent(expected) else { return }
        // Polls read client configuration off the main thread; user actions below
        // still update synchronously so their result is visible immediately.
        let hooksState = dependencies.hooksState
        let state = await Task.detached(priority: .utility) { hooksState() }.value
        guard isCurrent(expected) else { return }
        publishHookConfiguration(state)
    }
    private func fetchIfEnabled(_ id: ProviderID, resolver: ClientExecutableResolver, generation expected: UInt64) async -> Result<CatalogResult, Error>? {
        guard isCurrent(expected), providers.contains(id) else { return nil }
        let previous = (catalog[id] ?? []) + allSessions.filter { $0.provider == id }
        let priorityIDs = allSessions.filter { $0.provider == .codex && $0.phase.isActive }
            .sorted { $0.observedAt > $1.observedAt }.map(\.sessionID)
        do {
            let result = try await dependencies.catalog(id, resolver, previous, priorityIDs)
            guard isCurrent(expected) else { return nil }
            return .success(result)
        } catch {
            guard isCurrent(expected), !(error is CancellationError) else { return nil }
            return .failure(error)
        }
    }
    /// A hook wrote a record. A read already in progress may have enumerated the
    /// directory before the write, so the change schedules exactly one more read.
    func sourceChanged() { beginEvents(afterChange: true) }
    @discardableResult private func beginEvents(requested: Bool = false, afterChange: Bool = false) -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        // Freshness belongs to the display clock, not source success. Keep menu
        // subscribers in sync even while a read is pending or repeatedly fails.
        // Do this before coalescing reads; the background timer still has to age
        // the last observation without starting another source operation.
        publishVisible()
        if let eventTask {
            if afterChange { eventsChanged = true }
            return eventTask
        }
        let current = generation, id = UUID()
        eventID = id; eventsChanged = false
        eventDemand = SharedWorkDemand(requested: requested)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performReadEvents(generation: current)
            guard self.eventID == id else { return }
            self.eventTask = nil; self.eventID = nil; self.eventDemand = nil
            if self.eventsChanged, self.isCurrent(current) { self.beginEvents() }
        }
        eventTask = task
        return task
    }
    func readEvents() async {
        guard let task = beginEvents(requested: true), let demand = eventDemand else { return }
        await Self.wait(for: task, demand: demand)
    }
    private func performReadEvents(generation expected: UInt64) async {
        guard isCurrent(expected) else { return }
        guard !providers.isEmpty else { acceptSessions([]); return }
        let rows = catalog.values.flatMap { $0 }
        do {
            let events = try await dependencies.events(rows, providers, now())
            guard isCurrent(expected) else { return }
            let date = now()
            recordHookDiagnostics(events.filter { providers.contains($0.provider) && !internalSessionIDs.contains($0.id) })
            let currentEvents = suppressResolvedClaudeQuestions(events.filter { providers.contains($0.provider) }, catalog: rows, now: date)
            // `--all` re-lists finished and dormant background tasks on every poll.
            // Such history joins the merge only when a hook event names it; otherwise
            // it is passed through unchanged for completion notices (S-12).
            let eventIDs = Set(currentEvents.map(\.id))
            let history = rows.filter { $0.catalogHistory == true && !eventIDs.contains($0.id) }
            let live = history.isEmpty ? rows : rows.filter { !($0.catalogHistory == true && !eventIDs.contains($0.id)) }
            var merged = SessionList.merge(catalog: live, events: currentEvents, now: date) + history
            // S-13 / A-02: a client killed mid-turn sends no Stop or SessionEnd.
            let completeClaude = providers.contains(.claude) && typedIssues[.claude] == nil ? catalog[.claude].map { Set($0.map(\.id)) } : nil
            merged = SessionList.endingDeadClaudeRuntimes(merged, completeCatalog: completeClaude, stopped: &stoppedRuntimes,
                                                          isAlive: dependencies.isProcessAlive)
            if now().timeIntervalSince(titlesCheckedAt) >= (polling?.titles ?? 15) {
                let titles = try await dependencies.titles(merged, hiddenIDs, providers)
                guard isCurrent(expected) else { return }
                desktopTitles = titles
                var savedTitles = titles
                for row in merged where savedTitles[row.id] == nil { savedTitles[row.id] = row.title }
                // A local title write must not suppress fresh lifecycle data.
                // Retry on the normal title cadence, retaining an honest error
                // until recovery without clearing another operation's message.
                do {
                    try visibility?.updateTitles(savedTitles)
                    guard isCurrent(expected) else { return }
                    if titleSaveOwnsConnectionMessage { connectionMessage = nil }
                } catch {
                    guard isCurrent(expected) else { return }
                    connectionMessage = L("Не удалось сохранить изменение. Попробуйте ещё раз.")
                    titleSaveOwnsConnectionMessage = true
                }
                titlesCheckedAt = now()
            }
            guard isCurrent(expected) else { return }
            for i in merged.indices where merged[i].provider == .claude {
                if let title = desktopTitles[merged[i].id] { merged[i].title = title }
            }
            acceptSessions(merged, now: now())
        } catch {
            guard isCurrent(expected), !(error is CancellationError) else { return }
            if let issue = error as? ClientIntegrationIssue { record(issue, provider: issue.provider) }
            else { connectionMessage = L("Не удалось сохранить изменение. Попробуйте ещё раз.") }
        }
    }
    private func record(_ error: Error, provider: ProviderID) {
        guard let issue = ClientIntegrationIssue.classify(error, provider: provider, capability: .sessionCatalog) else { return }
        typedIssues[provider] = issue
        issues[provider] = L(issue.message)
        appendDiagnostic(DiagnosticEntry(date: now(), issue: issue))
    }
    private func appendDiagnostic(_ entry: DiagnosticEntry) {
        diagnosticEntries.append(entry)
        if diagnosticEntries.count > 32 { diagnosticEntries.removeFirst(diagnosticEntries.count - 32) }
    }
    /// S-13 decisions by session and hook-record time: one failed catalog read
    /// must not revive a stopped client (R2-02).
    private var stoppedRuntimes: [String: Date] = [:]
    /// Latest hook fact already turned into an entry, by session and kind.
    private var reportedHookDiagnostics: [String: Date] = [:]
    /// Hook records keep only their latest fact; each new one becomes one entry.
    /// It is diagnostic only: no connection issue, message or badge.
    private func recordHookDiagnostics(_ events: [AgentSession]) {
        for event in events {
            guard let fact = event.hookDiagnostic else { continue }
            let key = event.id + ":" + fact.kind.rawValue
            guard fact.at > (reportedHookDiagnostics[key] ?? .distantPast) else { continue }
            reportedHookDiagnostics[key] = fact.at
            appendDiagnostic(DiagnosticEntry(date: fact.at, issue: ClientIntegrationIssue(provider: event.provider, capability: .sessionCatalog,
                                                                                            reason: .unsupportedResponse), hook: fact))
        }
        if reportedHookDiagnostics.count > 512 {
            reportedHookDiagnostics = Dictionary(uniqueKeysWithValues: reportedHookDiagnostics.sorted { $0.value > $1.value }.prefix(256).map { ($0.key, $0.value) })
        }
    }
    private func suppressResolvedClaudeQuestions(_ events: [AgentSession], catalog: [AgentSession], now: Date) -> [AgentSession] {
        resolvedClaudeQuestions = resolvedClaudeQuestions.filter {
            let age = now.timeIntervalSince($0.value)
            return age >= -60 && age < 600
        }
        let confirmed = Dictionary(catalog.filter {
            $0.provider == .claude && $0.catalogHistory != true &&
                ![.idle, .unknown].contains($0.effectivePhase(now: now))
        }.map { ($0.id, $0.observedAt) }, uniquingKeysWith: max)
        return events.map { event in
            guard event.provider == .claude, event.phase == .input, event.responseRequestsInput == true else { return event }
            if let observed = confirmed[event.id], observed > event.observedAt {
                resolvedClaudeQuestions[event.id] = max(resolvedClaudeQuestions[event.id] ?? .distantPast, event.observedAt)
            }
            guard let resolved = resolvedClaudeQuestions[event.id], event.observedAt <= resolved else { return event }
            // Keep identity/title/history, but do not reuse the old question as
            // evidence of current waiting or successful completion of new work.
            var historical = event
            historical.phase = .unknown
            historical.responseRequestsInput = nil
            historical.runtimeConfirmed = false
            return historical
        }
    }

    func acceptSessions(_ rows: [AgentSession], now: Date? = nil) {
        let now = now ?? self.now()
        internalSessionIDs.formUnion(rows.filter { $0.isCodexSubagent == true || $0.isNestedClaudeSession == true }.map(\.id))
        internalSessionIDs.subtract(rows.filter { $0.provider == .claude && $0.isNestedClaudeSession == false }.map(\.id))
        // Starting a CLI to inspect its UI is not a task. Include it only once
        // a prompt, tool, response or request establishes actual task activity.
        let taskRows = rows.filter { providers.contains($0.provider) && !$0.isUnstartedClaudeLifecycle && !internalSessionIDs.contains($0.id) }
        // Keep history available to the panel without reporting retained state
        // as a current observation to activity tracking or Keep Awake.
        onObservation?(taskRows.filter { $0.catalogHistory != true }, now)
        do {
            try removeHiddenInternalSessions()
            // The local event timer usually delivers the first rows before the
            // catalogs; checking then would stamp the day without any evidence.
            if providers.allSatisfy(catalogSettled.contains),
               organizationCheckedAt.map({ now.timeIntervalSince($0) >= 86400 || now < $0 }) ?? true {
                try visibility?.pruneRemoved(now: now)
                // Only a provider whose current catalog arrived complete can prove absence.
                // Re-listed history is not presence: it must not keep a hidden entry
                // or an arrangement slot alive indefinitely (S-12).
                let complete = Set(providers.filter { catalog[$0] != nil && typedIssues[$0] == nil })
                try visibility?.observe(Set(rows.filter { $0.catalogHistory != true }.map(\.id)), completeProviders: complete, now: now)
                var next = arrangement
                if next.observe(Set(taskRows.filter { $0.catalogHistory != true }.map(\.id)), now: now) { try saveArrangement(next) }
                organizationCheckedAt = now
            }
            try visibility?.removeUnstartedClaudeLifecycles(rows)
            let restored = try visibility?.restoreNewTasks(taskRows, now: now) ?? []
            if let lastHidden, restored.contains(lastHidden.id) {
                undoDismissTask?.cancel(); self.lastHidden = nil
            }
            try hideInactiveSessions(taskRows, now: now)
        } catch { connectionMessage = error.localizedDescription }
        allSessions = taskRows; publishVisible(now: now)
        observations.send((sessions, now))
    }
    private func removeHiddenInternalSessions() throws {
        let hidden = internalSessionIDs.intersection(visibility?.hidden ?? [])
        if !hidden.isEmpty { try visibility?.removeHidden(hidden, now: now()) }
    }
    private func hideInactiveSessions(_ rows: [AgentSession], now: Date) throws {
        guard [5, 10, 20].contains(autoHideMinutes), let visibility else { return }
        let visible = visibility.visible(rows)
        let ids = Set(visible.map(\.id))
        inactiveSince = inactiveSince.filter { ids.contains($0.key) }
        for row in visible {
            // Never hide ongoing work, requests for input/permission, or an
            // unconfirmed state merely because its latest event is old.
            // Retained catalog history is never shown as current; it is not archived.
            guard row.catalogHistory != true, !row.phase.isActive, row.phase != .unknown, row.runtimeConfirmed != false,
                  !row.isUnstartedClaudeLifecycle else {
                inactiveSince.removeValue(forKey: row.id)
                continue
            }
            if inactiveSince[row.id] == nil {
                // Only a row the panel shows as current starts an interval: history,
                // stale entries and sessions that ended unseen do not fill the list.
                guard row.isCurrent(now: now) else { continue }
                inactiveSince[row.id] = min(row.updatedAt, now)
            }
            let since = max(inactiveSince[row.id]!, min(row.updatedAt, now))
            inactiveSince[row.id] = since
            if now.timeIntervalSince(since) >= Double(autoHideMinutes * 60) {
                try self.visibility?.hide(row, now: now)
                inactiveSince.removeValue(forKey: row.id)
            }
        }
    }
    func updateHookConfiguration() {
        publishHookConfiguration(dependencies.hooksState())
        var states: [ProviderID: ClientConnection.LocalState] = [:]
        for provider in ProviderID.allCases { states[provider] = dependencies.clientSetup(provider)?.inspect() }
        if connectionStates != states { connectionStates = states }
    }
    /// An unchanged state must not invalidate every observing view on each poll.
    private func publishHookConfiguration(_ state: [ProviderID: Bool]) {
        if hooksInstalled != state { hooksInstalled = state }
    }
    /// Launch maintenance (owner decisions 17 and 18): point the stable helper link
    /// at this copy, then move Lunavect's own entries that name another path to it.
    /// Removed events stay removed, paused (disableAllHooks) or unreadable settings
    /// are not written, and a translocated copy writes nothing and asks to be moved.
    private func repairMovedConnections() {
        guard dependencies.allowsClientConfiguration else { return }
        var notices: [SetupNotice] = []
        var translocated = false
        if let location = dependencies.helperLocation {
            translocated = location.isTranslocated
            do { try location.refreshLink() }
            catch { Self.connectionLog.error("Helper link not updated: \(String(describing: error), privacy: .public)") }
        }
        if translocated {
            notices.append(SetupNotice(message: L("macOS запустила Lunavect из временной копии. Перенесите Lunavect в папку «Программы» и откройте его оттуда: до этого команды подключений не обновляются."), warning: true))
        }
        var repaired: [ProviderID] = []
        if let setup = dependencies.clientSetup(.claude) {
            do { try SessionHooks.restrictOwnBackups(bridgeDirectory: setup.bridgeDirectory, backupDirectory: setup.backupDirectory) }
            catch { Self.connectionLog.error("Backup permissions not restricted: \(String(describing: error), privacy: .public)") }
        }
        for provider in providers {
            guard let setup = dependencies.clientSetup(provider) else { continue }
            do {
                if try setup.repair() == .repaired { repaired.append(provider) }
            } catch {
                connectionMessage = L("Не удалось восстановить подключение после переноса приложения. Откройте «Подключения» и повторите настройку.")
                    + " " + localConnectionSummary(setup.inspect())
            }
        }
        if !repaired.isEmpty {
            Self.connectionLog.notice("Moved Lunavect commands to the helper link: \(repaired.map(\.rawValue).joined(separator: ","), privacy: .public)")
            notices.append(SetupNotice(message: L("Команды Lunavect в настройках {0} обновлены: теперь они не зависят от расположения приложения.",
                                                  repaired.map(\.title).joined(separator: ", ")), warning: false))
        }
        let copies = translocated ? [] : dependencies.installedCopies()
        if !copies.isEmpty {
            notices.append(SetupNotice(message: L("Установлена ещё одна копия Lunavect: {0}. Оставьте одну копию, чтобы виджеты и подключения работали с ней.",
                                                  copies.map(\.path).joined(separator: ", ")), warning: true))
        }
        let warning = notices.contains(where: \.warning)
        setupNotice = notices.isEmpty ? nil : SetupNotice(message: notices.map(\.message).joined(separator: "\n"), warning: warning)
    }
    private static let connectionLog = Logger(subsystem: "com.weekleft.app", category: "connections")
    /// The provider's client configuration; nil in previews and tests without fixtures.
    func localSetup(_ provider: ProviderID) -> ClientConnection.LocalSetup? {
        dependencies.allowsClientConfiguration ? dependencies.clientSetup(provider) : nil
    }
    func disconnect(_ provider: ProviderID) -> Bool {
        guard dependencies.allowsClientConfiguration, let setup = dependencies.clientSetup(provider) else { return false }
        defer { updateHookConfiguration() }
        do {
            try setup.apply(.disconnect)
            eventsDisabledByUser.remove(provider)
            return true
        } catch {
            let state = (error as? ClientConnection.LocalFailure)?.state ?? setup.inspect()
            connectionMessage = L("Отключение не завершено. Повторите попытку, чтобы завершить оставшиеся шаги.")
                + " " + localConnectionSummary(state)
            return false
        }
    }
    private func localConnectionSummary(_ state: ClientConnection.LocalState) -> String {
        if let status = state.statusLine {
            return L("statusLine: {0}. События: {1}.", L(status.message), L(state.hooks.message))
        }
        return L("События: {0}.", L(state.hooks.message))
    }
    func toggleHooks(_ provider: ProviderID) {
        guard dependencies.allowsClientConfiguration, let setup = dependencies.clientSetup(provider) else { return }
        do {
            if hooksInstalled[provider] == true {
                try SessionHooks.remove(provider: provider, configURL: setup.configURL, backupDirectory: setup.backupDirectory)
                eventsDisabledByUser.insert(provider)
                connectionMessage = L("События {0} отключены. Остальные обработчики сохранены.", provider.title)
            } else {
                guard let executable = setup.executable else {
                    throw setup.translocated ? SessionError.translocated : SessionError.unavailable
                }
                try SessionHooks.install(provider: provider, executable: executable, configURL: setup.configURL,
                                         backupDirectory: setup.backupDirectory)
                eventsDisabledByUser.remove(provider)
                connectionMessage = provider == .codex
                    ? L("Обработчики добавлены. В Codex откройте /hooks и разрешите команды Lunavect. До первого события статус останется неизвестным.")
                    : L("Обработчики добавлены. События появятся при следующем действии в Claude Code; уже открытой сессии может потребоваться перезапуск.")
            }
        } catch { connectionMessage = error.localizedDescription }
        updateHookConfiguration()
    }
}

/// Callers share one in-flight read. Work the store started itself (timers,
/// file changes) ends only through invalidation; work callers requested ends
/// when every caller waiting for it has been cancelled.
final class SharedWorkDemand: Sendable {
    private let waiting = OSAllocatedUnfairLock(initialState: 0)
    let requested: Bool
    init(requested: Bool) { self.requested = requested }
    func join() { waiting.withLock { $0 += 1 } }
    /// A waiter was cancelled; true when nobody who requested the work still waits.
    func leave() -> Bool { waiting.withLock { $0 -= 1; return requested && $0 <= 0 } }
}

enum SessionNavigation {
    /// Test isolation (R2-N-02): under XCTest navigation never scripts, launches or
    /// connects to the user's applications, nor reads their Desktop session records,
    /// unless a test driving operator-owned fixtures opts in. A routing regression in
    /// a test then fails with this error instead of opening a real app.
    struct LiveSystemRefused: LocalizedError, Equatable {
        let action: String
        var errorDescription: String? { "Test isolation: refused \(action)" }
    }
    @MainActor static var allowsLiveSystemInTests = false {
        // Terminal focus runs osascript through SessionProcess (R2-X-03).
        didSet { allowsLiveSystemInTests ? LiveProcessGuard.allow(["/usr/bin/osascript"]) : LiveProcessGuard.disallow(["/usr/bin/osascript"]) }
    }
    @MainActor static func checkLiveSystem(_ action: String) throws {
        guard LiveWriteGuard.underTestsForStores, !allowsLiveSystemInTests else { return }
        fputs("LUNAVECT TEST ISOLATION: refused live navigation (\(action))\n", stderr)
        throw LiveSystemRefused(action: action)
    }
    /// `focus` is the only step that scripts another application; tests replace it.
    @MainActor static func open(_ session: AgentSession, resolver: ClientExecutableResolver = ClientExecutableResolver(),
                                focus: @MainActor (AgentSession) async throws -> Bool = { try await focusTerminal($0) },
                                openIDE: @MainActor (AgentSession) async throws -> Void = { try await focusIDE($0) }) async throws {
        try Task.checkCancellation()
        if session.ideLocation != nil || session.client == .vscode || session.client == .jetbrains {
            try await openIDE(session)
            return
        }
        if session.terminalFocusCandidate {
            let focused = try await focus(session)
            try Task.checkCancellation()
            if focused { return }
        }
        if session.client == .terminal || session.client == .background {
            let script = try session.terminalScript(resolver: resolver)
            var directoryExists: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directoryExists), directoryExists.boolValue else { throw SessionOpeningError.missingProject }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw SessionOpeningError.missingTerminal }
            let directory = SessionHooks.directory.appendingPathComponent("Openers")
            try LiveWriteGuard.check(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Best-effort: an old launcher that cannot be removed must not block opening.
            _ = try? SessionHooks.pruneOpeners(in: directory)
            let file = directory.appendingPathComponent(session.provider.rawValue + "-" + session.sessionID + ".command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) }
            catch { throw SessionOpeningError.launchFailed(session.client) }
            return
        }
        // Editor sessions returned above: every VS Code or JetBrains row uses its companion.
        try checkLiveSystem("desktop link")
        let url: URL?
        if session.provider == .codex { url = session.codexURL }
        else {
            let records = await Task.detached { ClaudeSessionMetadata.records(for: [session.sessionID]) }.value
            url = records[session.sessionID].flatMap { session.claudeDesktopURL(desktopID: $0.desktopID) }
        }
        guard let url else { throw session.provider == .claude ? SessionOpeningError.missingDesktopLink : SessionOpeningError.invalidID }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw SessionOpeningError.missingClient(session.provider.title) }
        guard NSWorkspace.shared.open(url) else { throw SessionOpeningError.launchFailed(session.client) }
    }
    @MainActor static func focusIDE(_ session: AgentSession) async throws {
        try checkLiveSystem("editor bridge")
        try await IDEBridge.open(session, activateApp: { pid in
            await MainActor.run { activateEditor(pid) }
        }) { url, app in
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return true
            } catch { return false }
        }
    }
    /// Activation is cooperative on macOS 14 and later: yield to the editor first.
    /// From a notification Lunavect itself may not be active, so the first request
    /// can be refused; a request on behalf of the current app is the second try.
    @MainActor static func activateEditor(_ pid: Int32) -> Bool {
        guard let editor = NSRunningApplication(processIdentifier: pid) else { return false }
        NSApp.yieldActivation(to: editor)
        if editor.activate() { return true }
        return editor.activate(from: NSRunningApplication.current, options: [])
    }
    /// A live CLI session stays where it runs: bring its own tab to the front.
    /// The policy lives in `TerminalLocation.focusSession`; only the running-app check needs AppKit.
    @MainActor static func focusTerminal(_ session: AgentSession) async throws -> Bool {
        try checkLiveSystem("terminal focus")
        let log = Logger(subsystem: "com.weekleft.app", category: "navigation")
        let environment = TerminalFocusEnvironment(isRunning: { bundle in
            await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }
        })
        do {
            let focused = try await TerminalLocation.focusSession(session, environment: environment)
            log.notice("terminal focus \(focused ? "succeeded" : "found no tab", privacy: .public)")
            return focused
        } catch {
            log.notice("terminal focus failed: tty=\(session.terminalTTY ?? "nil", privacy: .public) app=\(session.terminalApp ?? "nil", privacy: .public)")
            throw error
        }
    }
    // The pasteboard and opener are parameters so tests prove the refusal on a
    // private pasteboard and a recorder, never on the user's clipboard or Finder.
    @MainActor static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        guard (try? checkLiveSystem("clipboard")) != nil else { return }
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
    @MainActor static func openCodex(_ session: AgentSession, open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard (try? checkLiveSystem("codex link")) != nil else { return false }
        guard let url = session.codexURL else { return false }
        return open(url)
    }
    @MainActor static func revealProject(_ session: AgentSession, open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard (try? checkLiveSystem("reveal folder")) != nil else { return false }
        guard session.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: session.cwd) else { return false }
        return open(URL(fileURLWithPath: session.cwd))
    }
}

enum AppArtwork {
    private static func mark(named name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources")
        #else
        let url = Bundle.main.url(forResource: name, withExtension: "png")
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
    }
    static let brandMark = mark(named: "LunavectMark")
    static let brandMarkLeft = mark(named: "LunavectMarkLeft")
    static let brandMarkRight = mark(named: "LunavectMarkRight")
    static var icon: NSImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "LunavectTide", withExtension: "icns", subdirectory: "Resources")
        #else
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "LunavectTide"
        let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns")
        #endif
        return url.flatMap(NSImage.init(contentsOf:))
    }
}
