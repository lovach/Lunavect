import XCTest
import AppKit
import SwiftUI
import WeekleftCore
@testable import Weekleft

final class MenuBarLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func snapshot(_ provider: ProviderID = .codex, used: Double = 28, fetchedAgo: TimeInterval = 0, resetAfter: TimeInterval = 3600, at date: Date? = nil) throws -> UsageSnapshot {
        let reference = date ?? now
        return try UsageSnapshot(provider: provider,
                          weekly: QuotaWindow(usedPercent: used, durationMinutes: 10080, resetsAt: reference.addingTimeInterval(resetAfter)),
                          fiveHour: QuotaWindow(usedPercent: 91, durationMinutes: 300, resetsAt: reference.addingTimeInterval(600)),
                          fetchedAt: reference.addingTimeInterval(-fetchedAgo))
    }
    func testRemainingAndPeriodSelection() throws {
        let data = try [snapshot(.claude, used: 100), snapshot(.codex, used: 0)]
        var preferences = MenuBarLimitsPreferences(enabled: true)
        let entries = MenuBarLimitEntry.make(snapshots: data, providers: ProviderID.allCases, preferences: preferences, now: now)
        XCTAssertEqual(entries.map(\.value), ["0%", "100%"])
        preferences.period = .fiveHour
        XCTAssertEqual(MenuBarLimitEntry.make(snapshots: data, providers: ProviderID.allCases, preferences: preferences, now: now).map(\.value), ["9%", "9%"])
    }
    func testUnavailableExpiredAndSavedValuesStayDistinct() throws {
        let preferences = MenuBarLimitsPreferences(enabled: true)
        for (snapshot, expected) in [(UsageSnapshot(provider: .codex), "—"), (try snapshot(resetAfter: 0), "—"),
                                     (try snapshot(fetchedAgo: 901), "72%*"), (try snapshot(fetchedAgo: 900), "72%") ] {
            let entry = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [snapshot], providers: [.codex], preferences: preferences, now: now).first)
            XCTAssertEqual(entry.value, expected)
        }
        var failed = try snapshot()
        failed.issue = "offline"
        XCTAssertEqual(MenuBarLimitEntry.make(snapshots: [failed], providers: [.codex], preferences: preferences, now: now).first?.value, "72%*")
        var expiredOtherWindow = try snapshot()
        expiredOtherWindow.fiveHour = try QuotaWindow(usedPercent: 30, durationMinutes: 300, resetsAt: now)
        XCTAssertEqual(MenuBarLimitEntry.make(snapshots: [expiredOtherWindow], providers: [.codex], preferences: preferences, now: now).first?.value, "72%")
    }
    func testDisabledProvidersAreNeverShownFromSavedSnapshots() throws {
        let data = try [snapshot(.claude), snapshot(.codex)]
        XCTAssertEqual(MenuBarLimitEntry.make(snapshots: data, providers: [.codex], preferences: .init(enabled: true), now: now).map(\.provider), [.codex])
        XCTAssertTrue(MenuBarLimitEntry.make(snapshots: data, providers: [.codex], preferences: .init(enabled: true, provider: .claude), now: now).isEmpty)
        XCTAssertTrue(MenuBarLimitEntry.make(snapshots: data, providers: [], preferences: .init(enabled: true), now: now).isEmpty)
    }
    @MainActor func testDefaultsAreOptInAndChoicePersists() throws {
        let suite = "Lunavect.MenuBarLimitsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = MenuBarAppearance(defaults: defaults)
        XCTAssertFalse(appearance.limits.enabled)
        XCTAssertFalse(appearance.limits.showsResetCountdown)
        let oldStyle = appearance.statusStyle
        for icon in MenuBarLimitsColor.allCases {
            for meter in MenuBarLimitsColor.allCases {
                for showsCountdown in [false, true] {
                appearance.limits = .init(enabled: true, provider: .codex, period: .fiveHour, style: .rings,
                                          iconColor: icon, meterColor: meter, showsResetCountdown: showsCountdown)
                let restored = MenuBarAppearance(defaults: defaults)
                XCTAssertEqual(restored.limits, appearance.limits)
                XCTAssertEqual(restored.statusStyle, oldStyle)
                }
            }
        }
    }
    @MainActor func testUpgradeKeepsEnabledProvidersAndPeriod() throws {
        let old = Data(#"{"enabled":true,"provider":"claude","period":"fiveHour"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarLimitsPreferences.self, from: old)
        XCTAssertEqual(decoded, .init(enabled: true, provider: .claude, period: .fiveHour, style: .bars))
        let rings = Data(#"{"enabled":true,"provider":"codex","period":"weekly","style":"rings"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarLimitsPreferences.self, from: rings),
                       .init(enabled: true, provider: .codex, style: .rings, iconColor: .system, meterColor: .provider))
    }
    @MainActor func testCountdownUsesResetDateAndAdvancesWithoutAnotherFetch() throws {
        let old = L10n.defaults.object(forKey: "languageCode")
        L10n.defaults.set("en", forKey: "languageCode")
        defer { L10n.defaults.set(old, forKey: "languageCode") }
        let data = try [snapshot(.claude, resetAfter: 36 * 3600)]
        let before = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: data, providers: [.claude], preferences: .init(enabled: true), now: now).first)
        XCTAssertEqual(before.countdown, "1 d 12 hr")
        XCTAssertEqual(before.compactCountdown, "1d 12h")
        let after = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: data, providers: [.claude], preferences: .init(enabled: true), now: now.addingTimeInterval(13 * 3600)).first)
        XCTAssertEqual(after.compactCountdown, "23h 0m")
        XCTAssertEqual(after.resetDate, before.resetDate)
        XCTAssertEqual(after.remaining, before.remaining)
        let expired = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: data, providers: [.claude], preferences: .init(enabled: true), now: now.addingTimeInterval(36 * 3600)).first)
        XCTAssertEqual(expired.value, "—"); XCTAssertEqual(expired.compactCountdown, "—")
        XCTAssertNil(expired.resetDate)
    }
    @MainActor func testNativeItemUpdatesExpiresOpensAndRemoves() async throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let controller = MenuBarLimitsController(autosaveName: nil) {}
        controller.popover.animates = false
        defer { controller.stop() }
        let data = try [snapshot()]
        controller.update(snapshots: data, providers: [.codex], preferences: .init(), now: now)
        XCTAssertNil(controller.statusItem)
        controller.update(snapshots: data, providers: [.codex], preferences: .init(enabled: true), now: now)
        let item = try XCTUnwrap(controller.statusItem), button = try XCTUnwrap(item.button)
        let width = item.length
        XCTAssertEqual(controller.content.entries.first?.value, "72%")
        try await Task.sleep(for: .milliseconds(100))
        button.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        button.performClick(nil)
        XCTAssertFalse(controller.popover.isShown)
        controller.refresh(now: now.addingTimeInterval(901))
        XCTAssertEqual(controller.content.entries.first?.value, "72%*")
        XCTAssertEqual(item.length, width)
        controller.refresh(now: now.addingTimeInterval(3600))
        XCTAssertEqual(controller.content.entries.first?.value, "—")
        XCTAssertEqual(item.length, width)
        controller.update(snapshots: [try snapshot(used: 0)], providers: [.codex], preferences: .init(enabled: true, showsResetCountdown: true), now: now)
        XCTAssertTrue(controller.statusItem === item)
        XCTAssertEqual(controller.content.entries.first?.value, "100%")
        XCTAssertEqual(item.length, width)
        XCTAssertTrue(button.toolTip?.contains("100%") == true)
        let details = controller.panel.entries
        let tooltip = button.toolTip
        controller.update(snapshots: [try snapshot(used: 0)], providers: [.codex],
                          preferences: .init(enabled: true, showsResetCountdown: false), now: now)
        XCTAssertFalse(controller.content.showsResetCountdown)
        XCTAssertEqual(item.length, width, "Toggling the countdown must not shift neighbouring menu bar items")
        XCTAssertEqual(controller.panel.entries, details, "Hiding the menu bar countdown must retain reset details in the panel")
        XCTAssertEqual(button.toolTip, tooltip)
        XCTAssertNotNil(controller.panel.entries.first?.resetDate)
        controller.update(snapshots: data, providers: [], preferences: .init(enabled: true), now: now)
        XCTAssertNil(controller.statusItem)
        controller.update(snapshots: data, providers: [.codex], preferences: .init(enabled: true), now: now)
        XCTAssertNotNil(controller.statusItem)
        controller.update(snapshots: data, providers: [.codex], preferences: .init(), now: now)
        XCTAssertNil(controller.statusItem)
    }
    @MainActor func testStyleAndPeriodChangesReachNativeIndicatorAndPersistSelection() throws {
        _ = NSApplication.shared
        var selected: MenuBarLimitsPeriod?
        let controller = MenuBarLimitsController(onSelectPeriod: { selected = $0 }, autosaveName: nil) {}
        defer { controller.stop() }
        let instant = Date()
        let data = try [snapshot(at: instant)]
        controller.update(snapshots: data, providers: [.codex], preferences: .init(enabled: true), now: instant)
        let barWidth = try XCTUnwrap(controller.statusItem).length
        controller.update(snapshots: data, providers: [.codex], preferences: .init(enabled: true, style: .rings,
                          iconColor: .provider, meterColor: .system), now: instant)
        XCTAssertEqual(controller.content.style, .rings)
        XCTAssertEqual(controller.content.iconColor, .provider)
        XCTAssertEqual(controller.content.meterColor, .system)
        XCTAssertEqual(controller.panel.iconColor, .provider)
        XCTAssertEqual(controller.panel.meterColor, .system)
        XCTAssertLessThan(try XCTUnwrap(controller.statusItem).length, barWidth)
        controller.selectPeriod(.fiveHour)
        XCTAssertEqual(selected, .fiveHour)
        XCTAssertEqual(controller.panel.period, .fiveHour)
        XCTAssertEqual(controller.content.entries.first?.value, "9%")
        XCTAssertEqual(controller.content.style, .rings)
        XCTAssertEqual(controller.content.iconColor, .provider)
        XCTAssertEqual(controller.content.meterColor, .system)
    }

    @MainActor func testRenderIndependentColors() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMITS_STATUS"] else { throw XCTSkip("Opt-in native color rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalLanguage = L10n.defaults.object(forKey: "languageCode")
        L10n.defaults.set("ru", forKey: "languageCode")
        defer { L10n.defaults.set(originalLanguage, forKey: "languageCode") }
        let entries = MenuBarLimitEntry.make(snapshots: try [snapshot(.claude, resetAfter: 36 * 3600), snapshot(.codex, used: 63, resetAfter: 5 * 86400)],
                                            providers: ProviderID.allCases, preferences: .init(), now: now)
        let choices: [(String, MenuBarLimitsColor, MenuBarLimitsColor)] = [
            ("Цветные иконки и шкалы", .provider, .provider),
            ("Системные иконки", .system, .provider),
            ("Системные шкалы", .provider, .system),
            ("Всё системное", .system, .system)
        ]
        for dark in [true, false] {
            let board = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 220))
            board.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            board.wantsLayer = true; board.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.94, alpha: 1).cgColor
            for (index, choice) in choices.enumerated() {
                let y = CGFloat(3 - index) * 46 + 30
                let label = NSTextField(labelWithString: choice.0)
                label.font = .systemFont(ofSize: 11); label.textColor = .labelColor
                label.frame = NSRect(x: 14, y: y + 8, width: 165, height: 17); board.addSubview(label)
                for style in [MenuBarLimitsStyle.bars, .rings] {
                    let view = MenuBarLimitsContent(frame: NSRect(x: style == .bars ? 190 : 394, y: y, width: style == .bars ? 192 : 68, height: 32))
                    view.entries = entries; view.style = style; view.iconColor = choice.1; view.meterColor = choice.2
                    board.addSubview(view)
                }
            }
            let caption = NSTextField(labelWithString: "Нативный интерфейс · примерные данные")
            caption.font = .systemFont(ofSize: 10); caption.textColor = .secondaryLabelColor
            caption.frame = NSRect(x: 14, y: 6, width: 400, height: 16); board.addSubview(caption)
            let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = board; board.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
            board.cacheDisplay(in: board.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("colors-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
    }
    @MainActor func testNativeLimitsPopoverClosesOnDeactivationAndDoesNotMoveForCountdowns() async throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        var shown = 0, hidden = 0
        let controller = MenuBarLimitsController(onShow: { shown += 1 }, onHide: { hidden += 1 }, autosaveName: nil) {}
        controller.popover.animates = false
        defer { controller.stop() }
        controller.update(snapshots: [try snapshot()], providers: [.codex], preferences: .init(enabled: true), now: now)
        let button = try XCTUnwrap(controller.statusItem?.button)
        try await Task.sleep(for: .milliseconds(100))
        button.performClick(nil)
        let frame = try XCTUnwrap(controller.popover.contentViewController?.view.window).frame
        controller.refresh(now: now.addingTimeInterval(61))
        XCTAssertEqual(controller.popover.contentViewController?.view.window?.frame, frame)
        XCTAssertEqual(shown, 1)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertFalse(controller.popover.isShown)
        XCTAssertEqual(hidden, 1)
    }
    @MainActor func testRenderNativeLimits() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMITS_STATUS"] else { throw XCTSkip("Opt-in native menu bar rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(originalLanguage, forKey: "languageCode") }
        let data = try [snapshot(.claude, used: 89, resetAfter: 33 * 3600), snapshot(.codex, used: 13, resetAfter: 163 * 3600)]
        for language in ["en", "ru", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for dark in [true, false] {
                let board = NSView(frame: NSRect(x: 0, y: 0, width: 730, height: 142))
                board.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                board.wantsLayer = true; board.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.94, alpha: 1).cgColor
                for (index, height) in [22.0, 28.0, 32.0].enumerated() {
                    let view = MenuBarLimitsContent(frame: NSRect(x: 16, y: 12 + Double(index) * 42, width: 170, height: height))
                    view.entries = MenuBarLimitEntry.make(snapshots: data, providers: ProviderID.allCases, preferences: .init(enabled: true), now: now)
                    view.showsResetCountdown = true
                    view.frame.size.width = view.preferredWidth
                    board.addSubview(view)
                    let saved = MenuBarLimitsContent(frame: NSRect(x: 230, y: view.frame.minY, width: 192, height: height))
                    saved.showsResetCountdown = true
                    saved.entries = MenuBarLimitEntry.make(snapshots: index == 2 ? [] : [try snapshot(.claude, used: 0), data[1]], providers: ProviderID.allCases,
                                                          preferences: .init(enabled: true, period: index == 0 ? .fiveHour : .weekly),
                                                          now: now.addingTimeInterval(index == 2 ? 3600 : 901))
                    saved.frame.size.width = saved.preferredWidth
                    board.addSubview(saved)
                    let hidden = MenuBarLimitsContent(frame: NSRect(x: 430, y: view.frame.minY, width: 170, height: height))
                    hidden.entries = view.entries; hidden.showsResetCountdown = false
                    hidden.frame.size.width = hidden.preferredWidth
                    board.addSubview(hidden)
                    let rings = MenuBarLimitsContent(frame: NSRect(x: 650, y: view.frame.minY, width: 68, height: height))
                    rings.style = .rings
                    rings.entries = index == 2 ? [MenuBarLimitEntry.make(snapshots: [], providers: [.claude], preferences: .init(), now: now)[0]] : (index == 1 ? saved.entries : view.entries)
                    board.addSubview(rings)
                    if language == "ru", dark, index == 2 {
                        let preview = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 136))
                        preview.appearance = board.appearance
                        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                        let indicator = MenuBarLimitsContent(frame: NSRect(x: 12, y: 76, width: 192, height: 32))
                        indicator.entries = view.entries
                        indicator.showsResetCountdown = true
                        indicator.iconColor = .provider
                        indicator.frame.size.width = indicator.preferredWidth
                        preview.addSubview(indicator)
                        let hidden = MenuBarLimitsContent(frame: NSRect(x: 12, y: 20, width: 192, height: 32))
                        hidden.entries = indicator.entries; hidden.iconColor = .provider; hidden.showsResetCountdown = false
                        hidden.frame.size.width = hidden.preferredWidth; preview.addSubview(hidden)
                        for (title, y) in [("С временем до сброса", 111.0), ("Без времени до сброса", 55.0)] {
                            let label = NSTextField(labelWithString: title)
                            label.font = .systemFont(ofSize: 11); label.textColor = .labelColor
                            label.frame = NSRect(x: 12, y: y, width: 200, height: 16); preview.addSubview(label)
                        }
                        let label = NSTextField(labelWithString: "Нативный вид · примерные данные")
                        label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
                        label.frame = NSRect(x: 12, y: 4, width: 200, height: 14); preview.addSubview(label)
                        let previewWindow = NSWindow(contentRect: preview.frame, styleMask: .borderless, backing: .buffered, defer: false)
                        previewWindow.contentView = preview; preview.layoutSubtreeIfNeeded()
                        let image = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
                        preview.cacheDisplay(in: preview.bounds, to: image)
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preview.png"))
                        previewWindow.contentView = nil
                    }
                }
                let window = NSWindow(contentRect: board.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = board
                board.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(board.bitmapImageRepForCachingDisplay(in: board.bounds))
                board.cacheDisplay(in: board.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("limits-\(language)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
    }

    @MainActor func testRenderLimitsSettings() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMITS_STATUS"] else { throw XCTSkip("Opt-in native settings rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Lunavect.LimitsRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let oldLanguage = L10n.defaults.object(forKey: "languageCode")
        defer { defaults.removePersistentDomain(forName: suite); L10n.defaults.set(oldLanguage, forKey: "languageCode") }
        let appearance = MenuBarAppearance(defaults: defaults)
        appearance.limits.enabled = true
        let data = try [snapshot(.claude, resetAfter: 36 * 3600, at: .now), snapshot(.codex, used: 63, resetAfter: 5 * 86400, at: .now)]
        for language in ["en", "ru", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for (style, showsCountdown) in [(MenuBarLimitsStyle.bars, true), (.bars, false), (.rings, true)] {
            appearance.limits.style = style
            appearance.limits.showsResetCountdown = showsCountdown
            let host = NSHostingView(rootView: MenuBarLimitsSettings(appearance: appearance, snapshots: data, providers: ProviderID.allCases)
                .padding(20).frame(width: 570).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            XCTAssertLessThanOrEqual(host.frame.width, 571)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let suffix = style == .bars ? (showsCountdown ? "" : "-no-time") : "-rings"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("settings-\(language)\(suffix).png"))
            window.contentView = nil
            }
        }
    }

    @MainActor func testRenderLimitsPopover() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LIMITS_STATUS"] else { throw XCTSkip("Opt-in native limits popover rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = L10n.defaults.object(forKey: "languageCode")
        defer { L10n.defaults.set(old, forKey: "languageCode") }
        let data = try [snapshot(.claude, used: 28, resetAfter: 36 * 3600), snapshot(.codex, used: 63, resetAfter: 5 * 86400)]
        for language in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            L10n.defaults.set(language, forKey: "languageCode")
            for stale in [false, true] {
                let model = MenuBarLimitsPanelModel()
                model.entries = MenuBarLimitEntry.make(snapshots: data, providers: ProviderID.allCases, preferences: .init(enabled: true), now: now.addingTimeInterval(stale ? 901 : 0))
                let host = NSHostingView(rootView: MenuBarLimitsPopover(model: model, onPeriod: { _ in }, onRefresh: {}, onMenu: {}, onSettings: {})
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                XCTAssertEqual(host.frame.width, 340, accuracy: 1)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("panel-\(language)-\(stale ? "saved" : "fresh").png"))
                window.contentView = nil
            }
        }
    }
}
