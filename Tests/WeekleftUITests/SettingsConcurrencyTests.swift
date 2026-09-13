import XCTest
import SwiftUI
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class ConcurrencyAwakeClient: AwakeClient {
    var isAvailable = true
    var begins = 0
    var disconnects = 0
    func requestPermission() throws {}
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { begins += 1 }
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() { disconnects += 1 }
}

private actor AwakeReferenceOwner {
    private var value: KeepAwake?
    init(_ value: KeepAwake) { self.value = value }
    func release() { value = nil }
}

final class SettingsConcurrencyTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "Lunavect.SettingsConcurrency." + UUID().uuidString
        let result = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return result
    }

    @MainActor func testUpdateViewBindingsPreserveCouplingAndStoredChoices() throws {
        let defaults = try defaults()
        let updates = AppUpdates(defaults: defaults, isolated: true)
        let view = UpdateSettingsView(updates: updates)
        view.automaticDownloads.wrappedValue = false
        view.automaticChecks.wrappedValue = true
        XCTAssertTrue(view.automaticChecks.wrappedValue)
        XCTAssertFalse(view.automaticDownloads.wrappedValue)
        view.automaticDownloads.wrappedValue = true
        XCTAssertTrue(view.automaticChecks.wrappedValue)
        view.automaticChecks.wrappedValue = false
        XCTAssertFalse(view.automaticDownloads.wrappedValue)
        let restored = AppUpdates(defaults: defaults, isolated: true)
        XCTAssertFalse(restored.checkingAutomatically)
        XCTAssertFalse(restored.automatic)
    }

    @MainActor func testIdleGraceViewBindingMovesExistingDeadlineAndRejectsUnsupportedValue() async throws {
        let defaults = try defaults(), client = ConcurrencyAwakeClient()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        defer { awake.shutdown() }
        let view = KeepAwakeSettingsView(awake: awake)
        await awake.setAutomatic(true)
        await awake.start(for: .untilStopped)
        await awake.reconcileAutomatic()
        XCTAssertEqual(awake.idleDeadline, now.addingTimeInterval(60))
        view.idleGrace.wrappedValue = 120
        XCTAssertEqual(awake.idleDeadline, now.addingTimeInterval(120))
        XCTAssertEqual(defaults.integer(forKey: "awake.idleGraceSeconds"), 120)
        view.idleGrace.wrappedValue = 999
        XCTAssertEqual(view.idleGrace.wrappedValue, 120)
        XCTAssertEqual(awake.idleDeadline, now.addingTimeInterval(120))
    }

    @MainActor func testHeartbeatTimerIsInvalidatedWhenOwnerIsReleased() async throws {
        var timers: [Timer] = []
        var awake: KeepAwake? = KeepAwake(client: ConcurrencyAwakeClient(), defaults: try defaults(), scheduleTimer: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            return timer
        })
        await awake?.start(for: .untilStopped)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers.first?.timeInterval, 10)
        XCTAssertEqual(timers.first?.isValid, true)
        weak let released = awake
        awake = nil
        XCTAssertNil(released)
        XCTAssertEqual(timers.first?.isValid, false)
    }

    @MainActor func testPermissionTimerIsInvalidatedAfterPendingTaskReleasesOwner() async throws {
        let client = ConcurrencyAwakeClient(); client.isAvailable = false
        var timers: [Timer] = []
        var awake: KeepAwake? = KeepAwake(client: client, defaults: try defaults(), scheduleTimer: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            return timer
        })
        awake?.requestPermission()
        XCTAssertEqual(timers.first?.timeInterval, 1)
        XCTAssertEqual(timers.first?.isValid, true)
        weak let released = awake
        awake = nil
        for _ in 0..<50 where released != nil { await Task.yield() }
        XCTAssertNil(released)
        XCTAssertEqual(timers.first?.isValid, false)
        XCTAssertEqual(client.begins, 0)
    }

    @MainActor func testLastReleaseOnAnotherActorStillInvalidatesMainRunLoopTimer() async throws {
        var timers: [Timer] = []
        var awake: KeepAwake? = KeepAwake(client: ConcurrencyAwakeClient(), defaults: try defaults(), scheduleTimer: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            return timer
        })
        await awake?.start(for: .untilStopped)
        let owner = AwakeReferenceOwner(try XCTUnwrap(awake))
        awake = nil
        XCTAssertEqual(timers.first?.isValid, true)
        await owner.release()
        // Isolated deinit may enqueue cleanup on MainActor. Explicit shutdown is
        // still the immediate path; this verifies the eventual cleanup boundary.
        for _ in 0..<50 where timers.first?.isValid == true { await Task.yield() }
        XCTAssertEqual(timers.first?.isValid, false)
    }

    @MainActor func testShutdownInvalidatesBothTimersImmediatelyWhileOwnerSurvives() async throws {
        let client = ConcurrencyAwakeClient()
        var timers: [Timer] = []
        let awake = KeepAwake(client: client, defaults: try defaults(), scheduleTimer: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true, block: action)
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            return timer
        })
        await awake.start(for: .untilStopped)
        client.isAvailable = false
        awake.requestPermission()
        XCTAssertEqual(timers.count, 2)
        XCTAssertTrue(timers.allSatisfy(\.isValid))
        awake.shutdown()
        XCTAssertTrue(timers.allSatisfy { !$0.isValid })
        XCTAssertFalse(awake.isEnabled)
        XCTAssertFalse(awake.isAwaitingPermission)
        XCTAssertEqual(client.disconnects, 1)
    }
}
