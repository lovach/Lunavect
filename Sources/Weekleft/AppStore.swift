import SwiftUI
import WidgetKit
import Network
import Combine
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// Optional composition seams; isolated stores always override external I/O.
@MainActor struct AppDataServices {
    let snapshots: SnapshotPersistence
    let activity: ActivityService
    var clock: () -> Date = Date.init
    var localQuota: @Sendable (Date) async -> UsageSnapshot? = { now in
        let reader = Task.detached(priority: .utility) { try? ClaudeProvider.latest(now: now) }
        return await withTaskCancellationHandler(operation: { await reader.value }, onCancel: { reader.cancel() })
    }
    var refreshQuota: ((ProviderID, String, Bool) async throws -> UsageSnapshot)? = nil
    /// When the Claude status line last reported (its saved receipt time).
    var statusLineObservedAt: @Sendable () -> Date? = { ClaudeProvider.statusLineObservedAt() }
    var scheduling = AppRefreshScheduling()
    var discoverCodex: @Sendable () -> String? = AppStore.discoverCodex
}

/// Cancel handles keep timers and system notifications replaceable in lifecycle
/// tests while exercising the production start/stop and generation guards.
@MainActor struct AppRefreshScheduling {
    var repeating: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> (() -> Void) = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    var wake: (@escaping @MainActor @Sendable () -> Void) -> (() -> Void) = { action in
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        return { center.removeObserver(observer) }
    }
    /// One-shot delay: wake settle, session-event debounce and the reset timer.
    var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> (() -> Void) = { delay, action in
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = min(5, max(0.1, delay / 20))
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var snapshots: [UsageSnapshot]
    @Published var preferences: WidgetPreferences {
        didSet {
            guard preferences != oldValue else { return }
            let changed = Set(preferences.providers).symmetricDifference(oldValue.providers)
            for id in changed { providerGenerations[id, default: 0] += 1; refreshPolicy.forget(id) }
            if !changed.isEmpty { activityService.setProviders(preferences.providers) }
            schedulePersistence()
        }
    }
    @Published var refreshing = false
    @Published var storageIssue: String?
    var activityHistory: ActivityHistory { activityService.history }
    var activityDetails: ActivityDetails { activityService.details }
    var activityIssue: String? { activityService.issue }
    var activityDetailsIssue: String? { activityService.detailsIssue }
    var importingActivity: Bool { activityService.importing }
    var activityUnavailable: Bool { activityService.unavailable }
    @Published var codexPath: String {
        didSet {
            guard codexPath != oldValue else { return }
            // A response from the previous executable is no longer an observation
            // of this connection, even if the user switches back before it arrives.
            providerGenerations[.codex, default: 0] += 1
            refreshPolicy.forget(.codex)
            if !isolated { defaults.set(codexPath, forKey: "codexPath") }
        }
    }
    private let snapshotPersistence: SnapshotPersistence?
    private let activityService: ActivityService
    private let clock: () -> Date
    private var appliedWrite = 0
    private var providerGenerations: [ProviderID: Int] = [:]
    private let localQuota: @Sendable (Date) async -> UsageSnapshot?
    private let refreshQuota: ((ProviderID, String, Bool) async throws -> UsageSnapshot)?
    private let statusLineReceipt: @Sendable () -> Date?
    private let scheduling: AppRefreshScheduling
    private let codexDiscovery: @Sendable () -> String?
    private var cancelTriggers: [() -> Void] = []
    private var backgroundRefresh: Task<Void, Never>?
    private var localRefresh: Task<Void, Never>?
    /// When each provider is asked for new quota data (QuotaRefreshPolicy).
    private var refreshPolicy = QuotaRefreshPolicy()
    private var lastSessionEvent: [ProviderID: Date] = [:]
    private var pendingEventProviders: Set<ProviderID> = []
    /// Automatic requests that arrived while a refresh ran; evaluated after it.
    private var deferredRequests: [(trigger: QuotaRefreshPolicy.Trigger, providers: Set<ProviderID>?)] = []
    private var cancelEventDebounce: (() -> Void)?
    private var cancelWakeSettle: (() -> Void)?
    private var cancelResetCheck: (() -> Void)?
    private var lifecycleGeneration = 0
    private var started = false
    private let preferenceWrites = DeferredWrite()
    private let savesChanges: Bool
    let isolated: Bool
    private let defaults: UserDefaults
    private let quotaFetcher: ((ProviderID, String) async throws -> UsageSnapshot)?
    let network: NetworkConnection
    private var networkObserver: AnyCancellable?
    private var activityObserver: AnyCancellable?
    var onNetworkRestored: (() async -> Void)?
    var providers: [ProviderID] { preferences.providers }
    /// Views build resolvers for every row on each render. Discovery (file checks
    /// and a Launch Services lookup) runs only when a caller actually resolves
    /// Codex, and an explicitly selected path still bypasses it.
    var clientResolver: ClientExecutableResolver {
        guard !isolated else { return ClientExecutableResolver(codexPath: codexPath, discoverCodex: { nil }) }
        return ClientExecutableResolver(codexPath: codexPath, discoverCodex: codexDiscovery)
    }
    init(state: SharedState? = nil, savesChanges: Bool = true,
         quotaFetcher: ((ProviderID, String) async throws -> UsageSnapshot)? = nil,
         network: NetworkConnection? = nil, activityHistory: ActivityHistory? = nil, activityDetails: ActivityDetails? = nil,
         isolated: Bool = false, defaults: UserDefaults = .standard, dataServices: AppDataServices? = nil) {
        self.isolated = isolated; self.defaults = defaults
        self.savesChanges = savesChanges && !isolated; self.quotaFetcher = quotaFetcher
        self.network = network ?? NetworkConnection()
        clock = dataServices?.clock ?? Date.init
        localQuota = dataServices?.localQuota ?? { @Sendable now in
            let worker = Task.detached(priority: .utility) { try? ClaudeProvider.latest(now: now) }
            return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        }
        refreshQuota = dataServices?.refreshQuota
        statusLineReceipt = dataServices?.statusLineObservedAt ?? { @Sendable in ClaudeProvider.statusLineObservedAt() }
        scheduling = dataServices?.scheduling ?? AppRefreshScheduling()
        codexDiscovery = dataServices?.discoverCodex ?? Self.discoverCodex
        snapshotPersistence = isolated ? nil : dataServices?.snapshots ?? SnapshotPersistence(reload: {
            WidgetReloadLedger.shared.noteRequest()
            WidgetCenter.shared.reloadTimelines(ofKind: "WeekleftWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectOverviewWidget")
        }, reloadActivity: {
            // Quota receipts do not change activity; its history saves reload it.
            WidgetReloadLedger.shared.noteRequest()
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectActivityWidget")
        })
        if isolated {
            activityService = ActivityService(history: activityHistory, details: activityDetails, isolated: true, clock: clock)
        } else {
            activityService = dataServices?.activity ?? ActivityService(history: activityHistory, details: activityDetails,
                storage: ActivityPersistence(reload: {
                    WidgetCenter.shared.reloadTimelines(ofKind: "LunavectActivityWidget")
                    WidgetCenter.shared.reloadTimelines(ofKind: "LunavectOverviewWidget")
                }), writesEnabled: self.savesChanges, clock: clock)
        }
        let saved = isolated ? "" : defaults.string(forKey: "codexPath") ?? ""
        codexPath = isolated ? "" : saved
        var loadedState = state ?? SharedState()
        if state == nil, let persistence = snapshotPersistence {
            let result = persistence.load(readOnly: !self.savesChanges)
            loadedState = result.state; storageIssue = result.issue
        }
        // A failed /usage without any saved reading leaves only its issue. Of that, only a
        // sign-in state is kept, so it stays visible after a restart (R26-V2-01).
        let signedOut = loadedState.snapshots.first { $0.provider == .claude && !ClaudeProvider.isTrustedSnapshot($0) }
            .flatMap(SignInAttention.init)
        loadedState.snapshots.removeAll { $0.provider == .claude && !ClaudeProvider.isTrustedSnapshot($0) }
        if loadedState.preferences.enabledProviders == nil {
            loadedState.preferences.migrateConnections(snapshots: loadedState.snapshots, configured: isolated ? [] : ProviderID.allCases.filter {
                SessionHooks.configured($0) || ($0 == .claude && ClaudeProvider.statusLineConfigured())
            })
        }
        if !loadedState.snapshots.contains(where: { $0.provider == .claude }) {
            loadedState.snapshots.append(UsageSnapshot(provider: .claude, issue: signedOut?.issue ?? UsageError.waitingForClaude.errorDescription))
        }
        snapshots = loadedState.snapshots; preferences = loadedState.preferences
        activityService.setProviders(preferences.providers)
        activityObserver = activityService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        networkObserver = self.network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.network.onRestored = { [weak self] in
            guard let self, self.started else { return }
            let generation = self.lifecycleGeneration
            while self.refreshing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, self.started, self.lifecycleGeneration == generation, !self.network.isOffline else { return }
            // A restored connection may have removed the cause of earlier failures.
            self.refreshPolicy.resetBackoff()
            await self.refresh(only: nil, trigger: .networkRestored)
            if !Task.isCancelled, self.started, self.lifecycleGeneration == generation { await self.onNetworkRestored?() }
        }
    }
    // Read-only executable discovery captures no store or UI state.
    nonisolated static let discoverCodex: @Sendable () -> String? = {
        if let path = CodexProvider.discoverCLI() { return path }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return nil }
        let path = app.appendingPathComponent("Contents/Resources/codex").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    func start() {
        guard !isolated, !started else { return }
        started = true
        network.start(); activityService.start(providers: providers)
        requestBackgroundRefresh(trigger: .launch)
        let generation = lifecycleGeneration
        cancelTriggers = [
            scheduling.repeating(5) { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.requestLocalRefresh()
            },
            // An evaluation tick: the policy decides whether any provider is due.
            scheduling.repeating(QuotaFreshness.evaluationTick) { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.requestBackgroundRefresh(trigger: .timer)
            },
            scheduling.wake { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.handleWake()
            }
        ]
        scheduleResetCheck()
    }
    /// The network needs a few seconds after wake. A connection that is still down
    /// reports its return through `network.onRestored` instead.
    private func handleWake() {
        guard started else { return }
        cancelWakeSettle?()
        let generation = lifecycleGeneration
        cancelWakeSettle = scheduling.after(refreshPolicy.timing.wakeSettle) { [weak self] in
            guard let self, self.started, self.lifecycleGeneration == generation else { return }
            self.cancelWakeSettle = nil
            guard !self.network.isOffline else { return }
            self.refreshPolicy.resetBackoff()
            self.requestBackgroundRefresh(trigger: .wake)
        }
    }
    /// A finished response changes the account's usage. Session rows from hooks and
    /// local events count; catalog rows (including Lunavect's own probe) do not.
    /// A burst is debounced into one evaluation after a quiet period.
    func observeSessionEvents(_ rows: [AgentSession], now: Date) {
        guard started else { return }
        var fresh: Set<ProviderID> = []
        for provider in providers {
            guard let latest = rows.filter({ $0.provider == provider && [.hook, .localEvent].contains($0.evidence) }).map(\.updatedAt).max() else { continue }
            let known = lastSessionEvent[provider]
            guard known.map({ latest > $0 }) ?? true else { continue }
            lastSessionEvent[provider] = latest
            refreshPolicy.noteEvent(provider, at: min(latest, now))
            // The first observation after launch is the baseline, not a new response.
            if known != nil { fresh.insert(provider) }
        }
        guard !fresh.isEmpty else { return }
        pendingEventProviders.formUnion(fresh)
        cancelEventDebounce?()
        let generation = lifecycleGeneration
        cancelEventDebounce = scheduling.after(refreshPolicy.timing.eventDebounce) { [weak self] in
            guard let self, self.started, self.lifecycleGeneration == generation else { return }
            self.cancelEventDebounce = nil
            let due = self.pendingEventProviders
            self.pendingEventProviders = []
            self.requestBackgroundRefresh(trigger: .sessionEvent, only: due)
        }
    }
    /// One confirming request at the earliest reset plus its grace, or at the end of
    /// the backoff while a passed reset is still unconfirmed.
    private func scheduleResetCheck() {
        cancelResetCheck?(); cancelResetCheck = nil
        guard started else { return }
        let now = clock()
        guard let date = refreshPolicy.nextCheck(snapshots.filter { providers.contains($0.provider) }, now: now) else { return }
        let generation = lifecycleGeneration
        cancelResetCheck = scheduling.after(date.timeIntervalSince(now)) { [weak self] in
            guard let self, self.started, self.lifecycleGeneration == generation else { return }
            self.cancelResetCheck = nil
            self.requestBackgroundRefresh(trigger: .resetDue)
        }
    }
    private func requestLocalRefresh() {
        guard started, localRefresh == nil, providers.contains(.claude) else { return }
        let generation = lifecycleGeneration, providerGeneration = providerGenerations[.claude, default: 0]
        localRefresh = Task { [weak self] in
            defer { if self?.lifecycleGeneration == generation { self?.localRefresh = nil } }
            guard !Task.isCancelled, self?.started == true, self?.lifecycleGeneration == generation,
                  self?.providers.contains(.claude) == true,
                  self?.providerGenerations[.claude, default: 0] == providerGeneration else { return }
            guard let reader = self?.localQuota, let now = self?.clock() else { return }
            let snapshot = await reader(now)
            guard let self, self.lifecycleGeneration == generation else { return }
            guard !Task.isCancelled, self.started, self.providers.contains(.claude),
                  self.providerGenerations[.claude, default: 0] == providerGeneration, var snapshot,
                  let index = self.snapshots.firstIndex(where: { $0.provider == .claude }) else { return }
            let current = self.snapshots[index]
            if Self.isSameReading(snapshot, current) {
                // The saved files hold the reading that is shown. Their windows are the
                // original: snapshot.json rewritten by an older copy of the app loses the
                // reset precision (R2-P-04). They do not know the failure of the latest
                // request, which stays with its mark (R2-Q-02).
                snapshot.issue = current.issue ?? snapshot.issue
                if snapshot.modelQuotas == nil { snapshot.modelQuotas = current.modelQuotas }
            } else {
                guard ClaudeProvider.preferredObservation([current, snapshot], now: self.clock()) == snapshot else { return }
            }
            guard snapshot != current else { return }
            self.snapshots[index] = snapshot; self.persist(); self.scheduleResetCheck()
        }
    }
    /// One observation of one source: the same observation time.
    private static func isSameReading(_ lhs: UsageSnapshot, _ rhs: UsageSnapshot) -> Bool {
        lhs.provider == rhs.provider && lhs.source == rhs.source && lhs.fetchedAt != nil && lhs.fetchedAt == rhs.fetchedAt
    }
    /// An automatic evaluation. One that arrives while a refresh runs is kept and
    /// evaluated after it: that refresh may not have included its provider.
    private func requestBackgroundRefresh(trigger: QuotaRefreshPolicy.Trigger, only providers: Set<ProviderID>? = nil) {
        deferRequest(trigger, providers)
        runDeferredRequests()
    }
    private func deferRequest(_ trigger: QuotaRefreshPolicy.Trigger, _ providers: Set<ProviderID>?) {
        guard started else { return }
        guard let index = deferredRequests.firstIndex(where: { $0.trigger == trigger }) else {
            deferredRequests.append((trigger, providers)); return
        }
        // nil asks about every provider.
        deferredRequests[index].providers = deferredRequests[index].providers.flatMap { old in providers.map { old.union($0) } }
    }
    private func runDeferredRequests() {
        guard started, backgroundRefresh == nil, !refreshing, !deferredRequests.isEmpty else { return }
        let requests = deferredRequests
        deferredRequests = []
        let generation = lifecycleGeneration
        backgroundRefresh = Task { [weak self] in
            for request in requests {
                guard !Task.isCancelled, self?.started == true, self?.lifecycleGeneration == generation else { break }
                await self?.refresh(only: request.providers, trigger: request.trigger)
            }
            guard let self, self.lifecycleGeneration == generation else { return }
            self.backgroundRefresh = nil
            self.runDeferredRequests()
        }
    }
    /// No quota request is running or waiting to run. Tests wait for this (with a
    /// deadline) instead of yielding a fixed number of times.
    var quotaRefreshIdle: Bool {
        !refreshing && backgroundRefresh == nil && deferredRequests.isEmpty && localRefresh == nil && !network.recoveryPending
    }
    func stop() {
        started = false; lifecycleGeneration += 1
        cancelTriggers.forEach { $0() }; cancelTriggers.removeAll()
        for cancel in [cancelEventDebounce, cancelWakeSettle, cancelResetCheck] { cancel?() }
        cancelEventDebounce = nil; cancelWakeSettle = nil; cancelResetCheck = nil
        pendingEventProviders = []; deferredRequests = []; lastSessionEvent = [:]; refreshPolicy = QuotaRefreshPolicy()
        backgroundRefresh?.cancel(); backgroundRefresh = nil
        localRefresh?.cancel(); localRefresh = nil
        refreshing = false; network.stop()
        preferenceWrites.cancel()
        if savesChanges, let persistence = snapshotPersistence {
            apply(persistence.flush(SharedState(snapshots: snapshots, preferences: preferences)))
        }
        activityService.stop()
    }
    /// What an explicit refresh did, so a control can say why nothing happened (R2-U-03).
    enum RefreshOutcome: Equatable {
        /// The providers were asked (or none is connected).
        case asked
        /// No network: the request waits for the connection.
        case offline
        /// Another request runs; this one is evaluated after it.
        case running
        /// Every requested provider was asked less than 30 s ago; asking is possible again at this moment.
        case tooSoon(until: Date)
    }
    /// `force` is an explicit request (at most once per 30 s per provider);
    /// otherwise the refresh policy decides which providers are due.
    @discardableResult
    func refresh(provider requestedProvider: ProviderID? = nil, force: Bool = true) async -> RefreshOutcome {
        let requested = requestedProvider.map { Set([$0]) }
        let trigger: QuotaRefreshPolicy.Trigger = force ? .manual : .timer
        var outcome = RefreshOutcome.asked
        if network.isOffline { outcome = .offline }
        else if refreshing { outcome = .running }
        else if force {
            let now = clock()
            let asked = providers.filter { requested?.contains($0) ?? true }
            let waits = asked.compactMap { refreshPolicy.manualRetryDate($0, now: now) }
            if !asked.isEmpty, waits.count == asked.count, let until = waits.min() { outcome = .tooSoon(until: until) }
        }
        await refresh(only: requested, trigger: trigger)
        return outcome
    }
    /// When the Claude status line last reported; an isolated store reads no live file (R2-U-04).
    func statusLineObservedAt() -> Date? { isolated ? nil : statusLineReceipt() }
    func refresh(only requested: Set<ProviderID>?, trigger: QuotaRefreshPolicy.Trigger) async {
        guard !Task.isCancelled, !network.isOffline else { return }
        // One refresh at a time; a request during it is evaluated afterwards.
        guard !refreshing else { deferRequest(trigger, requested); return }
        let now = clock()
        let due = Set(providers.filter { id in
            (requested?.contains(id) ?? true)
                && refreshPolicy.shouldFetch(id, snapshot: snapshots.first { $0.provider == id }, trigger: trigger, now: now)
        })
        guard !due.isEmpty else { scheduleResetCheck(); return }
        refreshing = true
        let generation = lifecycleGeneration, selectedGenerations = providerGenerations
        defer { if lifecycleGeneration == generation { refreshing = false; runDeferredRequests() } }
        let path = codexPath
        async let codex = fetchIfEnabled(.codex, path: path, due: due)
        async let claude = fetchIfEnabled(.claude, path: path, due: due)
        for (id, result) in await [(ProviderID.codex, codex), (.claude, claude)] {
            guard !Task.isCancelled, lifecycleGeneration == generation else { return }
            guard providers.contains(id), providerGenerations[id, default: 0] == selectedGenerations[id, default: 0], let result else { continue }
            let index = snapshots.firstIndex { $0.provider == id }
            switch result {
            case .success(let snapshot):
                // Claude's fallback returns the saved observation with the failure as its issue.
                let reason = ClientIntegrationIssue.legacy(snapshot.issue, provider: id, capability: Self.quotaCapability(id))?.reason
                refreshPolicy.record(id, snapshot: snapshot, succeeded: snapshot.issue == nil, reason: reason, at: clock())
                if let index {
                    // The local reader may publish a newer Claude observation while a slower
                    // provider keeps this refresh open. A delayed fallback must not roll it back.
                    let current = snapshots[index]
                    if id == .claude, let shown = current.fetchedAt, let incoming = snapshot.fetchedAt, shown > incoming,
                       ClaudeProvider.preferredObservation([snapshot, current], now: clock()) == current { continue }
                    if current != snapshot { snapshots[index] = snapshot }
                }
                else { snapshots.append(snapshot) }
            case .failure(let error):
                if !(error is CancellationError) {
                    let reason = ClientIntegrationIssue.classify(error, provider: id, capability: Self.quotaCapability(id))?.reason
                    refreshPolicy.record(id, snapshot: index.map { snapshots[$0] }, succeeded: false, reason: reason, at: clock())
                }
                guard !network.isOffline else { continue }
                let message = (error as? ClientIntegrationIssue)?.message
                    ?? (error as? UsageError)?.errorDescription ?? (error as? SessionOpeningError)?.errorDescription
                    ?? "Не удалось обновить данные. Проверьте подключение к интернету."
                if let index {
                    if snapshots[index].issue != message { snapshots[index].issue = message }
                } else { snapshots.append(UsageSnapshot(provider: id, issue: message)) }
            }
        }
        persist()
        scheduleResetCheck()
    }
    private static func quotaCapability(_ id: ProviderID) -> ClientIntegrationIssue.Capability { id == .claude ? .usageProbe : .rateLimits }
    private func fetchIfEnabled(_ id: ProviderID, path: String, due: Set<ProviderID>) async -> Result<UsageSnapshot, Error>? {
        guard !Task.isCancelled, providers.contains(id), due.contains(id) else { return nil }
        guard !isolated || quotaFetcher != nil else { return nil }
        let resolver = clientResolver
        // The policy has decided: the provider is asked now.
        return await Self.capture {
            if let quotaFetcher { return try await quotaFetcher(id, path) }
            if let refreshQuota { return try await refreshQuota(id, path, true) }
            if id == .codex { return try await CodexProvider.fetch(resolver: resolver) }
            return try await ClaudeProvider.refresh()
        }
    }
    func setProvider(_ id: ProviderID, enabled: Bool) {
        var next = Set(providers)
        if enabled { next.insert(id) } else { next.remove(id) }
        preferences.enabledProviders = ProviderID.allCases.filter { next.contains($0) }
    }
    // The operation captures actor-owned injected services. Keep that orchestration
    // on the store's actor; the providers own their detached process/I/O work.
    private static func capture(_ operation: @MainActor () async throws -> UsageSnapshot) async -> Result<UsageSnapshot, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    func observeActivity(_ rows: [AgentSession], now: Date? = nil) { activityService.observe(rows, now: now) }
    func flushActivity(now: Date? = nil) { activityService.flush(now: now) }
    func importActivityHistory() { activityService.requestImport() }
    /// Only the statistics page's explicit button keeps an unreadable history aside.
    func startOverActivityHistory() { activityService.startOverPreservingHistory() }
    private func schedulePersistence() {
        guard savesChanges else { return }
        preferenceWrites.schedule { [weak self] in self?.persist() }
    }
    private func persist() {
        preferenceWrites.cancel()
        guard savesChanges, let persistence = snapshotPersistence else { return }
        persistence.submit(SharedState(snapshots: snapshots, preferences: preferences)) { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }
    private func apply(_ result: SnapshotPersistence.WriteResult) {
        guard result.sequence >= appliedWrite else { return }
        appliedWrite = result.sequence
        if storageIssue != result.issue { storageIssue = result.issue }
    }
    func subscriptionBinding(_ id: ProviderID) -> Binding<Date> {
        Binding(get: {
            let value = self.preferences.subscriptionDates[id.rawValue] ?? ""
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: value) ?? self.clock()
        }, set: { date in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            self.preferences.subscriptionDates[id.rawValue] = f.string(from: date)
        })
    }
}

/// Coalesces a burst of preference edits; shutdown synchronously flushes the final value.
@MainActor final class DeferredWrite {
    private let delay: Duration
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?
    init(delay: Duration = .milliseconds(200)) { self.delay = delay }
    func schedule(_ write: @escaping () -> Void) {
        cancel(); pending = write
        let delay = delay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        let write = pending
        cancel()
        write?()
    }
    func cancel() { task?.cancel(); task = nil; pending = nil }
    deinit { task?.cancel() }
}

@MainActor final class NetworkConnection: ObservableObject {
    enum State { case unknown, online, offline }
    @Published private(set) var state: State = .unknown
    @Published private(set) var restoring = false
    /// When the Mac lost its network path; rows wait a moment before saying so.
    @Published private(set) var offlineSince: Date?
    var isOffline: Bool { state == .offline }
    var onRestored: (() async -> Void)?
    /// A restored connection is settling or being handled by `onRestored`.
    private(set) var recoveryPending = false
    private var monitor: NWPathMonitor?
    private var recovery: Task<Void, Never>?
    private var recoveryToken = 0
    private var generation = 0
    private let settle: () async throws -> Void
    private let makeMonitor: () -> NWPathMonitor?
    init(settle: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
         makeMonitor: @escaping () -> NWPathMonitor? = { NWPathMonitor() }) {
        self.settle = settle; self.makeMonitor = makeMonitor
    }
    func start() {
        guard monitor == nil, let monitor = makeMonitor() else { return }
        self.monitor = monitor
        let generation = generation
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.update(available: available)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.weekleft.network"))
    }
    func stop() {
        generation += 1
        monitor?.cancel(); monitor = nil
        recovery?.cancel(); recovery = nil
        restoring = false; recoveryPending = false
    }
    func update(available: Bool) {
        let next: State = available ? .online : .offline
        guard state != next else { return }
        let wasOffline = isOffline
        state = next; recovery?.cancel(); restoring = false; recoveryPending = false
        offlineSince = available ? nil : Date()
        guard wasOffline, available else { return }
        recoveryToken += 1
        let token = recoveryToken
        recoveryPending = true
        recovery = Task { [weak self] in
            defer { if self?.recoveryToken == token { self?.recoveryPending = false } }
            guard let self else { return }
            do { try await settle() } catch { return }
            guard !Task.isCancelled, !isOffline else { return }
            restoring = true
            await onRestored?()
            if !Task.isCancelled { restoring = false }
        }
    }
    deinit { monitor?.cancel(); recovery?.cancel() }
}

struct NetworkStatusView: View {
    @ObservedObject var network: NetworkConnection
    var body: some View {
        if network.isOffline || network.restoring {
            HStack(spacing: 8) {
                if network.restoring { ProgressView().controlSize(.small) }
                else { InterfaceIcon(.info, size: 15) }
                Text(L(network.isOffline ? "Ждём соединение. Данные обновятся автоматически." : "Соединение вернулось. Обновляем данные…"))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("network-status")
        }
    }
}
