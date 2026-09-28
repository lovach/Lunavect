import XCTest
import WeekleftCore
import AppKit
@testable import Weekleft

/// App shell findings of audit 05 (H-09, H-10, H-12) and matrix P6, on pure
/// functions, fakes and temporary folders only.
final class AppShellTests: XCTestCase {
    /// H-09: links saved before the rename still open their page.
    func testBothURLSchemesRouteToTheSamePages() throws {
        for (link, expected) in [("weekleft://limits", "lunavect://limits"), ("lunavect://settings/menu-bar", "lunavect://settings/menu-bar"),
                                 ("WeekLeft://activity?period=week", "lunavect://activity?period=week")] {
            XCTAssertEqual(AppURLRoute.normalized(try XCTUnwrap(URL(string: link)))?.absoluteString, expected, link)
        }
        XCTAssertNil(AppURLRoute.normalized(try XCTUnwrap(URL(string: "https://lunavect.app/limits"))))
        XCTAssertEqual(ActivityPeriod.from(widgetURL: try XCTUnwrap(AppURLRoute.normalized(try XCTUnwrap(URL(string: "weekleft://activity?period=month"))))), .month)
    }

    /// H-10: the command-line status line install never writes a relative path.
    func testCommandLineStatusLineInstallNeedsAnAbsoluteExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect cli " + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let none = HookHelperLocation(link: root.appendingPathComponent("bin/LunavectHook"), bundle: root.appendingPathComponent("Lunavect.app"), fallback: nil)
        XCTAssertNil(CommandLineMaintenance.statusLineExecutable(location: none, argument: "Lunavect"))
        XCTAssertNil(CommandLineMaintenance.statusLineExecutable(location: none, argument: "./Lunavect"))
        XCTAssertEqual(CommandLineMaintenance.statusLineExecutable(location: none, argument: "/opt/Lunavect"), "/opt/Lunavect")
        let moved = HookHelperLocation(link: root.appendingPathComponent("bin/LunavectHook"),
                                       bundle: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/1/d/Lunavect.app"), fallback: nil)
        XCTAssertNil(CommandLineMaintenance.statusLineExecutable(location: moved, argument: "/private/var/folders/x/T/AppTranslocation/1/d/Lunavect.app/Contents/MacOS/Lunavect"))
    }

    /// H-12: older copies of settings and saved status lines were created 0644.
    func testOwnBackupsBecomePrivateAndForeignFilesAndLinksStayAsTheyAre() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect permissions " + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = root.appendingPathComponent("ClaudeStatusLine"), backups = root.appendingPathComponent("Sessions/backups")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        let own = [bridge.appendingPathComponent("previous-statusline.json"), bridge.appendingPathComponent("settings-backup-\(uuid).json"),
                   bridge.appendingPathComponent("statusline-restoration-ab12.json"), backups.appendingPathComponent("claude-\(uuid).json"),
                   backups.appendingPathComponent("codex-restoration-cd34.json")]
        let foreign = [bridge.appendingPathComponent("notes.json"), backups.appendingPathComponent("claude-not-a-uuid.json")]
        let outside = root.appendingPathComponent("outside.json")
        for file in own + foreign + [outside] {
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        try FileManager.default.createSymbolicLink(at: bridge.appendingPathComponent("settings-backup-\(UUID().uuidString).json"), withDestinationURL: outside)
        XCTAssertEqual(try SessionHooks.restrictOwnBackups(bridgeDirectory: bridge, backupDirectory: backups), own.count)
        func mode(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
        for file in own { XCTAssertEqual(try mode(file), 0o600, file.lastPathComponent) }
        for file in foreign + [outside] { XCTAssertEqual(try mode(file), 0o644, file.lastPathComponent) }
        XCTAssertEqual(try SessionHooks.restrictOwnBackups(bridgeDirectory: bridge, backupDirectory: backups), 0)
    }

    /// Matrix P6: a second launch hands over to the running copy and quits.
    func testSecondLaunchFindsTheRunningCopyAndAsksItToReopen() {
        struct Copy: RunningCopy { let processIdentifier: pid_t; let isTerminated: Bool; let isFinishedLaunching: Bool; let bundleURL: URL? }
        let app = URL(fileURLWithPath: "/Applications/Lunavect.app")
        let copies = [Copy(processIdentifier: 10, isTerminated: false, isFinishedLaunching: true, bundleURL: app),
                      Copy(processIdentifier: 20, isTerminated: true, isFinishedLaunching: true, bundleURL: app),
                      Copy(processIdentifier: 30, isTerminated: false, isFinishedLaunching: false, bundleURL: app)]
        XCTAssertNil(InstanceHandover.existing(in: [copies[0]], current: 10), "never itself")
        XCTAssertEqual(InstanceHandover.existing(in: copies, current: 99)?.processIdentifier, 10)
        XCTAssertNil(InstanceHandover.existing(in: [copies[1]], current: 99), "a terminated copy is gone")
        XCTAssertEqual(InstanceHandover.existing(in: [copies[2]], current: 99)?.processIdentifier, 30)
        XCTAssertNil(InstanceHandover.existing(in: [copies[2]], current: 99, onlyFinishedLaunching: true), "an older copy still starting is not reopened")
        var events: [String] = []
        InstanceHandover.reopen(copies[0], open: { events.append("open " + $0.path); return true }, activate: { events.append("activate") })
        InstanceHandover.reopen(copies[0], open: { _ in events.append("open failed"); return false }, activate: { events.append("activate") })
        InstanceHandover.reopen(Copy(processIdentifier: 40, isTerminated: false, isFinishedLaunching: true, bundleURL: nil),
                                open: { _ in events.append("unexpected"); return true }, activate: { events.append("activate") })
        XCTAssertEqual(events, ["open /Applications/Lunavect.app", "open failed", "activate", "activate"])
    }
}

/// Audit 05 §5 item 13: menus are built from the current interface language, so
/// the language observer's rebuild shows the new language without a restart.
@MainActor final class MenuLanguageTests: XCTestCase {
    func testMainAndStatusMenusFollowTheSelectedLanguage() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu, previousLanguage = L10n.selection
        defer { NSApp.mainMenu = previousMenu; L10n.defaults.set(previousLanguage, forKey: "languageCode") }
        let environment = try AppEnvironment.preview(rows: [])
        defer { environment.stop() }
        let delegate = AppDelegate(environment: environment)
        var titles: [String: [String]] = [:]
        for code in ["en", "de"] {
            L10n.defaults.set(code, forKey: "languageCode")
            delegate.configureMainMenu()
            let main = NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []
            titles[code] = main + delegate.statusMenu().items.map(\.title).filter { !$0.isEmpty }
            XCTAssertTrue(titles[code]!.contains(L("Проверить обновления")))
            XCTAssertTrue(titles[code]!.contains(L("Открыть сессии")))
            XCTAssertFalse(titles[code]!.contains { $0.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil }, "\(code): \(titles[code]!)")
        }
        XCTAssertNotEqual(titles["en"], titles["de"])
    }
}
