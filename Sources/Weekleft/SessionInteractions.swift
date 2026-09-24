import AppKit
import OSLog
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SessionKeyboardFocus {
    static let search = "search-field"

    static func recover(_ current: String?, visibleIDs: [String]) -> String? {
        guard let current, current != search, !visibleIDs.contains(current) else { return current }
        return search
    }
}

enum HiddenSessionKeyboardFocus: Equatable, Hashable {
    case back, search, restore(String), remove(String), restoreMany

    static func recover(_ current: Self?, visibleIDs: [String], showsSearch: Bool, showsRestoreMany: Bool) -> Self? {
        let fallback: Self = showsSearch ? .search : .back
        switch current {
        case .restore(let id), .remove(let id): return visibleIDs.contains(id) ? current : fallback
        case .restoreMany: return !showsRestoreMany || visibleIDs.isEmpty ? fallback : current
        case .search: return showsSearch ? current : .back
        default: return current
        }
    }
}

@MainActor final class SessionMenuAnchor: ObservableObject {
    weak var view: NSView?
    struct Item {
        var title: String
        var enabled = true
        var keyEquivalent = ""
        var keyModifiers: NSEvent.ModifierFlags = []
        var action: (() -> Void)?
        static var separator: Item { Item(title: "", action: nil) }
    }
    private final class Action: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func invoke() { body() }
    }
    func show(_ items: [Item]) {
        guard let view, view.window != nil else { return }
        let menu = makeMenu(items)
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.minY), in: view)
    }
    func makeMenu(_ items: [Item]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for item in items {
            guard let body = item.action else { menu.addItem(.separator()); continue }
            let action = Action(body)
            let entry = NSMenuItem(title: item.title, action: #selector(Action.invoke), keyEquivalent: item.keyEquivalent)
            entry.keyEquivalentModifierMask = item.keyModifiers
            // NSMenuItem does not retain target. Keep the closure alive for the
            // menu's lifetime, including activation by a keyboard equivalent.
            entry.representedObject = action
            entry.target = action; entry.isEnabled = item.enabled; menu.addItem(entry)
        }
        return menu
    }
}
struct SessionActionsMenu: View {
    let items: [SessionMenuAnchor.Item]
    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            if let action = items[index].action {
                Button(items[index].title, action: action).disabled(!items[index].enabled)
            } else { Divider() }
        }
    }
}

struct SessionMenuAnchorView: NSViewRepresentable {
    let anchor: SessionMenuAnchor
    // This view only positions the menu. Pointer events belong to the button,
    // including the empty padding around its small ellipsis glyph.
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { let view = Marker(); anchor.view = view; return view }
    func updateNSView(_ view: Marker, context: Context) { anchor.view = view }
}

@MainActor final class SessionReorderState: ObservableObject {
    /// Both the row menu and keyboard use the current filtered order. Pinning
    /// remains a separate action; moving a row cannot cross that boundary.
    static func adjacentTarget(for id: String, movingDown: Bool, rows: [AgentSession], pinned: Set<String>) -> String? {
        let group = rows.filter { pinned.contains($0.id) == pinned.contains(id) }
        guard let index = group.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + (movingDown ? 1 : -1)
        return group.indices.contains(next) ? group[next].id : nil
    }

    @discardableResult static func move(_ id: String, movingDown: Bool, rows: [AgentSession], store: SessionStore) throws -> Bool {
        guard let target = adjacentTarget(for: id, movingDown: movingDown, rows: rows, pinned: store.arrangement.pinned) else { return false }
        try store.move(id, before: target, after: movingDown, visible: rows.map(\.id))
        return true
    }

