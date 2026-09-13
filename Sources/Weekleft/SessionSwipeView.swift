import AppKit
import OSLog
import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct SessionSwipeView: NSViewRepresentable {
    var regions: [String: CGRect]
    var viewport: CGRect
    var enabled = true
    var onOffset: (String, Double) -> Void
    var onAction: (String, SessionSwipe.Action) -> Void
    func makeNSView(context: Context) -> SwipeSurface { SwipeSurface() }
    func updateNSView(_ view: SwipeSurface, context: Context) {
        view.enabled = enabled
        view.regions = regions; view.viewport = viewport; view.onOffset = onOffset; view.onAction = onAction
        view.diagnose()
    }
    static func dismantleNSView(_ view: SwipeSurface, coordinator: ()) { view.stop() }

    final class SwipeSurface: NSView {
        var enabled = true { didSet { if !enabled { trackedID = nil; gesture = SessionSwipe(); consumeMomentum = false } } }
        var regions: [String: CGRect] = [:]
        var viewport = CGRect.zero
        var onOffset: (String, Double) -> Void = { _, _ in }
        var onAction: (String, SessionSwipe.Action) -> Void = { _, _ in }
        private var diagnosticSnapshot = ""
        func diagnose() {
            #if DEBUG
            guard CommandLine.arguments.contains("--swipe-diagnostics") else { return }
                let snapshot =
                    "frame=\(frame) bounds=\(bounds) visible=\(visibleRect) viewport=\(viewport) regions=\(regions.values.sorted { $0.minY < $1.minY }) window=\(window != nil) hidden=\(isHiddenOrHasHiddenAncestor)"
                if snapshot != diagnosticSnapshot {
                diagnosticSnapshot = snapshot
                Logger(subsystem: "com.weekleft.app", category: "swipe-diagnostic").notice("\(snapshot, privacy: .public)")
            }
            #endif
        }
        override func layout() { super.layout(); diagnose() }
        private var monitor: Any?
        private var gesture = SessionSwipe()
        private var trackedID: String?
        override var isFlipped: Bool { true }
        private var consumeMomentum = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            trackedID = nil; gesture = SessionSwipe()
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard enabled, let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
            if !event.momentumPhase.isEmpty { return consumeMomentum ? nil : event }
            guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return event }
            #if DEBUG
            if CommandLine.arguments.contains("--swipe-diagnostics"), event.phase.contains(.began) {
                    Logger(subsystem: "com.weekleft.app", category: "swipe-diagnostic").notice(
                        "event phase=\(event.phase.rawValue) windowMatch=\(event.window === window) point=\(String(describing: self.convert(event.locationInWindow, from: nil)), privacy: .public) regions=\(self.regions.count)"
                    )
                }
            #endif
            if event.phase.contains(.began) {
                consumeMomentum = false
                let point = convert(event.locationInWindow, from: nil)
                // SwiftUI reports row rectangles in this one panel coordinate space.
                // Separate NSView backgrounds in lazy rows can share misleading frames.
                trackedID = SessionSwipe.target(at: point, regions: regions, viewport: viewport.intersection(visibleRect))
                gesture = SessionSwipe()
            }
            guard let id = trackedID else { return event }
            // Normalize to finger direction even when Natural Scrolling is disabled.
            let sign = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
            gesture.update(dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY * sign)
            let consumed = gesture.horizontal
            onOffset(id, gesture.offset)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let action = gesture.finish(cancelled: event.phase.contains(.cancelled))
                trackedID = nil; consumeMomentum = consumed; onOffset(id, 0)
                if let action { onAction(id, action) }
            }
            return consumed ? nil : event
        }
    }
}
