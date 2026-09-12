import SwiftUI
import WidgetKit
import Network
import Combine
#if SWIFT_PACKAGE
import WeekleftCore
#endif

@MainActor final class AppStore: ObservableObject {
    @Published var snapshots: [UsageSnapshot]
    @Published var preferences: WidgetPreferences { didSet { persist() } }
    @Published var refreshing = false
    @Published var storageIssue: String?
    @Published private(set) var activityHistory = ActivityHistory()
    @Published private(set) var activityIssue: String?
    @Published private(set) var importingActivity = false
    @Published private(set) var activityDetails = ActivityDetails()
    @Published private(set) var activityDetailsIssue: String?
    private var detailsLoaded = false
    private var snapshotWritable = true
    private var storageRecoveryIssue: String?
    private var activityRecoveryIssue: String?
    private var detailsRecoveryIssue: String?
    private var activityTracker = ActivityTracker()
    private var activityLoaded = false
    var activityUnavailable: Bool { !activityLoaded }
    private var activitySavedAt = Date.distantPast
    private var pendingActivityImport = false
    @Published var codexPath: String { didSet { UserDefaults.standard.set(codexPath, forKey: "codexPath") } }
    private var refreshTimer: Timer?
    private var localTimer: Timer?
    private let savesChanges: Bool
    private let quotaFetcher: ((ProviderID, String) async throws -> UsageSnapshot)?
    let network: NetworkConnection
    private var networkObserver: AnyCancellable?
    var onNetworkRestored: (() async -> Void)?
    var providers: [ProviderID] { preferences.providers }
    init(state: SharedState? = nil, savesChanges: Bool = true,
         quotaFetcher: ((ProviderID, String) async throws -> UsageSnapshot)? = nil,
         network: NetworkConnection? = nil, activityHistory: ActivityHistory? = nil, activityDetails: ActivityDetails? = nil) {
        self.savesChanges = savesChanges; self.quotaFetcher = quotaFetcher
        self.network = network ?? NetworkConnection()
        let saved = UserDefaults.standard.string(forKey: "codexPath") ?? ""
        codexPath = FileManager.default.isExecutableFile(atPath: saved) ? saved : Self.discoverCodex() ?? ""
        var loadedState = state ?? SharedState()
        if state == nil {
            if savesChanges {
                do {
                    let result = try SnapshotStore.loadRecovering()
                    loadedState = result.value
                    if result.backupURL != nil { storageRecoveryIssue = "Повреждённый файл настроек сохранён отдельно. Доступные настройки восстановлены." }
                } catch {
                    snapshotWritable = false
                    storageRecoveryIssue = "Не удалось прочитать настройки. Исходный файл сохранён; запись отключена до перезапуска."
                }
            } else { loadedState = SnapshotStore.load() }
        }
        snapshots = loadedState.snapshots; preferences = loadedState.preferences
        storageIssue = storageRecoveryIssue
        snapshots.removeAll { $0.provider == .claude && !ClaudeProvider.isTrustedSnapshot($0) }
        preferences.migrateConnections(snapshots: snapshots, configured: ProviderID.allCases.filter {
            SessionHooks.configured($0) || ($0 == .claude && ClaudeProvider.statusLineConfigured())
        })
        snapshots.append(contentsOf: snapshots.contains(where: { $0.provider == .claude }) ? [] : [UsageSnapshot(provider: .claude, issue: UsageError.waitingForClaude.errorDescription)])
        do {
            if let activityHistory { self.activityHistory = activityHistory }
            else if savesChanges {
                let result = try LocalStateRecovery.load(from: ActivityHistory.fileURL, empty: ActivityHistory(), read: { try ActivityHistory.load(from: $0) })
                self.activityHistory = result.value
                if result.backupURL != nil { activityRecoveryIssue = "Повреждённый файл статистики сохранён отдельно. Сбор новых данных продолжен." }
            } else { self.activityHistory = try ActivityHistory.load() }
            do {
                if let activityDetails { self.activityDetails = activityDetails }
                else if savesChanges {
                    let result = try LocalStateRecovery.load(from: ActivityDetails.fileURL, empty: ActivityDetails(), read: { try ActivityDetails.load(from: $0) })
                    self.activityDetails = result.value
                    if result.backupURL != nil { detailsRecoveryIssue = "Повреждённый файл статистики сохранён отдельно. Сбор новых данных продолжен." }
                }
                detailsLoaded = true
                activityDetailsIssue = detailsRecoveryIssue
            } catch { activityDetailsIssue = "Не удалось прочитать разбивку по сессиям. Общая статистика сохранена." }
            activityTracker = ActivityTracker(history: self.activityHistory, details: self.activityDetails)
            activityLoaded = true
            activityIssue = activityRecoveryIssue
        } catch { activityIssue = "Не удалось прочитать статистику активности." }
        networkObserver = self.network.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.network.onRestored = { [weak self] in
            guard let self else { return }
            while self.refreshing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, !self.network.isOffline else { return }
            await self.refresh()
            if !Task.isCancelled { await self.onNetworkRestored?() }
        }
    }
    static func discoverCodex() -> String? {
        if let path = CodexProvider.discoverCLI() { return path }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return nil }
        let path = app.appendingPathComponent("Contents/Resources/codex").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    func start() {
        guard refreshTimer == nil else { return }
        network.start()
        if activityHistory.needsImport { importActivityHistory() }
        Task { await refresh(force: false) }
        localTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.providers.contains(.claude), let snapshot = try? ClaudeProvider.latest(), let index = self.snapshots.firstIndex(where: { $0.provider == .claude }), (snapshot.fetchedAt ?? .distantPast) > (self.snapshots[index].fetchedAt ?? .distantPast) else { return }
                self.snapshots[index] = snapshot; self.persist()
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh(force: false) } }
        if let localTimer { RunLoop.main.add(localTimer, forMode: .common) }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }
    func refresh(provider requestedProvider: ProviderID? = nil, force: Bool = true) async {
        guard !refreshing, !network.isOffline else { return }; refreshing = true
        defer { refreshing = false }
        if !FileManager.default.isExecutableFile(atPath: codexPath), let found = Self.discoverCodex() { codexPath = found }
        let path = codexPath
        async let codex = fetchIfEnabled(.codex, path: path, requested: requestedProvider, force: force)
        async let claude = fetchIfEnabled(.claude, path: path, requested: requestedProvider, force: force)
        for (id, result) in await [(ProviderID.codex, codex), (.claude, claude)] {
            guard providers.contains(id), let result else { continue }
            let index = snapshots.firstIndex { $0.provider == id }
            switch result {
            case .success(let snapshot):
                if let index { snapshots[index] = snapshot } else { snapshots.append(snapshot) }
            case .failure(let error):
                guard !network.isOffline else { continue }
                let message = (error as? UsageError)?.errorDescription ?? "Не удалось обновить данные. Проверьте подключение к интернету."
                if let index {
                    snapshots[index].issue = message
                } else { snapshots.append(UsageSnapshot(provider: id, issue: message)) }
            }
        }
        persist()
    }
    private func fetchIfEnabled(_ id: ProviderID, path: String, requested: ProviderID?, force: Bool) async -> Result<UsageSnapshot, Error>? {
        guard providers.contains(id), requested == nil || requested == id else { return nil }
        return await Self.capture {
            if let quotaFetcher { return try await quotaFetcher(id, path) }
            if id == .codex { return try await CodexProvider.fetch(cliPath: path) }
            return try await ClaudeProvider.refresh(force: force)
        }
    }
    func setProvider(_ id: ProviderID, enabled: Bool) {
        var next = Set(providers)
        if enabled { next.insert(id) } else { next.remove(id) }
        preferences.enabledProviders = ProviderID.allCases.filter { next.contains($0) }
    }
    nonisolated private static func capture(_ operation: () async throws -> UsageSnapshot) async -> Result<UsageSnapshot, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    func observeActivity(_ rows: [AgentSession], now: Date = Date()) {
        guard activityLoaded else { return }
        activityTracker.observe(rows, now: now)
        if now.timeIntervalSince(activitySavedAt) >= 60 { flushActivity(now: now) }
    }
    func flushActivity(now: Date = Date()) {
        guard activityLoaded else { return }
        activityHistory = activityTracker.history
        activityTracker.pruneDetails(now: now)
        activityDetails = activityTracker.details
        activitySavedAt = now
        if detailsLoaded, savesChanges {
            do { try activityDetails.save(); activityDetailsIssue = detailsRecoveryIssue }
            catch { activityDetailsIssue = "Не удалось сохранить разбивку по сессиям." }
        }
        guard savesChanges else { return }
        do {
            try activityHistory.save(); activityIssue = activityRecoveryIssue
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectActivityWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "LunavectOverviewWidget")
        } catch { activityIssue = "Не удалось сохранить статистику активности." }
    }
    func importActivityHistory() {
        guard activityLoaded, !providers.isEmpty else { return }
        guard !importingActivity else { pendingActivityImport = true; return }
        importingActivity = true
        let sources = ActivityHistoryImporter.localSources().filter { providers.contains($0.provider) }
        let boundary = activityTracker.prepareImport(now: Date())
        // Persist the boundary before background work so a restart cannot move it forward.
        flushActivity()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                var result = ActivityHistoryImporter.read(sources: sources, before: boundary)
                let ids = Dictionary(grouping: result.details, by: \.provider).mapValues { Set($0.prefix(2000).map(\.sessionID)) }
                let claude = ClaudeSessionMetadata.titles(for: ids[.claude] ?? [])
                let codex = CodexSessionMetadata.titles(for: ids[.codex] ?? [])
                for i in result.details.indices {
                    let row = result.details[i]
                    if let name = (row.provider == .claude ? claude : codex)[row.sessionID] { result.details[i].title = name }
                }
                return result
            }.value
            guard let self else { return }
            self.activityTracker.mergeImport(result, now: Date())
            self.flushActivity()
            self.importingActivity = false
            if self.pendingActivityImport { self.pendingActivityImport = false; self.importActivityHistory() }
        }
    }
    private func persist() {
        guard savesChanges, snapshotWritable else { return }
        do {
            try SnapshotStore.save(SharedState(snapshots: snapshots, preferences: preferences)); storageIssue = storageRecoveryIssue
            WidgetCenter.shared.reloadAllTimelines()
        } catch { storageIssue = "Не удалось сохранить данные виджета." }
    }
    func subscriptionBinding(_ id: ProviderID) -> Binding<Date> {
        Binding(get: {
            let value = self.preferences.subscriptionDates[id.rawValue] ?? ""
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: value) ?? Date()
        }, set: { date in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            self.preferences.subscriptionDates[id.rawValue] = f.string(from: date)
        })
    }
}

@MainActor final class NetworkConnection: ObservableObject {
    enum State { case unknown, online, offline }
    @Published private(set) var state: State = .unknown
    @Published private(set) var restoring = false
    var isOffline: Bool { state == .offline }
    var onRestored: (() async -> Void)?
    private var monitor: NWPathMonitor?
    private var recovery: Task<Void, Never>?
    private let settle: () async throws -> Void
    init(settle: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) { self.settle = settle }
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.update(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.weekleft.network"))
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
