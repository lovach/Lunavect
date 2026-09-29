import Foundation
import os
#if SWIFT_PACKAGE
import WeekleftCore
#endif

/// Keeps the token ledger current: reads what the Claude and Codex logs gained on a
/// utility queue, publishes the result and hands the days to the statistics archive.
@MainActor final class TokenService: ObservableObject {
    @Published private(set) var ledger: TokenLedger
    /// True until every log has been read once; the first pass over months of logs takes a while.
    @Published private(set) var catchingUp = false
    /// Receives the ledger's days whenever they change, before old days are dropped.
    var onDaily: (([String: [String: TokenCounts]]) -> Void)?
    typealias Scan = @Sendable (inout TokenLedger, Date) -> TokenLedger.ScanReport
    private let url: URL?
    private let scan: Scan
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "com.weekleft.token-ledger", qos: .utility)
    private let logger = Logger(subsystem: "com.weekleft.app", category: "tokens")
    private var loop: Task<Void, Never>?
    private var savedAt = Date.distantPast
    private var unsaved = false

    /// - Parameter url: nil keeps the ledger in memory (previews, tests without a fixture file).
    /// - Parameter scan: reads the logs; under tests the default reads nothing, so no test sees the real logs.
    init(url: URL? = TokenService.defaultURL, clock: @escaping () -> Date = Date.init, scan: Scan? = nil) {
        self.url = url; self.clock = clock
        let idle: Scan = { _, _ in .init() }, logs: Scan = { ledger, now in ledger.scan(now: now) }
        self.scan = scan ?? (LiveWriteGuard.underTestsForStores ? idle : logs)
        ledger = url.flatMap { try? TokenLedger.load(from: $0) } ?? TokenLedger()
        catchingUp = ledger.caughtUp != true
    }
    nonisolated static var defaultURL: URL? { LiveWriteGuard.underTestsForStores ? nil : TokenLedger.fileURL }

    func start(interval: Duration = .seconds(15)) {
        guard loop == nil else { return }
        onDaily?(ledger.daily)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanOnce()
                // The first pass continues at once in slices; afterwards only appended lines are read.
                let pause: Duration = self.catchingUp ? .milliseconds(300) : interval
                try? await Task.sleep(for: pause)
            }
        }
    }
    func stop() {
        loop?.cancel(); loop = nil
        save(force: true)
    }

    func scanOnce() async {
        let current = ledger, now = clock(), scan = scan
        let (updated, report) = await withCheckedContinuation { (continuation: CheckedContinuation<(TokenLedger, TokenLedger.ScanReport), Never>) in
            queue.async {
                var copy = current
                let report = scan(&copy, now)
                continuation.resume(returning: (copy, report))
            }
        }
        let changed = report.filesRead > 0 || updated.caughtUp != ledger.caughtUp
        if changed {
            var value = updated
            onDaily?(value.daily)
            value.pruneDays(now: now)
            ledger = value; unsaved = true
        }
        if catchingUp != (updated.caughtUp != true) { catchingUp = updated.caughtUp != true }
        save(force: false)
    }

    /// At most once a minute while working; the ledger is several megabytes.
    private func save(force: Bool) {
        guard unsaved, let url, force || clock().timeIntervalSince(savedAt) >= 60 else { return }
        let value = ledger
        unsaved = false; savedAt = clock()
        let write: @Sendable () -> Void = { [logger] in
            do { try value.save(to: url) }
            catch { logger.error("Token ledger not saved: \((error as NSError).domain, privacy: .public) \((error as NSError).code)") }
        }
        if force { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    // MARK: Queries for the interface

    func tokens(_ provider: ProviderID, sessionID: String) -> SessionTokens? { ledger.sessions[TokenLedger.sessionKey(provider, sessionID)] }

    /// Estimated percent of a limit window a session used, and its current pace in percent an hour.
    func share(of session: SessionTokens, window: QuotaWindow?, now: Date) -> (percent: Double, perHour: Double)? {
        guard let window, let percent = ledger.limitPercent(of: session, window: window, now: now),
              let resets = window.resetsAt else { return nil }
        let start = resets.addingTimeInterval(-Double(window.durationMinutes) * 60)
        let total = ledger.weight(session.provider, from: start, to: now)
        let perHour = total > 0 ? window.usedPercent * session.rate(now: now) / total : 0
        return (percent, perHour)
    }
}
