import AppKit
import Combine
import Foundation
import OSLog
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// Owns activity observations and import lifetime. Disk work is serialized by
/// ActivityPersistence; importing never holds the UI actor while reading files.
@MainActor final class ActivityService: ObservableObject {
    typealias Importer = @Sendable (Set<ProviderID>, Date, Date) async throws -> ActivityImportResult
    @Published private(set) var history: ActivityHistory
    @Published private(set) var details: ActivityDetails
    @Published private(set) var issue: String?
    @Published private(set) var detailsIssue: String?
    @Published private(set) var importing = false
    /// The shared history could not be read; collection is paused until the user
    /// keeps a copy and starts over (`startOverPreservingHistory`).
    @Published private(set) var unavailable: Bool
    /// Phase transitions are saved after this quiet window, not on every change.
    static let transitionDebounce: TimeInterval = 15
    /// Private project/session details are written at most this often, and on quit.
    static let detailsInterval: TimeInterval = 300
    private let storage: ActivityPersistence?
    private let writesEnabled: Bool
    private let isolated: Bool
    private let clock: () -> Date
    private let importer: Importer
    private var tracker: ActivityTracker
    private var providers = Set<ProviderID>()
    private var savedAt = Date.distantPast
    private var observationState: Set<String> = []
    private var transitionSince: Date?
    private var submittedDetails: ActivityDetails?
    private var detailsSubmittedAt = Date.distantPast
    private var powerObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private let logger = Logger(subsystem: "com.weekleft.app", category: "activity")
    private var appliedWrite = 0
    private var importGeneration = 0
    /// Readable so tests can await a cancelled worker instead of a time window.
    private(set) var importTask: Task<Void, Never>?
    private var pendingImport = false
    private var started = false
    private var acceptsWork = true

