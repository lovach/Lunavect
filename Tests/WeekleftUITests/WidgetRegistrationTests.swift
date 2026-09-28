import XCTest
import Darwin
import WeekleftCore
@testable import Weekleft

@MainActor final class WidgetRegistrationTests: XCTestCase {
    /// Stands in for the widget extension: a process with a chosen executable path.
    nonisolated private static let sleeper = CompiledFixture("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                                                 name: "LunavectWidget", prefix: "widget-registration-fixture")
    nonisolated override class func setUp() {
        super.setUp()
        _ = try? sleeper.executable() // one clang run per suite
    }
    nonisolated override class func tearDown() {
        sleeper.remove()
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "WidgetRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private let target = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Applications/Lunavect.app"), version: "158")

    func testUpgradeAndRelocationRepairOnceWithoutResettingPreferences() async {
        let defaults = defaults(), calls = Attempts(), checks = Attempts()
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set("old-build", forKey: WidgetRegistration.stampKey)
        var reloads = 0
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in await calls.record(); return true }, reassert: { _ in await checks.record(); return true },
            reload: { reloads += 1 }, pause: {}, settle: { _ in }, registeredCopies: { [] })
        service.start(); service.start()
        await service.waitUntilFinished()
        service.start(); await service.waitUntilFinished()
        let firstCalls = await calls.count, firstChecks = await checks.count
        XCTAssertEqual(firstCalls, 1, "A known build is repaired once")
        XCTAssertEqual(firstChecks, 4, "Every launch reasserts registration on the full schedule")
        XCTAssertEqual(reloads, 6)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), target.stamp)
        XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
        let relocated = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Users/fixture/Applications/Lunavect.app"), version: "158")
        let moved = WidgetRegistration(defaults: defaults, target: relocated,
            repair: { _ in await calls.record(); return true }, reassert: { _ in true }, reload: {}, pause: {}, settle: { _ in }, registeredCopies: { [] })
        moved.start(); await moved.waitUntilFinished()
        let totalCalls = await calls.count
        XCTAssertEqual(totalCalls, 2)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), relocated.stamp)
    }

    func testTransientFailureRetriesBeforeSavingStamp() async {
        let defaults = defaults(), calls = Attempts()
        var reloads = 0
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in await calls.record() > 1 }, reassert: { _ in true }, reload: { reloads += 1 }, pause: {}, settle: { _ in }, registeredCopies: { [] })
        service.start(); await service.waitUntilFinished()
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reloads, 4)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), target.stamp)
    }

    func testPersistentFailureDoesNotSuppressNextLaunch() async {
        let defaults = defaults(), calls = Attempts()
        for _ in 0..<2 {
            let service = WidgetRegistration(defaults: defaults, target: target,
                repair: { _ in await calls.record(); return false }, reassert: { _ in XCTFail("Unrepaired build"); return false },
                reload: { XCTFail("Failed registration") }, pause: {}, settle: { _ in }, registeredCopies: { [] })
            service.start(); await service.waitUntilFinished()
            XCTAssertNil(defaults.string(forKey: WidgetRegistration.stampKey))
        }
        let count = await calls.count
        XCTAssertEqual(count, 4)
    }

    func testCancelledRepairDoesNotSaveStampOrReload() async {
        let defaults = defaults()
        let started = expectation(description: "Repair is running")
        // The repair reports success after cancellation; the service must still discard it.
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in started.fulfill(); try? await Task.sleep(for: .seconds(60)); return true },
            reassert: { _ in XCTFail("Cancelled registration"); return false },
            reload: { XCTFail("Cancelled registration") }, pause: {}, settle: { _ in }, registeredCopies: { [] })
        service.start()
        await fulfillment(of: [started], timeout: 5)
        service.stop()
        await service.waitUntilFinished()
        XCTAssertNil(defaults.string(forKey: WidgetRegistration.stampKey))
    }

    func testEveryLaunchReassertsRegistrationAfterReplacedCopiesSettle() async {
        let defaults = defaults(), log = EventLog()
        defaults.set(target.stamp, forKey: WidgetRegistration.stampKey)
        var elapsed: Duration = .zero
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in XCTFail("Current build restarts no extension"); return false },
            reassert: { _ in log.add("reassert"); return true }, reload: { log.add("reload") }, pause: {},
            settle: { elapsed += $0; log.add("check at \(elapsed.components.seconds) s") }, registeredCopies: { [] })
        service.start(); await service.waitUntilFinished()
        // Behavior: every reassertion waits for its settle period first, and each
        // successful one reloads the widgets. The offsets pin the launch schedule
        // documented in docs/development.md (5 seconds and 2 minutes after launch).
        XCTAssertEqual(log.events, ["check at 5 s", "reassert", "reload", "check at 120 s", "reassert", "reload"],
                       "The first check follows the restart; the last one falls in a quiet period")
        let failures = Attempts()
        let failing = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in XCTFail("Current build restarts no extension"); return false },
            reassert: { _ in await failures.record(); return false }, reload: { XCTFail("Failed check") }, pause: {}, settle: { _ in }, registeredCopies: { [] })
        failing.start(); await failing.waitUntilFinished()
        let failed = await failures.count
        XCTAssertEqual(failed, 1, "A failed check is retried on the next launch, not in a loop")
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), target.stamp)
    }

    func testStopDuringSettleSkipsReassert() async {
        let defaults = defaults()
        let settling = expectation(description: "First settle is running")
        defaults.set(target.stamp, forKey: WidgetRegistration.stampKey)
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in XCTFail("Current build"); return false },
            reassert: { _ in XCTFail("Stopped before the check"); return false },
            reload: { XCTFail("Stopped before the check") }, pause: {},
            settle: { _ in settling.fulfill(); try await Task.sleep(for: .seconds(60)) }, registeredCopies: { [] })
        service.start()
        await fulfillment(of: [settling], timeout: 5)
        service.stop()
        await service.waitUntilFinished()
    }

    func testUninstalledBundleCannotStartRepair() async {
        let service = WidgetRegistration(defaults: defaults(), target: nil,
            repair: { _ in XCTFail("Not installed"); return false }, reassert: { _ in XCTFail("Not installed"); return false },
            reload: { XCTFail("Not installed") }, settle: { _ in }, registeredCopies: { [] })
        service.start(); await service.waitUntilFinished()
        XCTAssertNil(WidgetRegistrationTarget.installed(bundle: Bundle(for: Self.self)))
    }

    func testOnlyExactExtensionExecutableIsStopped() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Foundation can display /private/var as /var; proc_pidpath returns the
        // POSIX path. Keep the fixture target identical to the kernel's path.
        let canonical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical))
        defer { try? FileManager.default.removeItem(at: root) }
        // A copied Apple-signed /bin/sleep is not a stable synthetic executable:
        // macOS can reject the relocated binary before discovery. Build our own
        // once per suite and copy it to each extension path.
        let compiled = try Self.sleeper.executable()
        let own = WidgetRegistrationTarget(app: root.appendingPathComponent("Installed/Lunavect.app"), version: "1")
        let other = WidgetRegistrationTarget(app: root.appendingPathComponent("Archive/Lunavect.app"), version: "1")
        func launch(_ target: WidgetRegistrationTarget) throws -> Process {
            let executable = URL(fileURLWithPath: target.executable)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: compiled, to: executable)
            let process = Process(); process.executableURL = executable
            try process.run()
            // A teardown block also runs after failed assertions and thrown errors.
            addTeardownBlock { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            return process
        }
        let owned = try launch(own), unrelated = try launch(other)
        // Process.run can return before the spawned process exposes its final
        // executable path. Establish that both fixtures are discoverable before
        // exercising the production path matcher, and report the actual path if not.
        func path(of process: Process) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(process.processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
        for (process, target) in [(owned, own), (unrelated, other)] {
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, path(of: process) != target.executable, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(path(of: process), target.executable, "Fixture must expose the path used by the production matcher")
            guard path(of: process) == target.executable else { return }
        }
        let stopped = await Task.detached { WidgetRegistrationSystem.stopExtension(own) }.value
        XCTAssertTrue(stopped)
        owned.waitUntilExit()
        XCTAssertEqual(owned.terminationReason, .uncaughtSignal)
        XCTAssertEqual(owned.terminationStatus, SIGTERM)
        XCTAssertTrue(unrelated.isRunning)
    }
}


