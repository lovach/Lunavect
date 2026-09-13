import Foundation

/// Counts elapsed wall time supported by two consecutive observations, never poll counts.
public struct ActivityTracker {
    public private(set) var history: ActivityHistory
    public private(set) var details: ActivityDetails
    private var previous: (date: Date, rows: [AgentSession])?
    private var clockWasCorrected = false
    public init(history: ActivityHistory = ActivityHistory(), details: ActivityDetails = ActivityDetails()) { self.history = history; self.details = details }
    public mutating func prepareImport(now: Date) -> Date { history.prepareImport(now: now) }
    public mutating func prepareImport(providers: Set<ProviderID>, now: Date) -> [ProviderID: Date] { history.prepareImport(providers: providers, now: now) }
    public mutating func mergeImport(_ result: ActivityImportResult, now: Date, providers: Set<ProviderID>? = nil) {
        history.mergeRecovered(result.intervals, now: now, limited: result.limited, report: result.report, providers: providers)
        let clipped = result.details.map { record in
            let boundary = providers == nil ? history.importCutoff ?? now : history.providerImportCutoffs?[record.provider.rawValue] ?? now
            var value = record
            if let providers, !providers.contains(record.provider) { value.intervals = []; return value }
            value.intervals = record.intervals.compactMap {
                guard $0.start < boundary else { return nil }
                var span = $0; span.end = min(span.end, boundary); span.recovered = true; span.recoveredProviders = span.providers; span.liveObservedProviders = 0
                return span.start < span.end ? span : nil
            }
            return value
        }
        details.merge(clipped, now: now)
    }
    public mutating func pruneDetails(now: Date) { details.prune(now: now) }
    public mutating func observe(_ rows: [AgentSession], now: Date = Date()) {
        // History ending in the future means the clock moved back while no tracker
        // was observing (restart, provider change). Reconcile instead of waiting.
        if previous == nil, let last = history.intervals.last, last.end > now { clockWasCorrected = true }
        // A clock moving backward must not count the same interval twice.
        if let previous, now <= previous.date {
            if now.timeIntervalSince(previous.date) < -300 {
                self.previous = (now, rows); clockWasCorrected = true
            }
            return
        }
        defer { previous = (now, rows) }
        guard let previous, now.timeIntervalSince(previous.date) <= 10,
              clockWasCorrected || (history.intervals.last.map({ $0.end <= previous.date }) ?? true) else { return }
        let known = Set(rows.filter { $0.effectivePhase(now: now) != .unknown && $0.observedAt <= now }.map(\.id))
        // Without any continuing, fresh source there is no observation of
        // inactivity either. Preserve a gap instead of drawing a false zero.
        var observed = 0
        for row in previous.rows where known.contains(row.id) && row.observedAt <= previous.date &&
            row.effectivePhase(now: previous.date) != .unknown && row.effectivePhase(now: now) != .unknown {
            observed |= row.provider == .claude ? 1 : 2
        }
        guard observed != 0 else { return }
        let current = Set(rows.filter { $0.effectivePhase(now: now) == .running && $0.observedAt <= now }.map(\.id))
        var mask = 0
        for row in previous.rows where current.contains(row.id) &&
            row.observedAt <= previous.date && row.effectivePhase(now: previous.date) == .running && row.effectivePhase(now: now) == .running {
            mask |= row.provider == .claude ? 1 : 2
            details.append(rows.first(where: { $0.id == row.id }) ?? row, start: previous.date, end: now, reconcilingClockCorrection: clockWasCorrected)
        }
        history.append(start: previous.date, end: now, providers: mask, observedProviders: observed, reconcilingClockCorrection: clockWasCorrected)
    }
}
