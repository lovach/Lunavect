import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class SessionDragSnapshotTests: XCTestCase {
    @MainActor func testDragSnapshotContainsOnlyTheWholeSelectedRowAtItsRealGrabPosition() throws {
        _ = NSApplication.shared
        let now = Date()
        let rows = [
            AgentSession(provider: .claude, sessionID: "drag-first", title: "Claude — первая карточка", cwd: "/test", client: .desktop, phase: .ready, updatedAt: now, observedAt: now),
            AgentSession(provider: .codex, sessionID: "drag-second", title: "Codex — вторая карточка", cwd: "/test", client: .terminal, phase: .input, updatedAt: now, observedAt: now)
        ]
        let content = VStack(spacing: 2) {
            ForEach(rows) { row in
                SessionRow(session: row, now: now, phase: row.phase, swipePresentation: SessionSwipePresentation(), onHide: {}, onError: { _ in }, onPin: {})
            }
        }.padding(8).frame(width: 360).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: CGSize(width: 360, height: 102))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let handles = descendants(host).compactMap { $0 as? SessionRowInteraction.Handle }
        XCTAssertEqual(handles.count, 2)
        var images: [Data] = []
        for handle in handles {
            let snapshot = try XCTUnwrap(handle.anchor?.snapshot(relativeTo: handle))
            XCTAssertEqual(snapshot.image.size.width, 344, accuracy: 0.5)
            XCTAssertEqual(snapshot.image.size.height, 42, accuracy: 0.5)
            // The whole row is captured, including the independent menu button.
            XCTAssertTrue(snapshot.frame.contains(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)))
            XCTAssertEqual(snapshot.frame.minX, 0, accuracy: 0.5)
            XCTAssertGreaterThan(handle.bounds.width, 300)
            for x in [5.0, 70.0, 250.0] {
                let point = try XCTUnwrap(host.superview).convert(CGPoint(x: x, y: 20), from: handle)
                XCTAssertTrue(host.hitTest(point) === handle, "Icon, title and free row space must all receive pointer events")
            }
            let menuPoint = try XCTUnwrap(host.superview).convert(CGPoint(x: snapshot.frame.maxX - 20, y: 20), from: handle)
            XCTAssertFalse(host.hitTest(menuPoint) === handle, "The menu button must not be covered by the row interaction")
            var clicks = 0, starts = 0, ends = 0, menus = 0
            handle.onClick = { clicks += 1 }; handle.onMenu = { menus += 1 }
            handle.onStart = { _, _, _ in starts += 1 }; handle.onEnd = { _ in ends += 1 }
            func event(_ type: NSEvent.EventType, x: CGFloat = 70, y: CGFloat = 20, count: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: handle.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: flags,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            }
            handle.mouseDown(with: try event(.leftMouseDown)); handle.mouseUp(with: try event(.leftMouseUp))
            XCTAssertEqual(clicks, 1)
            handle.mouseDown(with: try event(.leftMouseDown, count: 2)); handle.mouseUp(with: try event(.leftMouseUp, count: 2))
            XCTAssertEqual(clicks, 1, "Double click must not open twice")
            handle.mouseDown(with: try event(.leftMouseDown)); handle.mouseDragged(with: try event(.leftMouseDragged, y: 34))
            handle.mouseUp(with: try event(.leftMouseUp))
            XCTAssertEqual(starts, 1); XCTAssertEqual(ends, 1)
            XCTAssertEqual(clicks, 1, "Returning to the starting point after dragging must not open")
            handle.mouseDown(with: try event(.leftMouseDown, flags: .control)); handle.mouseUp(with: try event(.leftMouseUp))
            handle.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(menus, 2); XCTAssertEqual(clicks, 1)
            handle.mouseDown(with: try event(.leftMouseDown)); handle.mouseUp(with: try event(.leftMouseUp, x: -10))
            XCTAssertEqual(clicks, 1, "Release outside the row must not open")
            // A failed snapshot must not convert a drag into navigation.
            let anchor = handle.anchor; handle.anchor = nil
            handle.mouseDown(with: try event(.leftMouseDown)); handle.mouseDragged(with: try event(.leftMouseDragged, y: 34))
            handle.mouseUp(with: try event(.leftMouseUp)); handle.anchor = anchor
            XCTAssertEqual(clicks, 1)
            let bitmap = try XCTUnwrap(snapshot.image.representations.first as? NSBitmapImageRep)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 344)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            images.append(data)
            if let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_DRAG"] {
                try data.write(to: URL(fileURLWithPath: output + "-" + (handle.session?.sessionID ?? "row") + ".png"))
            }
        }
        XCTAssertNotEqual(images.first, images.last, "Each handle must capture its own row, not a shared ancestor or the entire panel")
        window.contentView = nil
    }
    @MainActor func testPointerSelectsInsertionEdgeAndLeavingListCancelsTarget() {
        let state = SessionReorderState()
        let first = CGRect(x: 8, y: 140, width: 344, height: 42)
        let second = CGRect(x: 8, y: 184, width: 344, height: 42)
        let third = CGRect(x: 8, y: 228, width: 344, height: 42)
        let regions = ["one": first, "two": second, "three": third]
        let viewport = CGRect(x: 0, y: 138, width: 360, height: 150)
        state.begin("three", rows: [])
        // Window coordinates increase upwards; SwiftUI panel coordinates downwards.
        state.lift(NSImage(size: third.size), frame: third, windowFrame: CGRect(x: 8, y: 80, width: 344, height: 42), grab: CGPoint(x: 311, y: 101))
        state.update(windowPoint: CGPoint(x: 311, y: 198), regions: regions, viewport: viewport)
        XCTAssertEqual(state.target, "one")
        XCTAssertFalse(state.insertAfter)
        XCTAssertEqual(state.position.y, 152, accuracy: 0.1)
        state.update(windowPoint: CGPoint(x: 311, y: 135), regions: regions, viewport: viewport)
        XCTAssertEqual(state.target, "two")
        XCTAssertTrue(state.insertAfter)
        state.update(windowPoint: CGPoint(x: -20, y: 135), regions: regions, viewport: viewport)
        XCTAssertNil(state.target)
        state.end()
        XCTAssertNil(state.image)
        XCTAssertNil(state.id)
        XCTAssertNil(state.rows)
    }

    @MainActor func testDragCannotCrossPinnedGroup() {
        let state = SessionReorderState()
        state.begin("one", rows: [], pinned: ["one"])
        state.lift(NSImage(size: CGSize(width: 344, height: 42)), frame: CGRect(x: 8, y: 140, width: 344, height: 42), windowFrame: CGRect(x: 8, y: 100, width: 344, height: 42), grab: CGPoint(x: 311, y: 121))
        state.update(windowPoint: CGPoint(x: 311, y: 77), regions: ["two": CGRect(x: 8, y: 184, width: 344, height: 42)], viewport: CGRect(x: 0, y: 138, width: 360, height: 150))
        XCTAssertNil(state.target)
    }

}
