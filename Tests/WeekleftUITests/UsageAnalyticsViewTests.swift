import XCTest
import AppKit
import SwiftUI
import WeekleftCore
@testable import Weekleft

final class UsageAnalyticsViewTests: XCTestCase {
    @MainActor func testNativeConsentCards() async throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ANALYTICS"] else {
            throw XCTSkip("Opt-in native consent render with isolated preferences and mock transport")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "Lunavect.ConsentRender." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let analytics = UsageAnalytics(defaults: defaults,
            configuration: UsageAnalyticsConfiguration(token: "phc_0123456789abcdefghijklmnop", host: "https://eu.i.posthog.com"),
            version: "0.2.4", build: "190", automaticDelivery: false, transport: { _ in
                XCTFail("Rendering must not submit analytics"); return 500
            })
        defer { analytics.stop() }
        for dark in [true, false] {
            for invitation in [true, false] {
                let view = UsageAnalyticsView(analytics: analytics, invitation: invitation).padding(24)
                    .frame(width: 580, height: 300).background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(x: 0, y: 0, width: 580, height: 300)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = "consent-\(invitation ? "welcome" : "settings")-\(L10n.selection)-\(dark ? "dark" : "light").png"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
                window.contentView = nil
            }
        }
        XCTAssertFalse(analytics.enabled); XCTAssertFalse(analytics.hasDecision)
    }
}
