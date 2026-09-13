import XCTest
@testable import WeekleftCore

final class SessionConvenienceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ id: String, _ phase: SessionPhase, seconds: Double = 0) -> AgentSession {
        AgentSession(provider: .codex, sessionID: id, title: id, cwd: "", phase: phase,
                     updatedAt: now.addingTimeInterval(seconds), observedAt: now.addingTimeInterval(seconds), evidence: .hook)
    }
    func testNoticesOnlyOnNewTransitions() {
        var tracker = SessionNoticeTracker()
        XCTAssertTrue(tracker.update([row("a", .running), row("old", .ready)], now: now).isEmpty)
        XCTAssertEqual(tracker.update([row("a", .permission, seconds: 1)], now: now.addingTimeInterval(1)).map(\.kind), [.permission])
        XCTAssertTrue(tracker.update([row("a", .permission, seconds: 2)], now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(tracker.update([row("a", .ready, seconds: 3)], now: now.addingTimeInterval(3)).map(\.kind), [.completed])
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 4)], now: now.addingTimeInterval(4)).isEmpty)
        _ = tracker.update([row("a", .running, seconds: 5)], now: now.addingTimeInterval(5))
        XCTAssertEqual(tracker.update([row("a", .input, seconds: 6)], now: now.addingTimeInterval(6)).map(\.kind), [.input])
    }
    func testNoNoticesOnRediscoveryStaleOrLateEvents() {
        var tracker = SessionNoticeTracker()
        _ = tracker.update([row("a", .running)], now: now)
        XCTAssertTrue(tracker.update([], now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .running, seconds: 2)], now: now.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: -10)], now: now.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 1)], now: now.addingTimeInterval(700)).isEmpty)
        XCTAssertTrue(tracker.update([row("a", .ready, seconds: 701)], now: now.addingTimeInterval(701)).isEmpty)
    }
    func testLongRunningWorkStillNotifiesWhileMonitoringContinues() {
        var tracker = SessionNoticeTracker()
        _ = tracker.update([row("a", .running)], now: now)
        for seconds in stride(from: 60, through: 1200, by: 60) {
            XCTAssertTrue(tracker.update([row("a", .running)], now: now.addingTimeInterval(Double(seconds))).isEmpty)
        }
        XCTAssertEqual(tracker.update([row("a", .ready, seconds: 1201)], now: now.addingTimeInterval(1201)).map(\.kind), [.completed])
    }
    func testOldWidgetPreferencesPreserveSavedValues() throws {
        let data = Data(#"{"showFiveHour":true,"transparency":0.7,"subscriptionDates":{"claude":"2026-10-02"}}"#.utf8)
        let value = try JSONDecoder().decode(WidgetPreferences.self, from: data)
        XCTAssertFalse(value.transparentBackground)
        XCTAssertTrue(value.showFiveHour)
        XCTAssertEqual(value.transparency, 0.7)
        XCTAssertEqual(value.subscriptionDates["claude"], "2026-10-02")
    }
    func testExperimentalBackgroundRequiresOptInAndRetainsExplicitChoice() throws {
        XCTAssertFalse(WidgetPreferences().transparentBackground)
        for enabled in [false, true] {
            var preferences = WidgetPreferences()
            preferences.transparentBackground = enabled
            let decoded = try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded.transparentBackground, enabled)
        }
    }
    func testMovingFirstRowAfterLastAndPinsStaySeparate() {
        let rows = [row("a", .running), row("b", .ready), row("c", .permission)]
        var order = SessionArrangement()
        order.move(rows[0].id, before: rows[2].id, after: true, visible: rows.map(\.id))
        XCTAssertEqual(order.arranged(rows).map(\.sessionID), ["b", "c", "a"])
        order.pinned.insert(rows[1].id)
        let saved = order
        order.move(rows[0].id, before: rows[1].id, visible: rows.map(\.id))
        XCTAssertEqual(order, saved)
    }
    func testOrderingAndPinsPersistWithoutChangingSessions() throws {
        let rows = [row("a", .running), row("b", .ready), row("c", .permission)]
        var order = SessionArrangement()
        order.move(rows[2].id, before: rows[0].id, visible: rows.map(\.id))
        XCTAssertEqual(order.arranged(rows).map(\.sessionID), ["c", "a", "b"])
        order.pinned.insert(rows[1].id)
        let restored = try JSONDecoder().decode(SessionArrangement.self, from: JSONEncoder().encode(order))
        XCTAssertEqual(restored.arranged(rows).map(\.sessionID), ["b", "c", "a"])
        XCTAssertEqual(restored.arranged([rows[0], rows[2]]).map(\.sessionID), ["c", "a"])
        order.move("codex:missing", before: rows[0].id, visible: rows.map(\.id))
        XCTAssertEqual(order, restored)
        XCTAssertEqual(rows[0].phase, .running)
    }
}

final class SessionArrangementRecoveryTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("arrangement.json")
    }
    private var arrangement: SessionArrangement {
        var value = SessionArrangement()
        value.order = ["codex:older", "claude:active", "codex:hidden"]
        value.pinned = ["claude:active"]
        return value
    }
    func testMissingAndValidArrangementRetainPinsAndHiddenOrder() throws {
        let url = try file()
        let missing = try SessionArrangement.loadRecovering(from: url)
        XCTAssertEqual(missing.value, SessionArrangement())
        XCTAssertNil(missing.backupURL)
        try arrangement.save(to: url)
        let saved = try SessionArrangement.loadRecovering(from: url)
        XCTAssertEqual(saved.value, arrangement)
        XCTAssertNil(saved.backupURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
    func testCorruptLoadPreservesExactPrivateRecoveryAndAllowsExplicitSave() throws {
        let url = try file(), original = Data(#"{"order":["codex:hidden"],"pinned":false}"#.utf8)
        try original.write(to: url)
        let recovered = try SessionArrangement.loadRecovering(from: url)
        let backup = try XCTUnwrap(recovered.backupURL)
        XCTAssertEqual(recovered.value, SessionArrangement())
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        try arrangement.save(to: url)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, arrangement)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
    func testCorruptionAfterSuccessfulLoadStopsSaveAndReportsRecovery() throws {
        let url = try file()
        try arrangement.save(to: url)
        var next = try SessionArrangement.loadRecovering(from: url).value
        next.pinned.insert("codex:older")
        let corrupt = Data("{unfinished external write".utf8)
        try corrupt.write(to: url)
        var backup: URL?
        XCTAssertThrowsError(try next.save(to: url)) { error in
            backup = (error as? SessionArrangementRecoveryError)?.backupURL
            XCTAssertNotNil(backup)
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // The failed call never persisted the requested pin; a later explicit
        // retry can use the last valid in-memory order after showing recovery.
        try next.save(to: url)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, next)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), corrupt)
    }
    func testUnreadableFileFailsLoadAndSaveWithoutReplacingOriginal() throws {
        let url = try file()
        try arrangement.save(to: url)
        let original = try Data(contentsOf: url)
        let denied: (URL) throws -> Data = { _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertThrowsError(try SessionArrangement.loadRecovering(from: url, read: denied))
        XCTAssertThrowsError(try SessionArrangement().save(to: url, read: denied))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["arrangement.json"])
    }
    func testReadOnlyValidFileLoadsButPinCannotReplaceIt() throws {
        let url = try file()
        try arrangement.save(to: url)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, arrangement)
        var next = arrangement
        next.pinned.insert("codex:older")
        XCTAssertThrowsError(try next.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o400)
    }
    func testReadOnlyCorruptionIsNotMovedOrOverwritten() throws {
        let url = try file(), original = Data("{broken".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertThrowsError(try SessionArrangement.loadRecovering(from: url))
        XCTAssertThrowsError(try arrangement.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["arrangement.json"])
    }
    func testUnwritableRecoveryDirectoryPreservesCorruptOriginal() throws {
        let url = try file(), original = Data("invalid arrangement".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.deletingLastPathComponent().path)
        XCTAssertThrowsError(try SessionArrangement.loadRecovering(from: url))
        XCTAssertThrowsError(try arrangement.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["arrangement.json"])
    }
    func testSaveKeepsSymlinkAndUpdatesItsValidTarget() throws {
        let url = try file(), link = url.deletingLastPathComponent().appendingPathComponent("linked-arrangement.json")
        try arrangement.save(to: url)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        var next = arrangement
        next.order.reverse()
        try next.save(to: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, next)
    }
    func testCorruptSymlinkRecoveryLeavesLinkAndKeepsWritingToTarget() throws {
        let url = try file(), link = url.deletingLastPathComponent().appendingPathComponent("linked-arrangement.json")
        let original = Data("{broken target".utf8)
        try original.write(to: url)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

        let recovered = try SessionArrangement.loadRecovering(from: link)
        let backup = try XCTUnwrap(recovered.backupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try arrangement.save(to: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, arrangement)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
    func testStandaloneSaveFollowsRelativeDanglingSymlinkChain() throws {
        let url = try file(), directory = url.deletingLastPathComponent()
        let first = directory.appendingPathComponent("first"), second = directory.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "arrangement.json")
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: first).value, SessionArrangement())
        try arrangement.save(to: first)
        XCTAssertEqual(try SessionArrangement.loadRecovering(from: url).value, arrangement)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.path), "second")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: second.path), "arrangement.json")
    }
    func testSymlinkCycleFailsWithoutReplacingAnyLink() throws {
        let first = try file(), second = first.deletingLastPathComponent().appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "arrangement.json")
        XCTAssertThrowsError(try SessionArrangement.loadRecovering(from: first))
        XCTAssertThrowsError(try arrangement.save(to: first))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.path), "second")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: second.path), "arrangement.json")
    }
    func testSymlinkTraversalBudgetStopsLongChainWithoutCreatingTarget() throws {
        let url = try file(), directory = url.deletingLastPathComponent()
        for index in 0..<41 {
            let destination = index == 40 ? "arrangement.json" : "link-\(index + 1)"
            try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link-\(index)").path, withDestinationPath: destination)
        }
        let first = directory.appendingPathComponent("link-0")
        XCTAssertThrowsError(try arrangement.save(to: first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 41)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.path), "link-1")
    }
}