    @Published var rows: [AgentSession]?
    @Published var target: String?
    @Published var insertAfter = false
    @Published var position = CGPoint.zero
    var image: NSImage?
    var id: String?
    var pinned: Set<String> = []
    private var sourceFrame = CGRect.zero
    private var sourceWindowFrame = CGRect.zero
    private var grabPoint = CGPoint.zero
    func begin(_ id: String, rows: [AgentSession], pinned: Set<String> = []) {
        self.id = id; self.rows = rows; self.pinned = pinned
    }
    func lift(_ image: NSImage, frame: CGRect, windowFrame: CGRect, grab: CGPoint) {
        self.image = image; sourceFrame = frame; sourceWindowFrame = windowFrame; grabPoint = grab
        position = CGPoint(x: frame.midX, y: frame.midY)
    }
    func update(windowPoint: CGPoint, regions: [String: CGRect], viewport: CGRect) {
        guard let id else { return }
        position = CGPoint(x: sourceFrame.midX + windowPoint.x - grabPoint.x,
                           y: sourceFrame.midY - windowPoint.y + grabPoint.y)
        let point = CGPoint(x: sourceFrame.minX + windowPoint.x - sourceWindowFrame.minX,
                            y: sourceFrame.maxY - windowPoint.y + sourceWindowFrame.minY)
        guard viewport.contains(point) else { target = nil; return }
        let eligible = regions.filter { $0.key != id && pinned.contains($0.key) == pinned.contains(id) }
        // Small inter-row gaps still select the nearest insertion edge.
        guard let closest = eligible.min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }) else { target = nil; return }
        target = closest.key; insertAfter = point.y > closest.value.midY
    }
    func end() { id = nil; rows = nil; target = nil; image = nil }
}

/// SwiftUI may flatten several rows into one NSHostingView. Capture the row's
/// measured rectangle in that view, not an ancestor guessed from its dimensions.
@MainActor final class SessionRowDragAnchor: ObservableObject {
    weak var view: NSView?

    func snapshot(relativeTo handle: NSView) -> (image: NSImage, frame: CGRect)? {
        guard let view, let content = view.window?.contentView,
              view.window === handle.window, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let rect = content.convert(view.bounds, from: view)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return (image, handle.convert(view.bounds, from: view))
    }
}

struct SessionRowDragAnchorView: NSViewRepresentable {
    let anchor: SessionRowDragAnchor
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { let view = Marker(); anchor.view = view; return view }
    func updateNSView(_ view: Marker, context: Context) { anchor.view = view }
}

/// Track a local reorder directly, without starting an inter-application drag
/// session (which can dismiss a menu-bar popover before a drop is delivered).
struct SessionRowInteraction: NSViewRepresentable {
    let session: AgentSession
    let anchor: SessionRowDragAnchor
    var toolTip: String? = nil
    var onClick: () -> Void
    var onMenu: () -> Void
    var onStart: (NSImage, CGRect, CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onEnd: (CGPoint?) -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.session = session; view.anchor = anchor; view.onClick = onClick; view.onMenu = onMenu; view.onStart = onStart; view.onMove = onMove; view.onEnd = onEnd
        view.setAccessibilityLabel(L("Перетащите, чтобы изменить порядок"))
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
    final class Handle: NSView {
        var session: AgentSession?
        var anchor: SessionRowDragAnchor?
        var onStart: (NSImage, CGRect, CGPoint) -> Void = { _, _, _ in }
        var onMove: (CGPoint) -> Void = { _ in }
        var onEnd: (CGPoint?) -> Void = { _ in }
        var onClick: () -> Void = {}
        var onMenu: () -> Void = {}
        private var moved = false
        private var lifting = false
        private var escapeMonitor: Any?
        private var down: NSEvent?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onMenu(); return }
            down = event; moved = false
        }
        override func rightMouseDown(with event: NSEvent) { onMenu() }
        override func mouseUp(with event: NSEvent) {
            let shouldOpen = down != nil && !moved && !lifting && event.clickCount == 1
                && bounds.contains(convert(event.locationInWindow, from: nil))
            finish(at: event.locationInWindow)
            if shouldOpen { onClick() }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = down else { return }
            if !lifting {
                guard hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y) > 4 else { return }
                // Once this is a drag it can never become a click, even if the
                // snapshot fails or the pointer returns to its starting point.
                moved = true
                guard let snapshot = anchor?.snapshot(relativeTo: self) else { return }
                lifting = true
                onStart(snapshot.image, convert(snapshot.frame, to: nil), start.locationInWindow)
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53, self?.lifting == true else { return event }
                    self?.finish(at: nil); return nil
                }
            }
            enclosingScrollView?.autoscroll(with: event)
            onMove(event.locationInWindow)
        }
        private func finish(at point: CGPoint?) {
            down = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
            guard lifting else { return }
            lifting = false; onEnd(point)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finish(at: nil) }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
