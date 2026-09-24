import XCTest
import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class SettingsAwakeClient: AwakeClient {
    var isAvailable = true
    var held = false
    var permissionRequests = 0
    var policies: [AwakeSafetyPolicy] = []
    var updates: [AwakeSafetyPolicy] = []
    var failure: AwakeFailure?
    func requestPermission() throws { permissionRequests += 1 }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { held = true; policies.append(policy) }
    func configure(policy: AwakeSafetyPolicy) async throws {
        updates.append(policy)
        if let failure { held = false; throw failure }
    }
    func keepAlive() async throws { if !held { throw AwakeFailure.lost } }
    func end() async throws { held = false }
    func disconnect() { held = false }
}
@MainActor private final class SettingsPermissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status = .notRegistered
    func notificationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func authorizeNotifications() async throws -> Bool { XCTFail("Unexpected access request"); return false }
    func registerLogin() throws { XCTFail("Unexpected login registration") }
    func unregisterLogin() async throws { loginStatus = .notRegistered }
    func openNotificationSettings() -> Bool { XCTFail("Unexpected settings redirect"); return false }
    func openLoginSettings() { XCTFail("Unexpected settings redirect") }
}

/// A banner authorization that stays in progress until the test answers.
@MainActor private final class PendingNotificationPermissions: FeaturePermissionAccess {
    var loginStatus: SMAppService.Status = .notRegistered
    var pending: CheckedContinuation<Void, Never>?
    func notificationStatus() async -> UNAuthorizationStatus { .notDetermined }
    func authorizeNotifications() async throws -> Bool { await withCheckedContinuation { pending = $0 }; return true }
    func registerLogin() throws {}
    func unregisterLogin() async throws { loginStatus = .notRegistered }
    func openNotificationSettings() -> Bool { true }
    func openLoginSettings() {}
}

