import XCTest
import WeekleftCore
import AppKit
import SwiftUI
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

/// Audit H-05 and 05 §5 item 16: turning events off on purpose is a state of its
/// own, not unfinished setup; also the paused and missing-path card states.
@MainActor final class EventsDisabledByUserTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect events " + UUID().uuidString).resolvingSymlinksInPath()
        let helper = root.appendingPathComponent("Applications/Lunavect.app/Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '{}'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Client"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Client/claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Client/claude").path)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(defaults: UserDefaults) -> SessionStore {
        let location = HookHelperLocation(link: root.appendingPathComponent("bin/LunavectHook"), bundle: root.appendingPathComponent("Applications/Lunavect.app"), fallback: nil)
        let base: URL = root
        let setup: (ProviderID) -> ClientConnection.LocalSetup = { provider in
            ClientConnection.LocalSetup(provider: provider, location: location,
                                        configURL: base.appendingPathComponent(provider == .claude ? ".claude/settings.json" : ".codex/hooks.json"),
                                        bridgeDirectory: base.appendingPathComponent("bridge"), backupDirectory: base.appendingPathComponent("backups"))
        }
        var dependencies = SessionStore.Dependencies()
        dependencies.allowsClientConfiguration = true
        dependencies.clientSetup = setup
        dependencies.hooksState = { Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, setup($0).inspect().hooks == .ready) }) }
        return SessionStore(directory: root.appendingPathComponent("sessions"), defaults: defaults, isolated: true, dependencies: dependencies)
    }
    func testDisablingEventsIsRememberedAndShownAsAChoiceNotAsSetup() throws {
        let suite = "EventsDisabled." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = store(defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(store.localSetup(.claude)).apply(.connect).connected)
        store.updateHookConfiguration()
        XCTAssertEqual(store.hooksInstalled[.claude], true)
        store.toggleHooks(.claude)
        XCTAssertEqual(store.hooksInstalled[.claude], false)
        XCTAssertTrue(store.eventsDisabledByUser.contains(.claude))
        XCTAssertTrue(self.store(defaults: defaults).eventsDisabledByUser.contains(.claude), "kept across launches")
        let client = root.appendingPathComponent("Client/claude").path
        let resolver = ClientExecutableResolver(discoverClaude: { client })
        let card = ConnectionCardState(provider: .claude, resolver: resolver, configured: false, snapshot: nil,
                                       local: store.connectionStates[.claude], eventsDisabled: true)
        XCTAssertFalse(card.needsSetup, "a deliberate choice is not unfinished setup")
        XCTAssertEqual(card.action, .enableEvents)
        XCTAssertEqual(card.actionTitle, "Включить события")
        XCTAssertEqual(card.statusTitle, "События отключены")
        let now = Date()
        let quota = UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 10, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)),
                                  fetchedAt: now, source: ClaudeUsageProbe.source)
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: false,
                                              snapshot: quota, sessionIssue: nil, now: now)
        XCTAssertEqual(diagnostic.state, .eventsMissing)
        XCTAssertEqual(ConnectionDiagnosticSummary.eventsChoice(for: diagnostic, eventsDisabled: true), "События отключены вами")
        XCTAssertNil(ConnectionDiagnosticSummary.eventsChoice(for: diagnostic, eventsDisabled: false))
        store.toggleHooks(.claude)
        XCTAssertEqual(store.hooksInstalled[.claude], true)
        XCTAssertFalse(store.eventsDisabledByUser.contains(.claude))
    }
    func testPausedAndMissingPathCardsSayWhatHappened() throws {
        let client = root.appendingPathComponent("Client/claude").path
        let resolver = ClientExecutableResolver(discoverClaude: { client })
        let paused = ConnectionCardState(provider: .claude, resolver: resolver, configured: false, snapshot: nil,
                                         local: .init(statusLine: .paused, hooks: .paused))
        XCTAssertFalse(paused.needsSetup, "Lunavect cannot and must not undo disableAllHooks")
        XCTAssertEqual(paused.statusTitle, "События приостановлены: в настройках клиента включено disableAllHooks")
        XCTAssertEqual(paused.action, .refresh)
        let moved = ConnectionCardState(provider: .claude, resolver: resolver, configured: false, snapshot: nil,
                                        local: .init(statusLine: .partial, hooks: .partial, missingExecutable: "/gone/Lunavect.app/Contents/Helpers/LunavectHook"))
        XCTAssertTrue(moved.needsSetup)
        XCTAssertEqual(moved.action, .setup)
        XCTAssertEqual(moved.statusTitle, "Команда Lunavect указывает на удалённый файл. Завершите настройку, чтобы обновить её.")
    }
}

