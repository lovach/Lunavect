import XCTest
import Darwin
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
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Foundation can display /private/var as /var; proc_pidpath returns the
        // POSIX path. Keep the fixture target identical to the kernel's path.
        let canonical = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical))
        defer { try? FileManager.default.removeItem(at: root) }
        // A copied Apple-signed /bin/sleep is not a stable synthetic executable:
        // macOS can reject the relocated binary before discovery. Build our own.
        let source = root.appendingPathComponent("fixture.c")
        try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
        let own = WidgetRegistrationTarget(app: root.appendingPathComponent("Installed/Lunavect.app"), version: "1")
        let other = WidgetRegistrationTarget(app: root.appendingPathComponent("Archive/Lunavect.app"), version: "1")
        func launch(_ target: WidgetRegistrationTarget) throws -> Process {
            let executable = URL(fileURLWithPath: target.executable)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = [source.path, "-o", executable.path]
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let process = Process(); process.executableURL = executable
            try process.run(); return process
        }
        let owned = try launch(own), unrelated = try launch(other)
        defer {
            if owned.isRunning { owned.terminate() }; if unrelated.isRunning { unrelated.terminate() }
            owned.waitUntilExit(); unrelated.waitUntilExit()
        }
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

private actor Attempts {
    var count = 0
    @discardableResult func record() -> Int { count += 1; return count }
}