final class SettingsPreferencesTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "Lunavect.SettingsTests." + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    @MainActor func testFreshProfileStartsQuietlyAndIsOnlyAppliedOnce() throws {
        let defaults = try defaults()
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        let appearance = MenuBarAppearance(defaults: defaults)
        XCTAssertEqual(appearance.icon, .lunavect); XCTAssertTrue(appearance.showsSessionStatus)
        XCTAssertFalse(appearance.limits.enabled); XCTAssertFalse(appearance.thinkingPhrases)
        XCTAssertEqual(defaults.string(forKey: "interfaceAppearance"), "system")
        let features = AppFeatures(defaults: defaults, permissionAccess: SettingsPermissions())
        XCTAssertFalse(features.banners); XCTAssertFalse(features.sounds); XCTAssertNil(features.shortcut)
        let awake = KeepAwake(client: SettingsAwakeClient(), defaults: defaults)
        XCTAssertFalse(awake.isEnabled); XCTAssertFalse(awake.automatic)
        XCTAssertEqual(awake.duration, .fifteenMinutes); XCTAssertEqual(awake.safetyPolicy, .init())
        defaults.set("light", forKey: "interfaceAppearance"); appearance.limits.enabled = true
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: false)
        XCTAssertEqual(defaults.string(forKey: "interfaceAppearance"), "light")
        XCTAssertTrue(MenuBarAppearance(defaults: defaults).limits.enabled)
    }
    @MainActor func testUpgradePreservesChoicesAndLegacyFallbacks() throws {
        let defaults = try defaults()
        defaults.set("codex", forKey: "menuBarIcon"); defaults.set(true, forKey: "noticeSounds")
        defaults.set(true, forKey: "awake.whileWorking")
        defaults.set(3, forKey: "welcomeCompletedVersion")
        AppDefaultSettings.prepare(defaults: defaults, existingInstallation: true)
        XCTAssertEqual(MenuBarAppearance(defaults: defaults).icon, .codex)
        XCTAssertTrue(AppFeatures(defaults: defaults).sounds)
        XCTAssertNil(defaults.object(forKey: "interfaceAppearance"), "Preserve the former dark fallback")
        let awake = KeepAwake(client: SettingsAwakeClient(), defaults: defaults)
        XCTAssertTrue(awake.automatic); XCTAssertFalse(awake.isEnabled)
        XCTAssertEqual(awake.duration, .untilStopped)
        XCTAssertEqual(defaults.integer(forKey: "welcomeCompletedVersion"), 3)
    }
    @MainActor func testAwakePreferencesPersistWithoutStartingHelperAndApplyOnNextStart() async throws {
        let defaults = try defaults(), client = SettingsAwakeClient()
        client.isAvailable = false
        let awake = KeepAwake(client: client, defaults: defaults)
        awake.duration = .fourHours; awake.setIdleGrace(120)
        let policy = AwakeSafetyPolicy(allowBattery: false, batteryProtection: false, minimumBatteryPercent: 25, thermalProtection: false)
        await awake.setSafetyPolicy(policy)
        XCTAssertTrue(client.policies.isEmpty); XCTAssertTrue(client.updates.isEmpty)
        XCTAssertEqual(client.permissionRequests, 0)
        let restored = KeepAwake(client: client, defaults: defaults)
        XCTAssertEqual(restored.safetyPolicy, policy); XCTAssertEqual(restored.duration, .fourHours)
        XCTAssertEqual(restored.idleGraceSeconds, 120)
        client.isAvailable = true; await restored.start()
        XCTAssertEqual(client.policies, [policy]); XCTAssertTrue(restored.isEnabled)
        await restored.restoreDefaults()
        XCTAssertFalse(restored.isEnabled); XCTAssertFalse(client.held)
        XCTAssertEqual(restored.safetyPolicy, .init()); XCTAssertEqual(restored.duration, .fifteenMinutes)
    }
    @MainActor func testStricterSafetyStopIsVisibleAndDoesNotLoopAutomaticRestart() async throws {
        let defaults = try defaults(), client = SettingsAwakeClient()
        let awake = KeepAwake(client: client, defaults: defaults), now = Date()
        awake.observe([AgentSession(provider: .codex, sessionID: "demo", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)])
        await awake.setAutomatic(true)
        client.failure = .battery
        await awake.setSafetyPolicy(.init(minimumBatteryPercent: 50))
        XCTAssertFalse(awake.isEnabled); XCTAssertNotNil(awake.issue)
        await awake.reconcileAutomatic()
        XCTAssertEqual(client.policies.count, 1)
        await awake.setAutomatic(false)
    }
    @MainActor func testResetCancelsPendingPermissionWithoutStartingLater() async throws {
        let defaults = try defaults(), client = SettingsAwakeClient()
        client.isAvailable = false
        let awake = KeepAwake(client: client, defaults: defaults)
        awake.requestPermission(); XCTAssertTrue(awake.isAwaitingPermission)
        await awake.restoreDefaults()
        client.isAvailable = true; await awake.checkPermission()
        XCTAssertFalse(awake.isAwaitingPermission); XCTAssertFalse(awake.isEnabled)
        XCTAssertTrue(client.policies.isEmpty)
    }
    @MainActor func testChangingGraceUsesTimeAlreadyElapsedAndImmediateMeansImmediate() async throws {
        let defaults = try defaults(), client = SettingsAwakeClient()
        var now = Date()
        let awake = KeepAwake(client: client, now: { now }, defaults: defaults)
        var row = AgentSession(provider: .codex, sessionID: "demo", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        awake.observe([row]); await awake.setAutomatic(true)
        row.phase = .ready; awake.observe([row]); await awake.reconcileAutomatic()
        now += 40; awake.setIdleGrace(30); await awake.reconcileAutomatic()
        XCTAssertFalse(awake.isEnabled)
        row.phase = .running; row.observedAt = now
        awake.observe([row]); await awake.reconcileAutomatic()
        XCTAssertTrue(awake.isEnabled)
        awake.setIdleGrace(0); row.phase = .permission
        awake.observe([row]); await awake.reconcileAutomatic()
        XCTAssertFalse(awake.isEnabled); XCTAssertTrue(awake.automatic)
        await awake.setAutomatic(false)
    }
    @MainActor func testAutomaticStopDescriptionUsesTheChosenGraceWording() throws {
        let awake = KeepAwake(client: SettingsAwakeClient(), defaults: try defaults())
        let expected = [0: L("Сон вернётся сразу после завершения работы."),
                        30: L("Сон вернётся через 30 секунд после завершения работы."),
                        60: L("Сон вернётся через 1 минуту после завершения работы."),
                        120: L("Сон вернётся через 2 минуты после завершения работы."),
                        300: L("Сон вернётся через 5 минут после завершения работы.")]
        for (seconds, text) in expected {
            awake.setIdleGrace(seconds)
            XCTAssertEqual(awake.automaticStopDescription, text)
        }
        // Every language names the choice, never "0 seconds" or "300 seconds".
        for language in ["en", "de", "es", "fr", "zh-Hans"] {
            XCTAssertFalse(L10n.text("Сон вернётся сразу после завершения работы.", language: language).contains("0"), language)
            XCTAssertFalse(L10n.text("Сон вернётся через 5 минут после завершения работы.", language: language).contains("300"), language)
        }
    }
    @MainActor func testRestoreDuringANotificationRequestResetsNothingAndSaysSo() async throws {
        let permissions = PendingNotificationPermissions()
        let features = AppFeatures(defaults: try defaults(), permissionAccess: permissions)
        features.sounds = true; features.completionCooldown = 30
        let enabling = Task { await features.setBanners(true) }
        while permissions.pending == nil { await Task.yield() }
        let whileBusy = await features.restoreDefaults()
        XCTAssertFalse(whileBusy, "The reset reports the pending macOS request")
        XCTAssertTrue(features.sounds, "Nothing is reset halfway")
        XCTAssertEqual(features.completionCooldown, 30)
        permissions.pending?.resume(); await enabling.value
        let afterwards = await features.restoreDefaults()
        XCTAssertTrue(afterwards)
        XCTAssertFalse(features.banners); XCTAssertFalse(features.sounds)
        XCTAssertEqual(features.completionCooldown, AppDefaultSettings.soundCooldown)
    }
    @MainActor func testRestorePresentationPreservesConnectionsDatesAndWelcomeProgress() async throws {
        let defaults = try defaults(), permissions = SettingsPermissions()
        defaults.set(1, forKey: "welcomeCompletedVersion")
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.icon = .claude; appearance.limits.enabled = true
        appearance.restoreDefaults()
        XCTAssertEqual(appearance.icon, .lunavect); XCTAssertFalse(appearance.limits.enabled)
        var widgets = WidgetPreferences()
        widgets.enabledProviders = [.codex]; widgets.subscriptionDates = ["codex": "2026-10-01"]
        widgets.showFiveHour = true; widgets.transparentBackground = true; widgets.transparency = 0.7
        widgets.restoreAppearanceDefaults()
        XCTAssertEqual(widgets.enabledProviders, [.codex]); XCTAssertEqual(widgets.subscriptionDates["codex"], "2026-10-01")
        XCTAssertFalse(widgets.showFiveHour); XCTAssertFalse(widgets.transparentBackground)
        let features = AppFeatures(defaults: defaults, permissionAccess: permissions)
        features.banners = true; features.sounds = true; features.completionCooldown = 30
        permissions.loginStatus = .enabled
        await features.restoreDefaults()
        XCTAssertFalse(features.banners); XCTAssertFalse(features.sounds)
        XCTAssertEqual(features.completionCooldown, 5); XCTAssertEqual(permissions.loginStatus, .notRegistered)
        XCTAssertEqual(defaults.integer(forKey: "welcomeCompletedVersion"), 1)
    }
    @MainActor func testUserSelectedSoundCooldownChangesDeliveryAndPersists() throws {
        for cooldown in [0, 30] {
            let defaults = try defaults()
            var now = Date(), count = 0
            let features = AppFeatures(defaults: defaults, now: { now }, playSound: { _ in count += 1 })
            features.sounds = true; features.completionCooldown = cooldown
            var rows = (0..<3).map { AgentSession(provider: .codex, sessionID: "demo\($0)", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now) }
            features.observe(rows)
            now += 1; rows[0].phase = .ready; rows[0].observedAt = now; features.observe(rows)
            now += 10; rows[1].phase = .ready; rows[1].observedAt = now; features.observe(rows)
            XCTAssertEqual(count, cooldown == 0 ? 2 : 1)
            now += 21; rows[2].phase = .ready; rows[2].observedAt = now; features.observe(rows)
            XCTAssertEqual(count, cooldown == 0 ? 3 : 2)
            XCTAssertEqual(AppFeatures(defaults: defaults).completionCooldown, cooldown)
        }
    }
    @MainActor func testUpdateChecksAndDownloadsCanBeSelectedIndependently() throws {
        let defaults = try defaults()
        let updates = AppUpdates(defaults: defaults)
        updates.setAutomatic(false); updates.setCheckingAutomatically(true)
        XCTAssertTrue(updates.checkingAutomatically); XCTAssertFalse(updates.automatic)
        let restored = AppUpdates(defaults: defaults)
        XCTAssertTrue(restored.checkingAutomatically); XCTAssertFalse(restored.automatic)
        updates.setAutomatic(true); updates.setCheckingAutomatically(false)
        XCTAssertFalse(updates.automatic); XCTAssertFalse(updates.checkingAutomatically)
        updates.setAutomatic(true)
        XCTAssertTrue(updates.automatic); XCTAssertTrue(updates.checkingAutomatically)
    }
    @MainActor func testRenderPreferencePages() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_PREFERENCES"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try defaults(), client = SettingsAwakeClient()
        let awake = KeepAwake(client: client, defaults: defaults)
        let features = AppFeatures(defaults: defaults, permissionAccess: SettingsPermissions())
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        func render<V: View>(_ view: V, name: String) throws {
            let host = NSHostingView(rootView: view.padding(24).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        for language in ["en", "ru", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            try render(KeepAwakeSettingsView(awake: awake), name: "awake-" + language)
            try render(NotificationSettingsView(features: features), name: "notifications-" + language)
            try render(BaseSettingsView(restore: { true }), name: "defaults-" + language)
        }
        L10n.defaults.set("en", forKey: "languageCode")
        await awake.setSafetyPolicy(.init(batteryProtection: false, thermalProtection: false))
        try render(KeepAwakeSettingsView(awake: awake), name: "awake-protections-off")
        client.isAvailable = false; awake.refreshPermission()
        try render(KeepAwakeSettingsView(awake: awake), name: "awake-unconfigured")
    }
}
