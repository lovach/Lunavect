import XCTest
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class SettingsRenderAwakeClient: AwakeClient {
    var isAvailable = false
    func requestPermission() throws { XCTFail("No system permission in a render") }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { XCTFail("No helper in a render") }
    func configure(policy: AwakeSafetyPolicy) async throws { XCTFail("No helper in a render") }
    func keepAlive() async throws { XCTFail("No helper in a render") }
    func end() async throws { XCTFail("No helper in a render") }
    func disconnect() {}
}

@MainActor private struct SettingsRenderPermissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status { .notRegistered }
    func notificationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func authorizeNotifications() async throws -> Bool { XCTFail("No permission request in a render"); return false }
    func registerLogin() throws { XCTFail("No login registration in a render") }
    func unregisterLogin() async throws { XCTFail("No login registration in a render") }
    func openNotificationSettings() -> Bool { XCTFail("No System Settings in a render"); return false }
    func openLoginSettings() { XCTFail("No System Settings in a render") }
}

final class SettingsUXRenderingTests: XCTestCase {
    @MainActor func testNativeSettingsUXMatrix() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SETTINGS_UX"] else {
            throw XCTSkip("Opt-in isolated production settings rendering")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.SettingsUXRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: sessionDirectory) }
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        let fixture = try PresentationFixture()
        let store = AppStore(state: SharedState(snapshots: fixture.snapshots, preferences: fixture.preferences), savesChanges: false,
                             activityHistory: fixture.history, activityDetails: fixture.details, isolated: true, defaults: defaults)
        let sessions = SessionStore(directory: sessionDirectory, defaults: defaults, isolated: true)
        let appearance = MenuBarAppearance(defaults: defaults)
        let awake = KeepAwake(client: SettingsRenderAwakeClient(), defaults: defaults)
        let updates = AppUpdates(defaults: defaults, isolated: true)
        let features = AppFeatures(defaults: defaults, permissionAccess: SettingsRenderPermissions(), playSound: { _ in XCTFail("No audio in a render") }, isolated: true)
        let languageSettings = LanguageSettings(defaults: defaults, reloadWidgets: { XCTFail("No widget reload in a render") })
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "ru"
        for scheme in [ColorScheme.light, .dark] {
            let suffix = language + (scheme == .light ? "-light" : "-dark")
            for section in [SettingsSection.general, .widget, .keepAwake, .updates, .statistics, .menuBar] {
                defaults.set(section.rawValue, forKey: "settingsSection")
                try render(SettingsView(store: store, menuBarAppearance: appearance, sessions: sessions,
                                        updates: updates, awake: awake, features: features, language: languageSettings).defaultAppStorage(defaults),
                           size: CGSize(width: 840, height: 680), scheme: scheme,
                           url: directory.appendingPathComponent(section.rawValue + "-" + suffix + ".png"))
            }
            for expanded in [false, true] {
                try render(MenuBarAppearanceView(appearance: appearance, snapshots: fixture.snapshots,
                                                 providers: [.claude, .codex], iconDetailsExpanded: expanded)
                            .padding(24).background(Color(nsColor: .windowBackgroundColor))
                            .disclosureGroupStyle(FullRowDisclosureStyle()),
                           size: CGSize(width: 590, height: expanded ? 1480 : 1040), scheme: scheme,
                           url: directory.appendingPathComponent("menu-bar-\(expanded ? "details" : "overview")-" + suffix + ".png"))
            }
            try render(WelcomeView(store: store, sessions: sessions, onFinish: {}, step: 3,
                                   widgetSetup: WidgetSetupStatus(fetch: { [] })),
                       size: CGSize(width: 640, height: 620), scheme: scheme,
                       url: directory.appendingPathComponent("welcome-keyboard-example-" + suffix + ".png"))
            defaults.set(SettingsSection.subscriptions.rawValue, forKey: "settingsSection")
            try render(SettingsView(store: store, menuBarAppearance: appearance, sessions: sessions,
                                    updates: updates, awake: awake, features: features, language: languageSettings).defaultAppStorage(defaults),
                       size: CGSize(width: 800, height: 580), scheme: scheme,
                       url: directory.appendingPathComponent("sidebar-minimum-" + suffix + ".png"))
            defaults.set(ActivitySource.codex.rawValue, forKey: "statisticsSource")
            store.preferences.enabledProviders = [.claude]
            try render(ScrollView { ActivityStatisticsView(store: store).defaultAppStorage(defaults).padding(24) }
                        .background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 600, height: 680), scheme: scheme,
                       url: directory.appendingPathComponent("statistics-disconnected-" + suffix + ".png"))
            store.preferences.enabledProviders = [.claude, .codex]
            try render(WidgetPreviewPicker(store: store).padding(24).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 600, height: 600), scheme: scheme,
                       url: directory.appendingPathComponent("widget-preview-" + suffix + ".png"))
        }
    }

    @MainActor private func render<V: View>(_ content: V, size: CGSize, scheme: ColorScheme, url: URL) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        }
        host.needsDisplay = true
        host.displayIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
