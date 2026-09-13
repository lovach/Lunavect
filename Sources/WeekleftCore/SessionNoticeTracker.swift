import Foundation

public enum SessionNoticeKind: String, CaseIterable, Sendable {
    case completed, permission, input
    public var title: String {
        switch self {
        case .completed: return L("Ответ готов")
        case .permission: return L("Нужно разрешение")
        case .input: return L("Ждёт ответа")
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
    }
    private var seen: [String: Seen] = [:]
    private var lastPoll: Date?
    public init() {}
    public mutating func update(_ rows: [AgentSession], now: Date = Date()) -> [SessionNotice] {
        let resumed = lastPoll.map { now.timeIntervalSince($0) > 120 || now.timeIntervalSince($0) < -300 } ?? false
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
            let prior = seen[row.id]
            guard prior == nil || row.observedAt >= prior!.observedAt else { continue }
            seen[row.id] = Seen(phase: phase, observedAt: row.observedAt,
                               lastSeenAt: now)
            // Baseline on first sight, and after a long monitoring gap. No historical alerts.
            guard let prior, prior.phase != phase, !resumed,
                  now.timeIntervalSince(row.observedAt) < 60 else { continue }
            let kind: SessionNoticeKind?
            switch phase {
            case .ready, .finished: kind = [.running, .permission, .input].contains(prior.phase) ? .completed : nil
            case .permission: kind = .permission
            case .input: kind = .input
            default: kind = nil
            }
            if let kind { result.append(SessionNotice(session: row, kind: kind)) }
        }
        // Keep recent disappeared/hidden sessions so rediscovery doesn't replay an alert.
        seen = seen.filter { now.timeIntervalSince($0.value.lastSeenAt) < 86400 }
        return result
    }
}
