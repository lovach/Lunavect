import XCTest
import AppKit
import UserNotifications
import WeekleftCore
@testable import Weekleft

final class HiddenSessionUndoTests: XCTestCase {
    @MainActor func testBurstOfCompletionsSharesOneSoundWithoutMutingAttention() throws {
        let suite = "Lunavect.SoundBurst." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var played: [SessionNoticeKind] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true
        var rows = (0..<5).map { index in
            AgentSession(provider: index % 2 == 0 ? .codex : .claude, sessionID: "burst-\(index)", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        }
        features.observe(rows)
        now += 1
        for i in [0, 1] { rows[i].phase = .ready; rows[i].observedAt = now }
        features.observe(rows)
        XCTAssertEqual(played, [.completed], "Simultaneous completions must not restart the cue")
        now += 1; rows[2].phase = .ready; rows[2].observedAt = now
        features.observe(rows)
        XCTAssertEqual(played, [.completed], "The next poll shares the same cooldown")
        rows[3].phase = .permission; rows[3].observedAt = now
        features.observe(rows)
        XCTAssertEqual(played, [.completed, .permission])
        now += 4; rows[4].phase = .ready; rows[4].observedAt = now
        features.observe(rows)
        XCTAssertEqual(played, [.completed, .permission, .completed])
        features.testNotification()
        XCTAssertEqual(played, [.completed, .permission, .completed, .completed], "An explicit test remains audible during the cooldown")
    }
    @MainActor func testCompletionBurstKeepsEveryBannerAndOnlyOneFallbackSound() async throws {
        let suite = "Lunavect.BannerBurst." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var played: [SessionNoticeKind] = []
        var requests: [UNNotificationRequest] = []
        let fallback = expectation(description: "Only the first failed banner plays the fallback")
        fallback.assertForOverFulfill = true
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: {
            played.append($0); fallback.fulfill()
        }, sendBanner: { request, callback in
            requests.append(request)
            callback(CocoaError(.fileWriteUnknown))
        })
        features.banners = true; features.sounds = true; features.notificationAllowed = true
        var rows = (0..<3).map { index in
            AgentSession(provider: .codex, sessionID: "banner-\(index)", title: "Example \(index)", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        }
        features.observe(rows)
        now += 1
        for i in rows.indices { rows[i].phase = .ready; rows[i].observedAt = now }
        features.observe(rows)
        XCTAssertEqual(requests.count, rows.count)
        XCTAssertEqual(requests.compactMap { $0.content.userInfo["sessionID"] as? String }, rows.map(\.id))
        XCTAssertEqual(requests.filter { $0.content.sound != nil }.count, 1)
        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertEqual(played, [.completed])
    }
    @MainActor func testSoundOnlyCompletionPlaysOnceWithoutNotificationPermission() throws {
        let suite = "Lunavect.SoundOnly." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var played: [SessionNoticeKind] = []
        let features = AppFeatures(defaults: defaults, now: { now }, playSound: { played.append($0) })
        features.sounds = true
        var row = AgentSession(provider: .codex, sessionID: "sound-test", title: "Example", cwd: "", phase: .running, updatedAt: now, observedAt: now)
        features.observe([row]); XCTAssertTrue(played.isEmpty)
        now += 1; row.phase = .ready; row.observedAt = now
        features.observe([row]); features.observe([row])
        XCTAssertEqual(played, [.completed])
        XCTAssertFalse(features.banners)
        XCTAssertEqual(features.notificationAuthorization, .notDetermined)
        features.sounds = false; features.testNotification()
        XCTAssertEqual(played, [.completed])
        features.previewCompletionSound()
        XCTAssertEqual(played, [.completed, .completed])
        XCTAssertFalse(features.sounds, "Preview must not change the user's channel settings")
    }
    @MainActor func testCompletionCueIsBundledPCMAndCanBeLoaded() throws {
        let url = try XCTUnwrap(NotificationAudio.completionURL)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertNotNil(NSSound(contentsOf: url, byReference: false))
    }
    @MainActor func testNotificationChannelsStartDisabledAndPersistIndependently() {
        let suite = "Lunavect.NoticeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppFeatures(defaults: defaults)
        XCTAssertFalse(settings.banners)
        XCTAssertFalse(settings.sounds)
        settings.sounds = true
        let restored = AppFeatures(defaults: defaults)
        XCTAssertTrue(restored.sounds)
        XCTAssertFalse(restored.banners)
    }
    @MainActor func testNewTaskReturnsToStoreAndClearsUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let t = Date()
        var row = AgentSession(provider: .claude, sessionID: "new-task", title: "Test", cwd: "", phase: .ready,
                               updatedAt: t, observedAt: t, evidence: .hook)
        row.turnStartedAt = t.addingTimeInterval(-60)
        store.acceptSessions([row]); try store.hide(row)
        row.phase = .running; row.observedAt = t.addingTimeInterval(5)
        row.updatedAt = row.observedAt; row.turnStartedAt = row.observedAt
        store.acceptSessions([row], now: row.observedAt)
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertEqual(store.sessions.map(\.id), [row.id])
        XCTAssertNil(store.lastHidden)
    }
    @MainActor func testUndoExpiresButHiddenSessionRemainsRestorable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, undoDelay: .milliseconds(30))
        let row = AgentSession(provider: .codex, sessionID: "undo-test", title: "Test", cwd: "", phase: .running, updatedAt: .now, observedAt: .now)
        store.sessions = [row]
        try store.hide(row)
        XCTAssertEqual(store.lastHidden?.id, row.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.lastHidden)
        XCTAssertEqual(store.hiddenCount, 1)
        XCTAssertTrue(store.sessions.isEmpty)
        try store.restore(row.id)
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertEqual(store.sessions.map(\.id), [row.id])
    }
}
