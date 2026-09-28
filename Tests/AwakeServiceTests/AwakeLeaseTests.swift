import XCTest
@testable import AwakeService

private final class Setting: SleepSetting {
    var disabled = false
    var failEnable = false, failRestore = false, mutateThenFail = false
    var writes: [Bool] = []
    var reads = 0
    func isDisabled() -> Bool { reads += 1; return disabled }
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
    func testConfigurableSafetySeparatesBatteryThermalAndPowerRules() {
        var policy = AwakeSafetyPolicy()
        XCTAssertEqual(policy.failure(onBattery: true, batteryPercent: 10, thermalSeverity: 0), .battery)
        XCTAssertNil(policy.failure(onBattery: false, batteryPercent: 2, thermalSeverity: 0))
        policy.batteryProtection = false
        XCTAssertNil(policy.failure(onBattery: true, batteryPercent: 2, thermalSeverity: 0))
        XCTAssertEqual(policy.failure(onBattery: false, batteryPercent: nil, thermalSeverity: 2), .thermal)
        policy.thermalProtection = false
        XCTAssertNil(policy.failure(onBattery: true, batteryPercent: 2, thermalSeverity: 3))
        policy.allowBattery = false
        XCTAssertEqual(policy.failure(onBattery: true, batteryPercent: nil, thermalSeverity: 0), .power)
    }
    func testSafetyChangeAppliesToActiveLeaseWithoutExtendingIt() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        let now = Date()
        var uptime: TimeInterval = 0
        let lease = try AwakeLease(setting: setting, journal: journal, now: { now }, uptime: { uptime },
            safety: { $0.failure(onBattery: true, batteryPercent: 18, thermalSeverity: 0) })
        try lease.begin(owner: owner, seconds: 0)
        var policy = AwakeSafetyPolicy(minimumBatteryPercent: 20)
        XCTAssertThrowsError(try lease.configure(owner: UUID(), policy: policy))
        XCTAssertTrue(setting.disabled)
        XCTAssertThrowsError(try lease.configure(owner: owner, policy: policy)) {
            XCTAssertEqual($0 as? AwakeFailure, .battery)
        }
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
        policy.batteryProtection = false; policy.thermalProtection = false
        try lease.begin(owner: owner, seconds: 0, policy: policy)
        uptime = 25; try lease.configure(owner: owner, policy: policy)
        uptime = 31; lease.tick()
        XCTAssertFalse(setting.disabled, "Disabling optional checks never disables the connection lease")
        XCTAssertEqual(lease.lastFailure, .expired)
        XCTAssertThrowsError(try lease.begin(owner: owner, seconds: 0, policy: .init(minimumBatteryPercent: 30)))
    }
    func testThermalChoiceIsAppliedByHelperAndDefaultsReturnForNextOwner() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        let lease = try AwakeLease(setting: setting, journal: journal,
            safety: { $0.failure(onBattery: false, batteryPercent: nil, thermalSeverity: 2) })
        XCTAssertThrowsError(try lease.begin(owner: owner, seconds: 0))
        try lease.begin(owner: owner, seconds: 0, policy: .init(thermalProtection: false))
        lease.tick(); XCTAssertTrue(setting.disabled)
        try lease.end(owner: owner)
        XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0))
        XCTAssertFalse(setting.disabled)
    }
    func testPolicyValidationBoundsExternalValues() throws {
        XCTAssertEqual(AwakeSafetyPolicy(minimumBatteryPercent: -10).minimumBatteryPercent, 5)
        var policy = AwakeSafetyPolicy()
        policy.minimumBatteryPercent = 1000
        let restored = try JSONDecoder().decode(AwakeSafetyPolicy.self, from: JSONEncoder().encode(policy)).normalized
        XCTAssertEqual(restored.minimumBatteryPercent, 50)
    }
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
            let lease = try AwakeLease(setting: setting, journal: journal, safety: { _ in safety })
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
        var uptime: TimeInterval = 0
        let lease = try AwakeLease(setting: setting, journal: journal, uptime: { uptime })
        try lease.begin(owner: owner, seconds: 0)
        setting.disabled = false
        uptime = 20; try lease.keepAlive(owner: owner)
        uptime = 31
        XCTAssertThrowsError(try lease.keepAlive(owner: owner))
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending)
    }
    func testClockRollbackCannotExtendTimedLeaseWhileHeartbeatsContinue() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var now = start, uptime: TimeInterval = 0
        let lease = try AwakeLease(setting: setting, journal: journal, now: { now }, uptime: { uptime })
        try lease.begin(owner: owner, seconds: 900)
        for elapsed in stride(from: 10, through: 890, by: 10) {
            uptime = Double(elapsed)
            now = start.addingTimeInterval(uptime - 3600)
            try lease.keepAlive(owner: owner)
        }
        XCTAssertTrue(setting.disabled)
        uptime = 900
        lease.tick()
        XCTAssertFalse(setting.disabled, "The 15-minute choice must expire after 15 elapsed minutes despite a clock correction")
        XCTAssertFalse(journal.pending)
        XCTAssertEqual(lease.lastFailure, .expired)
        XCTAssertThrowsError(try lease.keepAlive(owner: owner))
        // A later untimed lease must not inherit the previous duration deadline.
        try lease.begin(owner: owner, seconds: 0)
        uptime = 910; try lease.keepAlive(owner: owner)
        XCTAssertTrue(setting.disabled)
        try lease.end(owner: owner)
    }
    func testHeartbeatsDoNotSpawnSystemQueryOnEveryTick() throws {
        let setting = Setting(), journal = Journal(), owner = UUID()
        var uptime: TimeInterval = 0
        let lease = try AwakeLease(setting: setting, journal: journal, uptime: { uptime })
        XCTAssertTrue(lease.isIdle)
        try lease.begin(owner: owner, seconds: 0)
        XCTAssertFalse(lease.isIdle)
        let baseline = setting.reads
        for second in stride(from: 5, through: 60, by: 5) {
            uptime = Double(second); lease.tick(); try lease.keepAlive(owner: owner)
        }
        XCTAssertEqual(setting.reads - baseline, 2)
        try lease.end(owner: owner)
        XCTAssertTrue(lease.isIdle)
    }
    func testSystemSettingReadOnlyProbe() throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_TEST_AWAKE"] == "1" else { throw XCTSkip("Opt-in real pmset read; never mutates sleep") }
        _ = try SystemSleepSetting().isDisabled()
    }
}