    init(history: ActivityHistory? = nil, details: ActivityDetails? = nil,
         storage: ActivityPersistence? = nil, writesEnabled: Bool = true, isolated: Bool = false,
         powerNotifications: NotificationCenter? = NSWorkspace.shared.notificationCenter,
         clock: @escaping () -> Date = Date.init, importer: @escaping Importer = { providers, boundary, now in
             try await ActivityService.readLocalHistory(providers: providers, boundary: boundary, now: now)
         }) {
        self.isolated = isolated; self.clock = clock; self.importer = importer
        self.storage = isolated ? nil : storage
        self.writesEnabled = writesEnabled && !isolated && storage != nil
        let loaded: ActivityPersistence.LoadResult
        if let storage = self.storage {
            loaded = storage.load(history: history, details: details, readOnly: !writesEnabled)
        } else {
            loaded = .init(state: .init(history: history ?? ActivityHistory(), details: details ?? ActivityDetails()),
                           historyLoaded: true, detailsLoaded: true)
        }
        self.history = loaded.state.history; self.details = loaded.state.details
        issue = loaded.historyIssue; detailsIssue = loaded.detailsIssue; unavailable = !loaded.historyLoaded
        tracker = ActivityTracker(history: loaded.state.history, details: loaded.state.details)
        if !isolated, let center = powerNotifications {
            // Sleep and wake are explicit breaks, not inferred from the gap tolerance.
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.interruptObservation()
                        // A Mac that never wakes (battery, panic) must not lose the breakdown (R3-03).
                        if name == NSWorkspace.willSleepNotification { self?.saveBeforeSleep() }
                    }
                }
                powerObservers.append((center, token))
            }
        }
    }
    func interruptObservation() { tracker.interruptObservation() }
    /// History and details are written with fsync before the Mac sleeps.
    func saveBeforeSleep() {
        guard acceptsWork else { return }
        save(now: clock(), synchronously: false, forceDetails: true, durable: true)
    }
    func start(providers: [ProviderID]) {
        guard !isolated, !started else { return }
        started = true; acceptsWork = true
        setProviders(providers)
        if tracker.history.needsImport(providers: Set(providers)), !importing { scheduleImport() }
    }
    func setProviders(_ values: [ProviderID]) {
        let next = Set(values)
        guard next != providers else { return }
        let resume = importing
        cancelImport(); providers = next
        // Observations across a disabled/re-enabled source are not a continuous
        // measurement, even if both transitions happen within the normal 10 s gap.
        tracker = ActivityTracker(history: tracker.history, details: tracker.details)
        if acceptsWork, !next.isEmpty, resume || (started && tracker.history.needsImport(providers: next)) { scheduleImport() }
    }
    func observe(_ rows: [AgentSession], now: Date? = nil) {
        guard acceptsWork, !unavailable else { return }
        let now = now ?? clock()
        let selected = rows.filter { providers.contains($0.provider) }
        // Only what the tracker measures: running sessions and which sources are
        // observed at all. Ready, idle, finished or hidden changes do not save.
        let running = selected.filter { $0.effectivePhase(now: now) == .running }
        let known = Set(selected.filter { $0.effectivePhase(now: now) != .unknown }.map { "source:" + $0.provider.rawValue })
        let next = known.union(running.map { "running:" + $0.id })
        if next != observationState { observationState = next; transitionSince = transitionSince ?? now }
        let gaps = tracker.history.observationGaps?.count ?? 0
        tracker.observe(selected, now: now)
        if let recorded = tracker.history.observationGaps, recorded.count > gaps {
            logger.info("Observation gap not counted as work; \(recorded.count, privacy: .public) since \(recorded.since.timeIntervalSince1970, privacy: .public)")
        }
        // Retain the one-minute crash bound for measured work. Idle coverage can
        // checkpoint less often; debounced transitions and normal quit flush it.
        let interval: TimeInterval = running.isEmpty ? 300 : 60
        let transitionDue = transitionSince.map { now < $0 || now.timeIntervalSince($0) >= Self.transitionDebounce } ?? false
        if transitionDue || now < savedAt || now.timeIntervalSince(savedAt) >= interval { save(now: now, synchronously: false) }
    }
    func flush(now: Date? = nil) { save(now: now ?? clock(), synchronously: true) }
    func stop() {
        started = false; acceptsWork = false
        cancelImport()
        flush()
        tracker = ActivityTracker(history: tracker.history, details: tracker.details)
    }
    /// "Refresh history" and the connection wizard's import. With an unreadable
    /// history it does nothing: only the explicit start-over below moves the file
    /// aside (R3-02).
    func requestImport() { scheduleImport() }
    /// The statistics page's **Keep a copy and start over**, the only path that
    /// moves an unreadable history aside and starts a new one.
    func startOverPreservingHistory() {
        guard unavailable else { return }
        startOver()
    }
    private func startOver() {
        guard !isolated, writesEnabled, acceptsWork, let storage else { return }
        storage.startOverPreservingHistory { [weak self] result in
            Task { @MainActor in
                guard let self, self.unavailable, self.acceptsWork else { return }
                guard case .started = result else {
                    self.issue = "Не удалось сохранить копию файла статистики."
                    return
                }
                self.tracker = ActivityTracker(history: ActivityHistory(), details: self.tracker.details)
                self.history = self.tracker.history
                self.issue = "Прежний файл статистики сохранён отдельно. Сбор начат заново."
                self.unavailable = false
                self.scheduleImport()
            }
        }
    }
    private func scheduleImport() {
        guard !isolated, acceptsWork, !unavailable, !providers.isEmpty else { return }
        guard !importing else { pendingImport = true; return }
        importing = true
        let boundaries = tracker.prepareImport(providers: providers, now: clock())
        let state = submission(publish(now: clock()), now: clock(), forceDetails: true)
        let generation = importGeneration, selected = providers
        if writesEnabled, let storage {
            // The import boundary must be durable before history is read. A failed
            // write leaves the same boundary in memory for a safe explicit retry.
            storage.submit(state) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply(result)
                    guard self.acceptsWork, self.importGeneration == generation else { return }
                    guard result.historySaved else { self.importing = false; self.pendingImport = false; return }
                    self.beginImport(providers: selected, boundaries: boundaries, generation: generation)
                }
            }
        } else { beginImport(providers: selected, boundaries: boundaries, generation: generation) }
    }
    private func beginImport(providers: Set<ProviderID>, boundaries: [ProviderID: Date], generation: Int) {
        let importer = importer, now = clock()
        importTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let groups = Dictionary(grouping: providers, by: { boundaries[$0] ?? now })
                var results: [(Set<ProviderID>, ActivityImportResult)] = []
                for boundary in groups.keys.sorted() {
                    try Task.checkCancellation()
                    let selected = Set(groups[boundary] ?? [])
                    let result = try await importer(selected, boundary, now)
                    guard !result.cancelled else { throw CancellationError() }
                    results.append((selected, result))
                }
                guard !Task.isCancelled, let self,
                      self.acceptsWork, self.importGeneration == generation, self.providers == providers else { return }
                for (selected, result) in results { self.tracker.mergeImport(result, now: self.clock(), providers: selected) }
                // A merged import is written at once, private details included.
                self.save(now: self.clock(), synchronously: false, forceDetails: true)
                self.finishImport(generation: generation)
            } catch {
                guard !Task.isCancelled, let self, self.importGeneration == generation else { return }
                // Keep the existing history and the retry boundary after an I/O failure.
                if !(error is CancellationError), self.issue != "Не удалось прочитать статистику активности." { self.issue = "Не удалось прочитать статистику активности." }
                self.finishImport(generation: generation)
            }
        }
    }
    private func finishImport(generation: Int) {
        guard importGeneration == generation else { return }
        importing = false; importTask = nil
        if pendingImport { pendingImport = false; scheduleImport() }
    }
    private func cancelImport() {
        importGeneration += 1
        importTask?.cancel(); importTask = nil; pendingImport = false
        if importing { importing = false }
    }
    private func publish(now: Date) -> ActivityPersistence.State {
        tracker.pruneDetails(now: now)
        if history != tracker.history { history = tracker.history }
        if details != tracker.details { details = tracker.details }
        savedAt = now; transitionSince = nil
        return .init(history: tracker.history, details: tracker.details)
    }
    /// History is saved at every checkpoint; the private details only every five
    /// minutes, at import, before sleep and at quit (decision 23). The UI always sees both.
    private func submission(_ state: ActivityPersistence.State, now: Date, forceDetails: Bool) -> ActivityPersistence.State {
        var state = state
        if forceDetails || submittedDetails == nil || now < detailsSubmittedAt || now.timeIntervalSince(detailsSubmittedAt) >= Self.detailsInterval {
            submittedDetails = state.details; detailsSubmittedAt = now
        } else if let submittedDetails { state.details = submittedDetails }
        return state
    }
    private func save(now: Date, synchronously: Bool, forceDetails: Bool = false, durable: Bool = false) {
        guard !unavailable else { return }
        let state = submission(publish(now: now), now: now, forceDetails: forceDetails || synchronously)
        guard writesEnabled, let storage else { return }
        if synchronously { apply(storage.flush(state)) }
        else {
            storage.submit(state, durable: durable) { [weak self] result in
                Task { @MainActor in self?.apply(result) }
            }
        }
    }
    private func apply(_ result: ActivityPersistence.WriteResult) {
        guard result.sequence >= appliedWrite else { return }
        appliedWrite = result.sequence
        if issue != result.historyIssue { issue = result.historyIssue }
        if detailsIssue != result.detailsIssue { detailsIssue = result.detailsIssue }
    }
    nonisolated static func readLocalHistory(providers: Set<ProviderID>, boundary: Date, now: Date) async throws -> ActivityImportResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let sources = ActivityHistoryImporter.localSources().filter { providers.contains($0.provider) }
            var result = ActivityHistoryImporter.read(sources: sources, before: boundary, now: now)
            try Task.checkCancellation()
            guard !result.cancelled else { throw CancellationError() }
            let ids = Dictionary(grouping: result.details, by: \.provider).mapValues { Set($0.prefix(2000).map(\.sessionID)) }
            let claude = ClaudeSessionMetadata.titles(for: ids[.claude] ?? [])
            try Task.checkCancellation()
            let codex = CodexSessionMetadata.titles(for: ids[.codex] ?? [])
            for i in result.details.indices {
                try Task.checkCancellation()
                let row = result.details[i]
                if let name = (row.provider == .claude ? claude : codex)[row.sessionID] { result.details[i].title = name }
            }
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    deinit {
        importTask?.cancel()
        for (center, token) in powerObservers { center.removeObserver(token) }
    }
}
