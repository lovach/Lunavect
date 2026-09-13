import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class InterfaceAuditTests: XCTestCase {
    private func row(_ id: String, now: Date = Date()) -> AgentSession {
        AgentSession(provider: .codex, sessionID: id, title: "Проверить изменения интерфейса", cwd: "/tmp/Preview", client: .desktop,
                     phase: .ready, updatedAt: now, observedAt: now, runtimeConfirmed: true)
    }
    @MainActor func testUndoOutlivesToastAndSupportsMultipleStepsAndRedo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, undoDelay: .milliseconds(1))
        let rows = [row("a"), row("b"), row("c")]
        store.acceptSessions(rows)
        for item in rows { try store.hide(item) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.lastHidden)
        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo()
        XCTAssertEqual(store.hiddenCount, 2)
        XCTAssertTrue(store.sessions.contains { $0.id == rows[2].id })
        store.undoManager.undo()
        XCTAssertEqual(store.hiddenCount, 1)
        store.undoManager.redo()
        XCTAssertEqual(store.hiddenCount, 2)
        store.undoManager.undo(); store.undoManager.undo()
        XCTAssertEqual(store.hiddenCount, 0)
    }
    @MainActor func testRedoCannotHideANewTaskAndDeleteDoesNotResurrectRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var original = row("a")
        store.acceptSessions([original]); try store.hide(original); store.undoManager.undo()
        original.turnStartedAt = Date(); original.phase = .running
        store.acceptSessions([original]); store.undoManager.redo()
        XCTAssertEqual(store.hiddenCount, 0)
        try store.hide(original); try store.removeHidden()
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertFalse(store.undoManager.canRedo)
        XCTAssertEqual(store.hiddenCount, 0)
    }
    @MainActor func testUndoToastUsesTheSameHistoryAndPreservesPinnedOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let rows = [row("a"), row("b")]
        store.acceptSessions(rows); try store.setPinned(rows[0].id, true)
        try store.hide(rows[0]); try store.undoHide()
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertTrue(store.undoManager.canRedo)
        XCTAssertTrue(store.arrangement.pinned.contains(rows[0].id))
        store.undoManager.redo(); XCTAssertEqual(store.hiddenCount, 1)
    }
    @MainActor func testManualRestoreDismissesAnOlderHideToast() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let rows = [row("a"), row("b")]
        store.acceptSessions(rows)
        try store.hide(rows[0]); try store.hide(rows[1])
        try store.restore(rows[0].id)
        XCTAssertNil(store.lastHidden)
        try store.undoHide()
        XCTAssertEqual(store.hiddenIDs, [rows[1].id])
        store.undoManager.undo()
        XCTAssertEqual(store.hiddenCount, 2)
    }
    @MainActor func testSessionStatusUsesEffectivePhaseAndKeepsToolDetailsOutOfLabel() {
        let old = L10n.defaults.object(forKey: "languageCode")
        L10n.defaults.set("ru", forKey: "languageCode")
        defer { L10n.defaults.set(old, forKey: "languageCode") }
        var item = row("a"); item.phase = .running; item.tool = "mcp__cua_repl__js"
        func label(_ phase: SessionPhase) -> String {
            SessionRow(session: item, now: Date(), phase: phase, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in }).statusTitle
        }
        XCTAssertEqual(label(.running), "Работает")
        XCTAssertEqual(label(.unknown), "Нет свежего статуса")
        XCTAssertEqual(label(.permission), "Нужно разрешение")
        item.tool = nil; XCTAssertEqual(label(.running), "Думает")
    }
    @MainActor func testNativeAuditScreens() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_AUDIT"] else { throw XCTSkip("Opt-in native UI inspection") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "AuditPreview-" + UUID().uuidString)!
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AuditSessions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let sessions = SessionStore(directory: sessionDirectory, defaults: defaults)
        let now = Date()
        var first = row("one", now: now); first.phase = .running; first.tool = "very_long_internal_tool_name"; first.turnStartedAt = now.addingTimeInterval(-180)
        var waiting = row("two", now: now); waiting.provider = .claude; waiting.phase = .permission
        sessions.acceptSessions([first, waiting, row("three", now: now)])
        let weekly = try QuotaWindow(usedPercent: 38, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))
        let expired = try QuotaWindow(usedPercent: 12, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-1))
        let five = try QuotaWindow(usedPercent: 20, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))
        let snapshots = [UsageSnapshot(provider: .claude, weekly: weekly, fiveHour: five, fetchedAt: now, source: "Claude Code statusLine"),
                         UsageSnapshot(provider: .codex, weekly: expired, fiveHour: five, fetchedAt: now.addingTimeInterval(-7200))]
        var prefs = WidgetPreferences(); prefs.enabledProviders = [.claude, .codex]; prefs.showFiveHour = true
        let store = AppStore(state: SharedState(snapshots: snapshots, preferences: prefs), savesChanges: false, activityHistory: ActivityHistory())
        let appearance = MenuBarAppearance(defaults: defaults)
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        let oldSection = UserDefaults.standard.object(forKey: "settingsSection")
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode"); UserDefaults.standard.set(oldSection, forKey: "settingsSection") }
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for scheme in [ColorScheme.dark, .light] {
                let suffix = language + (scheme == .dark ? "-dark" : "-light")
                try render(
                    SessionsView(
                        store: sessions, updates: uiDependencies.updates, awake: uiDependencies.awake, isPreview: true,
                        onSettings: {}), size: CGSize(width: 360, height: 370), scheme: scheme,
                    path: directory.appendingPathComponent("sessions-" + suffix + ".png"))
                try render(
                    SessionsView(
                        store: sessions, updates: uiDependencies.updates, awake: uiDependencies.awake, isPreview: true,
                        onSettings: {}, attentionOnly: true), size: CGSize(width: 360, height: 330), scheme: scheme,
                    path: directory.appendingPathComponent("waiting-" + suffix + ".png"))
                if language == "ru" || language == "de" {
                    for section in SettingsSection.allCases {
                        UserDefaults.standard.set(section.rawValue, forKey: "settingsSection")
                        try render(
                            SettingsView(
                                store: store, menuBarAppearance: appearance, sessions: sessions,
                                updates: uiDependencies.updates, awake: uiDependencies.awake,
                                features: uiDependencies.features, language: uiDependencies.language),
                            size: CGSize(width: 840, height: 680), scheme: scheme,
                            path: directory.appendingPathComponent(section.rawValue + "-" + suffix + ".png"))
                    }
                }
            }
            try render(WeekleftCard(snapshots: snapshots, preferences: prefs).background(Color(white: 0.14)), size: CGSize(width: 344, height: 172), scheme: .dark,
                       path: directory.appendingPathComponent("widget-" + language + ".png"))
        }
        L10n.defaults.set("ru", forKey: "languageCode")
        try sessions.hide(waiting)
        try render(HiddenSessionsView(sessions: sessions.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}),
                   size: CGSize(width: 360, height: 360), scheme: .dark, path: directory.appendingPathComponent("hidden.png"))
        try render(WelcomeView(store: store, sessions: sessions, onFinish: {}, step: 3), size: CGSize(width: 640, height: 620), scheme: .dark,
                   path: directory.appendingPathComponent("welcome.png"))
    }
    @MainActor private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, path: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
