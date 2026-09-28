import Foundation
import OSLog
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// History is shared with widgets; session details remain in their private file.
/// One queue preserves the order of writes, including the blocking termination
/// flush. Each state holds the complete history and details, so a newer state
/// replaces one still waiting for the disk: a slow disk keeps at most one waiting
/// state, and the final flush waits for at most the write in progress (R2-R-02).
final class ActivityPersistence: @unchecked Sendable {
    struct State: Equatable, Sendable {
        var history: ActivityHistory
        var details: ActivityDetails
    }
    struct LoadResult {
        var state: State
        var historyLoaded: Bool
        var detailsLoaded: Bool
        var historyIssue: String?
        var detailsIssue: String?
    }
    struct WriteResult: Sendable {
        var sequence: Int
        var historyIssue: String?
        var detailsIssue: String?
        var historySaved: Bool
        var counters: PersistenceCounters
    }
    private let queue = DispatchQueue(label: "com.weekleft.activity-storage", qos: .utility)
    private let historyURL: URL
    private let detailsURL: URL
    private let readHistory: (URL) throws -> ActivityHistory
    private let readDetails: (URL) throws -> ActivityDetails
    private let writeHistory: (ActivityHistory, URL) throws -> Void
    private let writeDetails: (ActivityDetails, URL, Bool) throws -> Void
    private let reload: () -> Void
    private let clock: () -> Date
    private let reloadInterval: TimeInterval
    private var lastReloadAt: Date?
    private var lastReloadCoverage: Set<Int> = []
    private let completionQueue: DispatchQueue
    private let flushTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.weekleft.storage", category: "activity")
    private var readOnly = false
    private var historyWritable = true, detailsWritable = true
    private var savedHistory: ActivityHistory?, savedDetails: ActivityDetails?
    /// Whether the saved details reached the disk with fsync.
    private var detailsSynchronized = false
    private var historyRecoveryIssue: String?, detailsRecoveryIssue: String?
    private var counts = PersistenceCounters()
    /// Waits for the queue: every write submitted before has finished.
    var counters: PersistenceCounters { queue.sync { counts } }
    /// A state submitted while an earlier one had not started writing yet. Its
    /// requests get the result of the write that replaced them; replaced requests
    /// count as submitted and skipped.
    private struct Waiting {
        let id: Int
        var state: State
        var durable: Bool
        var requests: Int
        var completions: [@Sendable (WriteResult) -> Void]
    }
    private let waitingLock = NSLock()
    private var waiting: Waiting?
    private var waitingIDs = 0

