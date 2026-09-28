import Foundation

public enum SessionNoticeKind: String, CaseIterable, Sendable {
    case completed, permission, input, failed, limit
    public var title: String {
        switch self {
        case .completed: return L("Ответ готов")
        case .permission: return L("Нужно разрешение")
        case .input: return L("Ждёт ответа")
        case .failed: return L("Ошибка")
        case .limit: return L("Лимиты")
        }
    }
}
public struct SessionNotice: Sendable {
    public let session: AgentSession
    public let kind: SessionNoticeKind
}
/// Observed transitions, not a notification on every catalog refresh.
public struct SessionNoticeTracker {
    private struct Seen {
        var phase: SessionPhase
        var observedAt: Date
        var lastSeenAt: Date
        /// Task-event time (`updatedAt`) of the last reply or failure already
        /// announced or seen as the baseline: one event, at most one notice.
        var settledAt: Date?
    }
    private var seen: [String: Seen] = [:]
    private var lastPoll: Date?
    public init() {}
    public mutating func update(_ rows: [AgentSession], now: Date = Date()) -> [SessionNotice] {
        let resumed = lastPoll.map { now.timeIntervalSince($0) > 120 || now.timeIntervalSince($0) < -300 } ?? false
        let previousPoll = lastPoll
        lastPoll = now
        if resumed { seen.removeAll() }
        var result: [SessionNotice] = []
        for row in rows {
            // Retained task state is neither a live transition nor a baseline
            // for an alert when the user later reopens that session.
            guard !(row.catalogHistory == true && [.input, .permission].contains(row.phase)) else {
                seen.removeValue(forKey: row.id); continue
            }
            let phase = row.effectivePhase(now: now)
            guard phase != .unknown else {
                if seen[row.id] != nil { seen[row.id]?.lastSeenAt = now }
                continue
            }
            var prior = seen[row.id]
            guard prior == nil || row.observedAt >= prior!.observedAt else { continue }
            // Only the initial list is history. A session first seen while monitoring
            // runs, whose task event came after the previous poll, started working in
            // between: its prompt and next state fell between two reads (R2-S-03).
            // Catalog-only rows carry no event time and stay a baseline.
            if prior == nil, !resumed, let previousPoll, row.evidence != .catalog,
               row.hasTaskActivity == true, row.updatedAt > previousPoll {
                prior = Seen(phase: .running, observedAt: .distantPast, lastSeenAt: now, settledAt: nil)
            }
            // A newer Claude listing requested while Stop hooks still run says busy for
            // one poll; the next idle listing restores the same reply. Settle each
            // event-timed reply or failure so that flicker cannot repeat it (R2-S-02).
            // A row carries an event time when a hook, log or status-bar record
            // decided it or contributed task activity to it; a catalog-only row
            // carries only a start time and is never settled.
            let settles = [.ready, .failed, .finished].contains(phase) && (row.evidence != .catalog || row.hasTaskActivity == true)
            seen[row.id] = Seen(phase: phase, observedAt: row.observedAt,
                               lastSeenAt: now, settledAt: settles ? row.updatedAt : prior?.settledAt)
            // Baseline on first sight of the initial list, and after a long monitoring gap. No historical alerts.
            guard let prior, prior.phase != phase, !resumed,
                  now.timeIntervalSince(row.observedAt) < 60,
                  !(settles && prior.settledAt == row.updatedAt) else { continue }
            let kind: SessionNoticeKind?
            switch phase {
            // Only a reply announces completion. SessionEnd after active work
            // without a Stop means the client closed, often right after Esc: silent.
            case .ready: kind = [.running, .permission, .input].contains(prior.phase) ? .completed : nil
            // `claude -p` and SDK scripts send Stop and SessionEnd within milliseconds;
            // one read can see only the end of a reply Stop already answered (R2-05).
            case .finished: kind = [.running, .permission, .input].contains(prior.phase) && row.replyFinished == true ? .completed : nil
            case .permission: kind = .permission
            case .input: kind = .input
            case .failed: kind = [.running, .permission, .input].contains(prior.phase) ? .failed : nil
            default: kind = nil
            }
            if let kind { result.append(SessionNotice(session: row, kind: kind)) }
        }
        // Keep recent disappeared/hidden sessions so rediscovery doesn't replay an alert.
        seen = seen.filter { now.timeIntervalSince($0.value.lastSeenAt) < 86400 }
        return result
    }
}
