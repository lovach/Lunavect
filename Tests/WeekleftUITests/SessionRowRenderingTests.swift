import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class SessionRowRenderingTests: XCTestCase {
    @MainActor func testRenderActualRowsAtPartialSwipeOffsets() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SWIPE"] else { throw XCTSkip("Set LUNAVECT_RENDER_SWIPE to export native rows for visual inspection") }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let now = Date()
        let row = AgentSession(provider: .codex, sessionID: "render-only", title: "Настрой проект по OpenAI", cwd: "/test", client: .desktop, phase: .ready, updatedAt: now, observedAt: now)
        let offsets = [0.0, 22.0, 70.0, -22.0, -70.0]
        let presentations = offsets.map { offset in
            let state = SessionSwipePresentation(); state.id = row.id; state.offset = offset; return state
        }
        let content = VStack(spacing: 12) {
            ForEach(Array(presentations.enumerated()), id: \.offset) { index, state in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offset: \(Int(offsets[index])) pt").font(.system(size: 10)).foregroundStyle(.secondary)
                    SessionRow(session: row, now: now, phase: .ready, swipePresentation: state, onHide: {}, onError: { _ in })
                }
            }
        }.padding(14).frame(width: 372).background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, Locale(identifier: "ru")).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output))
        XCTAssertGreaterThan(data.count, 1000)
        window.contentView = nil
    }
}
