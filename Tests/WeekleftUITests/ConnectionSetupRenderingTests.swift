import XCTest
import SwiftUI
import AppKit
@testable import Weekleft
import WeekleftCore

final class ConnectionSetupRenderingTests: XCTestCase {
    @MainActor func testRenderConnectionSteps() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CONNECTION"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_CONNECTION to inspect native connection steps")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(), sessions = SessionStore()
        store.snapshots = []
        for provider in ProviderID.allCases {
            for step in 0...3 {
                let host = NSHostingView(rootView: ConnectionSetupView(provider: provider, store: store, sessions: sessions, initialStep: step))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = CGRect(x: 0, y: 0, width: 600, height: 580)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(provider.rawValue)-\(step).png"))
                window.contentView = nil
            }
        }
    }
}
