import AppKit
import SwiftUI
import XCTest
import WeekleftCore
@testable import Weekleft

/// The owner's case of 28.09 (Claude Code signed out, `/usage` shows "API Usage
/// Billing") on the places she looks at: the limits popover and the sessions panel.
/// Opt-in; only inside the proven render sandbox (`LegacyRenderIsolation.require`).
@MainActor final class SignInAttentionRenderingTests: XCTestCase {
    func testRenderSignedOutClaudeInPopoverAndPanel() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SIGN_IN"] else { throw XCTSkip("Opt-in isolated native rendering") }
        try LegacyRenderIsolation.require()
        let language = try LegacyRenderIsolation.language()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Current rows need the panel's own clock; the fixture follows it.
        let now = Date()
        let signedOut = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message
        let saved = UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 12, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600)),
            fetchedAt: now.addingTimeInterval(-2 * 3600), source: "Claude Code /usage", issue: signedOut)
        let codex = UsageSnapshot(provider: .codex,
            weekly: try QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 5, durationMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600)),
            fetchedAt: now.addingTimeInterval(-60), source: "Codex app-server")
        // A first connection while signed out: nothing was ever received.
        let empty = UsageSnapshot(provider: .claude, issue: signedOut)
        let preview = try LegacyRenderFixture(snapshots: [saved, codex], now: now)
        defer { preview.stop() }
        for (state, snapshots) in [("saved", [saved, codex]), ("empty", [empty, codex])] {
            for scheme in [ColorScheme.dark, .light] {
                let suffix = "\(state)-\(language)-\(scheme == .dark ? "dark" : "light")"
                let model = MenuBarLimitsPanelModel()
                model.entries = MenuBarLimitEntry.make(snapshots: snapshots, providers: ProviderID.allCases,
                                                       preferences: .init(enabled: true), now: now)
                let popover = MenuBarLimitsPopover(model: model, onPeriod: { _ in }, onRefresh: {}, onMenu: {}, onSettings: {})
                try render(popover, width: 340, scheme: scheme, to: output.appendingPathComponent("popover-\(suffix).png"))
                let panel = SessionPanelState(isVisible: true)
                let sessions = SessionsView(store: preview.environment.sessions, panelState: panel, updates: preview.environment.updates,
                                            awake: preview.environment.awake, isPreview: false, onSettings: {})
                    .defaultAppStorage(preview.environment.defaults)
                try render(sessions, width: 360, scheme: scheme, to: output.appendingPathComponent("panel-\(suffix).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, scheme: ColorScheme, to url: URL) throws {
        let root = view.frame(width: width).frame(height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = CGSize(width: width, height: height ?? ceil(host.fittingSize.height))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        let window = SignInRenderWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor private final class SignInRenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var backingScaleFactor: CGFloat { 2 }
}
