import AppKit
import SwiftUI
import WeekleftCore
import XCTest
@testable import Weekleft

final class WidgetTransparencyTests: XCTestCase {
    func testStoredTransparencyPreservesOldValuesAndNewEndpoints() throws {
        for value in [0.0, 0.2, 0.5, 0.7, 0.75, 1.0] {
            let data = Data("{\"transparency\":\(value),\"transparentBackground\":true}".utf8)
            let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: data)
            XCTAssertEqual(decoded.transparency, value)
            let restored = try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(decoded))
            XCTAssertEqual(restored, decoded)
        }
        for (input, expected) in [(-2.0, 0.0), (2.0, 1.0)] {
            let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: Data("{\"transparency\":\(input)}".utf8))
            XCTAssertEqual(decoded.transparency, expected)
        }
        XCTAssertFalse(WidgetPreferences().transparentBackground)
    }

    @MainActor func testRenderedBackdropAlphaAndRemovableContent() throws {
        for (value, expected) in [(0.0, 1.0), (0.5, 0.5), (1.0, 0.0), (-1.0, 1.0), (2.0, 0.0), (.nan, 0.5)] {
            let image = try bitmap(ActivityWidgetBackground(transparent: true, transparency: value), size: CGSize(width: 40, height: 40))
            XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 20, y: 20)).alphaComponent, expected, accuracy: 0.01)
        }
        let standard = try bitmap(ActivityWidgetBackground(transparent: false, transparency: 1), size: CGSize(width: 40, height: 40))
        XCTAssertEqual(try XCTUnwrap(standard.colorAt(x: 20, y: 20)).alphaComponent, 1)
        for content in LunavectWidgetContent.allCases {
            let card = LunavectWidgetCard(snapshots: [], preferences: .init(), history: .init(),
                content: content, family: .medium, drawsBackground: false)
            let image = try bitmap(card, size: LunavectWidgetSize.medium.dimensions)
            XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 1, y: 1)).alphaComponent, 0,
                           "WidgetKit must be able to remove the entire decorative background")
        }
    }

    // Pure value views and fictional data; no app stores, preferences or visible windows.
    @MainActor func testExportTransparencyComparison() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_TRANSPARENCY"] else {
            throw XCTSkip("Opt-in native transparency comparison")
        }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshots = try ProviderID.allCases.map { id in
            try UsageSnapshot(provider: id,
                weekly: QuotaWindow(usedPercent: id == .claude ? 35 : 58, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                fetchedAt: now)
        }
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-1800), end: now, providers: 3)
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for light in [false, true] {
            let board = VStack(alignment: .leading, spacing: 16) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { transparency in
                    HStack(alignment: .top, spacing: 16) {
                        Text("\(Int(transparency * 100))%")
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit().frame(width: 48)
                        ForEach([LunavectWidgetContent.limits, .activity], id: \.self) { content in
                            let prefs: WidgetPreferences = {
                                var value = WidgetPreferences()
                                value.transparentBackground = true; value.transparency = transparency
                                return value
                            }()
                            LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history,
                                content: content, family: .medium, now: now)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                    }
                }
            }.padding(24)
                .foregroundStyle(light ? Color.black : Color.white)
                .background(LinearGradient(colors: light
                    ? [Color(red: 0.65, green: 0.72, blue: 0.84), Color(red: 0.43, green: 0.57, blue: 0.59)]
                    : [Color(red: 0.13, green: 0.09, blue: 0.27), Color(red: 0.07, green: 0.23, blue: 0.27)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            let image = try bitmap(board, size: CGSize(width: 816, height: 572))
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(light ? "transparency-light.png" : "transparency-dark.png"))
        }
    }

    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        renderer.proposedSize = ProposedViewSize(size); renderer.scale = 2; renderer.isOpaque = false
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
}
