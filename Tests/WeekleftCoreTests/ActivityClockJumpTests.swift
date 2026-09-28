import XCTest
@testable import WeekleftCore

/// Wall-clock jumps while the app observes: a clock set far ahead and then
/// corrected must not stop live collection in the corrected present (R2-P).
final class ActivityClockJumpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(at date: Date, phase: SessionPhase = .running) -> AgentSession {
        AgentSession(provider: .claude, sessionID: "fixture", title: "Synthetic", cwd: "/tmp/fixture", phase: phase,
                     updatedAt: date, observedAt: date, evidence: .localEvent, runtimeConfirmed: true)
    }
    private func observe(_ tracker: inout ActivityTracker, from start: Date, seconds: [TimeInterval]) {
        for offset in seconds { tracker.observe([row(at: start.addingTimeInterval(offset))], now: start.addingTimeInterval(offset)) }
    }

    func testCorrectedForwardJumpKeepsRecordingThePresent() {
        for jump in [40.0, 400.0] {
            var tracker = ActivityTracker()
            observe(&tracker, from: base, seconds: [0, 5, 10])
            // The clock is set `jump` days ahead for a moment, then corrected.
            let ahead = base.addingTimeInterval(jump * 86400)
            observe(&tracker, from: ahead, seconds: [0, 5])
            let present = base.addingTimeInterval(3600)
            observe(&tracker, from: present, seconds: [0, 5, 10, 15, 20])
            XCTAssertEqual(tracker.history.summary(now: present.addingTimeInterval(20), period: .day).totals.claude, 20,
                           "\(Int(jump)) days ahead: work observed after the correction is recorded")
            // A restart after the correction reconciles the same way.
            var restarted = ActivityTracker(history: tracker.history, details: tracker.details)
            let later = present.addingTimeInterval(600)
            observe(&restarted, from: later, seconds: [0, 5, 10])
            XCTAssertEqual(restarted.history.summary(now: later.addingTimeInterval(10), period: .day).totals.claude, 30,
                           "\(Int(jump)) days ahead: a restarted tracker records the present too")
            XCTAssertEqual(restarted.details.records.values.first?.totals(in: DateInterval(start: present, end: later.addingTimeInterval(10))).active, 30)
        }
    }
}
