import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ProductImprovementsTests: XCTestCase {
    @MainActor func testUpdateNoticeStaysAccessibleWithoutOverlayingArtworkOrMovingStatusItem() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let suite = "Lunavect.UpdateBadge." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdates(defaults: defaults, isolated: true)
        let animator = MenuBarAnimator(statusItem: item, updates: updates)
        animator.update(icon: .claude, onlyWhileWorking: true, running: 0, waiting: 0)
        let width = item.button?.image?.size.width
        updates.phase = .ready("9.9.9")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(animator.content.subviews, [animator.content.artwork])
        XCTAssertTrue(item.button?.toolTip?.contains("9.9.9") == true)
        XCTAssertEqual(item.button?.image?.size.width, width)
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_STATUS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let button = try XCTUnwrap(item.button)
            button.appearance = NSAppearance(named: .darkAqua)
            button.layoutSubtreeIfNeeded(); animator.content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("update-menu-bar.png"))
            updates.canCheck = true
            try render(UpdateNoticeView(updates: updates).padding(12), size: CGSize(width: 392, height: 76), to: directory.appendingPathComponent("update-panel.png"))
        }
        updates.phase = .idle
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(animator.content.subviews, [animator.content.artwork])
        XCTAssertFalse(item.button?.toolTip?.contains("9.9.9") == true)
    }
    @MainActor func testRenderLimitsStatisticsAndUpdates() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
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
                .init(
                    provider: .claude, sessionID: "c", title: "Add a connection guide",
                    cwd: "/Users/demo/Projects/Lunavect",
                    intervals: [
                        .init(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), providers: 1)
                    ]),
                .init(
                    provider: .codex, sessionID: "x", title: "Test usage limits", cwd: "/Users/demo/Projects/Lunavect",
                    intervals: [
                        .init(start: now.addingTimeInterval(-3500), end: now.addingTimeInterval(-1900), providers: 2)
                    ]),
            ], now: now)
        let store = AppStore(state: SharedState(snapshots: [claude, codex], preferences: preferences), savesChanges: false, activityHistory: history, activityDetails: details)
        let sessions = SessionStore(directory: directory.appendingPathComponent("empty-sessions"), defaults: defaults)
        let appearance = MenuBarAppearance(defaults: defaults)
        for language in ["ru", "en", "de", "fr", "es", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            defaults.set("limits", forKey: "settingsSection")
            defaults.set(false, forKey: "showClaudeModelQuotas")
            try render(
                SettingsView(
                    store: store, menuBarAppearance: appearance, sessions: sessions, updates: uiDependencies.updates,
                    awake: uiDependencies.awake, features: uiDependencies.features, language: uiDependencies.language
                ).defaultAppStorage(defaults), size: CGSize(width: 880, height: 740),
                to: directory.appendingPathComponent("limits-\(language).png"))
        }
        L10n.defaults.set("ru", forKey: "languageCode")
        defaults.set(false, forKey: "showClaudeModelQuotas")
        try render(
            LimitsProviderSummary(snapshot: claude, showFiveHour: true, now: now).defaultAppStorage(defaults).padding(
                20), size: CGSize(width: 620, height: 280), to: directory.appendingPathComponent("model-visible.png"))
        var yesterday = claude
        yesterday.fetchedAt = now.addingTimeInterval(-26 * 3600)
        try render(
            LimitsProviderSummary(snapshot: yesterday, showFiveHour: false, now: now).defaultAppStorage(defaults).padding(20),
            size: CGSize(width: 620, height: 280), to: directory.appendingPathComponent("limits-yesterday.png"))
        L10n.defaults.set("en", forKey: "languageCode")
        try render(
            ActivityStatisticsView(store: store, historyExpanded: true).disclosureGroupStyle(FullRowDisclosureStyle())
                .padding(24), size: CGSize(width: 660, height: 1320),
            to: directory.appendingPathComponent("history-aligned.png"))
        let features = AppFeatures(defaults: defaults, playSound: { _ in })
        features.sounds = true
        try render(NotificationSettingsView(features: features).padding(24), size: CGSize(width: 620, height: 480), to: directory.appendingPathComponent("sound-only.png"))
        appearance.limits.enabled = false
        try render(
            MenuBarLimitsSettings(appearance: appearance, snapshots: [claude, codex], providers: [.claude, .codex])
                .padding(24), size: CGSize(width: 620, height: 530),
            to: directory.appendingPathComponent("limits-disabled-settings.png"))
        try render(
            ActivityBreakdownView(
                data: ActivityBreakdownData(
                    history: history, details: details, providers: [.claude, .codex], period: .day, selectedDate: nil,
                    now: now), expanded: ["/Users/demo/Projects/Lunavect"]
            ).disclosureGroupStyle(FullRowDisclosureStyle()), size: CGSize(width: 640, height: 540),
            to: directory.appendingPathComponent("breakdown.png"))
        defaults.set("updates", forKey: "settingsSection")
        try render(
            SettingsView(
                store: store, menuBarAppearance: appearance, sessions: sessions, updates: uiDependencies.updates,
                awake: uiDependencies.awake, features: uiDependencies.features, language: uiDependencies.language
            ).defaultAppStorage(defaults), size: CGSize(width: 800, height: 580),
            to: directory.appendingPathComponent("updates-minimum.png"))
        let session = AgentSession(
            provider: .claude, sessionID: "fixture", title: "Проверить новую версию приложения",
            cwd: "/Users/demo/Projects/Lunavect", phase: .running, updatedAt: now, observedAt: now,
            runtimeConfirmed: true)
        try render(
            SessionRow(
                session: session, now: now, phase: .running, swipePresentation: SessionSwipePresentation(), onHide: {},
                onError: { _ in }
            ).padding(10), size: CGSize(width: 360, height: 72),
            to: directory.appendingPathComponent("session-path.png"))
        let updates = AppUpdates(); updates.phase = .ready("1.2.0"); updates.canCheck = true
        try render(UpdateNoticeView(updates: updates).padding(16), size: CGSize(width: 360, height: 80), to: directory.appendingPathComponent("update-ready.png"))
    }
    @MainActor func testRenderStatisticsControls() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CONTROLS"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.ControlsPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        let now = Date(), today = Calendar.current.startOfDay(for: now)
        var history = ActivityHistory(), details = ActivityDetails()
        let records = (0..<341).map { index in
            let provider: ProviderID = index % 2 == 0 ? .claude : .codex
            let start = today.addingTimeInterval(-Double(index % 6 + 1) * 86400 + Double(index % 8) * 3600)
            let span = ActivityInterval(start: start, end: start.addingTimeInterval(1800), providers: provider == .claude ? 1 : 2)
            return ActivityDetailRecord(provider: provider, sessionID: "demo-\(index)", title: "Session \(index + 1)", cwd: "/Users/demo/Projects/Project \(index % 40 + 1)", intervals: [span])
        }
        details.merge(records, now: now)
        history.mergeRecovered(records.flatMap(\.intervals), now: now, limited: false)
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]
        let store = AppStore(state: SharedState(snapshots: [], preferences: preferences), savesChanges: false, activityHistory: history, activityDetails: details)
        let sessions = SessionStore(directory: directory.appendingPathComponent("empty-sessions"), defaults: defaults)
        let appearance = MenuBarAppearance(defaults: defaults)
        let breakdown = ActivityBreakdownData(history: history, details: details, providers: [.claude, .codex], period: .week, selectedDate: nil, now: now)
        XCTAssertEqual(breakdown.records.count, 341)
        for language in ["ru", "en", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            let chartData = ActivityChartData(history: history, now: now, period: .week, providers: [.claude, .codex])
            try render(
                ActivityDetailChart(data: chartData, pinnedDate: today.addingTimeInterval(-86400)),
                size: CGSize(width: 620, height: 500),
                to: directory.appendingPathComponent("chart-selected-\(language).png"))
            try render(ActivityDetailChart(data: chartData), size: CGSize(width: 620, height: 500), to: directory.appendingPathComponent("chart-cleared-\(language).png"))
            defaults.set("statistics", forKey: "settingsSection")
            try render(
                SettingsView(
                    store: store, menuBarAppearance: appearance, sessions: sessions, updates: uiDependencies.updates,
                    awake: uiDependencies.awake, features: uiDependencies.features, language: uiDependencies.language
                ).defaultAppStorage(defaults), size: CGSize(width: 880, height: 940),
                to: directory.appendingPathComponent("statistics-\(language).png"))
            try render(
                ActivityBreakdownView(data: breakdown, expanded: ["/Users/demo/Projects/Project 1"]),
                size: CGSize(width: 640, height: 540), to: directory.appendingPathComponent("projects-\(language).png"))
            defaults.set("menuBar", forKey: "settingsSection")
            appearance.showsSessionStatus = false
            if language == "ru" {
                try render(MenuBarAppearanceView(appearance: appearance).padding(20), size: CGSize(width: 640, height: 210), to: directory.appendingPathComponent("menu-bar-controls.png"))
            }
            try render(
                SettingsView(
                    store: store, menuBarAppearance: appearance, sessions: sessions, updates: uiDependencies.updates,
                    awake: uiDependencies.awake, features: uiDependencies.features, language: uiDependencies.language
                ).defaultAppStorage(defaults), size: CGSize(width: 840, height: 650),
                to: directory.appendingPathComponent("widgets-only-\(language).png"))
            appearance.showsSessionStatus = true
        }
    }

    @MainActor func testRenderMenuBarSections() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_MENU_SECTIONS"] else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.MenuSectionsPreview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLanguage = L10n.selection
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        let now = Date()
        let snapshots = try ProviderID.allCases.map { provider in
            try UsageSnapshot(provider: provider, weekly: QuotaWindow(usedPercent: provider == .claude ? 28 : 62, durationMinutes: 10080, resetsAt: now.addingTimeInterval(172800)), fetchedAt: now)
        }
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]
        let store = AppStore(state: SharedState(snapshots: snapshots, preferences: preferences), savesChanges: false)
        let sessions = SessionStore(directory: directory.appendingPathComponent("empty-sessions"), defaults: defaults)
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.selectIcon(.lunavect)
        defaults.set("menuBar", forKey: "settingsSection")
        for language in ["ru", "en", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for enabled in [true, false] {
                appearance.limits.enabled = enabled
                appearance.showsSessionStatus = enabled
                try render(
                    SettingsView(
                        store: store, menuBarAppearance: appearance, sessions: sessions,
                        updates: uiDependencies.updates, awake: uiDependencies.awake, features: uiDependencies.features,
                        language: uiDependencies.language
                    ).defaultAppStorage(defaults), size: CGSize(width: 840, height: enabled ? 1500 : 740),
                    to: directory.appendingPathComponent("sections-\(enabled ? "on" : "off")-\(language).png"))
                if language == "ru" && !enabled {
                    try render(MenuBarAppearanceView(appearance: appearance).padding(20), size: CGSize(width: 640, height: 300), to: directory.appendingPathComponent("sections-compact.png"))
                }
            }
        }
    }

    @MainActor func testDiagnosticsSheetFitsTheSmallestSettingsWindow() throws {
        _ = NSApplication.shared
        let preview = try AppEnvironment.preview(rows: [])
        defer { preview.stop() }
        // Prepared results keep the sheet from starting a live client check.
        let diagnostics = ConnectionDiagnostics()
        diagnostics.results = [ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
            snapshot: UsageSnapshot(provider: .claude, issue: UsageError.claudeUsageUnavailable.errorDescription), sessionIssue: nil),
            ConnectionDiagnostic(provider: .codex, clientFound: false, signIn: .unavailable, eventsConfigured: false, snapshot: nil, sessionIssue: nil)]
        let view = ConnectionDiagnosticsView(store: preview.store, sessions: preview.sessions, diagnostics: diagnostics, onConnect: { _, _ in })
        let size = NSHostingView(rootView: view).fittingSize
        // Settings keeps a content height of at least 580 points (Main.swift contentMinSize).
        XCTAssertLessThanOrEqual(size.height, 580, "A taller sheet runs past a minimum-height Settings window")
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_PRODUCT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(view, size: size, to: directory.appendingPathComponent("diagnostics-minimum.png"))
        }
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
