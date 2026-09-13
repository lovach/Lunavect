import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class HiddenSessionsRenderingTests: XCTestCase {
    @MainActor func testPanelFitsWholeRowsAcrossCountsScrollLimitsAndFooterChanges() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, defaults: uiDependencies.defaults, isolated: true)
        defer { store.stop() }
        let state = SessionPanelState(isVisible: true)
        var height: CGFloat = 480
        var sections: [String: CGFloat] = [:]
        var measuredViewport: CGRect = .zero
        let panel = SessionsView(store: store, panelState: state, updates: uiDependencies.updates,
            awake: uiDependencies.awake, onSettings: {}, onHeightChange: { height = $0 })
            .onPreferenceChange(SessionPanelSectionHeights.self) { sections = $0 }
            .onPreferenceChange(SessionScrollRegion.self) { measuredViewport = $0 }
            .defaultAppStorage(uiDependencies.defaults)
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }

        func settle() {
            for _ in 0..<6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                window.setContentSize(NSSize(width: 360, height: height))
                host.frame.size = NSSize(width: 360, height: height)
                host.layoutSubtreeIfNeeded()
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func panelRect(of view: NSView) -> CGRect {
            let rect = host.convert(view.bounds, from: view)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.maxY - rect.maxY,
                                                  width: rect.width, height: rect.height)
        }
        func checkScrollLimits(expectedCount: Int) throws {
            settle()
            let handle = try XCTUnwrap(descendants(host).compactMap { $0 as? SessionRowInteraction.Handle }.first)
            let scroll = try XCTUnwrap(handle.enclosingScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            var topRowCount = 0
            for bottom in [false, true, false] {
                // Move the real NSClipView to its natural limits, without using
                // the production layout formula or a synthetic scroll rectangle.
                let maximumY = max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                let y = document.isFlipped == bottom ? maximumY : document.bounds.minY
                scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle()

                let viewport = panelRect(of: scroll.contentView)
                // AppKit pixel-aligns the clip view; SwiftUI retains its fractional origin.
                XCTAssertEqual(viewport.minY, measuredViewport.minY, accuracy: 1)
                XCTAssertEqual(viewport.height, measuredViewport.height, accuracy: 0.5)
                XCTAssertGreaterThan(viewport.height, 0)
                let currentIDs = Set(store.sessions.map(\.id))
                let cards = descendants(host).compactMap { view -> (id: String, frame: CGRect)? in
                    guard let handle = view as? SessionRowInteraction.Handle,
                          let id = handle.session?.id, currentIDs.contains(id), let anchor = handle.anchor?.view else { return nil }
                    return (id, panelRect(of: anchor))
                }.filter { !$0.frame.intersection(viewport).isNull && $0.frame.intersection(viewport).height > 0.5 }
                    .sorted { $0.frame.minY < $1.frame.minY }
                XCTAssertFalse(cards.isEmpty)
                for card in cards {
                    XCTAssertEqual(card.frame.height, 42, accuracy: 0.5, "Actual native row height: \(card.id)")
                    XCTAssertEqual(card.frame.intersection(viewport).height, card.frame.height, accuracy: 0.5,
                                   "Clipped row at \(bottom ? "bottom" : "top") limit: \(card.id)")
                }
                let first = try XCTUnwrap(cards.first), last = try XCTUnwrap(cards.last)
                XCTAssertEqual(first.frame.minY, viewport.minY, accuracy: 0.5, "No partial row or empty strip at viewport start")
                XCTAssertEqual(last.frame.maxY, viewport.maxY, accuracy: 0.5, "The final whole row reaches the viewport end")
                for (previous, next) in zip(cards, cards.dropFirst()) {
                    XCTAssertEqual(next.frame.minY - previous.frame.maxY, 2, accuracy: 0.5)
                }
                if bottom {
                    XCTAssertEqual(last.id, state.orderedIDs.last)
                    XCTAssertEqual(cards.count, topRowCount)
                } else {
                    XCTAssertEqual(first.id, state.orderedIDs.first)
                    topRowCount = cards.count
                }
                let overflowing = document.bounds.height > scroll.contentView.bounds.height + 0.5
                XCTAssertEqual(cards.count < expectedCount, overflowing)
                if !overflowing { XCTAssertEqual(cards.count, expectedCount) }
                let top = try XCTUnwrap(sections["top"]), footerHeight = try XCTUnwrap(sections["bottom"])
                let maximumOffset = max(0, document.bounds.height - scroll.contentView.bounds.height)
                XCTAssertEqual(state.scrollOffset, bottom ? maximumOffset : 0, accuracy: 0.5,
                               "The mounted production observer must follow native top → bottom → top scrolling")
                let layout = SessionPanelLayout(rowCount: expectedCount, topHeight: top, bottomHeight: footerHeight)
                let position = state.overflowPosition(ids: state.orderedIDs, layout: layout)
                let offscreen = expectedCount - cards.count
                XCTAssertEqual(position.aboveCount, bottom ? offscreen : 0)
                XCTAssertEqual(position.belowCount, bottom ? 0 : offscreen)
                if overflowing {
                    XCTAssertEqual(position.pointsDown, !bottom)
                    XCTAssertEqual(position.count, offscreen)
                    XCTAssertEqual(position.label, L(bottom ? "Выше: {0}" : "Ещё ниже: {0}", String(offscreen)))
                    XCTAssertEqual(position.accessibilityLabel,
                                   L(bottom ? "Показать предыдущие сессии" : "Показать следующие сессии"))
                    XCTAssertNotNil(position.targetID)
                }
                XCTAssertNil(state.viewportRequest, "Observing native scrolling must never issue scrollTo")
                let footer = CGRect(x: 0, y: host.bounds.height - footerHeight, width: 360, height: footerHeight)
                XCTAssertGreaterThan(top, 100)
                // Rounded chrome measurements may differ by less than 2 pt.
                // The fixed allowance is 8 pt padding and a 24 pt overflow cue.
                XCTAssertEqual(height - top - footerHeight - viewport.height,
                               overflowing ? 32 : 8, accuracy: 2)
                XCTAssertEqual(viewport.minY - top, 4, accuracy: 1)
                XCTAssertEqual(footer.minY - viewport.maxY, overflowing ? 28 : 4, accuracy: 1)
                XCTAssertTrue(cards.allSatisfy { $0.frame.intersection(footer).isNull }, "Footer cannot cover a session")
                XCTAssertLessThanOrEqual(height, 480)
            }
        }

        for count in [1, 2, 5, 12, 2] {
            let now = Date()
            let rows = (0..<count).map {
                AgentSession(provider: .codex, sessionID: "space-\($0)", title: "Сессия \($0 + 1)", cwd: "/tmp/Preview",
                             client: .desktop, phase: .running, updatedAt: now, observedAt: now)
            }
            store.acceptSessions(rows)
            try checkScrollLimits(expectedCount: count)
            if count == 5 || count == 12 {
                let compactFooter = try XCTUnwrap(sections["bottom"])
                try store.hide(rows[0])
                try checkScrollLimits(expectedCount: count - 1)
                XCTAssertGreaterThan(try XCTUnwrap(sections["bottom"]), compactFooter, "Undo must enlarge the actual footer")
                try store.restore(rows[0].id)
                try checkScrollLimits(expectedCount: count)
                XCTAssertEqual(try XCTUnwrap(sections["bottom"]), compactFooter, accuracy: 0.5)
            }
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
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let preview = try LegacyRenderFixture()
        defer { preview.stop() }
        let store = preview.environment.sessions
        let t = LegacyRenderIsolation.now
        let rows = (0..<8).map {
            AgentSession(
                provider: $0 % 2 == 0 ? .claude : .codex, sessionID: "fixture-\($0)",
                title: [
                    "Название проекта на русском", "Überarbeitung der Sitzungsübersicht", "修复会话列表",
                    "Vérifier les notifications",
                ][$0 % 4], cwd: "/tmp/Test", client: .desktop, phase: .ready, updatedAt: t, observedAt: t)
        }
        store.acceptSessions(rows)
        for row in rows { try store.hide(row) }
        let hidden = HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {})
            .frame(width: 360, height: 480)
        try render(hidden, to: output + "-hidden.png")
        try store.restore(rows[0].id)
        try render(SessionsView(store: store, updates: preview.environment.updates, awake: preview.environment.awake, isPreview: true, onSettings: {}).frame(width: 360), to: output + "-compact.png")
        try store.restore(rows[1].id)
        try render(
            SessionsView(
                store: store, updates: preview.environment.updates, awake: preview.environment.awake, isPreview: true,
                onSettings: {}, query: "а"
            ).frame(width: 360), to: output + "-filtered.png")
        store.acceptSessions([rows[1]])
        try render(
            SessionsView(
                store: store, updates: preview.environment.updates, awake: preview.environment.awake, isPreview: true,
                onSettings: {}, provider: "claude"), to: output + "-empty-claude.png")
        store.acceptSessions([rows[0]])
        try render(
            SessionsView(
                store: store, updates: preview.environment.updates, awake: preview.environment.awake, isPreview: true,
                onSettings: {}, provider: "codex"), to: output + "-empty-codex.png")
        store.acceptSessions([])
        try render(SessionsView(store: store, updates: preview.environment.updates, awake: preview.environment.awake, isPreview: true, onSettings: {}), to: output + "-empty-all.png")
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
