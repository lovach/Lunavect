import XCTest
import WeekleftCore
@testable import Weekleft

final class SessionStoreRecoveryTests: XCTestCase {
    private var savedArrangement: SessionArrangement {
        var value = SessionArrangement()
        value.order = ["codex:a", "codex:b", "claude:c"]
        value.pinned = ["claude:c"]
        return value
    }
    @MainActor private func withDirectory(_ body: (URL, UserDefaults) throws -> Void) throws {
        let suite = "Lunavect.SessionStoreRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory, defaults)
    }
    @MainActor func testUnreadableVisibilityReportsActualFailureAndRecoversOnNextAction() throws {
        try withDirectory { directory, defaults in
            let file = directory.appendingPathComponent("hidden-sessions.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let store = SessionStore(directory: directory, defaults: defaults, isolated: true)
            let row = AgentSession(provider: .claude, sessionID: "fixture", title: "Fixture", cwd: "", phase: .ready, updatedAt: Date(), observedAt: Date())
            XCTAssertEqual(store.connectionMessage, SessionVisibilityError.unreadable.localizedDescription)
            XCTAssertThrowsError(try store.hide(row)) { XCTAssertEqual($0 as? SessionVisibilityError, .unreadable) }
            try FileManager.default.removeItem(at: file)
            try Data(#"{"sessions":{}}"#.utf8).write(to: file)
            store.acceptSessions([row])
            try store.hide(row)
            XCTAssertEqual(store.hiddenCount, 1)
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertNil(store.connectionMessage)
        }
    }
    func testShortcutDisplayUsesPhysicalKeyAndNamedFunctionKeyRegardlessOfSavedLayout() {
        XCTAssertEqual(PanelShortcut(keyCode: 37, modifiers: 256, label: "⌘Д").displayLabel, "⌘L")
        XCTAssertEqual(PanelShortcut(keyCode: 37, modifiers: 256, label: "⌘L").displayLabel, "⌘L")
        XCTAssertEqual(PanelShortcut(keyCode: 122, modifiers: 256, label: "private-use-character").displayLabel, "⌘F1")
        XCTAssertEqual(PanelShortcut(keyCode: 126, modifiers: 256, label: "up").displayLabel, "⌘↑")
    }
    @MainActor func testCorruptInitialArrangementReportsRecoveryAndPinPreservesBackup() throws {
        try withDirectory { directory, defaults in
            let file = directory.appendingPathComponent("arrangement.json")
            let original = Data(#"{"order":["codex:old"],"pinned":"invalid"}"#.utf8)
            try original.write(to: file)

            let store = SessionStore(directory: directory, defaults: defaults)
            XCTAssertEqual(store.arrangement, SessionArrangement())
            XCTAssertEqual(store.connectionMessage, L("Повреждённый порядок сессий сохранён отдельно. Закрепление и перемещение снова доступны."))
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("arrangement.json.corrupt-") }
            XCTAssertEqual(backups.count, 1)
            let backup = try XCTUnwrap(backups.first)
            XCTAssertEqual(try Data(contentsOf: backup), original)

            try store.setPinned("codex:new", true)
            XCTAssertEqual(store.arrangement.pinned, ["codex:new"])
            XCTAssertEqual(try SessionArrangement.loadRecovering(from: file).value, store.arrangement)
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }
    @MainActor func testInitialReadErrorBlocksSavingAfterPermissionsRestoreUntilReload() throws {
        try withDirectory { directory, defaults in
            let file = directory.appendingPathComponent("arrangement.json")
            try savedArrangement.save(to: file)
            let original = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertThrowsError(try Data(contentsOf: file), "The fixture must actually deny the initial read")

            let store = SessionStore(directory: directory, defaults: defaults)
            XCTAssertEqual(store.arrangement, SessionArrangement())
            XCTAssertEqual(store.connectionMessage, L("Не удалось прочитать порядок сессий. Исходный файл сохранён; закрепление и перемещение отключены до перезапуска."))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try store.setPinned("codex:new", true))
            XCTAssertThrowsError(try store.move("codex:b", before: "codex:a", visible: savedArrangement.order))
            XCTAssertEqual(store.arrangement, SessionArrangement())
            XCTAssertEqual(try Data(contentsOf: file), original)

            let reloaded = SessionStore(directory: directory, defaults: defaults)
            XCTAssertEqual(reloaded.arrangement, savedArrangement)
            try reloaded.setPinned("codex:new", true)
            XCTAssertEqual(reloaded.arrangement.order, savedArrangement.order)
            XCTAssertEqual(reloaded.arrangement.pinned, ["claude:c", "codex:new"])
        }
    }
    @MainActor func testCorruptionAfterLoadStopsMoveAndPreservesMemoryBeforeExplicitRetry() throws {
        try withDirectory { directory, defaults in
            let file = directory.appendingPathComponent("arrangement.json")
            try savedArrangement.save(to: file)
            let store = SessionStore(directory: directory, defaults: defaults)
            let corrupt = Data("{incomplete external write".utf8)
            try corrupt.write(to: file)

            var backup: URL?
            XCTAssertThrowsError(try store.move("codex:b", before: "codex:a", visible: savedArrangement.order)) { error in
                backup = (error as? SessionArrangementRecoveryError)?.backupURL
                XCTAssertNotNil(backup)
            }
            XCTAssertEqual(store.arrangement, savedArrangement)
            XCTAssertEqual(store.connectionMessage, L("Повреждённый порядок сессий сохранён отдельно. Повторите закрепление или перемещение."))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), corrupt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

            try store.move("codex:b", before: "codex:a", visible: savedArrangement.order)
            XCTAssertEqual(store.arrangement.order, ["codex:b", "codex:a", "claude:c"])
            XCTAssertEqual(store.arrangement.pinned, savedArrangement.pinned)
            XCTAssertEqual(try SessionArrangement.loadRecovering(from: file).value, store.arrangement)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), corrupt)
        }
    }
}
