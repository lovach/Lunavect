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
    var scheduling = AppRefreshScheduling()
    var discoverCodex: () -> String? = AppStore.discoverCodex
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
}

@MainActor final class AppStore: ObservableObject {
    @Published var snapshots: [UsageSnapshot]
    @Published var preferences: WidgetPreferences {
        didSet {
            guard preferences != oldValue else { return }
            let changed = Set(preferences.providers).symmetricDifference(oldValue.providers)
            for id in changed { providerGenerations[id, default: 0] += 1 }
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
        didSet { if !isolated, codexPath != oldValue { defaults.set(codexPath, forKey: "codexPath") } }
    }
    private let snapshotPersistence: SnapshotPersistence?
    private let activityService: ActivityService
    private let clock: () -> Date
    private var appliedWrite = 0
    private var providerGenerations: [ProviderID: Int] = [:]
    private let localQuota: @Sendable (Date) async -> UsageSnapshot?
    private let refreshQuota: ((ProviderID, String, Bool) async throws -> UsageSnapshot)?
    private let scheduling: AppRefreshScheduling
    private let codexDiscovery: () -> String?
    private var cancelTriggers: [() -> Void] = []
    private var backgroundRefresh: Task<Void, Never>?
    private var localRefresh: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var started = false
    private let preferenceWrites = DeferredWrite()
    private let savesChanges: Bool
    private let isolated: Bool
    private let defaults: UserDefaults
    private let quotaFetcher: ((ProviderID, String) async throws -> UsageSnapshot)?
    let network: NetworkConnection
    private var networkObserver: AnyCancellable?
    private var activityObserver: AnyCancellable?
    var onNetworkRestored: (() async -> Void)?
    var providers: [ProviderID] { preferences.providers }
    var clientResolver: ClientExecutableResolver {
        let automaticPath = !isolated && codexPath.isEmpty ? codexDiscovery() : nil
        return ClientExecutableResolver(codexPath: codexPath, discoverCodex: { automaticPath })
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
        scheduling = dataServices?.scheduling ?? AppRefreshScheduling()
        codexDiscovery = dataServices?.discoverCodex ?? Self.discoverCodex
        snapshotPersistence = isolated ? nil : dataServices?.snapshots ?? SnapshotPersistence(reload: {
            WidgetCenter.shared.reloadTimelines(ofKind: "WeekleftWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectActivityWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectOverviewWidget")
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
        loadedState.snapshots.removeAll { $0.provider == .claude && !ClaudeProvider.isTrustedSnapshot($0) }
        if loadedState.preferences.enabledProviders == nil {
            loadedState.preferences.migrateConnections(snapshots: loadedState.snapshots, configured: isolated ? [] : ProviderID.allCases.filter {
                SessionHooks.configured($0) || ($0 == .claude && ClaudeProvider.statusLineConfigured())
            })
        }
        if !loadedState.snapshots.contains(where: { $0.provider == .claude }) {
            loadedState.snapshots.append(UsageSnapshot(provider: .claude, issue: UsageError.waitingForClaude.errorDescription))
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
            await self.refresh(force: false)
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
        requestBackgroundRefresh(force: false)
        let generation = lifecycleGeneration
        cancelTriggers = [
            scheduling.repeating(5) { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.requestLocalRefresh()
            },
            scheduling.repeating(300) { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.requestBackgroundRefresh(force: false)
            },
            scheduling.wake { [weak self] in
                guard self?.lifecycleGeneration == generation else { return }
                self?.requestBackgroundRefresh(force: false)
            }
        ]
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
                  self.providerGenerations[.claude, default: 0] == providerGeneration, let snapshot,
                  let index = self.snapshots.firstIndex(where: { $0.provider == .claude }),
                  snapshot != self.snapshots[index],
                  ClaudeProvider.preferredObservation([self.snapshots[index], snapshot], now: self.clock()) == snapshot else { return }
            self.snapshots[index] = snapshot; self.persist()
        }
    }
    private func requestBackgroundRefresh(force: Bool) {
        guard started, backgroundRefresh == nil else { return }
        let generation = lifecycleGeneration
        backgroundRefresh = Task { [weak self] in
            guard !Task.isCancelled, self?.started == true, self?.lifecycleGeneration == generation else { return }
            await self?.refresh(force: force)
            if self?.lifecycleGeneration == generation { self?.backgroundRefresh = nil }
        }
    }
    func stop() {
        started = false; lifecycleGeneration += 1
        cancelTriggers.forEach { $0() }; cancelTriggers.removeAll()
        backgroundRefresh?.cancel(); backgroundRefresh = nil
        localRefresh?.cancel(); localRefresh = nil
        refreshing = false; network.stop()
        preferenceWrites.cancel()
        if savesChanges, let persistence = snapshotPersistence {
            apply(persistence.flush(SharedState(snapshots: snapshots, preferences: preferences)))
        }
        activityService.stop()
    }
    func refresh(provider requestedProvider: ProviderID? = nil, force: Bool = true) async {
        guard !Task.isCancelled, !refreshing, !network.isOffline else { return }; refreshing = true
        let generation = lifecycleGeneration, selectedGenerations = providerGenerations
        defer { if lifecycleGeneration == generation { refreshing = false } }
        let path = codexPath
        async let codex = fetchIfEnabled(.codex, path: path, requested: requestedProvider, force: force)
        async let claude = fetchIfEnabled(.claude, path: path, requested: requestedProvider, force: force)
        for (id, result) in await [(ProviderID.codex, codex), (.claude, claude)] {
            guard !Task.isCancelled, lifecycleGeneration == generation else { return }
            guard providers.contains(id), providerGenerations[id, default: 0] == selectedGenerations[id, default: 0], let result else { continue }
            let index = snapshots.firstIndex { $0.provider == id }
            switch result {
            case .success(let snapshot):
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
    }
    private func fetchIfEnabled(_ id: ProviderID, path: String, requested: ProviderID?, force: Bool) async -> Result<UsageSnapshot, Error>? {
        guard !Task.isCancelled, providers.contains(id), requested == nil || requested == id else { return nil }
        guard !isolated || quotaFetcher != nil else { return nil }
        let resolver = clientResolver
        return await Self.capture {
            if let quotaFetcher { return try await quotaFetcher(id, path) }
            if let refreshQuota { return try await refreshQuota(id, path, force) }
            if id == .codex { return try await CodexProvider.fetch(resolver: resolver) }
            return try await ClaudeProvider.refresh(force: force)
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
    var isOffline: Bool { state == .offline }
    var onRestored: (() async -> Void)?
    private var monitor: NWPathMonitor?
    private var recovery: Task<Void, Never>?
    private var generation = 0
    private let settle: () async throws -> Void
    private let makeMonitor: () -> NWPathMonitor?
    init(settle: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
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
        restoring = false
    }
    func update(available: Bool) {
        let next: State = available ? .online : .offline
        guard state != next else { return }
        let wasOffline = isOffline
        state = next; recovery?.cancel(); restoring = false
        guard wasOffline, available else { return }
        recovery = Task { [weak self] in
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