    init(historyURL: URL = ActivityHistory.fileURL, detailsURL: URL = ActivityDetails.fileURL,
         readHistory: @escaping (URL) throws -> ActivityHistory = { try ActivityHistory.load(from: $0) },
         readDetails: @escaping (URL) throws -> ActivityDetails = { try ActivityDetails.load(from: $0) },
         writeHistory: @escaping (ActivityHistory, URL) throws -> Void = { try $0.save(to: $1) },
         // Private details are rewritten every five minutes without fsync (decision 23);
         // quit and sleep ask for a durable write (R3-03). The Bool is `synchronize`.
         writeDetails: @escaping (ActivityDetails, URL, Bool) throws -> Void = { try $0.save(to: $1, synchronize: $2) },
         reload: @escaping () -> Void = {}, clock: @escaping () -> Date = Date.init,
         reloadInterval: TimeInterval = 900, completionQueue: DispatchQueue = .main, flushTimeout: TimeInterval = 3) {
        self.historyURL = historyURL; self.detailsURL = detailsURL
        self.readHistory = readHistory; self.readDetails = readDetails
        self.writeHistory = writeHistory; self.writeDetails = writeDetails; self.reload = reload; self.completionQueue = completionQueue
        self.clock = clock; self.reloadInterval = reloadInterval; self.flushTimeout = flushTimeout
    }
    func load(history: ActivityHistory? = nil, details: ActivityDetails? = nil, readOnly: Bool = false) -> LoadResult {
        blocking {
            self.readOnly = self.readOnly || readOnly
            if !self.readOnly {
                // A write killed between its temporary and the rename leaves `.UUID.tmp`.
                let now = self.clock()
                for directory in Set([self.historyURL, self.detailsURL].map { $0.resolvingSymlinksInPath().deletingLastPathComponent() }) {
                    _ = try? LocalStateRecovery.removeAbandonedTemporaries(in: directory, now: now)
                }
            }
            var state = State(history: history ?? ActivityHistory(), details: details ?? ActivityDetails())
            var historyLoaded = true, detailsLoaded = true
            if history == nil, self.historyWritable {
                self.savedHistory = nil
                do {
                    var recovered = false
                    if self.readOnly { state.history = try self.readHistory(self.historyURL) }
                    else {
                        let result = try LocalStateRecovery.load(from: self.historyURL, empty: ActivityHistory(), read: self.readHistory)
                        state.history = result.value; recovered = result.backupURL != nil
                    }
                    if recovered { self.historyRecoveryIssue = "Повреждённый файл статистики сохранён отдельно. Сбор новых данных продолжен." }
                    else if FileManager.default.fileExists(atPath: self.historyURL.path) { self.savedHistory = state.history }
                } catch {
                    historyLoaded = false; self.historyWritable = false
                    self.historyRecoveryIssue = "Не удалось прочитать статистику активности."
                }
            }
            if !self.historyWritable { historyLoaded = false }
            if details == nil, self.detailsWritable {
                self.savedDetails = nil
                do {
                    var recovered = false
                    if self.readOnly { state.details = try self.readDetails(self.detailsURL) }
                    else {
                        let result = try LocalStateRecovery.load(from: self.detailsURL, empty: ActivityDetails(), read: self.readDetails)
                        state.details = result.value; recovered = result.backupURL != nil
                    }
                    if recovered { self.detailsRecoveryIssue = "Повреждённый файл статистики сохранён отдельно. Сбор новых данных продолжен." }
                    else if FileManager.default.fileExists(atPath: self.detailsURL.path) { self.savedDetails = state.details }
                } catch {
                    detailsLoaded = false; self.detailsWritable = false
                    self.detailsRecoveryIssue = "Не удалось прочитать разбивку по сессиям. Общая статистика сохранена."
                }
            }
            if !self.detailsWritable { detailsLoaded = false }
            return LoadResult(state: state, historyLoaded: historyLoaded, detailsLoaded: detailsLoaded,
                              historyIssue: self.historyRecoveryIssue, detailsIssue: self.detailsRecoveryIssue)
        }
    }
    /// `durable` writes the private details with fsync (before sleep); the periodic
    /// cadence leaves it off.
    func submit(_ state: State, durable: Bool = false, completion: @escaping @Sendable (WriteResult) -> Void) {
        let scheduled = waitingLock.withLock { () -> Int? in
            if var next = waiting {
                next.state = state; next.durable = next.durable || durable
                next.requests += 1; next.completions.append(completion)
                waiting = next
                return nil
            }
            waitingIDs += 1
            waiting = Waiting(id: waitingIDs, state: state, durable: durable, requests: 1, completions: [completion])
            return waitingIDs
        }
        guard let id = scheduled else { return }
        queue.async {
            // A flush may have taken this state already; a later one has its own block.
            guard let next = self.waitingLock.withLock({ () -> Waiting? in
                guard let value = self.waiting, value.id == id else { return nil }
                self.waiting = nil
                return value
            }) else { return }
            let result = self.write(next.state, durable: next.durable, replaced: next.requests - 1)
            self.completionQueue.async { next.completions.forEach { $0(result) } }
        }
    }
    /// Test support: requests waiting to be written (at most one state).
    var waitingRequests: Int { waitingLock.withLock { waiting?.requests ?? 0 } }
    /// Termination waits at most `flushTimeout` for the disk; an unresponsive
    /// volume must not block quitting. A late write still completes in order.
    func flush(_ state: State) -> WriteResult {
        // The final state replaces a waiting one; its requests get the final result,
        // also when the write finishes after the deadline.
        let replaced = waitingLock.withLock { () -> Waiting? in defer { waiting = nil }; return waiting }
        let completions = replaced?.completions ?? [], requests = replaced?.requests ?? 0
        let operation: @Sendable () -> WriteResult = {
            let result = self.write(state, durable: true, replaced: requests)
            if !completions.isEmpty { self.completionQueue.async { completions.forEach { $0(result) } } }
            return result
        }
        if let result = blocking(timeout: flushTimeout, operation) { return result }
        logger.error("Activity flush exceeded \(self.flushTimeout, privacy: .public) s; quitting without waiting")
        return WriteResult(sequence: 0, historyIssue: "Не удалось сохранить статистику активности.", detailsIssue: nil,
                           historySaved: false, counters: PersistenceCounters())
    }
    enum StartOverResult: Sendable { case started(URL?), failed }
    /// "Save a copy and start over" for a history that cannot be read (for example
    /// larger than the read limit): the file is kept beside it, never deleted.
    func startOverPreservingHistory(completion: @escaping @Sendable (StartOverResult) -> Void) {
        queue.async {
            let result: StartOverResult
            if self.readOnly || self.historyWritable { result = .failed }
            else {
                let target = self.historyURL.resolvingSymlinksInPath()
                do {
                    var copy: URL?
                    if FileManager.default.fileExists(atPath: target.path) {
                        let backup = target.appendingPathExtension("unreadable-\(Int(self.clock().timeIntervalSince1970))-\(UUID().uuidString)")
                        try LiveWriteGuard.check(target, backup)
                        try FileManager.default.moveItem(at: target, to: backup)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                        copy = backup
                    }
                    self.historyWritable = true; self.savedHistory = nil
                    self.historyRecoveryIssue = "Прежний файл статистики сохранён отдельно. Сбор начат заново."
                    self.logger.notice("Unreadable activity history kept aside; collection restarted")
                    result = .started(copy)
                } catch {
                    self.logger.error("Unreadable activity history could not be moved aside: \((error as NSError).code, privacy: .public)")
                    result = .failed
                }
            }
            self.completionQueue.async { completion(result) }
        }
    }

