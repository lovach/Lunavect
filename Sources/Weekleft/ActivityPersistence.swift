import Foundation
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// History is shared with widgets; session details remain in their private file.
/// One queue preserves submission order, including the blocking termination flush.
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
    private let writeDetails: (ActivityDetails, URL) throws -> Void
    private let reload: () -> Void
    private let clock: () -> Date
    private let reloadInterval: TimeInterval
    private var lastReloadAt: Date?
    private var lastReloadCoverage: Set<Int> = []
    private let completionQueue: DispatchQueue
    private var readOnly = false
    private var historyWritable = true, detailsWritable = true
    private var savedHistory: ActivityHistory?, savedDetails: ActivityDetails?
    private var historyRecoveryIssue: String?, detailsRecoveryIssue: String?
    private var counts = PersistenceCounters()
    var counters: PersistenceCounters { queue.sync { counts } }

    init(historyURL: URL = ActivityHistory.fileURL, detailsURL: URL = ActivityDetails.fileURL,
         readHistory: @escaping (URL) throws -> ActivityHistory = { try ActivityHistory.load(from: $0) },
         readDetails: @escaping (URL) throws -> ActivityDetails = { try ActivityDetails.load(from: $0) },
         writeHistory: @escaping (ActivityHistory, URL) throws -> Void = { try $0.save(to: $1) },
         writeDetails: @escaping (ActivityDetails, URL) throws -> Void = { try $0.save(to: $1) },
         reload: @escaping () -> Void = {}, clock: @escaping () -> Date = Date.init,
         reloadInterval: TimeInterval = 900, completionQueue: DispatchQueue = .main) {
        self.historyURL = historyURL; self.detailsURL = detailsURL
        self.readHistory = readHistory; self.readDetails = readDetails
        self.writeHistory = writeHistory; self.writeDetails = writeDetails; self.reload = reload; self.completionQueue = completionQueue
        self.clock = clock; self.reloadInterval = reloadInterval
    }
    func load(history: ActivityHistory? = nil, details: ActivityDetails? = nil, readOnly: Bool = false) -> LoadResult {
        blocking {
            self.readOnly = self.readOnly || readOnly
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
    func submit(_ state: State, completion: @escaping @Sendable (WriteResult) -> Void) {
        queue.async {
            let result = self.write(state)
            self.completionQueue.async { completion(result) }
        }
    }
    func flush(_ state: State) -> WriteResult { blocking { self.write(state) } }

    private func write(_ state: State) -> WriteResult {
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
        if detailsWritable, savedDetails != state.details {
            do { try writeDetails(state.details, detailsURL); savedDetails = state.details; wrote = true }
            catch { savedDetails = nil; detailsIssue = "Не удалось сохранить разбивку по сессиям."; failed = true }
        }
        if wrote { counts.written += 1 }
        if failed { counts.failed += 1 }
        if !wrote && !failed { counts.skipped += 1 }
        return WriteResult(sequence: counts.submitted, historyIssue: historyIssue, detailsIssue: detailsIssue,
                           historySaved: historySaved, counters: counts)
    }
    private final class ResultBox<Value>: @unchecked Sendable { var value: Value? }
    private func blocking<Value>(_ operation: @escaping @Sendable () -> Value) -> Value {
        // DispatchQueue.sync can execute on the caller; force I/O off the main
        // thread even for the intentionally blocking startup/termination boundary.
        dispatchPrecondition(condition: .notOnQueue(queue))
        let box = ResultBox<Value>(), completed = DispatchSemaphore(value: 0)
        queue.async { box.value = operation(); completed.signal() }
        completed.wait()
        return box.value!
    }
}
