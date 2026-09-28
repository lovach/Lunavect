import XCTest
import AppKit
import Carbon
@testable import Weekleft
@testable import WeekleftCore

/// r2 audit X, R2-X-03: under XCTest nothing reaches the user's system other
/// than files (LiveWriteGuard covers those): no installed client or system tool
/// starts, no link or Finder window opens, the clipboard, login items, System
/// Settings and global shortcuts stay untouched. Every proof uses a harmless
/// witness (a marker file `/usr/bin/touch` would create, the pasteboard change
/// count, the returned value); none reads the user's data.
@MainActor final class R2IntegrationLiveSystemTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lunavect-r2-X-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProgramsOutsideTestFixturesStartOnlyByExplicitPermission() throws {
        let root = try folder(), marker = root.appendingPathComponent("started")
        // A system program outside the fixture folder: refused before it starts.
        XCTAssertThrowsError(try SessionProcess.run(path: "/usr/bin/touch", arguments: [marker.path], timeout: 2)) {
            XCTAssertTrue($0 is LiveWriteGuard.Refused, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The refused program never ran")
        // Named by the test: it runs, and only while permitted.
        LiveProcessGuard.allow(["/usr/bin/touch"])
        _ = try SessionProcess.run(path: "/usr/bin/touch", arguments: [marker.path], timeout: 2)
        LiveProcessGuard.disallow(["/usr/bin/touch"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try SessionProcess.run(path: "/usr/bin/touch", arguments: [marker.path], timeout: 2))
        // A fixture inside the temporary folder still runs.
        let fixture = root.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf ok\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        XCTAssertEqual(String(decoding: try SessionProcess.run(path: fixture.path, arguments: [], timeout: 2), as: UTF8.self), "ok")
    }

    func testClientProbesAndToolsGoThroughTheGuard() async throws {
        let root = try folder()
        // Every production launch of a client or tool shares SessionProcess.withRunningProcess.
        do { _ = try await ClaudeUsageProbe.fetch(cliPath: "/usr/bin/touch", timeout: 2, directory: root.appendingPathComponent("probe")); XCTFail("probe") }
        catch { XCTAssertTrue(error is LiveWriteGuard.Refused, "probe: \(error)") }
        XCTAssertThrowsError(try CodexProvider.read(cliPath: "/usr/bin/touch", timeout: 2)) { XCTAssertTrue($0 is LiveWriteGuard.Refused, "codex: \($0)") }
        let state = await ClientConnection.signInState(.claude, executable: "/usr/bin/touch", timeout: 2)
        XCTAssertEqual(state, .unavailable)
        do { _ = try await TerminalLocation.executeFocusScript("return true", app: "Terminal", timeout: 2); XCTFail("osascript") }
        catch { XCTAssertEqual(error as? SessionOpeningError, .terminalFocusFailed("Terminal")) }
        XCTAssertEqual(WidgetRegistrationSystem.widgetHost(), .unknown, "pluginkit is not asked")
        XCTAssertFalse(WidgetRegistrationSystem.stopExtension(WidgetRegistrationTarget(
            app: root.appendingPathComponent("Lunavect.app"), version: "1")))
    }

    func testRowActionsLeaveClipboardLinksAndFinderAlone() throws {
        let root = try folder()
        let session = AgentSession(provider: .codex, sessionID: "11111111-2222-3333-4444-555555555555", title: "Fixture",
                                   cwd: root.path, phase: .ready, updatedAt: Date(), observedAt: Date())
        let pasteboard = NSPasteboard.general.changeCount
        SessionNavigation.copy(session.resumeCommand)
        XCTAssertEqual(NSPasteboard.general.changeCount, pasteboard, "The user's clipboard is not replaced")
        XCTAssertFalse(SessionNavigation.openCodex(session), "No codex:// link is opened")
        XCTAssertFalse(SessionNavigation.revealProject(session), "No Finder window is opened")
    }

    func testFeaturesWithSystemAccessTouchNoLoginItemSettingsOrShortcut() async throws {
        let access = SystemFeaturePermissionAccess()
        XCTAssertThrowsError(try access.registerLogin())
        do { try await access.unregisterLogin(); XCTFail("login item removal") } catch {}
        XCTAssertFalse(access.openNotificationSettings(), "System Settings is not opened")
        let suite = "lunavect-r2-X." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, playSound: { _ in })
        defer { features.stop() }
        features.registerShortcut(PanelShortcut(keyCode: 37, modifiers: UInt32(cmdKey | optionKey), label: "L"))
        XCTAssertNil(features.shortcut, "No global shortcut is registered")
        XCTAssertNil(defaults.data(forKey: "panelShortcut"))
    }

    func testDiagnosticsWithPreviewStoresNeverFindOrAskInstalledClients() async throws {
        var preferences = WidgetPreferences(); preferences.enabledProviders = ProviderID.allCases
        let preview = try AppEnvironment.preview(rows: [], state: SharedState(preferences: preferences))
        defer { preview.stop() }
        let diagnostics = ConnectionDiagnostics()
        await diagnostics.check(store: preview.store, sessions: preview.sessions)
        XCTAssertEqual(Set(diagnostics.results.map(\.provider)), Set(ProviderID.allCases))
        for result in diagnostics.results {
            XCTAssertFalse(result.clientFound, "\(result.provider.rawValue): a preview never looks for the installed client")
            XCTAssertEqual(result.state, .missingClient)
        }
    }
}
