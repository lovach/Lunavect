import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ReleaseScreenshots: XCTestCase {
    @MainActor func testRenderPublicScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RELEASE_SCREENSHOTS"] else {
            throw XCTSkip("Opt-in public screenshots using fictional data")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "Lunavect.ReleaseScreenshots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previous = L10n.defaults.object(forKey: "languageCode")
        L10n.defaults.set("en", forKey: "languageCode")
        defer { L10n.defaults.set(previous, forKey: "languageCode"); defaults.removePersistentDomain(forName: suite) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessions = SessionStore(directory: temporary, defaults: defaults)
        let now = Date()
        var work = AgentSession(provider: .claude, sessionID: "demo-working", title: "Build the onboarding flow", cwd: "/Users/demo/Projects/Lunavect", client: .desktop, phase: .running, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        work.turnStartedAt = now.addingTimeInterval(-72)
        let waiting = AgentSession(provider: .codex, sessionID: "demo-permission", title: "Review the release checklist", cwd: "/Users/demo/Projects/Lunavect", client: .desktop, phase: .permission, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        let ready = AgentSession(provider: .codex, sessionID: "demo-ready", title: "Polish the settings screen", cwd: "/Users/demo/Projects/Atlas", client: .desktop, phase: .ready, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        sessions.acceptSessions([work, waiting, ready])
        try render(SessionsView(store: sessions, onSettings: {}).defaultAppStorage(defaults), size: CGSize(width: 360, height: 355), to: output.appendingPathComponent("sessions.png"))
        let claude = UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 32, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 16, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600)), fetchedAt: now, source: "Claude Code /usage")
        let codex = UsageSnapshot(provider: .codex,
            weekly: try QuotaWindow(usedPercent: 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 9, durationMinutes: 300, resetsAt: now.addingTimeInterval(4 * 3600)), fetchedAt: now, source: "Codex app-server")
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude, .codex]; preferences.showFiveHour = true
        let store = AppStore(state: SharedState(snapshots: [claude, codex], preferences: preferences), savesChanges: false,
            activityHistory: ActivityHistory(), activityDetails: ActivityDetails())
        defaults.set("limits", forKey: "settingsSection")
        try render(SettingsView(store: store, menuBarAppearance: MenuBarAppearance(defaults: defaults), sessions: sessions).defaultAppStorage(defaults), size: CGSize(width: 880, height: 740), to: output.appendingPathComponent("limits.png"))
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, to path: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark).environment(\.controlActiveState, .key))
        host.appearance = NSAppearance(named: .darkAqua); host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.07)); host.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
