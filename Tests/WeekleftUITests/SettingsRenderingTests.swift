import XCTest
import SwiftUI
import AppKit
import WeekleftCore
@testable import Weekleft

final class SettingsRenderingTests: XCTestCase {
    @MainActor func testRenderSettingsPages() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SETTINGS"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_SETTINGS to inspect native settings pages")
        }
        try LegacyRenderIsolation.require()
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = try LegacyRenderFixture()
        defer { preview.stop() }
        let defaults = preview.environment.defaults
        let appearance = preview.environment.menuBarAppearance
        appearance.systemColor = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SYSTEM_COLOR"] == "1"
        for section in SettingsSection.allCases {
            defaults.set(section.rawValue, forKey: "settingsSection")
            let host = NSHostingView(rootView: preview.settings())
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 840, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(section.rawValue + "-" + (try LegacyRenderIsolation.language()) + ".png"))
            window.contentView = nil
        }
    }
}

extension SettingsRenderingTests {
    @MainActor func testRenderActivityImportReport() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_IMPORT_REPORT"] else { throw XCTSkip("Opt-in import report rendering") }
        try LegacyRenderIsolation.require()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = ActivityImportReport(), claude = ActivityImportReport.Provider(id: .claude), codex = ActivityImportReport.Provider(id: .codex)
        claude.filesRead = 1000; claude.filesWithoutTiming = 750; claude.recoveredSeconds = 5 * 3600 + 20 * 60
        claude.daysRecovered = 12; claude.agentRecords = 120; claude.taskRecords = 15; claude.toolRecords = 160
        claude.firstRecovered = Date(timeIntervalSince1970: 1787356800); claude.lastRecovered = Date(timeIntervalSince1970: 1788998400)
        codex.filesRead = 90; codex.filesWithoutTiming = 5; codex.recoveredSeconds = 8 * 3600
        codex.daysRecovered = 4; codex.taskRecords = 40; codex.issues[.incompleteTask] = 3; codex.issues[.malformed] = 1
        codex.firstRecovered = claude.lastRecovered?.addingTimeInterval(-3 * 86400); codex.lastRecovered = claude.lastRecovered
        report.providers = [claude, codex]
        for language in [try LegacyRenderIsolation.language()] {
            for width in [340.0, 580.0] {
                let view = ActivityImportReportView(report: report, expanded: true).padding(16).foregroundStyle(.secondary)
                try LegacyRenderIsolation.render(view, size: CGSize(width: width, height: width < 400 ? 700 : 450),
                    to: directory.appendingPathComponent("\(language)-\(Int(width)).png"))
            }
        }
    }
}
