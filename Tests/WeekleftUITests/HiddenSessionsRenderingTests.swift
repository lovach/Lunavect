import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class HiddenSessionsRenderingTests: XCTestCase {
    @MainActor func testPanelKeepsOneEmptyRowAcrossCountsAndFooterChanges() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var height: CGFloat = 480
        var chrome: CGFloat = 0
        var viewport: CGRect = .zero
        let panel = SessionsView(store: store, onSettings: {}, onHeightChange: { height = $0 })
            .onPreferenceChange(SessionPanelSectionHeights.self) { chrome = $0.values.reduce(0, +) }
            .onPreferenceChange(SessionScrollRegion.self) { viewport = $0 }
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for count in [1, 2, 5, 12, 2] {
            let now = Date()
            let rows = (0..<count).map {
                AgentSession(provider: .codex, sessionID: "space-\($0)", title: "Сессия \($0 + 1)", cwd: "/tmp/Preview", client: .desktop, phase: .running, updatedAt: now, observedAt: now)
            }
            store.acceptSessions(rows)
            // Also exercise a footer that grows when Undo becomes available.
            if count == 5 { try store.hide(rows[0]) }
            let visibleCount = count == 5 ? count - 1 : count
            for _ in 0..<6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.frame.size = NSSize(width: 360, height: height)
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertGreaterThan(chrome, 100)
            XCTAssertGreaterThan(viewport.height, 0)
            XCTAssertEqual(height - chrome - viewport.height, 42, accuracy: 1, "Exactly one card reserved for \(count) sessions")
            let rowsHeight = CGFloat(visibleCount) * 42 + CGFloat(visibleCount - 1) * 2 + 8
            XCTAssertEqual(viewport.height, min(rowsHeight, 480 - chrome - 42), accuracy: 1)
            XCTAssertLessThanOrEqual(height, 480)
            if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SPARE_ROW"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "-\(count).png"))
            }
            if count == 5 { try store.restore(rows[0].id) }
        }
    }

    @MainActor func testReorderingKeepsSnapshotUntilDragEndsWithoutHidingRows() {
        let state = SessionReorderState(), t = Date()
        let rows = ["a", "b"].map { AgentSession(provider: .codex, sessionID: $0, title: $0, cwd: "", phase: .ready, updatedAt: t, observedAt: t) }
        state.begin("codex:b", rows: rows)
        var arrangement = SessionArrangement()
        arrangement.move("codex:b", before: "codex:a", visible: rows.map(\.id))
        XCTAssertEqual(state.rows?.map(\.id), ["codex:a", "codex:b"])
        XCTAssertEqual(arrangement.arranged(rows).map(\.id), ["codex:b", "codex:a"])
        state.end(); XCTAssertNil(state.rows); XCTAssertNil(state.id)
    }
    @MainActor func testRenderHiddenAndCompactPanels() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_HIDDEN"] else { throw XCTSkip("Opt-in native rendering") }
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let t = Date()
        let rows = (0..<8).map { AgentSession(provider: $0 % 2 == 0 ? .claude : .codex, sessionID: "fixture-\($0)", title: ["Название проекта на русском", "Überarbeitung der Sitzungsübersicht", "修复会话列表", "Vérifier les notifications"][$0 % 4], cwd: "/tmp/Test", client: .desktop, phase: .ready, updatedAt: t, observedAt: t) }
        store.acceptSessions(rows)
        for row in rows { try store.hide(row) }
        let hidden = HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {})
            .frame(width: 360, height: 480)
        try render(hidden, to: output + "-hidden.png")
        try store.restore(rows[0].id)
        try render(SessionsView(store: store, onSettings: {}).frame(width: 360), to: output + "-compact.png")
        try store.restore(rows[1].id)
        try render(SessionsView(store: store, onSettings: {}, query: "а").frame(width: 360), to: output + "-filtered.png")
        store.acceptSessions([rows[1]])
        try render(SessionsView(store: store, onSettings: {}, provider: "claude"), to: output + "-empty-claude.png")
        store.acceptSessions([rows[0]])
        try render(SessionsView(store: store, onSettings: {}, provider: "codex"), to: output + "-empty-codex.png")
        store.acceptSessions([])
        try render(SessionsView(store: store, onSettings: {}), to: output + "-empty-all.png")
    }
    @MainActor private func render<V: View>(_ view: V, to path: String) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        window.contentView = nil
    }
}
