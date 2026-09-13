import XCTest
import AppKit
import SwiftUI
import WeekleftCore
@testable import Weekleft

final class SessionsUXTests: XCTestCase {
    func testFocusRecoversOnlyWhenItsControlDisappears() {
        XCTAssertEqual(SessionKeyboardFocus.recover("codex:a", visibleIDs: ["codex:b"]), SessionKeyboardFocus.search)
        XCTAssertEqual(SessionKeyboardFocus.recover("codex:a", visibleIDs: []), SessionKeyboardFocus.search)
        XCTAssertEqual(SessionKeyboardFocus.recover(SessionKeyboardFocus.search, visibleIDs: []), SessionKeyboardFocus.search)
        XCTAssertEqual(SessionKeyboardFocus.recover("codex:a", visibleIDs: ["codex:a"]), "codex:a")
        XCTAssertNil(SessionKeyboardFocus.recover(nil, visibleIDs: ["codex:a"]), "A background update must not take focus from another control")
        XCTAssertEqual(HiddenSessionKeyboardFocus.recover(.restore("a"), visibleIDs: ["b"], showsSearch: true, showsRestoreMany: true), .search)
        XCTAssertEqual(HiddenSessionKeyboardFocus.recover(.remove("a"), visibleIDs: [], showsSearch: false, showsRestoreMany: false), .back)
        XCTAssertEqual(HiddenSessionKeyboardFocus.recover(.search, visibleIDs: ["a"], showsSearch: false, showsRestoreMany: false), .back)
        XCTAssertEqual(HiddenSessionKeyboardFocus.recover(.restoreMany, visibleIDs: [], showsSearch: true, showsRestoreMany: true), .search)
        XCTAssertEqual(HiddenSessionKeyboardFocus.recover(.restore("a"), visibleIDs: ["a"], showsSearch: true, showsRestoreMany: true), .restore("a"))
        XCTAssertNil(HiddenSessionKeyboardFocus.recover(nil, visibleIDs: [], showsSearch: true, showsRestoreMany: true))
    }

    @MainActor func testBulkFocusRecoversWhenNewTaskLeavesOnlyOneHiddenSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var visibility = try SessionVisibility(url: directory.appendingPathComponent("visibility.json"))
        let now = Date()
        var restarted = row("restarted", now: now)
        let remaining = row("remaining", now: now)
        try visibility.hide(restarted, now: now)
        try visibility.hide(remaining, now: now)
        func panel(query: String = "") -> HiddenSessionsView {
            HiddenSessionsView(sessions: visibility.summaries, onBack: {}, onRestore: { _ in }, onRemove: { _ in },
                               onRemoveAll: {}, query: query)
        }
        XCTAssertTrue(panel().showsRestoreMany)
        XCTAssertEqual(panel().recoveredFocus(.restoreMany), .restoreMany)

        restarted.phase = .running
        restarted.evidence = .hook
        restarted.turnStartedAt = now.addingTimeInterval(1)
        restarted.observedAt = now.addingTimeInterval(1)
        restarted.updatedAt = now.addingTimeInterval(1)
        XCTAssertEqual(try visibility.restoreNewTasks([restarted], now: restarted.observedAt), [restarted.id])
        XCTAssertEqual(panel().visibleSessions.map(\.id), [remaining.id])
        XCTAssertFalse(panel().showsRestoreMany)
        XCTAssertEqual(panel().recoveredFocus(.restoreMany), .back, "Do not keep focus on the removed bulk button")

