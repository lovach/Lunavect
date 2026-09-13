import XCTest
import AppKit
import SwiftUI
@testable import Weekleft

final class InterfaceIconRenderingTests: XCTestCase {
    @MainActor func testRenderCompleteControlAlphabet() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_ICONS"] else { throw XCTSkip("Opt-in native icon inspection") }
        try LegacyRenderIsolation.require()
        let glyphs = InterfaceGlyph.allCases
        let board = LazyVGrid(columns: Array(repeating: GridItem(.fixed(80)), count: 6), spacing: 18) {
            ForEach(glyphs.indices, id: \.self) { index in
                VStack(spacing: 10) {
                    InterfaceIcon(glyphs[index], size: 20)
                    Text(String(describing: glyphs[index])).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(height: 52)
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        try LegacyRenderIsolation.render(board, size: CGSize(width: 584, height: 680),
            to: URL(fileURLWithPath: output + "-" + (try LegacyRenderIsolation.language()) + ".png"))
    }
}
