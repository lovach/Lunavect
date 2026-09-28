import XCTest
import WeekleftCore
@testable import Weekleft

/// Launch maintenance of client connections through SessionStore (audit 02 S-16,
/// 05 H-04 and §5 item 2, matrix P3/P4). Temporary folders only; the store's
/// live defaults, ~/.claude and ~/.codex are never used.
@MainActor final class ConnectionMaintenanceStoreTests: XCTestCase {
    private var root: URL!
    private var link: URL { root.appendingPathComponent("Application Support/Weekleft/bin/LunavectHook") }
    private var app: URL { root.appendingPathComponent("Applications/Lunavect.app") }
    private let old = "/Users/fixture/Downloads/Old Lunavect.app/Contents/Helpers/LunavectHook"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect maintenance " + UUID().uuidString).resolvingSymlinksInPath()
        let helper = app.appendingPathComponent("Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '{}'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func config(_ provider: ProviderID) -> URL { root.appendingPathComponent(provider == .claude ? ".claude/settings.json" : ".codex/hooks.json") }
    private func store(bundle: URL? = nil, copies: [URL] = []) throws -> (SessionStore, UserDefaults) {
        let location = HookHelperLocation(link: link, bundle: bundle ?? app, fallback: nil)
        var dependencies = SessionStore.Dependencies()
        dependencies.allowsClientConfiguration = true
        dependencies.helperLocation = location
        let base: URL = root
        dependencies.clientSetup = { provider in
            ClientConnection.LocalSetup(provider: provider, location: location,
                                        configURL: base.appendingPathComponent(provider == .claude ? ".claude/settings.json" : ".codex/hooks.json"),
                                        bridgeDirectory: base.appendingPathComponent("bridge"), backupDirectory: base.appendingPathComponent("backups"))
        }
        dependencies.installedCopies = { copies }
        let suite = "ConnectionMaintenance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(directory: root.appendingPathComponent("sessions"), defaults: defaults, isolated: true, dependencies: dependencies)
        addTeardownBlock { await MainActor.run { store.stop() } }
        return (store, defaults)
    }
    private func start(_ store: SessionStore) {
        store.start(clientResolver: { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) })
    }
    private func installOld() throws {
        for provider in ProviderID.allCases {
            try FileManager.default.createDirectory(at: config(provider).deletingLastPathComponent(), withIntermediateDirectories: true)
            try SessionHooks.install(provider: provider, executable: old, configURL: config(provider), backupDirectory: root.appendingPathComponent("backups"))
        }
        try ClaudeProvider.installStatusLine(executable: old, settingsURL: config(.claude), bridgeDirectory: root.appendingPathComponent("bridge"))
    }

    func testLaunchPointsTheLinkAtThisCopyAndMovesOldCommandsToIt() throws {
        try installOld()
        let (store, _) = try store()
        start(store)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       app.appendingPathComponent("Contents/Helpers/LunavectHook").path)
        for provider in ProviderID.allCases {
            let text = try String(contentsOf: config(provider), encoding: .utf8)
            XCTAssertFalse(text.contains("Old Lunavect.app"), provider.rawValue)
            XCTAssertTrue(text.contains("Weekleft/bin/LunavectHook"), provider.rawValue)
        }
        XCTAssertNil(store.connectionMessage)
        let notice = try XCTUnwrap(store.setupNotice)
        XCTAssertFalse(notice.warning)
        XCTAssertTrue(notice.message.contains("Claude") && notice.message.contains("Codex"), notice.message)
        XCTAssertEqual(store.connectionStates[.claude]?.connected, true)
    }

    func testPausedSettingsAreNeitherRewrittenNorReportedAsAMove() throws {
        try installOld()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config(.claude))) as? [String: Any])
        root["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: config(.claude))
        let bytes = try Data(contentsOf: config(.claude))
        let (store, _) = try store()
        store.useProviders([.claude])
        start(store)
        XCTAssertEqual(try Data(contentsOf: config(.claude)), bytes)
        XCTAssertNil(store.connectionMessage, "no false report about moving the app")
        XCTAssertNil(store.setupNotice)
        XCTAssertEqual(store.connectionStates[.claude]?.hooks, .paused)
    }

    func testATranslocatedCopyAsksToMoveTheAppAndWritesNothing() throws {
        try installOld()
        let bytes = try Data(contentsOf: config(.claude))
        let moved = root.appendingPathComponent("private/var/folders/xy/T/AppTranslocation/0A1B/d/Lunavect.app")
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/Helpers/LunavectHook"),
                                         to: moved.appendingPathComponent("Contents/Helpers/LunavectHook"))
        let (store, _) = try store(bundle: moved, copies: [app])
        start(store)
        XCTAssertEqual(try Data(contentsOf: config(.claude)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        let notice = try XCTUnwrap(store.setupNotice)
        XCTAssertTrue(notice.warning)
        XCTAssertEqual(notice.message, L("macOS запустила Lunavect из временной копии. Перенесите Lunavect в папку «Программы» и откройте его оттуда: до этого команды подключений не обновляются."))
    }

    /// Matrix P4: a Homebrew copy in /Applications next to one in ~/Applications.
    func testASecondInstalledCopyIsReportedAtLaunch() throws {
        let (store, _) = try store(copies: [URL(fileURLWithPath: "/Applications/Lunavect.app")])
        start(store)
        let notice = try XCTUnwrap(store.setupNotice)
        XCTAssertTrue(notice.warning)
        XCTAssertTrue(notice.message.contains("/Applications/Lunavect.app"), notice.message)
        let system = root.appendingPathComponent("System Apps"), home = root.appendingPathComponent("Home")
        for folder in [system, home.appendingPathComponent("Applications")] {
            let info = folder.appendingPathComponent("Lunavect.app/Contents/Info.plist")
            try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.weekleft.app", "CFBundlePackageType": "APPL"],
                                               format: .xml, options: 0).write(to: info)
        }
        let running = home.appendingPathComponent("Applications/Lunavect.app")
        XCTAssertEqual(InstalledCopies.others(running: running, applications: system, home: home).map(\.path),
                       [system.appendingPathComponent("Lunavect.app").path])
        XCTAssertEqual(InstalledCopies.others(running: system.appendingPathComponent("Lunavect.app"), applications: system, home: home).map(\.path),
                       [running.path])
        try FileManager.default.removeItem(at: running)
        XCTAssertTrue(InstalledCopies.others(running: system.appendingPathComponent("Lunavect.app"), applications: system, home: home).isEmpty)
    }
}
