import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft
final class SubscriptionCalendarRenderingTests: XCTestCase {
    @MainActor func testNativeCalendarPreview() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CALENDAR"] else { throw XCTSkip("Set LUNAVECT_RENDER_CALENDAR for visual verification") }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let calendar = SubscriptionCalendar.calendar()
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let host = NSHostingView(rootView: SubscriptionCalendarView(provider: .claude, selection: .constant(date), onClose: {}).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        XCTAssertGreaterThan(image.pixelsWide, 300)
        window.contentView = nil
    }
}
