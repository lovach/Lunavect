import Foundation
import OSLog
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct PersistenceCounters: Equatable, Sendable {
    var submitted = 0
    var written = 0
    var skipped = 0
    var failed = 0
}

/// Owns snapshot I/O. Disk operations run on one utility queue, including a
/// synchronous shutdown flush; callbacks never make that queue wait for the UI.
final class SnapshotPersistence: @unchecked Sendable {
    struct LoadResult: Sendable {
        let state: SharedState
        let writable: Bool
        let issue: String?
    }
    enum WriteDisposition: Equatable, Sendable { case written, unchanged, disabled, failed }
    struct WriteResult: Sendable {
        let disposition: WriteDisposition
        let issue: String?
        let sequence: Int
        let counters: PersistenceCounters
    }

    private let url: URL
    private let read: @Sendable (URL) -> SharedState
    private let recover: @Sendable (URL) throws -> RecoveredLocalState<SharedState>
    private let write: @Sendable (SharedState, URL) throws -> Void
    private let exists: @Sendable (URL) -> Bool
    private let reload: @Sendable () -> Void
    private let reloadActivity: @Sendable () -> Void
    private let clock: @Sendable () -> Date
    private let completionQueue: DispatchQueue
    private let flushTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.weekleft.storage", category: "snapshot")
    private let queue = DispatchQueue(label: "com.weekleft.snapshot-persistence", qos: .utility)
    // Protect submission order and counters independently of potentially slow I/O.
    private let submissionLock = NSLock()
    private var counts = PersistenceCounters()
    // Accessed only by the I/O queue.
    private var lastSaved: SharedState?
    private var recoveryIssue: String?
    private var readFailed = false
    private var readOnly = false
    private var lastReload: WidgetQuotaFingerprint?
    private var lastReloadState: SharedState?
    private var lastReloadAt: Date?
    private var lastActivityReload: ActivityWidgetInputs?

    init(url: URL = SnapshotStore.directory.appendingPathComponent("snapshot.json"),
         read: @escaping @Sendable (URL) -> SharedState = { SnapshotStore.load(from: $0) },
         recover: @escaping @Sendable (URL) throws -> RecoveredLocalState<SharedState> = { try SnapshotStore.loadRecovering(from: $0) },
         write: @escaping @Sendable (SharedState, URL) throws -> Void = { state, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
             try LocalStateRecovery.write(JSONEncoder().encode(state), to: url)
         },
         exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         reload: @escaping @Sendable () -> Void = {},
         reloadActivity: @escaping @Sendable () -> Void = {},
         clock: @escaping @Sendable () -> Date = { Date() },
         completionQueue: DispatchQueue = .main, flushTimeout: TimeInterval = 3) {
        self.url = url; self.read = read; self.recover = recover; self.write = write
        self.exists = exists; self.reload = reload; self.reloadActivity = reloadActivity; self.clock = clock; self.completionQueue = completionQueue
        self.flushTimeout = flushTimeout
    }

    var counters: PersistenceCounters { submissionLock.withLock { counts } }

    /// Keep startup's existing synchronous API, but execute the read off-main.
    /// A failed recovery read disables writes for this instance until restart.
    func load(readOnly: Bool = false) -> LoadResult {
        waitForOperation {
            self.readOnly = readOnly
            if readOnly || self.readFailed {
                return LoadResult(state: self.read(self.url), writable: false, issue: self.recoveryIssue)
            }
            // Only the writing app repairs the shared directory; widgets stay read-only.
            _ = try? LocalStateRecovery.removeAbandonedTemporaries(in: self.url.resolvingSymlinksInPath().deletingLastPathComponent(), now: self.clock())
            do {
                let result = try self.recover(self.url)
                if result.backupURL != nil {
                    self.recoveryIssue = "Повреждённый файл настроек сохранён отдельно. Доступные настройки восстановлены."
                    self.lastSaved = nil
                } else if self.exists(self.url) {
                    self.lastSaved = result.value
                } else {
                    // Missing files and recovery backups need an initial write.
                    self.lastSaved = nil
                }
                return LoadResult(state: result.value, writable: !self.readFailed, issue: self.recoveryIssue)
            } catch {
                self.readFailed = true
                self.recoveryIssue = "Не удалось прочитать настройки. Исходный файл сохранён; запись отключена до перезапуска."
                self.lastSaved = nil
                return LoadResult(state: SharedState(), writable: false, issue: self.recoveryIssue)
            }
        }
    }

    /// A result may reach the UI after a synchronous flush. Consumers should
    /// retain the greatest sequence they applied and ignore older completions.
    func submit(_ state: SharedState, completion: @escaping @Sendable (WriteResult) -> Void = { _ in }) {
        submissionLock.withLock {
            counts.submitted += 1
            let sequence = counts.submitted
            queue.async {
                let result = self.save(state, sequence: sequence)
                self.completionQueue.async { completion(result) }
            }
        }
    }

