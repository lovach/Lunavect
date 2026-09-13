import XCTest
import SwiftUI
import AppKit
@testable import Weekleft
import WeekleftCore

final class ConnectionSetupRenderingTests: XCTestCase {
    @MainActor func testRenderConnectionSteps() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CONNECTION"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_CONNECTION to inspect native connection steps")
        }
        try LegacyRenderIsolation.require()
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = try LegacyRenderFixture(snapshots: [])
        defer { preview.stop() }
        let store = preview.environment.store, sessions = preview.environment.sessions
        store.snapshots = []
        for provider in ProviderID.allCases {
            for step in 0...3 {
                let host = NSHostingView(rootView: ConnectionSetupView(provider: provider, store: store, sessions: sessions, initialStep: step))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = CGRect(x: 0, y: 0, width: 600, height: 580)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(provider.rawValue)-\(step).png"))
                window.contentView = nil
            }
        }
    }
}

extension ConnectionSetupRenderingTests {
    @MainActor func testRenderLocalRecoveryStatesWithoutClients() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LOCAL_RECOVERY"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_LOCAL_RECOVERY to inspect isolated local recovery states")
        }
        try LegacyRenderIsolation.require()
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures: [(String, ClientConnection.LocalState)] = [
            ("partial-connect", .init(statusLine: .ready, hooks: .absent)),
            ("partial-disconnect", .init(statusLine: .absent, hooks: .ready)),
            ("unreadable", .init(statusLine: .unavailable, hooks: .unavailable)),
            ("missing-hud-backup", .init(statusLine: .partial, hooks: .ready))
        ]
        let language = try LegacyRenderIsolation.language()
        for (name, state) in fixtures {
            try LegacyRenderIsolation.render(ConnectionLocalStateView(state: state).padding(24),
                size: CGSize(width: 520, height: 150),
                to: directory.appendingPathComponent("\(name)-\(language).png"))
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            ConnectionClientPathView(path: .constant("/missing/selected/codex"))
            InterfaceLabel(SessionOpeningError.unavailableConfiguredCodex.localizedDescription, .info)
                .foregroundStyle(.orange).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
        try LegacyRenderIsolation.render(view, size: CGSize(width: 600, height: 180),
            to: directory.appendingPathComponent("selected-codex-path-\(language).png"))
    }
}

final class ConnectionViewTaskCancellationTests: XCTestCase {
    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
    @MainActor func testClosingViewCancelsOwnedActionAndSuppressesItsResult() async throws {
        let actions = ConnectionViewTasks()
        actions.activate()
        var started = false, cancelled = false, published = false
        actions.start {
            started = true
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true }
            guard !Task.isCancelled else { return }
            published = true
        }
        try await eventually { started }
        actions.cancel()
        try await eventually { cancelled }
        XCTAssertFalse(published)
    }
    @MainActor func testOldCancelledActionCannotClearNewTaskHandle() async throws {
        let actions = ConnectionViewTasks()
        actions.activate()
        var firstResume: CheckedContinuation<Void, Never>?
        var secondResume: CheckedContinuation<Void, Never>?
        var firstFinished = false, thirdStarted = false
        actions.start {
            await withCheckedContinuation { firstResume = $0 }
            firstFinished = true
        }
        try await eventually { firstResume != nil }
        actions.cancel()
        actions.start { await withCheckedContinuation { secondResume = $0 } }
        try await eventually { secondResume != nil }
        firstResume?.resume(); firstResume = nil
        try await eventually { firstFinished }
        actions.start { thirdStarted = true }
        await Task.yield()
        XCTAssertFalse(thirdStarted, "The new action remains owned while the cancelled predecessor finishes")
        actions.cancel(); secondResume?.resume(); secondResume = nil
    }
    @MainActor func testLateNotificationCannotRestartWorkAfterViewDisappears() async throws {
        let actions = ConnectionViewTasks()
        var starts = 0
        actions.start { starts += 1 }
        await Task.yield()
        XCTAssertEqual(starts, 0)
        actions.activate(); actions.deactivate()
        actions.start { starts += 1 }
        await Task.yield()
        XCTAssertEqual(starts, 0)
        actions.activate()
        actions.start { starts += 1 }
        try await eventually { starts == 1 }
        XCTAssertEqual(starts, 1)
        actions.deactivate()
    }
    @MainActor func testCancellationBeforeSchedulingDoesNotStartClientWork() async {
        let actions = ConnectionViewTasks()
        actions.activate()
        var started = false
        actions.start { started = true }
        actions.cancel()
        await Task.yield()
        XCTAssertFalse(started)
    }
}

extension ConnectionSetupRenderingTests {
    @MainActor func testRenderUnsupportedDiagnosticsWithoutClients() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_CAPABILITY"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_CAPABILITY to inspect isolated unsupported-client diagnostics")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for reason in [ClientIntegrationIssue.Reason.unsupportedResponse, .unsupportedOperation, .clientPathUnavailable] {
            let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                snapshot: nil, sessionIssue: nil, sourceIssue: .init(provider: .codex, capability: .rateLimits, reason: reason))
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                ConnectionDiagnosticSummary(result: diagnostic)
                if let repair = diagnostic.repair { Button(L(repair.title)) {} }
            }.padding(24).frame(width: 620, height: 235, alignment: .leading).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 620, height: 235)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(reason.rawValue + ".png"))
            window.contentView = nil
        }
    }
}