/// Without a launchd respawn rule (decision 16) the helper itself must keep
/// retrying recovery, and its system boundaries are checked on fixtures only:
/// no pmset and no root journal (audit 05 H-02, H-11, §5 items 8 and 15).
final class AwakeHelperBoundaryTests: XCTestCase {
    func testRecoveryFailureAtStartupKeepsTheHelperRetryingInsteadOfExiting() throws {
        let setting = Setting(), journal = Journal()
        // A crashed lease left sleep disabled; pmset fails once at boot.
        setting.disabled = true; journal.pending = true; setting.failRestore = true
        let lease = try AwakeLease(setting: setting, journal: journal)
        XCTAssertFalse(lease.isIdle, "a pending restoration keeps the helper running")
        XCTAssertEqual(lease.lastFailure, .recovery)
        XCTAssertThrowsError(try lease.begin(owner: UUID(), seconds: 0), "no new lease before sleep is restored")
        setting.failRestore = false
        lease.tick()
        XCTAssertFalse(setting.disabled); XCTAssertFalse(journal.pending); XCTAssertTrue(lease.isIdle)
    }
    func testSleepSettingParsesPmsetOutputAndRejectsUnknownOutput() throws {
        let header = "System-wide power settings:\n"
        let current = "Currently in use:\n standby              1\n sleep                1 (sleep prevented by powerd)\n displaysleep         10\n"
        XCTAssertTrue(try SystemSleepSetting.parse(header + " SleepDisabled\t\t1\n" + current))
        XCTAssertFalse(try SystemSleepSetting.parse(header + " SleepDisabled\t\t0\n" + current))
        XCTAssertFalse(try SystemSleepSetting.parse(header + current), "never set: header without the key")
        XCTAssertFalse(try SystemSleepSetting.parse(current), "never set: no system-wide section at all")
        for unknown in ["", "pmset: command failed\n", header + " SleepDisabled\t\t2\n" + current,
                        header + " SleepDisabled 1 (by another tool)\n" + current] {
            XCTAssertThrowsError(try SystemSleepSetting.parse(unknown), unknown) { XCTAssertEqual($0 as? AwakeFailure, .system) }
        }
    }
    func testRecoveryJournalSurvivesARestartAndRefusesUnsafeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("awake-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("com.weekleft.awake").path, owner = geteuid()
        let journal = try SystemAwakeJournal(path: path, owner: owner)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertFalse(try journal.hasPendingRestore())
        try journal.mark()
        XCTAssertThrowsError(try journal.mark(), "an existing marker is never replaced")
        let restarted = try SystemAwakeJournal(path: path, owner: owner)
        XCTAssertTrue(try restarted.hasPendingRestore(), "a restarted helper sees the crash marker")
        try restarted.clear(); try restarted.clear()
        XCTAssertFalse(try journal.hasPendingRestore())
        XCTAssertThrowsError(try SystemAwakeJournal(path: path, owner: owner + 1), "another owner's folder")
        chmod(path, 0o755)
        XCTAssertThrowsError(try SystemAwakeJournal(path: path, owner: owner), "a folder others can read")
        chmod(path, 0o700)
        let link = root.appendingPathComponent("linked").path
        XCTAssertEqual(symlink(path, link), 0)
        XCTAssertThrowsError(try SystemAwakeJournal(path: link, owner: owner), "a linked folder is not followed")
        XCTAssertEqual(symlink("/etc/hosts", path + "/restore-sleep"), 0)
        XCTAssertThrowsError(try restarted.hasPendingRestore(), "a linked marker is not followed")
    }
}
