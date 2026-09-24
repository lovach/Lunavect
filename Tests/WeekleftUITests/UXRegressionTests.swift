import XCTest
import AppKit
import SwiftUI
import WeekleftCore
import AwakeService
@testable import Weekleft

@MainActor private final class UXAwakeClient: AwakeClient {
    var isAvailable = false
    var failure: AwakeFailure?
    var began = 0
    func requestPermission() throws {}
    func begin(seconds: Int, policy: AwakeSafetyPolicy) async throws {
        began += 1
        if let failure { throw failure }
    }
    func configure(policy: AwakeSafetyPolicy) async throws {}
    func keepAlive() async throws {}
    func end() async throws {}
    func disconnect() {}
}

@MainActor private final class UXWindowCloseProbe: NSObject, NSWindowDelegate {
    var closeCount = 0
    func windowWillClose(_ notification: Notification) { closeCount += 1 }
}

final class UXRegressionTests: XCTestCase {
    @MainActor func testBackToSessionsClosesNativeWindowBeforePolicyAndDeferredPresentation() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let closeProbe = UXWindowCloseProbe(); window.delegate = closeProbe
        let transition = SettingsToSessionsTransition()
        var previewVisible = true, policyUpdated = false, presented = 0
        var queued: [SettingsToSessionsTransition.Action] = []
        transition.start(sessionStatusEnabled: true, closeSettings: {
            window.close()
            previewVisible = false
        }, updateActivationPolicy: {
            XCTAssertEqual(closeProbe.closeCount, 1, "Policy update follows the real NSWindow close notification")
            XCTAssertFalse(previewVisible)
            policyUpdated = true
        }, showSessions: {
            XCTAssertEqual(closeProbe.closeCount, 1)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(previewVisible)
            XCTAssertTrue(policyUpdated)
            presented += 1
        }, showFallback: { XCTFail("An enabled status item can present sessions") }, enqueue: { queued.append($0) })
        XCTAssertEqual(closeProbe.closeCount, 1)
        XCTAssertTrue(policyUpdated)
        XCTAssertEqual(presented, 0, "Do not create a transient popover in the close/activation-policy turn")
        XCTAssertEqual(queued.count, 1)
        let present = try XCTUnwrap(queued.first)
        present(); present()
        XCTAssertEqual(presented, 1, "A deferred return is consumed once")
    }

    @MainActor func testNewWindowIntentCancelsDeferredSettingsReturn() throws {
        let transition = SettingsToSessionsTransition()
        var queued: [SettingsToSessionsTransition.Action] = []
        var presentations = 0
        transition.start(sessionStatusEnabled: true, closeSettings: {}, updateActivationPolicy: {},
            showSessions: { presentations += 1 }, showFallback: { XCTFail() }, enqueue: { queued.append($0) })
        transition.cancel() // showSettings/showWelcome invalidate the old intent.
        try XCTUnwrap(queued.first)()
        XCTAssertEqual(presentations, 0)
        transition.start(sessionStatusEnabled: true, closeSettings: {}, updateActivationPolicy: {},
            showSessions: { presentations += 1 }, showFallback: { XCTFail() }, enqueue: { queued.append($0) })
        queued[0]()
        XCTAssertEqual(presentations, 0)
        queued[1]()
        XCTAssertEqual(presentations, 1, "A later deliberate return remains possible")
    }

    @MainActor func testDisabledSessionStatusKeepsSettingsAndUsesMenuBarFallback() {
        let transition = SettingsToSessionsTransition()
        var fallbackCount = 0
        transition.start(sessionStatusEnabled: false,
            closeSettings: { XCTFail("Keep Settings available when no session icon can anchor a popover") },
            updateActivationPolicy: { XCTFail("Do not remove Settings from the Dock") },
            showSessions: { XCTFail("The hidden status item cannot anchor sessions") },
            showFallback: { fallbackCount += 1 }, enqueue: { _ in XCTFail("No delayed popover without an anchor") })
        XCTAssertEqual(fallbackCount, 1)
    }

    @MainActor func testPanelViewportFitsCompleteRowsAtBothScrollLimitsWithoutBlankFooterRow() {
        XCTAssertEqual(SessionRow.height, 42)
        let compact = SessionPanelLayout(rowCount: 1, topHeight: 142, bottomHeight: 30)
        XCTAssertEqual(compact.viewportHeight, 42)
        XCTAssertEqual(compact.panelHeight, 222, "Chrome + one 42-point row + 8 points of outer inset; no empty 42-point spacer")
        XCTAssertFalse(compact.showsOverflow)
        let nine = SessionPanelLayout(rowCount: 9, topHeight: 142, bottomHeight: 30)
        XCTAssertEqual(nine.visibleRowCount, 6)
        XCTAssertEqual(nine.viewportHeight, 262)
        XCTAssertEqual(nine.panelHeight, 466)
        XCTAssertTrue(nine.showsOverflow)
        let wrapped = SessionPanelLayout(rowCount: 9, topHeight: 170, bottomHeight: 34)
        XCTAssertEqual(wrapped.visibleRowCount, 5)
        XCTAssertEqual(wrapped.viewportHeight, 218)
        XCTAssertEqual(wrapped.panelHeight, 454)

        // Independent row rectangles reproduce the two native scroll limits.
        // Translated filters, undo messages and errors change chrome height.
        for count in [1, 2, 5, 6, 7, 9, 25, 40] {
            for chrome in [(142.0, 30.0), (170.0, 34.0), (225.5, 70.5)] {
                let layout = SessionPanelLayout(rowCount: count, topHeight: chrome.0, bottomHeight: chrome.1)
                XCTAssertLessThanOrEqual(layout.panelHeight, 480)
                let totalHeight = CGFloat(count * 42 + (count - 1) * 2)
                let viewport = CGRect(x: 0, y: 0, width: 344, height: layout.viewportHeight)
                for offset in [CGFloat.zero, max(0, totalHeight - layout.viewportHeight)] {
                    let intersections = (0..<count).map { index in
                        CGRect(x: 0, y: CGFloat(index * 44) - offset, width: 344, height: 42).intersection(viewport)
                    }.filter { !$0.isNull && !$0.isEmpty }
                    XCTAssertEqual(intersections.count, layout.visibleRowCount)
                    XCTAssertTrue(intersections.allSatisfy { $0.height == 42 }, "No partial row at either scroll limit")
                    XCTAssertEqual(intersections.first?.minY, 0)
                    XCTAssertEqual(intersections.last?.maxY, layout.viewportHeight)
                }
            }
        }
        let empty = SessionPanelLayout(rowCount: 0, topHeight: 142, bottomHeight: 30)
        XCTAssertEqual(empty.viewportHeight, 180)
        XCTAssertEqual(empty.panelHeight, 360)
        XCTAssertFalse(empty.showsOverflow)
    }

    @MainActor func testScrollingDoesNotInvalidateTheEntireSessionPanel() {
        let panel = SessionPanelState(isVisible: true)
        var panelInvalidations = 0, overflowInvalidations = 0
        let parent = panel.objectWillChange.sink { panelInvalidations += 1 }
        let overflow = panel.scrollPosition.objectWillChange.sink { overflowInvalidations += 1 }
        defer { parent.cancel(); overflow.cancel() }
        for pixel in 1...240 { panel.observeScrollOffset(CGFloat(pixel)) }
        XCTAssertEqual(panelInvalidations, 0, "Scroll pixels must not rebuild/filter/sort the full session list")
        XCTAssertEqual(overflowInvalidations, 240, "The overflow control must still receive live positions")
        XCTAssertEqual(panel.scrollOffset, 240)
        panel.observeScrollOffset(.nan)
        panel.observeScrollOffset(240)
        XCTAssertEqual(overflowInvalidations, 240)
        panel.isVisible = false
        XCTAssertEqual(panel.scrollOffset, 0)
        panel.observeScrollOffset(100)
        XCTAssertEqual(panel.scrollOffset, 0)
    }

    @MainActor func testSwipeSurfaceReadsLatestGeometryWithoutAViewUpdate() {
        let geometry = SessionPanelGeometry()
        let surface = SessionSwipeView.SwipeSurface()
        surface.geometry = geometry
        geometry.viewport = CGRect(x: 0, y: 0, width: 344, height: 260)
        geometry.regions = ["first": CGRect(x: 0, y: 0, width: 344, height: 42)]
        XCTAssertEqual(SessionSwipe.target(at: CGPoint(x: 40, y: 20), regions: surface.regions, viewport: surface.viewport), "first")
        geometry.regions = ["later": CGRect(x: 0, y: 0, width: 344, height: 42)]
        XCTAssertEqual(SessionSwipe.target(at: CGPoint(x: 40, y: 20), regions: surface.regions, viewport: surface.viewport), "later")
        geometry.viewport = .zero
        XCTAssertNil(SessionSwipe.target(at: CGPoint(x: 40, y: 20), regions: surface.regions, viewport: surface.viewport))
    }

    @MainActor func testOverflowCountsOffscreenRowsAndPagesOnlyOnExplicitRequest() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var rows = (0..<9).map { index in
            AgentSession(provider: .codex, sessionID: "page-\(index)", title: "Task \(index)", cwd: "",
                         phase: .running, updatedAt: now, observedAt: now)
        }
        let ids = rows.map(\.id)
        let layout = SessionPanelLayout(rowCount: rows.count, topHeight: 142, bottomHeight: 30)
        let top = SessionOverflowPosition(ids: ids, layout: layout, offset: 0)
        XCTAssertEqual(top.aboveCount, 0)
        XCTAssertEqual(top.belowCount, 3)
        XCTAssertEqual(top.nextID, ids[6])
        XCTAssertNil(top.previousID)
        let bottom = SessionOverflowPosition(ids: ids, layout: layout, offset: 132)
        XCTAssertEqual(bottom.aboveCount, 3)
        XCTAssertEqual(bottom.belowCount, 0)
        XCTAssertEqual(bottom.previousID, ids[0])
        XCTAssertNil(bottom.nextID)
        let partial = SessionOverflowPosition(ids: ids, layout: layout, offset: 22)
        XCTAssertEqual(partial.aboveCount, 1)
        XCTAssertEqual(partial.belowCount, 3, "Count rows beyond the viewport even when LazyVStack has not created them")
        let panel = SessionPanelState(isVisible: true)
        panel.reconcileOrder(rows)
        XCTAssertNil(panel.viewportRequest, "Showing an overflow hint must not itself scroll")
        panel.scrollPage(to: try XCTUnwrap(top.nextID), visibleIDs: ids)
        let request = try XCTUnwrap(panel.viewportRequest)
        XCTAssertEqual(request.id, ids[6])
        XCTAssertTrue(request.alignToTop)
        rows[0].phase = .input
        var arrival = rows[0]; arrival.sessionID = "page-new"
        panel.reconcileOrder([arrival] + rows.reversed())
        XCTAssertEqual(panel.viewportRequest, request, "New rows and phases may update the count, never reissue scrolling")
        XCTAssertEqual(panel.orderedIDs, ids + [arrival.id])
        panel.scrollPage(to: try XCTUnwrap(bottom.previousID), visibleIDs: panel.orderedIDs)
        XCTAssertEqual(panel.viewportRequest?.id, ids[0])
        XCTAssertNotEqual(panel.viewportRequest, request)
        panel.focusChanged(from: ids[0], to: ids[1], visibleIDs: ids)
        XCTAssertFalse(try XCTUnwrap(panel.viewportRequest).alignToTop, "Keyboard focus keeps the existing nearest-edge behavior")
    }

    func testConnectionCardUsesResolvedClientForStatusActionAndFoundStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let missing = directory.appendingPathComponent("removed-client").path
        let automatic = ClientExecutableResolver(codexPath: "", discoverCodex: { executable.path })
        let valid = ClientExecutableResolver(codexPath: executable.path, discoverCodex: { missing })
        for resolver in [automatic, valid] {
            let card = ConnectionCardState(provider: .codex, resolver: resolver, configured: true, snapshot: nil)
            XCTAssertTrue(card.clientFound)
            XCTAssertFalse(card.needsSetup)
            XCTAssertEqual(card.statusTitle, "Ждём лимиты")
            XCTAssertEqual(card.actionTitle, "Проверить данные")
        }
        XCTAssertEqual(automatic.codexPath, "", "Discovery must not turn an automatic choice into a saved explicit path")
        let absent = ConnectionCardState(provider: .codex,
            resolver: ClientExecutableResolver(discoverCodex: { nil }), configured: true, snapshot: nil)
        XCTAssertFalse(absent.clientFound)
        XCTAssertTrue(absent.needsSetup)
        XCTAssertEqual(absent.statusTitle, "Нужно установить приложение")
        XCTAssertEqual(absent.actionTitle, "Завершить настройку")
        let invalid = ConnectionCardState(provider: .codex,
            resolver: ClientExecutableResolver(codexPath: missing, discoverCodex: { executable.path }),
            configured: true, snapshot: nil)
        XCTAssertFalse(invalid.clientFound, "An explicit unavailable path must not fall back to the discovered client")
        XCTAssertTrue(invalid.needsSetup)
        XCTAssertEqual(invalid.statusTitle, "Клиент по выбранному пути недоступен. Выберите исполняемый файл заново.")
        XCTAssertEqual(invalid.actionTitle, "Завершить настройку")
        let unconfigured = ConnectionCardState(provider: .codex, resolver: automatic, configured: false, snapshot: nil)
        XCTAssertTrue(unconfigured.clientFound)
        XCTAssertTrue(unconfigured.needsSetup, "Finding the client alone does not prove its hooks are configured")
        let claude = ConnectionCardState(provider: .claude,
            resolver: ClientExecutableResolver(discoverClaude: { executable.path }), configured: true, snapshot: nil)
        XCTAssertTrue(claude.clientFound, "Both providers must use the shared resolver")
        XCTAssertFalse(claude.needsSetup)
    }

    func testArrangementRecoveryExplainsSavedCopyAtTheAction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("arrangement.json")
        let corrupt = Data("{corrupt fixture".utf8)
        try corrupt.write(to: url)
        var arrangement = SessionArrangement(); arrangement.pinned.insert("codex:example")
        do { try arrangement.save(to: url); XCTFail("The user action must stop after recovering corrupt data") }
        catch {
            XCTAssertTrue(error is SessionArrangementRecoveryError)
            XCTAssertEqual(SessionActionFeedback.message(for: error), L("Повреждённый порядок сессий сохранён отдельно. Повторите закрепление или перемещение."))
        }
    }

    @MainActor func testViewportRequestsRequireNewRowFocusOrExplicitReorder() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let rows = (0..<6).map { index in
            AgentSession(provider: .codex, sessionID: "viewport-\(index)", title: "Task \(index)", cwd: "",
                         phase: .running, updatedAt: now, observedAt: now)
        }
        let panel = SessionPanelState(isVisible: true)
        panel.reconcileOrder(rows)
        panel.focusChanged(from: nil, to: rows[0].id, visibleIDs: panel.orderedIDs)
        let firstRequest = try XCTUnwrap(panel.viewportRequest)
        XCTAssertEqual(firstRequest.id, rows[0].id)

        // Wheel scrolling leaves keyboard focus on the first row. Background
        // arrivals, removals and reordered observations must not reissue it.
        var arrival = rows[5]; arrival.sessionID = "new-arrival"; arrival.phase = .input
        var changed = Array(rows.dropLast().reversed()) + [arrival]
        panel.reconcileOrder(changed)
        panel.focusChanged(from: rows[0].id,
            to: SessionKeyboardFocus.recover(rows[0].id, visibleIDs: panel.orderedIDs), visibleIDs: panel.orderedIDs)
        XCTAssertEqual(panel.viewportRequest, firstRequest)

        changed.removeAll { $0.id == rows[0].id }
        panel.reconcileOrder(changed)
        let recovery = SessionKeyboardFocus.recover(rows[0].id, visibleIDs: panel.orderedIDs)
        XCTAssertEqual(recovery, SessionKeyboardFocus.search)
        panel.focusChanged(from: rows[0].id, to: recovery, visibleIDs: panel.orderedIDs)
        panel.focusChanged(from: rows[0].id, to: nil, visibleIDs: panel.orderedIDs)
        panel.focusChanged(from: nil, to: recovery, visibleIDs: panel.orderedIDs)
        XCTAssertEqual(panel.viewportRequest, firstRequest, "Focus recovery after removal cannot scroll to an old row")

        panel.focusChanged(from: recovery, to: rows[2].id, visibleIDs: panel.orderedIDs)
        let keyboardRequest = try XCTUnwrap(panel.viewportRequest)
        XCTAssertEqual(keyboardRequest.id, rows[2].id)
        XCTAssertNotEqual(keyboardRequest, firstRequest)
        panel.reconcileOrder(changed.reversed(), userReordered: true)
        panel.scrollAfterReorder(focusedID: rows[2].id, visibleIDs: panel.orderedIDs)
        XCTAssertEqual(panel.viewportRequest?.id, rows[2].id)
        XCTAssertNotEqual(panel.viewportRequest, keyboardRequest, "An explicit move may reveal the same focused row again")
        panel.isVisible = false
        XCTAssertNil(panel.viewportRequest)
        panel.focusChanged(from: nil, to: rows[2].id, visibleIDs: changed.map(\.id))
        XCTAssertNil(panel.viewportRequest, "A hidden panel must not retain an obsolete scroll request")
    }

    @MainActor func testVisiblePanelPreservesSixHitTargetsWhenPhasesAndTimestampsChange() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let environment = try AppEnvironment.preview(rows: [], now: now)
        defer { environment.stop() }
        let rows = (0..<6).map { index in
            AgentSession(provider: .codex, sessionID: "stable-\(index)", title: "Task \(index)", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        }
        environment.sessions.sessions = rows
        let panel = SessionPanelState(isVisible: true)
        panel.reconcileOrder(rows)
        let selectedID = rows[3].id
        var changed = rows.reversed().map { $0 }
        for index in changed.indices {
            changed[index].phase = index.isMultiple(of: 2) ? .permission : .running
            changed[index].updatedAt = now.addingTimeInterval(Double(index * 10))
            changed[index].observedAt = now
            changed[index].tool = "read"
        }
        environment.sessions.sessions = changed
        panel.reconcileOrder(environment.sessions.arrangement.arranged(changed))
        let view = SessionsView(store: environment.sessions, panelState: panel,
            updates: environment.updates, awake: environment.awake, onSettings: {})
        XCTAssertEqual(view.filteredSessions(at: now).map(\.id), rows.map(\.id))
        XCTAssertEqual(view.filteredSessions(at: now)[3].id, selectedID)
        XCTAssertEqual(view.filteredSessions(at: now)[3].phase, changed.first { $0.id == selectedID }?.phase)
        XCTAssertEqual(SessionKeyboardFocus.recover(selectedID, visibleIDs: view.filteredSessions(at: now).map(\.id)), selectedID)

        var arrival = rows[0]; arrival.sessionID = "new-attention"; arrival.phase = .permission
        environment.sessions.sessions = [arrival] + changed
        panel.reconcileOrder(environment.sessions.arrangement.arranged(environment.sessions.sessions))
        XCTAssertEqual(view.filteredSessions(at: now).map(\.id), rows.map(\.id) + [arrival.id])
        let filtered = SessionsView(store: environment.sessions, panelState: panel,
            updates: environment.updates, awake: environment.awake, onSettings: {}, attentionOnly: true)
        XCTAssertEqual(filtered.filteredSessions(at: now).map(\.id), view.filteredSessions(at: now).filter { $0.phase == .permission }.map(\.id))

        // Deliberate movement is applied immediately and survives later polls.
        let manual = [changed[0]] + rows.filter { $0.id != changed[0].id } + [arrival]
        panel.reconcileOrder(manual, userReordered: true)
        panel.reconcileOrder(environment.sessions.sessions)
        XCTAssertEqual(panel.stableOrder(environment.sessions.sessions).map(\.id), manual.map(\.id))
        panel.isVisible = false
        XCTAssertTrue(panel.orderedIDs.isEmpty)
        panel.isVisible = true
        panel.reconcileOrder(changed)
        XCTAssertEqual(panel.stableOrder(rows).map(\.id), changed.map(\.id))
    }

    @MainActor func testPermissionReturnKeepsRequestOriginAndCancellationCannotReturn() async throws {
        for origin in [AwakePermissionOrigin.sessions, .settings] {
            let environment = try AppEnvironment.preview(rows: [])
            defer { environment.stop() }
            let client = UXAwakeClient()
            let subject = KeepAwake(client: client, defaults: environment.defaults)
            defer { subject.shutdown() }
            var returned: [AwakePermissionOrigin] = []
            subject.onPermissionFinished = { returned.append($0) }
            subject.requestPermission(from: origin)
            await subject.checkPermission()
            XCTAssertTrue(returned.isEmpty)
            client.isAvailable = true
            await subject.checkPermission(); await subject.checkPermission()
            XCTAssertEqual(returned, [origin])
            XCTAssertEqual(client.began, 1)
            await subject.stop()
            subject.requestPermission(from: origin)
            subject.cancelPermission()
            await subject.checkPermission()
            XCTAssertEqual(returned, [origin])
        }
    }

    @MainActor func testSafetyRefusalsOfferConditionsInsteadOfRepeatingConnection() async throws {
        let environment = try AppEnvironment.preview(rows: [])
        defer { environment.stop() }
        let client = UXAwakeClient(); client.isAvailable = true
        let subject = KeepAwake(client: client, defaults: environment.defaults)
        defer { subject.shutdown() }
        for failure in [AwakeFailure.battery, .thermal, .power] {
            client.failure = failure
            await subject.start()
            XCTAssertFalse(subject.isEnabled)
            XCTAssertNotNil(subject.issue)
            XCTAssertEqual(subject.recoveryAction, .reviewConditions)
        }
        client.failure = .unavailable
        await subject.start()
        XCTAssertEqual(subject.recoveryAction, .retryConnection)
        client.failure = nil
        await subject.start()
        XCTAssertTrue(subject.isEnabled)
        XCTAssertNil(subject.issue)
        XCTAssertEqual(subject.recoveryAction, .none)
    }

    @MainActor func testNotificationNavigationPublishesFailureAndMissingTaskOnPanel() async throws {
        struct Failure: LocalizedError { var errorDescription: String? { "A synthetic launch failed" } }
        let state = SessionPanelState()
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Example", cwd: "", phase: .ready, updatedAt: Date(), observedAt: Date())
        var invoked = 0
        let failed = await state.openSession(id: row.id, rows: [row]) { _ in invoked += 1; throw Failure() }
        XCTAssertFalse(failed)
        XCTAssertEqual(state.issue, "A synthetic launch failed")
        let missing = await state.openSession(id: "missing", rows: [row]) { _ in invoked += 1 }
        XCTAssertFalse(missing)
        XCTAssertEqual(invoked, 1)
        XCTAssertEqual(state.issue, L("Сессия больше не активна или скрыта. Проверьте скрытые сессии внизу панели."))
        let opened = await state.openSession(id: row.id, rows: [row]) { _ in invoked += 1 }
        XCTAssertTrue(opened)
        XCTAssertNil(state.issue)
        XCTAssertEqual(invoked, 2)
    }

    @MainActor func testRepeatedPanelOpenRequestsOpenOnceAndLetThePanelStepAside() async throws {
        let state = SessionPanelState(isVisible: true)
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Example", cwd: "", phase: .ready, updatedAt: Date(), observedAt: Date())
        let stepsAside = expectation(forNotification: .lunavectSessionOpened, object: nil)
        stepsAside.assertForOverFulfill = true
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        // Return key repeats, a swipe and a click arrive while the first open is still running.
        let first = Task { await state.open(row) { _ in calls += 1; await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        XCTAssertTrue(state.openingIDs.contains(row.id))
        for _ in 0..<3 {
            let repeated = await state.open(row) { _ in calls += 1 }
            XCTAssertFalse(repeated)
        }
        release?.resume()
        let opened = await first.value
        XCTAssertTrue(opened)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(state.openingIDs.isEmpty)
        await fulfillment(of: [stepsAside], timeout: 1)
    }

    @MainActor func testOpenFailureIsShownOnThePanelAndBringsAClosedPanelBack() async throws {
        struct Failure: LocalizedError { var errorDescription: String? { "A synthetic launch failed" } }
        let state = SessionPanelState(isVisible: true)
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Example", cwd: "", phase: .ready, updatedAt: Date(), observedAt: Date())
        var reopened = 0
        state.onHiddenIssue = { reopened += 1 }
        let visible = await state.open(row) { _ in throw Failure() }
        XCTAssertFalse(visible)
        XCTAssertEqual(state.issue, "A synthetic launch failed")
        XCTAssertEqual(reopened, 0, "An open panel shows the message in place")
        // The client took focus and the popover closed before the route failed.
        let hidden = await state.open(row) { _ in state.isVisible = false; throw Failure() }
        XCTAssertFalse(hidden)
        XCTAssertEqual(state.issue, "A synthetic launch failed")
        XCTAssertEqual(reopened, 1, "A late failure brings the panel back instead of a detached alert")
    }

    @MainActor func testClosingThePanelEndsItsMessageAndHiddenSessionsPage() async throws {
        let state = SessionPanelState(isVisible: true)
        state.issue = "A failed notification open"
        state.showsHiddenSessions = true
        state.isVisible = false
        state.isVisible = true
        XCTAssertNil(state.issue, "A message belongs to the presentation it was shown in")
        XCTAssertFalse(state.showsHiddenSessions, "The menu-bar item reopens current sessions")
        // A failure reported while closed is kept for the presentation it brings forward.
        state.isVisible = false
        let opened = await state.openSession(id: "missing", rows: []) { _ in }
        XCTAssertFalse(opened)
        state.isVisible = true
        XCTAssertEqual(state.issue, L("Сессия больше не активна или скрыта. Проверьте скрытые сессии внизу панели."))
        state.isVisible = false
        XCTAssertNil(state.issue)
    }

    @MainActor func testNotificationOpensAKnownRowWithoutWaitingForACatalogRefresh() async throws {
        let state = SessionPanelState()
        let row = AgentSession(provider: .codex, sessionID: "fixture", title: "Example", cwd: "", phase: .ready, updatedAt: Date(), observedAt: Date())
        var rows = [row], refreshes = 0, opened: [String] = []
        let known = await state.openSession(id: row.id, rows: rows, refresh: { refreshes += 1 }) { opened.append($0.id) }
        XCTAssertTrue(known)
        XCTAssertEqual(refreshes, 0, "The notice came from a row the panel already has")
        XCTAssertEqual(opened, [row.id])
        // A session not yet in the list is looked up again after one refresh.
        let late = AgentSession(provider: .claude, sessionID: "late", title: "Example", cwd: "", phase: .input, updatedAt: Date(), observedAt: Date())
        let found = await state.openSession(id: late.id, rows: rows, refresh: { refreshes += 1; rows.append(late) }) { opened.append($0.id) }
        XCTAssertTrue(found)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(opened, [row.id, late.id])
    }

    @MainActor func testWelcomeKeepsFourStepsWithAndWithoutRegisteredWidget() async throws {
        let environment = try AppEnvironment.preview(rows: [])
        defer { environment.stop() }
        for kinds in [[], ["WeekleftWidget"]] {
            let status = WidgetSetupStatus(fetch: { kinds })
            await status.check()
            for step in 0...3 {
                let view = WelcomeView(store: environment.store, sessions: environment.sessions, onFinish: {}, step: step, widgetSetup: status)
                XCTAssertEqual(view.visibleSteps, [0, 1, 2, 3])
                XCTAssertEqual(view.stepLabel, L("Шаг {0} из {1}", String(step + 1), "4"))
                XCTAssertEqual(status.nextStep(after: step), min(3, step + 1))
            }
        }
    }

    func testSidebarNavigationUsesVisibleGroupOrderAndStopsAtEdges() {
        XCTAssertEqual(SettingsSection.limits.adjacent(offset: 1), .statistics)
        XCTAssertEqual(SettingsSection.statistics.adjacent(offset: -1), .limits)
        XCTAssertEqual(SettingsSection.subscriptions.adjacent(offset: 1), .updates)
        XCTAssertEqual(SettingsSection.limits.adjacent(offset: -1), .limits)
        XCTAssertEqual(SettingsSection.updates.adjacent(offset: 1), .updates)
    }
}
