import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class ReleaseScreenshots: XCTestCase {
    @MainActor func testRenderPublicScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RELEASE_SCREENSHOTS"] else {
            throw XCTSkip("Opt-in public screenshots using fictional data")
        }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let preview = try LegacyRenderFixture()
        defer { preview.stop() }
        let defaults = preview.environment.defaults
        let sessions = preview.environment.sessions
        let fixture = preview.presentation
        let now = fixture.now
        let history = fixture.history
        let preferences = fixture.preferences
        let claude = fixture.snapshots[0], codex = fixture.snapshots[1]
        sessions.acceptSessions(fixture.sessions())
        let sessionView = preview.sessions()
        try render(sessionView, size: CGSize(width: 360, height: 355), to: output.appendingPathComponent("sessions.png"))
        for section in ["limits", "statistics"] {
            defaults.set(section, forKey: "settingsSection")
            try render(preview.settings(),
                       size: CGSize(width: 920, height: 780), to: output.appendingPathComponent(section == "limits" ? "limits.png" : "activity.png"))
            if section == "statistics" {
                try render(preview.settings(),
                           size: CGSize(width: 920, height: 1060), to: output.appendingPathComponent("readme-activity.png"))
            }
        }

        func widget(_ content: LunavectWidgetContent, _ family: LunavectWidgetSize, source: ActivitySource = .all) -> some View {
            LunavectWidgetCard(snapshots: [claude, codex], preferences: preferences, history: history,
                               content: content, family: family, now: now, source: source)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        }
        let showcase = HStack(alignment: .top, spacing: 32) {
            sessionView.frame(width: 360, height: 355)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            VStack(spacing: 24) {
                widget(.limits, .medium)
                widget(.activity, .medium, source: .comparison)
            }
        }
        for scheme in [ColorScheme.dark, .light] {
            try render(showcase.padding(40), size: CGSize(width: 832, height: 456),
                       to: output.appendingPathComponent("showcase-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme, backdrop: true)
            try render(showcase.padding(24), size: CGSize(width: 784, height: 403),
                       to: output.appendingPathComponent("readme-overview-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme, transparent: true)
            let panel = sessionView.frame(width: 360, height: 355)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .padding(16)
            try render(panel, size: CGSize(width: 392, height: 387),
                       to: output.appendingPathComponent("readme-sessions-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme, transparent: true)
        }
        let themes = HStack(alignment: .top, spacing: 32) {
            ForEach([false, true], id: \.self) { dark in
                sessionView.frame(width: 360, height: 355)
                    .background(dark ? Color(white: 0.12) : Color(white: 0.96))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 14, y: 8)
            }
        }
        try render(themes.padding(40), size: CGSize(width: 832, height: 456), to: output.appendingPathComponent("sessions-themes.png"), backdrop: true)
        let widgets = HStack(alignment: .top, spacing: 32) {
            VStack(spacing: 16) {
                HStack(spacing: 16) { widget(.limits, .small); widget(.activity, .small) }
                widget(.activity, .medium, source: .comparison)
            }
            widget(.overview, .large)
        }
        try render(widgets.padding(40), size: CGSize(width: 832, height: 456), to: output.appendingPathComponent("widgets.png"), backdrop: true)
        try render(widgets.padding(24), size: CGSize(width: 800, height: 408),
                   to: output.appendingPathComponent("readme-widgets.png"), transparent: true)
        let activityDetail = ActivityDetailChart(
            data: ActivityChartData(history: history, now: now, period: .week, providers: [.claude, .codex]),
            chartHeight: 140)
            .frame(width: 670).padding(28)
        try render(activityDetail, size: CGSize(width: 832, height: 520),
                   to: output.appendingPathComponent("activity-detail.png"), backdrop: true)
        let social = HStack(spacing: 64) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    if let mark = AppArtwork.brandMark {
                        Image(nsImage: mark).resizable().scaledToFit().frame(width: 76, height: 76)
                    }
                    Text("Lunavect").font(.system(size: 48, weight: .semibold, design: .rounded))
                }
                Text("Claude Code & Codex").font(.system(size: 31, weight: .medium))
                Text("Status bar.\nUsage limits.\nDesktop widgets.")
                    .font(.system(size: 42, weight: .semibold)).lineSpacing(6)
                Text("Free & open source  ·  macOS 14+")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                Text("github.com/lovach/Lunavect")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }.frame(width: 480, alignment: .leading)
            ZStack(alignment: .topLeading) {
                sessionView.frame(width: 360, height: 355)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 16)
                widget(.limits, .small).offset(x: 276, y: 244)
            }.frame(width: 440, height: 408)
        }.padding(64)
        try render(social, size: CGSize(width: 1280, height: 640), to: output.appendingPathComponent("social-preview.png"), backdrop: true, scale: 1)
    }

    @MainActor private func render<V: View>(_ view: V, size: CGSize, to path: URL, scheme: ColorScheme = .dark, backdrop: Bool = false, transparent: Bool = false, scale: CGFloat? = nil) throws {
        let root = view.frame(width: size.width, height: size.height).background {
            if transparent {
                Color.clear
            } else if backdrop {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.07, green: 0.10, blue: 0.15), Color(red: 0.13, green: 0.12, blue: 0.15)]
                        : [Color(red: 0.92, green: 0.95, blue: 0.99), Color(red: 0.98, green: 0.95, blue: 0.92)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            } else { Color(nsColor: .windowBackgroundColor) }
        }.preferredColorScheme(scheme).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        if transparent { window.isOpaque = false; window.backgroundColor = .clear }
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.07)); host.layoutSubtreeIfNeeded() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if transparent {
            // README images need native Retina pixels; do not enlarge a 1x capture.
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width * 2))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height * 2))
        }
        if let scale {
            let result = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: size).draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(result.representation(using: .png, properties: [:])).write(to: path)
        } else {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        }
    }
}
