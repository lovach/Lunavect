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
        var hooksState: () -> [ProviderID: Bool] = { [:] }
        var initialEvents: (URL) -> [AgentSession] = { _ in [] }
        var schedulesTimers = false
        var watchesEvents = false
        var allowsClientConfiguration = false
        /// Hands a manually selected client executable to runtime observation.
        var configureRuntime: (ClientExecutableResolver) async -> Void = { _ in }

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
                 initialEvents: { CodexSessionMetadata.markingSubagents(in: SessionHooks.load(at: $0)) }, schedulesTimers: true, watchesEvents: true, allowsClientConfiguration: true,
                 configureRuntime: { resolver in
                     // Automatic discovery is already checked by the runtime reader itself.
                     await CodexActivityReader.shared.useExecutable(resolver.codexPath.isEmpty ? nil : resolver.codexPath)
                 })
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
    }
    /// Fixed codes only; bounded and local to this store's lifetime.
    @Published private(set) var diagnosticEntries: [DiagnosticEntry] = []
    @Published var hooksInstalled: [ProviderID: Bool] = [:]
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
        self.dependencies = dependencies ?? (isolated ? Dependencies() : .live(directory: base))
        if isolated { resolveClient = { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) } }
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
    private var panelVisible = false
    private var polling: SessionPolling?
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
        eventTask?.cancel(); eventTask = nil; eventID = nil
    }
    private func invalidateWork() {
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
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
    }
    isolated deinit {
        refreshTask?.cancel(); eventTask?.cancel(); undoDismissTask?.cancel()
        localTimer?.invalidate(); sourceTimer?.invalidate(); eventWatcher?.cancel()
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
                self.beginEvents()
            }
        }
        watcher.setCancelHandler { close(fd) }
        eventWatcher = watcher; watcher.resume()
    }
    @discardableResult private func beginRefresh() -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        if let refreshTask { return refreshTask }
        let current = generation, id = UUID()
        refreshing = true; refreshID = id
        lastCatalogPollAt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: current)
            if self.refreshID == id { self.refreshTask = nil; self.refreshID = nil; self.refreshing = false }
        }
        refreshTask = task
        return task
    }
    func refresh() async {
        guard let task = beginRefresh() else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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
        updateHookConfiguration()
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
    @discardableResult private func beginEvents() -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        // Freshness belongs to the display clock, not source success. Keep menu
        // subscribers in sync even while a read is pending or repeatedly fails.
        // Do this before coalescing reads; the background timer still has to age
        // the last observation without starting another source operation.
        publishVisible()
        if let eventTask { return eventTask }
        let current = generation, id = UUID()
        eventID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performReadEvents(generation: current)
            if self.eventID == id { self.eventTask = nil; self.eventID = nil }
        }
        eventTask = task
        return task
    }
    func readEvents() async {
        guard let task = beginEvents() else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performReadEvents(generation expected: UInt64) async {
        guard isCurrent(expected) else { return }
        guard !providers.isEmpty else { acceptSessions([]); return }
        let rows = catalog.values.flatMap { $0 }
        do {
            let events = try await dependencies.events(rows, providers, now())
            guard isCurrent(expected) else { return }
            let date = now()
            let currentEvents = suppressResolvedClaudeQuestions(events.filter { providers.contains($0.provider) }, catalog: rows, now: date)
            var merged = SessionList.merge(catalog: rows, events: currentEvents, now: date)
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
        diagnosticEntries.append(DiagnosticEntry(date: now(), issue: issue))
        if diagnosticEntries.count > 32 { diagnosticEntries.removeFirst(diagnosticEntries.count - 32) }
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
            if organizationCheckedAt.map({ now.timeIntervalSince($0) >= 86400 || now < $0 }) ?? true {
                try visibility?.pruneRemoved(now: now)
                var next = arrangement
                if next.observe(Set(taskRows.map(\.id)), now: now) { try saveArrangement(next) }
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
            guard !row.phase.isActive, row.phase != .unknown, row.runtimeConfirmed != false,
                  !row.isUnstartedClaudeLifecycle else {
                inactiveSince.removeValue(forKey: row.id)
                continue
            }
            if inactiveSince[row.id] == nil {
                // Historical catalog entries must not flood the hidden list.
                guard row.effectivePhase(now: now) != .unknown else { continue }
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
        hooksInstalled = dependencies.hooksState()
    }
    private func repairMovedConnections() {
        guard dependencies.allowsClientConfiguration else { return }
        guard let executable = SessionHooks.monitorExecutable() else { return }
        for provider in providers {
            let setup = ClientConnection.LocalSetup(provider: provider, executable: executable)
            do {
                if SessionHooks.configured(provider), !SessionHooks.installed(provider) {
                    try SessionHooks.install(provider: provider, executable: executable)
                }
                if provider == .claude, ClaudeProvider.statusLineConfigured(), !ClaudeProvider.statusLineInstalled() {
                    try ClaudeProvider.installStatusLine(executable: executable)
                }
            } catch {
                connectionMessage = L("Не удалось восстановить подключение после переноса приложения. Откройте «Подключения» и повторите настройку.")
                    + " " + localConnectionSummary(setup.inspect())
            }
        }
    }
    func disconnect(_ provider: ProviderID) -> Bool {
        guard dependencies.allowsClientConfiguration else { return false }
        let setup = ClientConnection.LocalSetup(provider: provider)
        defer { updateHookConfiguration() }
        do {
            try setup.apply(.disconnect)
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
        guard dependencies.allowsClientConfiguration else { return }
        do {
            if hooksInstalled[provider] == true {
                try SessionHooks.remove(provider: provider)
                connectionMessage = L("События {0} отключены. Остальные обработчики сохранены.", provider.title)
            } else {
                guard let executable = SessionHooks.monitorExecutable() else { throw SessionError.unavailable }
                try SessionHooks.install(provider: provider, executable: executable)
                connectionMessage = provider == .codex
                    ? L("Обработчики добавлены. В Codex откройте /hooks и разрешите команды Lunavect. До первого события статус останется неизвестным.")
                    : L("Обработчики добавлены. События появятся при следующем действии в Claude Code; уже открытой сессии может потребоваться перезапуск.")
            }
        } catch { connectionMessage = error.localizedDescription }
        updateHookConfiguration()
    }
}

enum SessionNavigation {
    /// `focus` is the only step that scripts another application; tests replace it.
    @MainActor static func open(_ session: AgentSession, resolver: ClientExecutableResolver = ClientExecutableResolver(),
                                focus: @MainActor (AgentSession) -> Bool = { focusTerminal($0) }) async throws {
        if session.terminalFocusCandidate, focus(session) { return }
        if session.client == .terminal || session.client == .background {
            let script = try session.terminalScript(resolver: resolver)
            var directoryExists: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directoryExists), directoryExists.boolValue else { throw SessionOpeningError.missingProject }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw SessionOpeningError.missingTerminal }
            let directory = SessionHooks.directory.appendingPathComponent("Openers")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(session.provider.rawValue + "-" + session.sessionID + ".command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) }
            catch { throw SessionOpeningError.launchFailed(session.client) }
            return
        }
        let url: URL?
        if session.provider == .codex { url = session.codexURL }
        else if session.client == .vscode { url = session.vscodeURL }
        else {
            let records = await Task.detached { ClaudeSessionMetadata.records(for: [session.sessionID]) }.value
            url = records[session.sessionID].flatMap { session.claudeDesktopURL(desktopID: $0.desktopID) }
        }
        guard let url else { throw session.provider == .claude && session.client != .vscode ? SessionOpeningError.missingDesktopLink : SessionOpeningError.invalidID }
        let clientName = session.client == .vscode ? "VS Code" : session.provider.title
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw SessionOpeningError.missingClient(clientName) }
        guard NSWorkspace.shared.open(url) else { throw SessionOpeningError.launchFailed(session.client) }
    }
    /// A live CLI session stays where it runs: bring its own tab to the front.
    @MainActor static func focusTerminal(_ session: AgentSession) -> Bool {
        let log = Logger(subsystem: "com.weekleft.app", category: "navigation")
        // Scripting a terminal that is not running would launch it with no tab to show.
        guard let target = TerminalLocation.focusTarget(for: session),
              let bundle = TerminalLocation.bundleIdentifier(forApp: target.app),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
              let source = TerminalLocation.focusScript(tty: target.tty, app: target.app),
              let script = NSAppleScript(source: source) else {
            log.notice("terminal focus unavailable: tty=\(session.terminalTTY ?? "nil", privacy: .public) app=\(session.terminalApp ?? "nil", privacy: .public)")
            return false
        }
        var error: NSDictionary?
        let focused = script.executeAndReturnError(&error).booleanValue && error == nil
        log.notice("terminal focus \(focused ? "succeeded" : "failed", privacy: .public) \(error?.description ?? "", privacy: .public)")
        return focused
    }
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @MainActor static func openCodex(_ session: AgentSession) -> Bool {
        guard let url = session.codexURL else { return false }
        return NSWorkspace.shared.open(url)
    }
    @MainActor static func revealProject(_ session: AgentSession) -> Bool {
        guard session.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: session.cwd) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
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