@MainActor final class WidgetHealthTests: XCTestCase {
    nonisolated private static let sleeper = CompiledFixture("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n",
                                                 name: "LunavectWidget", prefix: "widget-health-fixture")
    nonisolated override class func tearDown() { sleeper.remove(); super.tearDown() }
    private let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private func facts(stale: Int = 0, heartbeat: WidgetHeartbeat? = nil, pending: Date? = nil, placed: Bool = true) -> WidgetHealth.Facts {
        .init(staleProcesses: stale, heartbeat: heartbeat, build: "194", launchedAt: launch, pendingSince: pending, widgetsPlaced: placed)
    }

    func testRepairsAnExtensionMacOSNoLongerAccepts() {
        let now = launch.addingTimeInterval(3600)
        XCTAssertEqual(WidgetHealth.problem(facts(stale: 1), now: now), .earlierBuildRunning)
        // 28.09: the 0.2.4 extension kept answering after the updates to 0.2.5 and 0.2.6.
        XCTAssertEqual(WidgetHealth.problem(facts(heartbeat: .init(build: "193", at: launch.addingTimeInterval(600))), now: now), .earlierBuildAnswered)
        XCTAssertNil(WidgetHealth.problem(facts(heartbeat: .init(build: "193", at: launch.addingTimeInterval(30))), now: now),
                     "the old extension may answer while this launch registers its own")
        let answered = WidgetHeartbeat(build: "194", at: launch.addingTimeInterval(100))
        XCTAssertEqual(WidgetHealth.problem(facts(heartbeat: answered, pending: launch.addingTimeInterval(200)), now: now), .timelinesUnanswered)
        XCTAssertNil(WidgetHealth.problem(facts(heartbeat: answered, pending: now.addingTimeInterval(-600)), now: now), "WidgetKit may take minutes")
        XCTAssertNil(WidgetHealth.problem(facts(heartbeat: answered, pending: launch.addingTimeInterval(200), placed: false), now: now))
        XCTAssertNil(WidgetHealth.problem(facts(heartbeat: .init(build: "194", at: now.addingTimeInterval(-8 * 86400)),
                                                pending: launch.addingTimeInterval(200)), now: now), "a widget unused for a week was removed")
        XCTAssertNil(WidgetHealth.problem(facts(heartbeat: answered), now: now))
    }

