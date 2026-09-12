import XCTest
import AppKit
import SwiftUI
@testable import Weekleft

final class InterfaceIconRenderingTests: XCTestCase {
    @MainActor func testRenderCompleteControlAlphabet() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ICONS"] else { throw XCTSkip("Opt-in native icon inspection") }
        _ = NSApplication.shared
        let glyphs = InterfaceGlyph.allCases
        let board = LazyVGrid(columns: Array(repeating: GridItem(.fixed(80)), count: 6), spacing: 18) {
            ForEach(glyphs.indices, id: \.self) { index in
                VStack(spacing: 10) {
                    InterfaceIcon(glyphs[index], size: 20)
                    Text(String(describing: glyphs[index])).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(height: 52)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: board)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        window.contentView = nil
    }
}