/// Opt-in native render of the new connection card states and the launch
/// notice, for visual review. Isolated stores and temporary folders only.
@MainActor final class ConnectionStatesRenderingTests: XCTestCase {
    func testRenderConnectionCardStatesAndLaunchNotice() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CONNECTION_STATES"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        L10n.defaults.set(ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LANGUAGE"] ?? "en", forKey: "languageCode")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect card render " + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Applications/Lunavect.app/Contents/Helpers/LunavectHook")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let client = root.appendingPathComponent("claude")
        try Data().write(to: client); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let environment = try AppEnvironment.preview(rows: [])
        defer { environment.stop() }
        var images: [NSImage] = []
        for state in ["disabled", "paused", "moved"] {
            let base = root.appendingPathComponent(state)
            let settings = base.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let location = HookHelperLocation(link: base.appendingPathComponent("bin/LunavectHook"), bundle: root.appendingPathComponent("Applications/Lunavect.app"), fallback: nil)
            let setup = ClientConnection.LocalSetup(provider: .claude, location: location, configURL: settings,
                                                    bridgeDirectory: base.appendingPathComponent("bridge"), backupDirectory: base.appendingPathComponent("backups"))
            switch state {
            case "paused":
                try setup.apply(.connect)
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
                object["disableAllHooks"] = true
                try JSONSerialization.data(withJSONObject: object).write(to: settings)
            case "moved":
                try SessionHooks.install(provider: .claude, executable: "/Users/demo/Downloads/Lunavect.app/Contents/Helpers/LunavectHook",
                                         configURL: settings, backupDirectory: base.appendingPathComponent("backups"))
            default: try setup.apply(.connect)
            }
            var dependencies = SessionStore.Dependencies()
            dependencies.allowsClientConfiguration = true
            dependencies.clientSetup = { $0 == .claude ? setup : nil }
            dependencies.hooksState = { [.claude: setup.inspect().hooks == .ready] }
            let suite = "ConnectionStatesRender." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let sessions = SessionStore(directory: base.appendingPathComponent("sessions"), defaults: defaults, isolated: true, dependencies: dependencies)
            sessions.useProviders([.claude]); sessions.updateHookConfiguration()
            if state == "disabled" { sessions.toggleHooks(.claude) }
            var prefs = WidgetPreferences(); prefs.enabledProviders = [.claude]
            let store = AppStore(state: SharedState(snapshots: [], preferences: prefs), savesChanges: false, isolated: true, defaults: defaults)
            store.codexPath = ""
            let view = ScrollView { ConnectionsView(store: store, sessions: sessions).frame(width: 560).padding(20) }
                .frame(width: 600, height: 520).background(Color(nsColor: .windowBackgroundColor))
            images.append(try snapshot(view, size: NSSize(width: 600, height: 520)))
            _ = client
        }
        let panel = environment.sessions
        panel.setupNotice = .init(message: L("Команды Lunavect в настройках {0} обновлены: теперь они не зависят от расположения приложения.", "Claude Code, Codex")
                                  + "\n" + L("Установлена ещё одна копия Lunavect: {0}. Оставьте одну копию, чтобы виджеты и подключения работали с ней.", "/Applications/Lunavect.app"),
                                  warning: true)
        images.append(try snapshot(SessionsView(store: panel, updates: environment.updates, awake: environment.awake, onSettings: {}),
                                   size: NSSize(width: 360, height: 520)))
        let width = images.map(\.size.width).reduce(0, +) + CGFloat(images.count - 1) * 10
        let sheet = NSImage(size: NSSize(width: width, height: 520))
        sheet.lockFocus()
        var x: CGFloat = 0
        for image in images { image.draw(at: NSPoint(x: x, y: 520 - image.size.height), from: .zero, operation: .copy, fraction: 1); x += image.size.width + 10 }
        sheet.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output))
    }
    /// Codex skips hooks the user has not trusted (live check 30.09): the store asks at start,
    /// then at most hourly, and again at once when asked from Settings.
    func testCodexHookTrustIsAskedAtStartHourlyAndOnRequest() async throws {
        final class Calls: @unchecked Sendable { var count = 0; var answer = CodexProvider.HookTrust.untrusted }
        let calls = Calls()
        var dependencies = SessionStore.Dependencies()
        dependencies.hooksState = { [.codex: true] }
        dependencies.codexHookTrust = { _ in calls.count += 1; return calls.answer }
        let sessions = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isolated: true, dependencies: dependencies)
        sessions.useProviders([.codex])
        sessions.start(clientResolver: { ClientExecutableResolver() })
        defer { sessions.stop() }
        for _ in 0..<50 where sessions.codexHookTrust == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sessions.codexHookTrust, .untrusted)
        XCTAssertEqual(calls.count, 1)
        sessions.checkCodexHookTrust()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.count, 1, "not again within the hour")
        calls.answer = .trusted
        sessions.checkCodexHookTrust(force: true)
        for _ in 0..<50 where sessions.codexHookTrust != .trusted { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sessions.codexHookTrust, .trusted, "Check again asks at once")
        XCTAssertEqual(calls.count, 2)
    }
    private func snapshot<V: View>(_ view: V, size: NSSize) throws -> NSImage {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: size); image.addRepresentation(bitmap)
        return image
    }
}
