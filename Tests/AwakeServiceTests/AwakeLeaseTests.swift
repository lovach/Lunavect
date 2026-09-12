import XCTest
@testable import AwakeService

private final class Setting: SleepSetting {
    var disabled = false
    var failEnable = false, failRestore = false, mutateThenFail = false
    var writes: [Bool] = []
    func isDisabled() -> Bool { disabled }
    func setDisabled(_ value: Bool) throws {
        writes.append(value)
        if value && failEnable || !value && failRestore { throw AwakeFailure.system }
        disabled = value
        if value && mutateThenFail { throw AwakeFailure.system }
    }
}
private final class Journal: AwakeJournal {
    var pending = false, failMark = false
    func hasPendingRestore() -> Bool { pending }
    func mark() throws { if failMark { throw AwakeFailure.recovery }; pending = true }
    func clear() { pending = false }
}
final class AwakeLeaseTests: XCTestCase {
    func testLeaseExpiryReleasesGlobalSettingEvenWithoutClient() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        var uptime: TimeInterval = 100
        let lease = try AwakeLease(setting: setting, journal: journal, uptime: { uptime })
        try lease.begin(owner: owner, seconds: 0)
        XCTAssertTrue(setting.disabled); XCTAssertTrue(journal.pending)
        uptime += 25; try lease.keepAlive(owner: owner)
        uptime += 29; lease.tick(); XCTAssertTrue(setting.disabled)
        uptime += 2; lease.tick(); XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
        XCTAssertThrowsError(try lease.keepAlive(owner: owner))
    }
    func testRestartRecoversCrashMarkerBeforeAcceptingAnySession() throws {
        let setting = Setting(), journal = Journal()
        let old = try AwakeLease(setting: setting, journal: journal)
        try old.begin(owner: UUID(), seconds: 0)
        _ = try AwakeLease(setting: setting, journal: journal)
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
    }
    func testDoesNotTakeOwnershipOfAnExternalSleepOverride() throws {
        let setting = Setting(), journal = Journal()
        setting.disabled = true
        let lease = try AwakeLease(setting: setting, journal: journal)
        XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0)) { XCTAssertEqual($0 as? AwakeFailure, .external) }
        lease.shutdown(); lease.tick()
        XCTAssertTrue(setting.disabled); XCTAssertTrue(setting.writes.isEmpty); XCTAssertFalse(journal.pending)
    }
    func testRestoreFailureRetainsMarkerAndRetries() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        let lease = try AwakeLease(setting: setting, journal: journal)
        try lease.begin(owner: owner, seconds: 0)
        setting.failRestore = true
        XCTAssertThrowsError(try lease.end(owner: owner))
        XCTAssertTrue(journal.pending); XCTAssertTrue(setting.disabled)
        setting.failRestore = false; lease.tick()
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
    }
    func testFailedBeginRollsBackEvenIfCommandMutatedBeforeFailure() throws {
        let setting = Setting(), journal = Journal()
        setting.mutateThenFail = true
        let lease = try AwakeLease(setting: setting, journal: journal)
        XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0))
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
        XCTAssertEqual(setting.writes, [true, false])
    }
    func testJournalFailureNeverMutatesSystem() throws {
        let setting = Setting(), journal = Journal(); journal.failMark = true
        let lease = try AwakeLease(setting: setting, journal: journal)
        XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0))
        XCTAssertTrue(setting.writes.isEmpty)
    }
    func testOtherConnectionCannotRenewStopOrReplaceOwner() throws {
        let setting = Setting(), journal = Journal(), owner = UUID(), stranger = UUID()
        let lease = try AwakeLease(setting: setting, journal: journal)
        try lease.begin(owner: owner, seconds: 0)
        XCTAssertThrowsError(try lease.begin(owner: stranger, seconds: 900))
        XCTAssertThrowsError(try lease.keepAlive(owner: stranger))
        try lease.end(owner: stranger); XCTAssertTrue(setting.disabled)
        try lease.end(owner: owner); XCTAssertFalse(setting.disabled)
    }
    func testSafetyStopsActiveAndRefusesNewSession() throws {
        for reason in [AwakeFailure.battery, .thermal] {
            let setting = Setting(), journal = Journal()
            var safety: AwakeFailure?
            let lease = try AwakeLease(setting: setting, journal: journal, safety: { safety })
            try lease.begin(owner: UUID(), seconds: 0)
            safety = reason; lease.tick()
            XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
            XCTAssertEqual(lease.lastFailure, reason)
            XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0))
        }
    }
    func testAbsoluteDurationAndRenewalAreEnforcedByDaemon() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        var now = Date()
        let lease = try AwakeLease(setting: setting, journal: journal, now: { now })
        try lease.begin(owner: owner, seconds: 900)
        now += 800; try lease.begin(owner: owner, seconds: 3600)
        now += 900; lease.tick(); XCTAssertTrue(setting.disabled)
        now += 3000; lease.tick(); XCTAssertFalse(setting.disabled)
    }
    func testExternalRemovalDoesNotSilentlyReenable() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        let lease = try AwakeLease(setting: setting, journal: journal)
        try lease.begin(owner: owner, seconds: 0)
        setting.disabled = false
        XCTAssertThrowsError(try lease.keepAlive(owner: owner))
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
    }
    func testSystemSettingReadOnlyProbe() throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_TEST_AWAKE"] == "1" else { throw XCTSkip("Opt-in real pmset read; never mutates sleep") }
        _ = try SystemSleepSetting().isDisabled()
    }
}
