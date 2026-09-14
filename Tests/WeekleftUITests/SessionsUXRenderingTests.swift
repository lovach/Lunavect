import XCTest
import SwiftUI
import AppKit
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class SessionRenderAwakeClient: AwakeClient {
    var isAvailable = false
    func requestPermission() throws { XCTFail("Rendering must not request system permission") }
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws { XCTFail("Rendering must not prevent sleep") }
    func configure(policy: AwakeSafetyPolicy) async throws { XCTFail("Rendering must not configure the helper") }
    func keepAlive() async throws { XCTFail("Rendering must not contact the helper") }
    func end() async throws { XCTFail("Rendering must not contact the helper") }
    func disconnect() {}
}

final class SessionsUXRenderingTests: XCTestCase {
    @MainActor func testCompactionRowShowsExplicitActivity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload: [String: Any] = ["session_id": "compact-fixture", "hook_event_name": "PreCompact", "trigger": "manual"]
        var session = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude,
            previous: nil, now: now, client: .desktop).session
        session.title = "Подготовить презентацию"; session.cwd = "/Projects/Studio"
        let row = SessionRow(session: session, now: now.addingTimeInterval(184), phase: .running,
            swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in })
        XCTAssertEqual(row.statusTitle, L("Сжимает контекст"))
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SESSIONS_UX"] {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(row.padding(8), size: CGSize(width: 360, height: 66), scheme: .dark,
                to: directory.appendingPathComponent("claude-compacting.png"))
        }
    }

    @MainActor func testClaudeClosingQuestionCountsAsWaiting() throws {
        let suite = "Lunavect.ClosingQuestion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(defaults: defaults, isolated: true)
        let now = Date()
        let payload: [String: Any] = ["session_id": "closing-question", "hook_event_name": "Stop",
                                     "last_assistant_message": "Предлагаю пять правок.\n\n1. Делаем все пять? Предлагаю да."]
        var question = try SessionRecord.event(JSONSerialization.data(withJSONObject: payload), provider: .claude,
                                               previous: nil, now: now, client: .desktop).session
        question.title = "Доработать видео"; question.cwd = "/Projects/Studio"
        let ready = AgentSession(provider: .claude, sessionID: "completed-response", title: "Проверить обложку", cwd: "/Projects/Studio",
                                 client: .desktop, phase: .ready, updatedAt: now, observedAt: now)
        store.acceptSessions([question, ready], now: now)
        let awake = KeepAwake(client: SessionRenderAwakeClient(), defaults: defaults)
        let updates = AppUpdates(defaults: defaults, isolated: true)
        let view = SessionsView(store: store, updates: updates, awake: awake, isPreview: true, onSettings: {})
        XCTAssertEqual(view.currentCounts(at: now).waiting, 1)
        XCTAssertEqual(view.currentCounts(at: now).working, 0)
        XCTAssertEqual(store.activeCount, 1)
        if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SESSIONS_UX"] {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(view, size: CGSize(width: 360, height: 290), scheme: .dark,
                       to: directory.appendingPathComponent("claude-closing-question.png"))
        }
    }
    @MainActor func testNativeSessionsAndHiddenScreens() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SESSIONS_UX"] else {
            throw XCTSkip("Opt-in isolated native rendering")
        }
        _ = NSApplication.shared
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let suite = "Lunavect.SessionsUXRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let oldLanguage = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"]
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            if let oldLanguage { setenv("LUNAVECT_PREVIEW_LANGUAGE", oldLanguage, 1) }
            else { unsetenv("LUNAVECT_PREVIEW_LANGUAGE") }
        }
        let store = SessionStore(directory: directory, defaults: defaults, isolated: true)
        let hiddenStore = SessionStore(directory: directory.appendingPathComponent("hidden"), defaults: defaults, isolated: true)
        let awake = KeepAwake(client: SessionRenderAwakeClient(), defaults: defaults)
        let updates = AppUpdates(defaults: defaults, isolated: true)
        let now = Date()
        let sessions = [
            AgentSession(
                provider: .claude, sessionID: "render-running", title: "Überarbeitung der Einstellungen",
                cwd: "/Projects/Lunavect", client: .desktop, phase: .running, updatedAt: now, observedAt: now,
                runtimeConfirmed: true),
            AgentSession(
                provider: .codex, sessionID: "render-waiting", title: "Проверить список сессий",
                cwd: "/Projects/Lunavect", client: .desktop, phase: .permission, updatedAt: now, observedAt: now,
                runtimeConfirmed: true),
            AgentSession(
                provider: .codex, sessionID: "render-ready", title: "Prepare the release checklist",
                cwd: "/Projects/Atlas", client: .desktop, phase: .ready, updatedAt: now, observedAt: now,
                runtimeConfirmed: true),
        ]
        store.acceptSessions(sessions)
        let archived = (0..<12).map { index in
            AgentSession(provider: index.isMultiple(of: 2) ? .claude : .codex, sessionID: "hidden-\(index)",
                         title: ["Überarbeitung der Sitzungsübersicht", "Проверить уведомления и настройки", "Prepare the release checklist"][index % 3],
                         cwd: "/Projects/" + (index.isMultiple(of: 2) ? "Lunavect" : "Atlas"), client: .desktop,
                         phase: .ready, updatedAt: now, observedAt: now, runtimeConfirmed: true)
        }
        hiddenStore.acceptSessions(archived)
        for row in archived { try hiddenStore.hide(row) }
        for language in ["ru", "de"] {
            setenv("LUNAVECT_PREVIEW_LANGUAGE", language, 1)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = language + (scheme == .light ? "-light" : "-dark")
                try render(SessionsView(store: store, updates: updates, awake: awake, isPreview: true, onSettings: {}),
                           size: CGSize(width: 360, height: 390), scheme: scheme,
                           to: outputURL.appendingPathComponent("sessions-" + suffix + ".png"))
                try render(SessionsView(store: store, updates: updates, awake: awake, isPreview: true, onSettings: {}, attentionOnly: true),
                           size: CGSize(width: 360, height: 345), scheme: scheme,
                           to: outputURL.appendingPathComponent("waiting-" + suffix + ".png"))
                try render(HiddenSessionsView(sessions: hiddenStore.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}),
                           size: CGSize(width: 360, height: 480), scheme: scheme,
                           to: outputURL.appendingPathComponent("hidden-" + suffix + ".png"))
                for query in ["codex", "missing"] {
                    try render(HiddenSessionsView(sessions: hiddenStore.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}, query: query),
                               size: CGSize(width: 360, height: 480), scheme: scheme,
                               to: outputURL.appendingPathComponent("hidden-" + query + "-" + suffix + ".png"))
                }
                try render(HiddenSessionsView(sessions: Array(hiddenStore.hiddenSessions.prefix(1)), onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}),
                           size: CGSize(width: 360, height: 300), scheme: scheme,
                           to: outputURL.appendingPathComponent("hidden-compact-" + suffix + ".png"))
                var unknown = sessions[0]
                unknown.title = " \n "; unknown.phase = .unknown
                try render(VStack(spacing: 6) {
                    SessionRow(session: unknown, now: now, phase: .unknown, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in })
                    SessionRow(session: sessions[1], now: now, phase: .permission, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in },
                               onMove: { _ in }, canMoveUp: true, canMoveDown: true, isFocused: true)
                }.padding(8).background(Color(nsColor: .windowBackgroundColor)),
                           size: CGSize(width: 360, height: 106), scheme: scheme,
                           to: outputURL.appendingPathComponent("session-focus-unknown-" + suffix + ".png"))
            }
        }
    }

    @MainActor private func render<V: View>(_ content: V, size: CGSize, scheme: ColorScheme, to url: URL) throws {
        var effectiveEnvironment: [String: String] = [:]
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height).preferredColorScheme(scheme)
            .background(SessionRenderAccessibilityEnvironment { effectiveEnvironment = $0 }))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        host.needsDisplay = true
        host.displayIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let backingSize = host.convertToBacking(host.bounds).size
        XCTAssertEqual(bitmap.pixelsWide, Int(backingSize.width.rounded()))
        XCTAssertEqual(bitmap.pixelsHigh, Int(backingSize.height.rounded()))
        var sampledColors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 40)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 40)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    sampledColors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(sampledColors.count, 4, "A flat or blank native capture is not a valid render")
        XCTAssertEqual(effectiveEnvironment.count, 3, "Record the settings actually observed by SwiftUI")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        try JSONSerialization.data(withJSONObject: effectiveEnvironment, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("accessibility.json"))
    }
}

private struct SessionRenderAccessibilityEnvironment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let report: ([String: String]) -> Void
    var body: some View {
        Color.clear.onAppear {
            report(["effective_reduce_motion": String(reduceMotion), "effective_reduce_transparency": String(reduceTransparency),
                    "effective_increased_contrast": String(contrast == .increased)])
        }
    }
}
