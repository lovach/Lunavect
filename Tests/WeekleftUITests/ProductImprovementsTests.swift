import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ProductImprovementsTests: XCTestCase {
    @MainActor func testUpdateBadgeChangesWhileIdleWithoutMovingStatusItem() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let animator = MenuBarAnimator(statusItem: item)
        animator.update(icon: .codex, onlyWhileWorking: true, running: 0, waiting: 0)
        let width = item.length
        let oldPhase = AppUpdates.shared.phase
        defer { AppUpdates.shared.phase = oldPhase }
        AppUpdates.shared.phase = .ready("9.9.9")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(animator.content.updateBadge.isHidden)
        XCTAssertTrue(item.button?.toolTip?.contains("9.9.9") == true)
        XCTAssertEqual(item.length, width)
        AppUpdates.shared.phase = .idle
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(animator.content.updateBadge.isHidden)
        XCTAssertFalse(item.button?.toolTip?.contains("9.9.9") == true)
    }
    @MainActor func testRenderLimitsStatisticsAndUpdates() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_PRODUCT"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.ProductPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        let now = Date()
        let weekly = try QuotaWindow(usedPercent: 85, durationMinutes: 10080, resetsAt: now.addingTimeInterval(180_000))
        let five = try QuotaWindow(usedPercent: 4, durationMinutes: 300, resetsAt: now.addingTimeInterval(7_200))
        let model = ModelQuota(name: "Fable", window: try QuotaWindow(usedPercent: 88, durationMinutes: 10080, resetsAt: weekly.resetsAt), fetchedAt: now)
        let claude = UsageSnapshot(provider: .claude, weekly: weekly, fiveHour: five, fetchedAt: now, source: "Claude Code /usage", modelQuotas: [model])
        let codex = UsageSnapshot(provider: .codex, weekly: weekly, fetchedAt: now, source: "Codex app-server")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]; preferences.showFiveHour = true
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), providers: 3)
        var details = ActivityDetails()
        details.merge([
            .init(provider: .claude, sessionID: "c", title: "Add a connection guide", cwd: "/Users/demo/Projects/Lunavect", intervals: [.init(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), providers: 1)]),
            .init(provider: .codex, sessionID: "x", title: "Test usage limits", cwd: "/Users/demo/Projects/Lunavect", intervals: [.init(start: now.addingTimeInterval(-3500), end: now.addingTimeInterval(-1900), providers: 2)])
        ], now: now)
        let store = AppStore(state: SharedState(snapshots: [claude, codex], preferences: preferences), savesChanges: false, activityHistory: history, activityDetails: details)
        let sessions = SessionStore(directory: directory.appendingPathComponent("empty-sessions"), defaults: defaults)
        let appearance = MenuBarAppearance(defaults: defaults)
        for language in ["ru", "en", "de", "fr", "es", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            defaults.set("limits", forKey: "settingsSection")
            defaults.set(true, forKey: "showClaudeModelQuotas")
            try render(SettingsView(store: store, menuBarAppearance: appearance, sessions: sessions).defaultAppStorage(defaults), size: CGSize(width: 880, height: 740), to: directory.appendingPathComponent("limits-\(language).png"))
        }
        L10n.defaults.set("ru", forKey: "languageCode")
        defaults.set(false, forKey: "showClaudeModelQuotas")
        try render(LimitsProviderSummary(snapshot: claude, showFiveHour: true, now: now).defaultAppStorage(defaults).disclosureGroupStyle(FullRowDisclosureStyle()).padding(20), size: CGSize(width: 620, height: 350), to: directory.appendingPathComponent("model-collapsed.png"))
        try render(ActivityBreakdownView(history: history, details: details, providers: [.claude, .codex], period: .day, selectedDate: nil, now: now, expanded: ["/Users/demo/Projects/Lunavect"]).disclosureGroupStyle(FullRowDisclosureStyle()).padding(24), size: CGSize(width: 640, height: 540), to: directory.appendingPathComponent("breakdown.png"))
        defaults.set("updates", forKey: "settingsSection")
        try render(SettingsView(store: store, menuBarAppearance: appearance, sessions: sessions).defaultAppStorage(defaults), size: CGSize(width: 800, height: 580), to: directory.appendingPathComponent("updates-minimum.png"))
        let session = AgentSession(provider: .claude, sessionID: "fixture", title: "Проверить новую версию приложения", cwd: "/Users/demo/Projects/Lunavect", phase: .running, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        try render(SessionRow(session: session, now: now, phase: .running, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in }).padding(10), size: CGSize(width: 360, height: 72), to: directory.appendingPathComponent("session-path.png"))
        let updates = AppUpdates(); updates.phase = .ready("1.2.0"); updates.canCheck = true
        try render(UpdateNoticeView(updates: updates).padding(16), size: CGSize(width: 360, height: 80), to: directory.appendingPathComponent("update-ready.png"))
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, to path: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua); host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.07)); host.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
