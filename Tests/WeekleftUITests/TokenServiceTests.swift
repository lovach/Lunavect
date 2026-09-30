import XCTest
import WeekleftCore
@testable import Weekleft

/// Audit 30.09: the first pass reads the logs in slices; old days must stay whole across them, and the
/// archive takes older days only as rises until the pass is complete.
@MainActor final class TokenServiceTests: XCTestCase {
    func testTheFirstPassKeepsOldDaysAndHandsTheArchiveTheRightBoundary() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        let old = now.addingTimeInterval(-50 * 86400), day = ActivityArchive.key(old, calendar: calendar)
        final class Pass: @unchecked Sendable { var slice = 0 }
        let pass = Pass()
        let service = TokenService(url: nil, clock: { now }, scan: { ledger, now in
            pass.slice += 1
            ledger.record(TokenCounts(output: pass.slice == 1 ? 4 : 6), provider: .claude, session: "s\(pass.slice)", cwd: "/p", model: "m",
                          subagent: false, at: old, now: now, calendar: .current)
            var report = TokenLedger.ScanReport(); report.filesRead = 1; report.complete = pass.slice == 2
            if report.complete { ledger.caughtUp = true }
            return report
        })
        var handed: [(days: [String: [String: TokenCounts]], from: String)] = []
        service.onDaily = { handed.append(($0, $1)) }
        await service.scanOnce()
        XCTAssertEqual(handed.last?.from, "~", "during the first pass every day only rises")
        XCTAssertEqual(service.ledger.daily[day]?.values.reduce(0) { $0 + $1.output }, 4, "not dropped between slices")
        await service.scanOnce()
        XCTAssertEqual(handed.last?.days[day]?.values.reduce(0) { $0 + $1.output }, 10, "the whole day reaches the archive")
        XCTAssertEqual(handed.last?.from, ActivityArchive.key(now.addingTimeInterval(-Double(TokenLedger.keepDays) * 86400), calendar: calendar))
        XCTAssertNil(service.ledger.daily[day], "dropped once the archive has it")
    }
}
