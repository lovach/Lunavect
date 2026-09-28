import XCTest
import Darwin

/// Fixture cleanup kills by pid. A pid the system handed to another program after a
/// fixture exited must never be signalled, nor this test process (audit r2 R2-B-11).
final class NativeFixturesSafetyTests: XCTestCase {
    private func unrelatedSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func testAPidReusedSinceItWasReportedIsNeverSignalled() throws {
        let natives = NativeFixtures(prefix: "lunavect-r2-fixture-safety")
        let other = try unrelatedSleeper()
        defer { other.terminate(); other.waitUntilExit() }
        let start = try XCTUnwrap(NativeFixtures.startTime(of: other.processIdentifier))
        // The record describes an earlier process that had the same pid.
        natives.track(other.processIdentifier, recordedStart: start - 1)
        natives.stopAll()
        XCTAssertEqual(kill(other.processIdentifier, 0), 0, "a reused pid was killed")
        XCTAssertTrue(other.isRunning)
    }

    func testThisTestProcessIsNeverSignalled() {
        let natives = NativeFixtures(prefix: "lunavect-r2-fixture-safety")
        natives.track(getpid())
        natives.stopAll()
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    func testARegisteredFixtureAndItsTrackedProcessAreStillStopped() throws {
        let natives = NativeFixtures(prefix: "lunavect-r2-fixture-safety")
        let fixture = try natives.launch(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let tracked = try unrelatedSleeper()
        defer { if tracked.isRunning { tracked.terminate() }; tracked.waitUntilExit() }
        natives.track(tracked.processIdentifier)
        natives.stopAll()
        XCTAssertFalse(fixture.isRunning)
        XCTAssertEqual(fixture.terminationReason, .uncaughtSignal)
        tracked.waitUntilExit()
        XCTAssertEqual(tracked.terminationReason, .uncaughtSignal)
    }
}
