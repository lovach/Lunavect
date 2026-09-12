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
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.SettingsRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(), sessions = SessionStore()
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.systemColor = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_SYSTEM_COLOR"] == "1"
        for section in SettingsSection.allCases {
            defaults.set(section.rawValue, forKey: "settingsSection")
            let host = NSHostingView(rootView: SettingsView(store: store, menuBarAppearance: appearance, sessions: sessions)
                .defaultAppStorage(defaults))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 840, height: 650)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(section.rawValue + ".png"))
            window.contentView = nil
        }
    }
}

extension SettingsRenderingTests {
    @MainActor func testRenderActivityImportReport() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_IMPORT_REPORT"] else { throw XCTSkip("Opt-in import report rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        var report = ActivityImportReport(), claude = ActivityImportReport.Provider(id: .claude), codex = ActivityImportReport.Provider(id: .codex)
        claude.filesRead = 1000; claude.filesWithoutTiming = 750; claude.recoveredSeconds = 5 * 3600 + 20 * 60
        claude.daysRecovered = 12; claude.agentRecords = 120; claude.taskRecords = 15; claude.toolRecords = 160
        claude.firstRecovered = Date(timeIntervalSince1970: 1787356800); claude.lastRecovered = Date(timeIntervalSince1970: 1788998400)
        codex.filesRead = 90; codex.filesWithoutTiming = 5; codex.recoveredSeconds = 8 * 3600
        codex.daysRecovered = 4; codex.taskRecords = 40; codex.issues[.incompleteTask] = 3; codex.issues[.malformed] = 1
        codex.firstRecovered = claude.lastRecovered?.addingTimeInterval(-3 * 86400); codex.lastRecovered = claude.lastRecovered
        report.providers = [claude, codex]
        for language in ["ru", "de"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for width in [340.0, 580.0] {
                let host = NSHostingView(rootView: ActivityImportReportView(report: report, expanded: true).padding(16).frame(width: width).foregroundStyle(.secondary).background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: .darkAqua)
                let size = host.fittingSize
                XCTAssertLessThanOrEqual(size.width, width + 1)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(language)-\(Int(width)).png"))
                window.contentView = nil
            }
        }
    }
}
