import AppKit
import Foundation
import SwiftUI
import XCTest
import WeekleftCore
@testable import Weekleft

/// Process-only language and a checked sandbox are prerequisites, not best-effort defaults.
enum LegacyRenderIsolation {
    static let now = Date(timeIntervalSince1970: 1_789_206_960)

    static func language(environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        #if DEBUG
        guard env["LUNAVECT_NATIVE_RENDER_ISOLATION"] == "passed",
              let language = env["LUNAVECT_PREVIEW_LANGUAGE"],
              ["ru", "de", "en", "es", "fr", "zh-Hans"].contains(language),
              let forbidden = env["LUNAVECT_NATIVE_RENDER_FORBIDDEN"],
              FileManager.default.fileExists(atPath: forbidden),
              !FileManager.default.isReadableFile(atPath: forbidden), L10n.selection == language else {
            throw XCTSkip("Legacy export requires the sandbox launcher and a process-only language")
        }
        return language
        #else
        throw XCTSkip("The language override requires a Debug test build")
        #endif
    }

    @MainActor static func require() throws {
        _ = try language()
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize, to url: URL, scheme: ColorScheme = .dark) throws {
        try require()
        var environment: [String: String] = [:]
        let content = NativeRenderEnvironmentCapture(content: view) { environment = $0 }
            .frame(width: size.width, height: size.height)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: try language()))
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(size.width * 2)); XCTAssertEqual(image.height, Int(size.height * 2))
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        if let path = ProcessInfo.processInfo.environment["LUNAVECT_NATIVE_RENDER_ENVIRONMENT"] {
            try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Uses the production preview composition instead of maintaining a second set of services.
@MainActor final class LegacyRenderFixture {
    let presentation: PresentationFixture
    let environment: AppEnvironment

    init(snapshots: [UsageSnapshot]? = nil, preferences: WidgetPreferences? = nil, history: ActivityHistory? = nil, now: Date = LegacyRenderIsolation.now) throws {
        try LegacyRenderIsolation.require()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        presentation = try PresentationFixture(now: now, calendar: calendar)
        environment = try AppEnvironment.preview(rows: presentation.sessions(), now: presentation.now,
            languageCode: LegacyRenderIsolation.language(),
            state: SharedState(snapshots: snapshots ?? presentation.snapshots, preferences: preferences ?? presentation.preferences),
            activityHistory: history ?? presentation.history, activityDetails: presentation.details)
    }

    func stop() { environment.stop() }

    func settings() -> some View {
        SettingsView(store: environment.store, menuBarAppearance: environment.menuBarAppearance, sessions: environment.sessions,
            updates: environment.updates, awake: environment.awake, features: environment.features, language: environment.language)
            .defaultAppStorage(environment.defaults)
    }

    func sessions() -> some View {
        SessionsView(store: environment.sessions, updates: environment.updates, awake: environment.awake, isPreview: environment.isPreview, onSettings: {})
            .defaultAppStorage(environment.defaults)
    }
}
