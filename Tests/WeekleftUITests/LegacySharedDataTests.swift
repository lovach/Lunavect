import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// B-06: leftovers of the App Group migration in a synthetic home directory.
final class LegacySharedDataTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LegacySharedDataTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    func testFindsOnlyMigrationLeftoversAndMovesThemToTheTrash() throws {
        let home = try home(), group = "TEAM.com.lunavect.shared"
        let current = home.appendingPathComponent("Library/Group Containers/\(group)/Weekleft", isDirectory: true)
        let old = home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Weekleft", isDirectory: true)
        for url in [current.appendingPathComponent("snapshot.json"), old.appendingPathComponent("activity.json"), old.appendingPathComponent("snapshot.json"),
                    support.appendingPathComponent("snapshot.json"), support.appendingPathComponent("activity-details.json"),
                    support.appendingPathComponent("Sessions/records.json")] { try file(url) }
        // A migration symlink is not a copy.
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("activity.json"), withDestinationURL: current.appendingPathComponent("snapshot.json"))
        let found = LegacySharedData.find(group: group, current: current, home: home)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["Weekleft", "snapshot.json"])
        XCTAssertFalse(found.contains { $0.path.hasPrefix(current.path) })
        let trash = home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let remaining = LegacySharedData.moveToTrash(found) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(LegacySharedData.find(group: group, current: current, home: home), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("activity-details.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("snapshot.json").path))
        let failing = LegacySharedData.moveToTrash([support.appendingPathComponent("activity-details.json")]) { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(failing.count, 1)
    }

    func testBuildsWithoutADifferentGroupHaveNoLeftovers() throws {
        let home = try home()
        let support = home.appendingPathComponent("Library/Application Support/Weekleft", isDirectory: true)
        try file(support.appendingPathComponent("snapshot.json"))
        try file(home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft/activity.json"))
        // No App Group: Application Support is the live shared location.
        XCTAssertEqual(LegacySharedData.find(group: nil, current: support, home: home), [])
        // A development build still using the previous group keeps it.
        let devCurrent = home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft", isDirectory: true)
        XCTAssertEqual(LegacySharedData.find(group: "group.com.weekleft.shared", current: devCurrent, home: home).map(\.lastPathComponent), ["snapshot.json"])
    }
}
