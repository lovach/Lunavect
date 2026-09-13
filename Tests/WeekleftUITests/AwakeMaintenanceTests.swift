import XCTest
import ServiceManagement
import AwakeService
@testable import Weekleft

final class AwakeMaintenanceTests: XCTestCase {
    @MainActor private func registration() throws -> AwakeServiceRegistration {
        let name = "Lunavect.AwakeMaintenance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        // The published 103 helper has no recorded current-build key.
        return AwakeServiceRegistration(defaults: defaults, build: "104")
    }
    @MainActor func testClientStartupReplacesLegacyDaemonWithoutStartingALease() async throws {
        var status = SMAppService.Status.enabled
        var events: [String] = []
        var legacyKeepAlive = true
        let registration = try registration()
        let service = AwakeServiceAccess(readStatus: { status }, register: {
            events.append("register-current"); legacyKeepAlive = false; status = .enabled
        }, unregister: {
            events.append("unregister-103"); await Task.yield(); status = .notRegistered
        }, openSettings: { XCTFail("Startup must not request new permission") }, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: registration)
        await client.waitForStartupRefresh()
        XCTAssertNil(client.registrationFailure)
        XCTAssertEqual(events, ["unregister-103", "register-current"])
        XCTAssertFalse(legacyKeepAlive)
        let restarted = AwakeServiceClient(service: service, registration: registration)
        await restarted.waitForStartupRefresh()
        XCTAssertEqual(events.count, 2, "Same build must not churn registration")
    }
    @MainActor func testStartupLeavesDeniedAndUnregisteredServicesAlone() async throws {
        for status in [SMAppService.Status.requiresApproval, .notRegistered, .notFound] {
            let service = AwakeServiceAccess(readStatus: { status }, register: { XCTFail("No permission") },
                unregister: { XCTFail("No permission") }, openSettings: { XCTFail("No unsolicited settings") },
                verifySleepRestored: { XCTFail("No unsolicited power inspection") })
            let client = AwakeServiceClient(service: service, registration: try registration())
            await client.waitForStartupRefresh()
            XCTAssertFalse(client.isAvailable)
        }
    }
    @MainActor func testRemovalVerifiesSleepBeforeUnregisterAndKeepsRecoveryAvailableOnFailure() async throws {
        var status = SMAppService.Status.enabled
        var events: [String] = []
        let service = AwakeServiceAccess(readStatus: { status }, register: { XCTFail("Removal must not register") },
            unregister: { events.append("unregister"); status = .notRegistered }, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false)
        do {
            try await client.prepareForRemoval { events.append("sleep-pending"); throw AwakeFailure.recovery }
            XCTFail("Must preserve recovery service")
        } catch { XCTAssertEqual(error as? AwakeFailure, .recovery) }
        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(events, ["sleep-pending"])
        try await client.prepareForRemoval { events.append("sleep-restored") }
        XCTAssertEqual(events, ["sleep-pending", "sleep-restored", "unregister"])
        XCTAssertEqual(status, .notRegistered)
    }
    @MainActor func testRemovalFailureDoesNotPretendServiceIsGone() async throws {
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: {},
            unregister: { throw AwakeFailure.permission }, openSettings: {}, verifySleepRestored: {})
        let client = AwakeServiceClient(service: service, registration: try registration(), refreshAtStartup: false)
        do { try await client.prepareForRemoval {}; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? AwakeFailure, .permission) }
        XCTAssertTrue(client.isAvailable)
    }
    @MainActor func testUpgradePreservesBothExplicitAndLegacyUpdatePreferences() throws {
        for previous: Bool? in [nil, false, true] {
            let name = "Lunavect.UpdateMigration." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let previous { defaults.set(previous, forKey: "SUAutomaticallyUpdate") }
            AppDefaultSettings.prepare(defaults: defaults, existingInstallation: true)
            let updates = AppUpdates(defaults: defaults, isolated: true)
            XCTAssertEqual(updates.automatic, previous ?? true)
            XCTAssertEqual(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool, previous)
        }
        let name = "Lunavect.FreshUpdates." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        let updates = AppUpdates(defaults: defaults, isolated: true)
        XCTAssertFalse(updates.automatic); XCTAssertTrue(updates.checkingAutomatically)
    }
    @MainActor func testInterruptedLegacyLeaseKeepsRecoveryRegisteredUntilSleepIsRestored() async throws {
        var sleepDisabled = true
        var events: [String] = []
        let registration = try registration()
        let service = AwakeServiceAccess(readStatus: { .enabled }, register: { events.append("register") },
            unregister: { events.append("unregister") }, openSettings: {}, verifySleepRestored: {
                events.append("verify-sleep")
                if sleepDisabled { throw AwakeFailure.recovery }
            })
        let first = AwakeServiceClient(service: service, registration: registration)
        await first.waitForStartupRefresh()
        XCTAssertEqual(first.registrationFailure as? AwakeFailure, .recovery)
        XCTAssertEqual(events, ["verify-sleep"], "Old helper must keep its recovery registration")
        sleepDisabled = false
        let retry = AwakeServiceClient(service: service, registration: registration)
        await retry.waitForStartupRefresh()
        XCTAssertNil(retry.registrationFailure)
        XCTAssertEqual(events, ["verify-sleep", "verify-sleep", "unregister", "register"])
    }
}
