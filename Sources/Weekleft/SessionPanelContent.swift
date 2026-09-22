import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

enum SessionActionFeedback {
    static func message(for error: Error) -> String {
        if error is SessionArrangementRecoveryError {
            return L("Повреждённый порядок сессий сохранён отдельно. Повторите закрепление или перемещение.")
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct SessionViewportRequest: Equatable {
    let id: String
    let revision: Int
    var alignToTop = false
}

struct SessionPanelLayout {
    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let verticalInset: CGFloat = 4
    static let overflowHeight: CGFloat = 24
    static var rowStride: CGFloat { rowHeight + rowSpacing }

    let visibleRowCount: Int
    let viewportHeight: CGFloat
    let showsOverflow: Bool
    let panelHeight: CGFloat

    init(rowCount: Int, topHeight: CGFloat, bottomHeight: CGFloat, maximumHeight: CGFloat = 480) {
        let count = max(0, rowCount)
        let chrome = ceil(max(0, topHeight)) + ceil(max(0, bottomHeight))
        let available = max(0, maximumHeight - chrome - Self.verticalInset * 2)
        if count == 0 {
            visibleRowCount = 0
            viewportHeight = min(180, available)
            showsOverflow = false
        } else {
            showsOverflow = Self.height(for: count) > available
            let rowBudget = available - (showsOverflow ? Self.overflowHeight : 0)
            visibleRowCount = min(count, max(1, Int(floor(max(0, rowBudget + Self.rowSpacing) / Self.rowStride))))
            viewportHeight = Self.height(for: visibleRowCount)
        }
        panelHeight = chrome + Self.verticalInset * 2 + viewportHeight + (showsOverflow ? Self.overflowHeight : 0)
    }

    static func height(for count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * rowStride - rowSpacing : 0
    }
}

/// Counts come from the content offset, including rows not instantiated by the
/// lazy stack. No list observation creates a scroll request.
struct SessionOverflowPosition {
    let aboveCount: Int
    let belowCount: Int
    let previousID: String?
    let nextID: String?

    var pointsDown: Bool { belowCount > 0 }
    var targetID: String? { pointsDown ? nextID : previousID }
    var count: Int { pointsDown ? belowCount : aboveCount }
    var label: String { L(pointsDown ? "Ещё ниже: {0}" : "Выше: {0}", String(count)) }
    var accessibilityLabel: String { L(pointsDown ? "Показать следующие сессии" : "Показать предыдущие сессии") }

    init(ids: [String], layout: SessionPanelLayout, offset: CGFloat) {
        guard !ids.isEmpty, layout.visibleRowCount > 0 else {
            aboveCount = 0; belowCount = 0; previousID = nil; nextID = nil
            return
        }
        let maximumOffset = max(0, SessionPanelLayout.height(for: ids.count) - layout.viewportHeight)
        let offset = offset.isFinite ? min(maximumOffset, max(0, offset)) : 0
        let stride = SessionPanelLayout.rowStride
        let first = min(ids.count - 1, Int(floor(offset / stride + 0.001)))
        aboveCount = min(ids.count, max(0, Int(ceil(offset / stride - 0.001))))
        let last = Int(floor((offset + layout.viewportHeight - SessionPanelLayout.rowHeight) / stride + 0.001))
        belowCount = max(0, ids.count - last - 1)
        previousID = aboveCount > 0 ? ids[max(0, first - layout.visibleRowCount)] : nil
        nextID = belowCount > 0 ? ids[min(ids.count - 1, first + layout.visibleRowCount)] : nil
    }
}

/// Only the overflow control observes scroll pixels; the session list does not.
@MainActor final class SessionScrollPosition: ObservableObject {
    @Published var offset: CGFloat = 0
}

@MainActor final class SessionPanelState: ObservableObject {
    @Published var isVisible: Bool {
        didSet { if !isVisible { orderedIDs = []; viewportRequest = nil; scrollPosition.offset = 0 } }
    }
    @Published var issue: String?
    @Published private(set) var orderedIDs: [String] = []
    @Published private(set) var viewportRequest: SessionViewportRequest?
    let scrollPosition = SessionScrollPosition()
    var scrollOffset: CGFloat { scrollPosition.offset }
    init(isVisible: Bool = false) { self.isVisible = isVisible }

    func observeScrollOffset(_ offset: CGFloat) {
        guard isVisible, offset.isFinite, offset != scrollOffset else { return }
        scrollPosition.offset = offset
    }
    func overflowPosition(ids: [String], layout: SessionPanelLayout) -> SessionOverflowPosition {
        SessionOverflowPosition(ids: ids, layout: layout, offset: scrollOffset)
    }

    /// Observation updates may reconcile focus, but must not undo wheel scrolling.
    /// Only a new row focus, explicit reorder or paging requests viewport movement.
    func focusChanged(from previous: String?, to current: String?, visibleIDs: [String]) {
        guard previous != current else { return }
        requestScroll(to: current, visibleIDs: visibleIDs)
    }
    func scrollAfterReorder(focusedID: String?, visibleIDs: [String]) {
        requestScroll(to: focusedID, visibleIDs: visibleIDs)
    }
    func scrollPage(to id: String, visibleIDs: [String]) {
        requestScroll(to: id, visibleIDs: visibleIDs, alignToTop: true)
    }
    private func requestScroll(to id: String?, visibleIDs: [String], alignToTop: Bool = false) {
        guard isVisible, let id, visibleIDs.contains(id) else { return }
        viewportRequest = SessionViewportRequest(id: id, revision: (viewportRequest?.revision ?? 0) &+ 1, alignToTop: alignToTop)
    }

    /// Keep existing hit targets stationary while the user chooses a session.
    /// Explicit pin/move actions may replace the order; observations only append.
    func reconcileOrder(_ rows: [AgentSession], userReordered: Bool = false) {
        guard isVisible else { return }
        let incoming = rows.map(\.id), current = Set(incoming)
        let retained = userReordered ? [] : orderedIDs.filter { current.contains($0) }
        let known = Set(retained)
        let next = retained + incoming.filter { !known.contains($0) }
        if next != orderedIDs { orderedIDs = next }
    }
    func stableOrder(_ rows: [AgentSession]) -> [AgentSession] {
        guard isVisible, !orderedIDs.isEmpty else { return rows }
        let indices = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        return rows.enumerated().sorted {
            (indices[$0.element.id] ?? orderedIDs.count + $0.offset) <
                (indices[$1.element.id] ?? orderedIDs.count + $1.offset)
        }.map(\.element)
    }

    /// Notification navigation reports failures on the panel that is brought
    /// forward, including a task that disappeared since the notice was sent.
    func openSession(id: String, rows: [AgentSession], open: (AgentSession) async throws -> Void) async -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else {
            issue = L("Сессия больше не активна или скрыта. Проверьте скрытые сессии внизу панели.")
            return false
        }
        do {
            try await open(row)
            issue = nil
            return true
        } catch {
            issue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}

/// SwiftUI's lazy-stack geometry does not invalidate on every native scroll.
/// Read the actual clip bounds instead; this observer never requests scrolling.
struct SessionScrollOffsetReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.onChange = onChange
        view.connect()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private weak var document: NSView?
        private var generation = 0
        private var samplePending = false
        private var deliveredOffset: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func layout() { super.layout(); connect() }

        func connect() {
            guard window != nil, let scroll = enclosingScrollView, let nextDocument = scroll.documentView else {
                stop()
                return
            }
            if clip !== scroll.contentView || document !== nextDocument {
                stop()
                clip = scroll.contentView
                document = nextDocument
                scroll.contentView.postsBoundsChangedNotifications = true
                nextDocument.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                    name: NSView.frameDidChangeNotification, object: nextDocument)
            }
            scheduleSample()
        }
        func stop() {
            NotificationCenter.default.removeObserver(self)
            clip = nil
            document = nil
            generation &+= 1
            samplePending = false
            deliveredOffset = nil
        }
        @objc private func boundsChanged(_ notification: Notification) { scheduleSample() }
        private func scheduleSample() {
            guard !samplePending, clip != nil else { return }
            samplePending = true
            let expectedGeneration = generation
            // Avoid publishing during an AppKit/SwiftUI layout pass; coalesce
            // bounds and document-size changes into one current native sample.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.samplePending = false
                guard let clip = self.clip, let document = self.document else { return }
                let maximum = max(0, document.bounds.height - clip.bounds.height)
                let relative = clip.bounds.minY - document.bounds.minY
                let offset = min(maximum, max(0, document.isFlipped ? relative : maximum - relative))
                guard offset.isFinite, offset != self.deliveredOffset else { return }
                self.deliveredOffset = offset
                self.onChange?(offset)
            }
        }
    }
}

/// Remove the timeline and row hierarchy while hidden. SessionsView's filter
/// state remains outside this boundary and survives closing the popover.
struct SessionPanelContent<Content: View>: View {
    @ObservedObject var state: SessionPanelState
    @ViewBuilder var content: () -> Content
    var body: some View {
        if state.isVisible { content() }
    }
}
