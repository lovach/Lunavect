import XCTest
@testable import Weekleft

@MainActor final class WidgetRegistrationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WidgetRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private let target = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Applications/Lunavect.app"), version: "158")

    func testUpgradeAndRelocationRepairOnceWithoutResettingPreferences() async {
        let defaults = defaults(), calls = Attempts()
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set("old-build", forKey: WidgetRegistration.stampKey)
        var reloads = 0
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in await calls.record(); return true }, reload: { reloads += 1 }, pause: {})
        service.start(); service.start()
        await service.waitUntilFinished()
        service.start(); await service.waitUntilFinished()
        let firstCalls = await calls.count
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), target.stamp)
        XCTAssertFalse(defaults.bool(forKey: "SUEnableAutomaticChecks"))
        let relocated = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Users/fixture/Applications/Lunavect.app"), version: "158")
        let moved = WidgetRegistration(defaults: defaults, target: relocated,
            repair: { _ in await calls.record(); return true }, reload: {}, pause: {})
        moved.start(); await moved.waitUntilFinished()
        let totalCalls = await calls.count
        XCTAssertEqual(totalCalls, 2)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), relocated.stamp)
    }

    func testTransientFailureRetriesBeforeSavingStamp() async {
        let defaults = defaults(), calls = Attempts()
        var reloads = 0
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in await calls.record() > 1 }, reload: { reloads += 1 }, pause: {})
        service.start(); await service.waitUntilFinished()
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(defaults.string(forKey: WidgetRegistration.stampKey), target.stamp)
    }

    func testPersistentFailureDoesNotSuppressNextLaunch() async {
        let defaults = defaults(), calls = Attempts()
        for _ in 0..<2 {
            let service = WidgetRegistration(defaults: defaults, target: target,
                repair: { _ in await calls.record(); return false }, reload: { XCTFail("Failed registration") }, pause: {})
            service.start(); await service.waitUntilFinished()
            XCTAssertNil(defaults.string(forKey: WidgetRegistration.stampKey))
        }
        let count = await calls.count
        XCTAssertEqual(count, 4)
    }

    func testCancelledRepairDoesNotSaveStampOrReload() async {
        let defaults = defaults()
        let service = WidgetRegistration(defaults: defaults, target: target,
            repair: { _ in try? await Task.sleep(for: .seconds(60)); return true },
            reload: { XCTFail("Cancelled registration") }, pause: {})
        service.start(); await Task.yield(); service.stop()
        await service.waitUntilFinished()
        XCTAssertNil(defaults.string(forKey: WidgetRegistration.stampKey))
    }

    func testUninstalledBundleCannotStartRepair() async {
        let service = WidgetRegistration(defaults: defaults(), target: nil,
            repair: { _ in XCTFail("Not installed"); return false }, reload: { XCTFail("Not installed") })
        service.start(); await service.waitUntilFinished()
        XCTAssertNil(WidgetRegistrationTarget.installed(bundle: Bundle(for: Self.self)))
    }

    func testOnlyExactExtensionExecutableIsStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = WidgetRegistrationTarget(app: root.appendingPathComponent("Installed/Lunavect.app"), version: "1")
        let other = WidgetRegistrationTarget(app: root.appendingPathComponent("Archive/Lunavect.app"), version: "1")
        func launch(_ target: WidgetRegistrationTarget) throws -> Process {
            let executable = URL(fileURLWithPath: target.executable)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
            let process = Process(); process.executableURL = executable; process.arguments = ["30"]
            try process.run(); return process
        }
        let owned = try launch(own), unrelated = try launch(other)
        defer {
            if owned.isRunning { owned.terminate() }; if unrelated.isRunning { unrelated.terminate() }
            owned.waitUntilExit(); unrelated.waitUntilExit()
        }
        let stopped = await Task.detached { WidgetRegistrationSystem.stopExtension(own) }.value
        XCTAssertTrue(stopped)
        owned.waitUntilExit()
        XCTAssertEqual(owned.terminationReason, .uncaughtSignal)
        XCTAssertTrue(unrelated.isRunning)
    }
}

private actor Attempts {
    var count = 0
    @discardableResult func record() -> Int { count += 1; return count }
}
