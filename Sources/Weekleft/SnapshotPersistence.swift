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
             try LiveWriteGuard.check(url)
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

/// Copies left by earlier installations after the App Group migration (B-06,
/// decision 24): the previous group container's shared folder and the
/// Application Support fallback files. The app no longer reads them and never
/// removes them on its own; the user can check and move them to the Trash.
/// Probing starts only on that request, because another group container may be
/// protected by macOS.
///
/// Only these exact paths are ever offered (R3-07). The previous group is also
/// the live container of every non-Distribution build (check.sh, renders, local
/// runs) and Application Support is live for a build without an App Group, so a
/// copy written within `inUse` may belong to another build and is never offered;
/// neither is anything inside the running build's own container.
enum LegacySharedData {
    static let previousGroup = "group.com.weekleft.shared"
    static let inUse: TimeInterval = 7 * 86400
    static func find(group: String? = Bundle.main.object(forInfoDictionaryKey: "WeekleftAppGroup") as? String,
                     current: URL = SnapshotStore.directory,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [URL] {
        // Without an App Group, Application Support is the live location, not a leftover.
        guard let group, !group.isEmpty else { return [] }
        let live = current.standardizedFileURL.path
        let ownContainer = home.appendingPathComponent("Library/Group Containers/\(group)", isDirectory: true).standardizedFileURL.path
        var candidates: [URL] = []
        if group != previousGroup {
            candidates.append(home.appendingPathComponent("Library/Group Containers/\(previousGroup)/Weekleft", isDirectory: true))
        }
        let support = home.appendingPathComponent("Library/Application Support/Weekleft", isDirectory: true)
        if support.standardizedFileURL.path != live {
            // Only shared-state names; session records and activity-details.json stay live there.
            candidates += ["snapshot.json", "activity.json", "ActivitySelection"].map { support.appendingPathComponent($0) }
        }
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            guard path != live, !live.hasPrefix(path + "/"), !path.hasPrefix(live + "/"),
                  path != ownContainer, !path.hasPrefix(ownContainer + "/"),
                  let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.path) else { return false }
            // Written within a week: possibly the live data of another build.
            return lastModified(url).map { now.timeIntervalSince($0) >= inUse } ?? false
        }
    }
    /// The newest modification of the item and, for a folder, of what it holds
    /// (bounded, without following links). Nil when it cannot be read.
    static func lastModified(_ url: URL, limit: Int = 2_000) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isSymbolicLinkKey]
        guard var newest = try? url.resourceValues(forKeys: keys).contentModificationDate else { return nil }
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                        errorHandler: { _, _ in true }) else { return newest }
        var visited = 0
        for case let item as URL in items {
            visited += 1
            // Too much to check means it cannot be shown as unused.
            guard visited <= limit else { return .distantFuture }
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { items.skipDescendants() }
            if let date = values.contentModificationDate, date > newest { newest = date }
        }
        return newest
    }
    /// Paths and last changes, shown before anything is moved.
    static func details(of urls: [URL]) -> [(url: URL, modified: Date?)] { urls.map { ($0, lastModified($0)) } }
    /// Returns what could not be moved; the Trash keeps everything recoverable.
    static func moveToTrash(_ urls: [URL], trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [URL] {
        urls.filter { url in (try? trash(url)) == nil }
    }
}