    /// Enqueues behind every prior submission and waits for the final write.
    /// async + semaphore deliberately avoids DispatchQueue.sync's ability to run
    /// disk work on the calling (main) thread. Earlier callbacks are not awaited.
    /// Termination waits at most `flushTimeout`; the write itself stays queued.
    @discardableResult func flush(_ state: SharedState) -> WriteResult {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let result = WaitingResult<WriteResult>()
        let finished = DispatchSemaphore(value: 0)
        let sequence = submissionLock.withLock { () -> Int in
            counts.submitted += 1
            let sequence = counts.submitted
            queue.async {
                result.value = self.save(state, sequence: sequence)
                finished.signal()
            }
            return sequence
        }
        guard finished.wait(timeout: .now() + max(0, flushTimeout)) == .success, let value = result.value else {
            logger.error("Snapshot flush exceeded \(self.flushTimeout, privacy: .public) s; quitting without waiting")
            return WriteResult(disposition: .failed, issue: "Не удалось сохранить данные виджета.", sequence: sequence, counters: counters)
        }
        return value
    }

    private func save(_ state: SharedState, sequence: Int) -> WriteResult {
        let disposition: WriteDisposition
        let issue: String?
        if readOnly || readFailed {
            disposition = .disabled; issue = recoveryIssue
            submissionLock.withLock { counts.skipped += 1 }
        } else if let saved = lastSaved, saved.snapshots == state.snapshots, saved.preferences == state.preferences {
            disposition = .unchanged; issue = recoveryIssue
            submissionLock.withLock { counts.skipped += 1 }
        } else {
            do {
                try write(state, url)
                lastSaved = state
                disposition = .written; issue = recoveryIssue
                submissionLock.withLock { counts.written += 1 }
            } catch {
                // A failed or partial write cannot seed the next deduplication.
                lastSaved = nil
                disposition = .failed; issue = "Не удалось сохранить данные виджета."
                submissionLock.withLock { counts.failed += 1 }
            }
        }
        if disposition == .written || (disposition == .unchanged && lastReloadState != nil) {
            reloadIfNeeded(state)
        }
        return WriteResult(disposition: disposition, issue: issue, sequence: sequence, counters: counters)
    }

    private func reloadIfNeeded(_ state: SharedState) {
        let now = clock()
        let fingerprint = WidgetQuotaFingerprint(state, now: now)
        // Compare the previously delivered observation at today's clock too:
        // its timeline may now say stale while the app has a fresh receipt.
        let deliveredNow = lastReloadState.map { WidgetQuotaFingerprint($0, now: now) }
        let receiptChanged = state.preferences.providers.contains { id in
            state.snapshots.first { $0.provider == id }?.fetchedAt !=
                lastReloadState?.snapshots.first { $0.provider == id }?.fetchedAt
        }
        let elapsed = lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
        // Persist every receipt, but coalesce timestamp-only reloads to five
        // minutes, leaving headroom before the 15-minute stale boundary.
        let refreshReceipt = receiptChanged && (elapsed >= 300 || elapsed < 0)
        guard fingerprint != lastReload || fingerprint != deliveredNow || refreshReceipt else { return }
        lastReload = fingerprint
        lastReloadState = state
        lastReloadAt = now
        reload()
        // The activity widget shows no quota; only shared preferences change it (C-01).
        let activity = ActivityWidgetInputs(state.preferences)
        if activity != lastActivityReload { lastActivityReload = activity; reloadActivity() }
    }

    private func waitForOperation<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) -> Value {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let result = WaitingResult<Value>()
        let finished = DispatchSemaphore(value: 0)
        submissionLock.withLock {
            queue.async { result.value = operation(); finished.signal() }
        }
        finished.wait()
        return result.value!
    }
}

/// Snapshot values the activity widget renders: its sources and appearance.
private struct ActivityWidgetInputs: Equatable {
    let providers: [ProviderID]
    let showFiveHour: Bool
    let transparency: Double
    let transparentBackground: Bool
    init(_ preferences: WidgetPreferences) {
        providers = preferences.providers; showFiveHour = preferences.showFiveHour
        transparency = preferences.transparency; transparentBackground = preferences.transparentBackground
    }
}

/// Immediate visible changes; receipt-only updates are coalesced separately.
private struct WidgetQuotaFingerprint: Equatable {
    struct Quota: Equatable {
        let remaining: Int
        let reset: Date?
    }
    struct Provider: Equatable {
        let id: ProviderID
        let weekly: Quota?
        let five: Quota?
        let stale: Bool
        let source: String
        let issue: String?
    }
    let preferences: WidgetPreferences
    let providers: [Provider]
    init(_ state: SharedState, now: Date) {
        preferences = state.preferences
        providers = state.preferences.providers.map { id in
            let snapshot = state.snapshots.first { $0.provider == id } ?? UsageSnapshot(provider: id)
            func quota(_ window: QuotaWindow?) -> Quota? {
                guard let window, !window.isExpired(at: now) else { return nil }
                return Quota(remaining: Int(window.remaining.rounded()), reset: window.resetsAt)
            }
            return Provider(id: id, weekly: quota(snapshot.weekly), five: state.preferences.showFiveHour ? quota(snapshot.fiveHour) : nil,
                            stale: snapshot.isStale(now: now), source: snapshot.source, issue: snapshot.issue)
        }
    }
}

/// A timed-out flush may read while the queue still writes; the lock keeps both sides safe.
private final class WaitingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value?
    var value: Value? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