    private func write(_ state: State, durable: Bool = false, replaced: Int = 0) -> WriteResult {
        // Requests replaced by this newer state were not written on their own.
        counts.submitted += replaced; counts.skipped += replaced
        counts.submitted += 1
        if readOnly {
            counts.skipped += 1
            return WriteResult(sequence: counts.submitted, historyIssue: historyRecoveryIssue, detailsIssue: detailsRecoveryIssue,
                               historySaved: false, counters: counts)
        }
        var historyIssue = historyRecoveryIssue, detailsIssue = detailsRecoveryIssue
        var historySaved = false, wrote = false, failed = false
        if historyWritable {
            do {
                if savedHistory != state.history {
                    try writeHistory(state.history, historyURL); savedHistory = state.history
                    wrote = true
                    let now = clock(), coverage = Set(state.history.intervals.map(\.knownProviders))
                    if lastReloadAt == nil || coverage != lastReloadCoverage || now < lastReloadAt!
                        || now.timeIntervalSince(lastReloadAt!) >= reloadInterval {
                        lastReloadAt = now; lastReloadCoverage = coverage; reload()
                    }
                }
                historySaved = true
            } catch { savedHistory = nil; historyIssue = "Не удалось сохранить статистику активности."; failed = true }
        }
        // A power loss or kernel panic after an unsynchronized rename can leave an empty
        // file, and recovery would then set the whole breakdown aside: quit and sleep
        // write it durably, repeating an unsynchronized write of the same content.
        if detailsWritable, savedDetails != state.details || (durable && !detailsSynchronized) {
            do {
                try writeDetails(state.details, detailsURL, durable)
                savedDetails = state.details; detailsSynchronized = durable; wrote = true
            } catch { savedDetails = nil; detailsSynchronized = false; detailsIssue = "Не удалось сохранить разбивку по сессиям."; failed = true }
        }
        if wrote { counts.written += 1 }
        if failed { counts.failed += 1 }
        if !wrote && !failed { counts.skipped += 1 }
        return WriteResult(sequence: counts.submitted, historyIssue: historyIssue, detailsIssue: detailsIssue,
                           historySaved: historySaved, counters: counts)
    }
    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: Value?
        var value: Value? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }
    private func blocking<Value>(_ operation: @escaping @Sendable () -> Value) -> Value {
        blocking(timeout: nil, operation)!
    }
    private func blocking<Value>(timeout: TimeInterval?, _ operation: @escaping @Sendable () -> Value) -> Value? {
        // DispatchQueue.sync can execute on the caller; force I/O off the main
        // thread even for the intentionally blocking startup/termination boundary.
        dispatchPrecondition(condition: .notOnQueue(queue))
        let box = ResultBox<Value>(), completed = DispatchSemaphore(value: 0)
        queue.async { box.value = operation(); completed.signal() }
        if let timeout { guard completed.wait(timeout: .now() + max(0, timeout)) == .success else { return nil } }
        else { completed.wait() }
        return box.value
    }
}
