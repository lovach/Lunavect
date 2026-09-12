import Foundation

/// Counts elapsed wall time supported by two consecutive observations, never poll counts.
public struct ActivityTracker {
    public private(set) var history: ActivityHistory
    public private(set) var details: ActivityDetails
    private var previous: (date: Date, rows: [AgentSession])?
    public init(history: ActivityHistory = ActivityHistory(), details: ActivityDetails = ActivityDetails()) { self.history = history; self.details = details }
    public mutating func prepareImport(now: Date) -> Date { history.prepareImport(now: now) }
    public mutating func mergeImport(_ result: ActivityImportResult, now: Date) {
        history.mergeRecovered(result.intervals, now: now, limited: result.limited, report: result.report)
        let boundary = history.importCutoff ?? now
        let clipped = result.details.map { record in
            var value = record
            value.intervals = record.intervals.compactMap {
                guard $0.start < boundary else { return nil }
                var span = $0; span.end = min(span.end, boundary); span.recovered = true
                return span.start < span.end ? span : nil
            }
            return value
        }
        details.merge(clipped, now: now)
    }
    public mutating func pruneDetails(now: Date) { details.prune(now: now) }
    public mutating func observe(_ rows: [AgentSession], now: Date = Date()) {
        // A clock moving backward must not count the same interval twice.
        if let previous, now <= previous.date { return }
        defer { previous = (now, rows) }
        guard let previous, now.timeIntervalSince(previous.date) <= 10,
              history.intervals.last.map({ $0.end <= previous.date }) ?? true else { return }
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
            details.append(rows.first(where: { $0.id == row.id }) ?? row, start: previous.date, end: now)
        }
        history.append(start: previous.date, end: now, providers: mask, observedProviders: observed)
    }
}
