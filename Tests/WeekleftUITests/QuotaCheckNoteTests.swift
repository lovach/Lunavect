import XCTest
import WeekleftCore
@testable import Weekleft

/// An explicit check within 30 s of the previous one says when it can run again
/// instead of doing nothing (audit r2 R2-U-03).
final class QuotaCheckNoteTests: XCTestCase {
    func testOnlyATooSoonCheckExplainsWhenItCanRunAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(QuotaCheckAvailability.note(for: .asked, now: now))
        XCTAssertNil(QuotaCheckAvailability.note(for: .offline, now: now))
        XCTAssertNil(QuotaCheckAvailability.note(for: .running, now: now))
        let note = QuotaCheckAvailability.note(for: .tooSoon(until: now.addingTimeInterval(23.2)), now: now)
        XCTAssertEqual(note, L("Данные только что проверены. Повторить проверку можно через {0} с.", "24"))
        XCTAssertEqual(QuotaCheckAvailability.note(for: .tooSoon(until: now.addingTimeInterval(-5)), now: now),
                       L("Данные только что проверены. Повторить проверку можно через {0} с.", "1"))
    }

}