    func testRepairsAreSpacedAndLimitedPerLaunch() {
        XCTAssertTrue(WidgetHealth.mayRepair(lastRepair: nil, repairs: 0, now: launch))
        XCTAssertFalse(WidgetHealth.mayRepair(lastRepair: launch, repairs: 1, now: launch.addingTimeInterval(1800)))
        XCTAssertTrue(WidgetHealth.mayRepair(lastRepair: launch, repairs: 1, now: launch.addingTimeInterval(3600)))
        XCTAssertFalse(WidgetHealth.mayRepair(lastRepair: launch, repairs: 3, now: launch.addingTimeInterval(86400)))
    }

    func testHealthCheckRepairsSilentlyAndReloads() async {
        let target = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Applications/Lunavect.app"), version: "194")
        let repairs = HealthCalls()
        var reloads = 0
        var health = WidgetHealthEnvironment()
        health.now = { [launch] in launch.addingTimeInterval(3600) }
        health.staleProcesses = { _ in 1 }
        health.heartbeat = { nil }
        health.pendingSince = { _ in nil }
        health.settlePending = { }
        health.widgetsPlaced = { true }
        let suite = "WidgetHealthTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let service = WidgetRegistration(defaults: UserDefaults(suiteName: suite)!, target: target,
            repair: { _ in await repairs.record(); return true }, reassert: { _ in true }, reload: { reloads += 1 }, pause: {}, settle: { _ in },
            registeredCopies: { [] }, health: health)
        await service.checkHealth(target)
        await service.checkHealth(target)
        let count = await repairs.count
        XCTAssertEqual(count, 1, "one repair an hour")
        XCTAssertEqual(reloads, 1)
    }

    func testFindsAndStopsAnExtensionWhoseBundleAnUpdateMoved() async throws {
        // Foundation's /var path, as the test guard expects for a file that no longer exists;
        // the kernel reports /private/var for the running process.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = WidgetRegistrationTarget(app: root.appendingPathComponent("Installed/Lunavect.app"), version: "194")
        let executable = URL(fileURLWithPath: installed.executable)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Self.sleeper.executable(), to: executable)
        let process = Process(); process.executableURL = executable
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let pid = process.processIdentifier
        let deadline = ContinuousClock.now + .seconds(5)
        let expected = WidgetRegistrationSystem.canonical(installed.executable)
        func launched() -> String? { ProcessInspection.launchPath(pid).map(WidgetRegistrationSystem.canonical) }
        while launched() != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(launched(), expected)
        XCTAssertFalse(WidgetRegistrationSystem.staleExtensionProcesses(installed).contains(pid), "the current extension is not stale")
        // Sparkle moves the replaced bundle away and later deletes it.
        let moved = root.appendingPathComponent("Sparkle/Installation/Lunavect.app")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: installed.app, to: moved)
        XCTAssertEqual(launched(), expected, "the launch path survives the move")
        XCTAssertTrue(WidgetRegistrationSystem.staleExtensionProcesses(installed).contains(pid))
        let stopped = await Task.detached { WidgetRegistrationSystem.stopExtension(installed) }.value
        XCTAssertTrue(stopped)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testStaleMeansStartedFromTheInstalledPathButRunningAnotherFile() {
        let path = "/Users/u/Applications/Lunavect.app/Contents/PlugIns/LunavectWidget.appex/Contents/MacOS/LunavectWidget"
        XCTAssertTrue(WidgetRegistrationSystem.isStale(current: nil, launchedAs: path, target: path))
        XCTAssertEqual(WidgetRegistrationSystem.canonical("/var/../var/folders/none/Lunavect.app"), "/private/var/folders/none/Lunavect.app")
        XCTAssertTrue(WidgetRegistrationSystem.isStale(current: "/Users/u/Library/Caches/x/Lunavect.app/Contents/MacOS/LunavectWidget", launchedAs: path, target: path))
        XCTAssertFalse(WidgetRegistrationSystem.isStale(current: path, launchedAs: path, target: path))
        XCTAssertFalse(WidgetRegistrationSystem.isStale(current: nil, launchedAs: "/Applications/Other.app/LunavectWidget", target: path))
        XCTAssertFalse(WidgetRegistrationSystem.isStale(current: nil, launchedAs: nil, target: path))
    }
}

private actor HealthCalls {
    var count = 0
    func record() { count += 1 }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ event: String) { lock.withLock { items.append(event) } }
    var events: [String] { lock.withLock { items } }
}

private actor Attempts {
    var count = 0
    @discardableResult func record() -> Int { count += 1; return count }
}
