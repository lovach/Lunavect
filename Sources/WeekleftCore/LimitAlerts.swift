import Foundation

public enum LimitWindowKind: String, Codable, Sendable { case fiveHour, weekly }

public struct LimitAlert: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case low(remaining: Int), restored }
    public let provider: ProviderID
    public let window: LimitWindowKind
    public let kind: Kind
    public let resetsAt: Date
    public init(provider: ProviderID, window: LimitWindowKind, kind: Kind, resetsAt: Date) {
        self.provider = provider; self.window = window; self.kind = kind; self.resetsAt = resetsAt
    }
}

/// One quota window until its reset: whether the low-limit alert was sent and
/// whether its return was announced. Persisted so a restart doesn't repeat them.
public struct LimitAlertState: Codable, Equatable, Sendable {
    public struct Cycle: Codable, Equatable, Sendable {
        public var provider: ProviderID
        public var window: LimitWindowKind
        /// The first reading of this reset. Readings within `sameCycle` of it belong to this cycle.
        public var resetsAt: Date
        /// A later reading of the same reset (Q-05), absent in older saved states.
        public var latestReset: Date?
        public var warned = false
        public var closed = false
        /// When the window has certainly reset: the latest reading, never an earlier one.
        public var returnsAt: Date { max(resetsAt, latestReset ?? resetsAt) }
    }
    public var cycles: [Cycle] = []
    public init(cycles: [Cycle] = []) { self.cycles = cycles }
}

/// Alerts from fresh quota observations only: an unknown or saved value never
/// crosses the threshold, and a reset is announced only for a window that was low.
public struct LimitAlertTracker {
    /// Sources round the same reset differently (statusLine, `/usage`, Codex).
    static let sameCycle: TimeInterval = 900
    /// A reset learned much later (the app was not running) is closed silently.
    static let lateReset: TimeInterval = 3600
    public private(set) var state: LimitAlertState
    public init(state: LimitAlertState = LimitAlertState()) { self.state = state }

    /// - Parameters:
    ///   - announce: false while limit notifications cannot be delivered; a low
    ///     window is then not consumed, and returns close silently.
    ///   - providers: connected providers; returns of other providers close silently.
    public mutating func update(_ snapshots: [UsageSnapshot], threshold: Int, now: Date,
                                announce: Bool = true, providers: Set<ProviderID>? = nil) -> [LimitAlert] {
        var alerts: [LimitAlert] = []
        for snapshot in snapshots where providers?.contains(snapshot.provider) ?? true {
            for (kind, window) in [(LimitWindowKind.fiveHour, snapshot.fiveHour), (.weekly, snapshot.weekly)] {
                guard let window, let resetsAt = window.resetsAt else { continue }
                // A later reading of the same reset (the end of the minute `/usage`
                // showed, the exact status-line epoch, a cycle saved by an earlier
                // version) moves the return later, never earlier: it is announced
                // only once the window has certainly reset (Q-05). Saved values count
                // here, since they can only delay the announcement.
                for other in state.cycles.indices where state.cycles[other].provider == snapshot.provider
                    && state.cycles[other].window == kind && !state.cycles[other].closed
                    && abs(state.cycles[other].resetsAt.timeIntervalSince(resetsAt)) <= Self.sameCycle && resetsAt > state.cycles[other].returnsAt {
                    state.cycles[other].latestReset = resetsAt
                }
                guard !snapshot.isStale(window: window, now: now), resetsAt > now else { continue }
                let index = state.cycles.firstIndex {
                    $0.provider == snapshot.provider && $0.window == kind && abs($0.resetsAt.timeIntervalSince(resetsAt)) <= Self.sameCycle
                } ?? {
                    // The provider moved this window's reset: the earlier cycle will not reset as announced.
                    for other in state.cycles.indices where state.cycles[other].provider == snapshot.provider
                        && state.cycles[other].window == kind && !state.cycles[other].closed && state.cycles[other].returnsAt > now {
                        state.cycles[other].closed = true
                    }
                    state.cycles.append(.init(provider: snapshot.provider, window: kind, resetsAt: resetsAt))
                    return state.cycles.count - 1
                }()
                // Compare the same whole percentage that every surface displays.
                let shown = Int(window.remaining.rounded())
                guard announce, !state.cycles[index].warned, shown < threshold else { continue }
                state.cycles[index].warned = true
                alerts.append(LimitAlert(provider: snapshot.provider, window: kind, kind: .low(remaining: shown), resetsAt: state.cycles[index].returnsAt))
            }
        }
        for index in state.cycles.indices where !state.cycles[index].closed && state.cycles[index].returnsAt <= now {
            let cycle = state.cycles[index]
            state.cycles[index].closed = true
            if announce, cycle.warned, providers?.contains(cycle.provider) ?? true, now.timeIntervalSince(cycle.returnsAt) <= Self.lateReset {
                alerts.append(LimitAlert(provider: cycle.provider, window: cycle.window, kind: .restored, resetsAt: cycle.returnsAt))
            }
        }
        state.cycles.removeAll { now.timeIntervalSince($0.returnsAt) > 8 * 86400 }
        return alerts
    }

    /// The next moment a low window resets and should be announced.
    public func nextDeadline(now: Date) -> Date? {
        state.cycles.filter { $0.warned && !$0.closed && now.timeIntervalSince($0.returnsAt) <= Self.lateReset }.map(\.returnsAt).min()
    }
}