        XCTAssertTrue(panel(query: "remaining").showsRestoreMany)
        XCTAssertEqual(panel(query: "remaining").recoveredFocus(.restoreMany), .restoreMany, "A filtered single result still has a bulk action")
        XCTAssertEqual(panel(query: "no match").recoveredFocus(.restoreMany), .search, "A disabled empty-result action cannot keep focus")
        XCTAssertNil(panel().recoveredFocus(nil), "A background restore must not steal unrelated focus")
    }

    @MainActor func testAccessibilityReorderOffersOnlyExecutableDirectionsAndUsesSameNativeCallback() throws {
        _ = NSApplication.shared
        try withStore { store, _, _ in
            let rows = [row("first"), row("last")]
            store.acceptSessions(rows)
            var card = SessionRow(session: rows[0], now: Date(), phase: .ready, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in },
                                  onMove: { down in
                                      do { try SessionReorderState.move(rows[0].id, movingDown: down, rows: rows, store: store) }
                                      catch { XCTFail("Accessible move failed: \(error)") }
                                  }, canMoveUp: false, canMoveDown: true)
            XCTAssertEqual(card.accessibilityReorderItems.map(\.title), [L("Переместить ниже")])
            let nativeActions = SessionMenuAnchor().makeMenu(card.accessibilityReorderItems)
            nativeActions.performActionForItem(at: 0)
            XCTAssertEqual(store.arrangement.arranged(rows).map(\.id), rows.reversed().map(\.id))
            card.isDragging = true
            XCTAssertTrue(card.accessibilityReorderItems.isEmpty)
            card.isDragging = false; card.canMoveDown = false
            XCTAssertTrue(card.accessibilityReorderItems.isEmpty)
        }
    }

    @MainActor func testMissingTitlesHaveDistinctRestoreAndRemovalLabels() throws {
        try withStore { store, directory, _ in
            var session = row("untitled", provider: .claude)
            session.title = " \n "
            store.acceptSessions([session]); try store.hide(session)
            let summary = try XCTUnwrap(store.hiddenSessions.first)
            XCTAssertEqual(HiddenSessionsView.displayTitle(for: summary), L("Сессия Claude"))
            let search = HiddenSessionsView(sessions: [summary], onBack: {}, onRestore: { _ in }, onRemove: { _ in },
                onRemoveAll: {}, query: L("Сессия Claude"))
            XCTAssertEqual(search.visibleSessions.map(\.id), [session.id])
            XCTAssertEqual(summary.title, " \n ", "Searching a display placeholder must not rewrite the saved title")
            XCTAssertTrue(HiddenSessionsView.restoreLabel(for: summary).contains(session.id))
            XCTAssertTrue(HiddenSessionsView.removalLabel(for: summary).contains(session.id))
            XCTAssertNotEqual(HiddenSessionsView.restoreLabel(for: summary), HiddenSessionsView.removalLabel(for: summary))
            let rowView = SessionRow(session: session, now: Date(), phase: .unknown, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in })
            XCTAssertEqual(rowView.displayTitle, session.project)
            XCTAssertTrue(rowView.accessibilityName.contains(session.id))

            let legacyFile = directory.appendingPathComponent("legacy-hidden.json")
            let legacy = ["sessions": ["claude:unknown-other": ["hiddenAt": Date().timeIntervalSinceReferenceDate]]]
            try JSONSerialization.data(withJSONObject: legacy).write(to: legacyFile)
            let legacySummary = try XCTUnwrap(try SessionVisibility(url: legacyFile).summaries.first)
            XCTAssertEqual(HiddenSessionsView.displayTitle(for: legacySummary), L("Сессия Claude"))
            XCTAssertNotEqual(HiddenSessionsView.removalLabel(for: summary), HiddenSessionsView.removalLabel(for: legacySummary))
        }
    }

    @MainActor func testReducedMotionSwipeClearsInheritedAnimationInNativeTransaction() throws {
        _ = NSApplication.shared
        let presentation = SessionSwipePresentation()
        var transactions: [Transaction] = []
        let host = NSHostingView(rootView: SessionSwipeTransactionProbe(presentation: presentation) { transactions.append($0) })
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        @MainActor func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        presentation.update(id: "row", offset: 80, reduceMotion: false)
        settle(); transactions.removeAll()
        withAnimation(.linear(duration: 1)) { presentation.update(id: "row", offset: 0, reduceMotion: true) }
        settle()
        XCTAssertEqual(presentation.offset, 0)
        let transaction = try XCTUnwrap(transactions.last, "The hosted view must observe the state change")
        XCTAssertNil(transaction.animation)
        XCTAssertTrue(transaction.disablesAnimations, "Reduce Motion must suppress an inherited parent animation, too")
    }
    @MainActor private func withStore(_ body: (SessionStore, URL, UserDefaults) throws -> Void) throws {
        let suite = "Lunavect.SessionsUX." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(SessionStore(directory: directory, defaults: defaults), directory, defaults)
    }

    private func row(_ id: String, provider: ProviderID = .codex, phase: SessionPhase = .ready, now: Date = Date()) -> AgentSession {
        AgentSession(provider: provider, sessionID: id, title: "Überprüfung \(id)", cwd: "/Projects/Atlas", client: .desktop,
                     phase: phase, updatedAt: now, observedAt: now, runtimeConfirmed: true)
    }

    @MainActor func testWaitingFilterPreservesSourceRowsAndUsesFreshEffectivePhase() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        try withStore { store, _, _ in
            let now = Date()
            let running = row("running", phase: .running, now: now)
            let waiting = row("permission", phase: .permission, now: now)
            let input = row("input", provider: .claude, phase: .input, now: now)
            var stale = row("stale", phase: .permission, now: now.addingTimeInterval(-7200))
            stale.runtimeConfirmed = false
            let ready = row("ready", now: now)
            store.acceptSessions([running, waiting, input, stale, ready], now: now)
            let normal = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {})
            let filtered = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {}, attentionOnly: true)
            XCTAssertEqual(Set(filtered.filteredSessions(at: now).map(\.id)), [waiting.id, input.id])
            XCTAssertTrue(normal.filteredSessions(at: now).contains { $0.id == running.id })
            XCTAssertTrue(normal.filteredSessions(at: now).contains { $0.id == ready.id })
            XCTAssertEqual(store.sessions.filter { $0.effectivePhase(now: now) == .running }.count, 1)
            XCTAssertEqual(store.sessions.filter { [.permission, .input].contains($0.effectivePhase(now: now)) }.count, 2)
            let codexOnly = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {}, provider: "codex", attentionOnly: true)
            XCTAssertEqual(codexOnly.filteredSessions(at: now).map(\.id), [waiting.id])
        }
    }

    @MainActor func testMenuAndKeyboardMovePersistWithinFilteredPinGroup() throws {
        _ = NSApplication.shared
        try withStore { store, directory, defaults in
            let rows = [row("pinned-one"), row("pinned-two"), row("first"), row("filtered-out"), row("last")]
            store.acceptSessions(rows)
            try store.setPinned(rows[0].id, true)
            try store.setPinned(rows[1].id, true)
            try store.move(rows[0].id, before: rows[1].id, visible: rows.map(\.id))
            let visible = [rows[0], rows[2], rows[4]]
            XCTAssertNil(SessionReorderState.adjacentTarget(for: rows[0].id, movingDown: true, rows: visible, pinned: store.arrangement.pinned))
            XCTAssertNil(SessionReorderState.adjacentTarget(for: rows[2].id, movingDown: false, rows: visible, pinned: store.arrangement.pinned))
            let card = SessionRow(session: rows[2], now: Date(), phase: .ready, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in },
                                  onMove: { down in
                                      do { try SessionReorderState.move(rows[2].id, movingDown: down, rows: visible, store: store) }
                                      catch { XCTFail("Move failed: \(error)") }
                                  }, canMoveUp: false, canMoveDown: true)
            let menu = SessionMenuAnchor().makeMenu(card.menuItems)
            let above = try XCTUnwrap(menu.items.first { $0.title == L("Переместить выше") })
            let below = try XCTUnwrap(menu.items.first { $0.title == L("Переместить ниже") })
            XCTAssertFalse(above.isEnabled)
            XCTAssertTrue(below.isEnabled)
            XCTAssertEqual(above.keyEquivalent, String(UnicodeScalar(NSUpArrowFunctionKey)!))
            XCTAssertEqual(below.keyEquivalent, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            XCTAssertEqual(below.keyEquivalentModifierMask, .option)
            menu.performActionForItem(at: menu.index(of: below))
            XCTAssertEqual(store.arrangement.arranged(visible).map(\.id), [rows[0].id, rows[4].id, rows[2].id])
            XCTAssertTrue(store.arrangement.order.contains(rows[1].id))
            XCTAssertTrue(store.arrangement.order.contains(rows[3].id))
            let reloaded = SessionStore(directory: directory, defaults: defaults)
            XCTAssertEqual(reloaded.arrangement, store.arrangement)
            let current = store.arrangement.arranged(visible)
            XCTAssertTrue(try SessionReorderState.move(rows[2].id, movingDown: false, rows: current, store: store))
            XCTAssertEqual(store.arrangement.arranged(visible).map(\.id), visible.map(\.id))
            let before = store.arrangement
            XCTAssertFalse(try SessionReorderState.move(rows[0].id, movingDown: true, rows: visible, store: store))
            XCTAssertEqual(store.arrangement, before)
        }
    }

    @MainActor func testHiddenSearchMatchesTitleProjectProviderAndSessionID() throws {
        try withStore { store, _, _ in
            var rows = [row("alpha"), row("beta", provider: .claude), row("gamma")]
            rows[2].cwd = "/Projects/Beacon"
            store.acceptSessions(rows)
            for row in rows { try store.hide(row) }
            @MainActor func results(_ query: String) -> [String] {
                HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}, query: query)
                    .visibleSessions.map(\.id).sorted()
            }
            XCTAssertEqual(results("  uberprufung  ATLAS codex  "), [rows[0].id])
            XCTAssertEqual(results("beacon"), [rows[2].id])
            XCTAssertEqual(results("claude:beta"), [rows[1].id])
            XCTAssertTrue(results("missing").isEmpty)
            XCTAssertEqual(results(" \n ").count, 3)
            let compact = HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {})
            XCTAssertFalse(compact.showsSearch)
        }
    }

    @MainActor func testBulkRestoreOnlyMatchingHiddenRowsAndUndoRestoresTheGroup() throws {
        let uiDependencies = try AppEnvironment.preview(rows: [])
        defer { uiDependencies.stop() }
        try withStore { store, _, _ in
            let rows = (0..<8).map { row("hidden-\($0)", provider: $0.isMultiple(of: 2) ? .codex : .claude) }
            store.acceptSessions(rows)
            for row in rows { try store.hide(row) }
            let panel = SessionsView(store: store, updates: uiDependencies.updates, awake: uiDependencies.awake, onSettings: {})
            let archive = HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { id in
                do { try store.restore(id) }
                catch { XCTFail("Restore failed: \(error)") }
            }, onRemove: { _ in XCTFail("Restore must not delete records") }, onRemoveAll: { XCTFail("Restore must not delete records") },
                                             onRestoreMany: panel.restoreHidden, query: "codex")
            XCTAssertTrue(archive.showsSearch)
            XCTAssertEqual(archive.visibleSessions.count, 4)
            archive.restoreVisible()
            XCTAssertEqual(Set(store.sessions.map(\.id)), Set(rows.filter { $0.provider == .codex }.map(\.id)))
            XCTAssertEqual(Set(store.hiddenIDs), Set(rows.filter { $0.provider == .claude }.map(\.id)))
            XCTAssertNil(store.lastHidden)
            store.undoManager.undo()
            XCTAssertEqual(Set(store.hiddenIDs), Set(rows.map(\.id)), "One Undo reverses the whole bulk action")
            store.undoManager.redo()
            XCTAssertEqual(store.hiddenCount, 4)
            let remaining = HiddenSessionsView(sessions: store.hiddenSessions, onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}, onRestoreMany: panel.restoreHidden)
            remaining.restoreVisible()
            XCTAssertEqual(store.hiddenCount, 0)
            XCTAssertEqual(Set(store.sessions.map(\.id)), Set(rows.map(\.id)))
            let emptySearch = HiddenSessionsView(sessions: [], onBack: {}, onRestore: { _ in }, onRemove: { _ in }, onRemoveAll: {}, query: "codex")
            XCTAssertTrue(emptySearch.showsSearch, "Search remains reachable when its last match disappears")
        }
    }
}

private struct SessionSwipeTransactionProbe: View {
    @ObservedObject var presentation: SessionSwipePresentation
    let onTransaction: (Transaction) -> Void
    var body: some View {
        Text(String(presentation.offset)).transaction { transaction in onTransaction(transaction) }
    }
}
