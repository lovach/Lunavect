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
        // Reduce Transparency and Increase Contrast always draw an opaque background;
        // check the contract that applies to this host instead of failing on it.
        let opaqueForAccessibility = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for (value, expected) in [(0.0, 1.0), (0.5, 0.5), (1.0, 0.0), (-1.0, 1.0), (2.0, 0.0), (.nan, 0.5)] {
            let image = try bitmap(ActivityWidgetBackground(transparent: true, transparency: value), size: CGSize(width: 40, height: 40))
            XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 20, y: 20)).alphaComponent, opaqueForAccessibility ? 1 : expected, accuracy: 0.01)
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

    func testIncreaseContrastStrengthensDimWidgetInk() {
        for (base, increased) in [(0.55, 0.95), (0.78, 0.95), (0.12, 0.3)] {
            XCTAssertEqual(WidgetInk.level(base, increased: increased, contrast: .standard), base)
            XCTAssertEqual(WidgetInk.level(base, increased: increased, contrast: .increased), increased)
        }
        XCTAssertEqual(WidgetInk.level(1, contrast: .increased), 1, "Increase Contrast never dims full-strength ink")
    }

    // Fictional values. Increase Contrast is read-only in public SwiftUI; this
    // comparison forces it through the underscored preview key, test-only.
    @MainActor func testExportIncreasedContrastComparison() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_TRANSPARENCY"] else {
            throw XCTSkip("Opt-in native contrast comparison")
        }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshots = try ProviderID.allCases.map { id in
            try UsageSnapshot(provider: id,
                weekly: QuotaWindow(usedPercent: id == .claude ? 35 : 58, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                fiveHour: QuotaWindow(usedPercent: 20, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                fetchedAt: now.addingTimeInterval(id == .claude ? -3 * 3600 : 0))
        }
        var history = ActivityHistory()
        history.append(start: now.addingTimeInterval(-1800), end: now, providers: 3)
        var prefs = WidgetPreferences(); prefs.transparentBackground = true; prefs.transparency = 1; prefs.showFiveHour = true
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let board = VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: .limits, family: .medium, now: now)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: .limits, family: .small, now: now)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
                LunavectWidgetCard(snapshots: snapshots, preferences: prefs, history: history, content: .overview, family: .large, now: now)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 8) {
                    ForEach([false, true], id: \.self) { active in
                        Button {} label: { InterfaceIcon(.settings) }.buttonStyle(InterfaceToolbarStyle(active: active))
                    }
                    Button {} label: { InterfaceIcon(.search) }.buttonStyle(InterfaceToolbarStyle(selected: true))
                }.padding(10).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }.padding(24)
                .background(LinearGradient(colors: [Color(red: 0.86, green: 0.89, blue: 0.93), Color(red: 0.70, green: 0.78, blue: 0.80)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\._colorSchemeContrast, contrast == .increased ? .increased : .standard)
            let image = try bitmap(board, size: CGSize(width: 588, height: 648))
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("contrast-\(contrast == .increased ? "increased" : "standard").png"))
        }
    }

    @MainActor private func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        renderer.proposedSize = ProposedViewSize(size); renderer.scale = 2; renderer.isOpaque = false
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
}
