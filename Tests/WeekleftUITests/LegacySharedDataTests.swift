import XCTest
import SwiftUI
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
    /// Copies are offered only after a week without writes: evaluate a month later.
    private let later = Date().addingTimeInterval(30 * 86400)
    private func age(_ url: URL, days: Double, now: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
    }

    /// R3-07: the previous group `group.com.weekleft.shared` is also the live
    /// container of every non-Distribution build (check.sh, renders, local runs), and
    /// Application Support is live for a build without an App Group (`swift run`).
    /// A copy written within the last week may be in use and is never offered.
    func testCopiesInUseByAnotherBuildAreNeverOffered() throws {
        let home = try home(), group = "TEAM.com.lunavect.shared", now = Date()
        let current = home.appendingPathComponent("Library/Group Containers/\(group)/Weekleft", isDirectory: true)
        let old = home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Weekleft", isDirectory: true)
        let devSnapshot = old.appendingPathComponent("snapshot.json"), selection = old.appendingPathComponent("ActivitySelection/widget.json")
        let supportSnapshot = support.appendingPathComponent("snapshot.json")
        for url in [current.appendingPathComponent("snapshot.json"), devSnapshot, selection, supportSnapshot] { try file(url) }
        for url in [devSnapshot, supportSnapshot, old, support, old.appendingPathComponent("ActivitySelection")] { try age(url, days: 40, now: now) }
        try age(selection, days: 1, now: now) // a development build wrote its widget selection yesterday
        XCTAssertEqual(LegacySharedData.find(group: group, current: current, home: home, now: now).map(\.path), [supportSnapshot.path],
                       "The previous group container is in use by a development build")
        try age(selection, days: 40, now: now)
        try age(supportSnapshot, days: 2, now: now)
        XCTAssertEqual(LegacySharedData.find(group: group, current: current, home: home, now: now).map(\.path), [old.path],
                       "A recently written Application Support copy may belong to a build without an App Group")
        try age(supportSnapshot, days: 40, now: now)
        XCTAssertEqual(Set(LegacySharedData.find(group: group, current: current, home: home, now: now).map(\.path)), [old.path, supportSnapshot.path])
        // The running build's own container is never a candidate, whatever its age.
        XCTAssertFalse(LegacySharedData.find(group: group, current: current, home: home, now: now).contains { $0.path.hasPrefix(current.deletingLastPathComponent().path) })
        let details = LegacySharedData.details(of: [supportSnapshot])
        XCTAssertEqual(details.first?.url, supportSnapshot)
        XCTAssertEqual(details.first?.modified.map { Int($0.timeIntervalSince1970) }, Int(now.addingTimeInterval(-40 * 86400).timeIntervalSince1970))
    }

    /// Opt-in visual check of the list shown before moving: LUNAVECT_RENDER_LEGACY_COPIES=<directory>.
    @MainActor func testRenderLegacyCopiesForInspection() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_LEGACY_COPIES"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_LEGACY_COPIES to inspect the list of copies")
        }
        _ = NSApplication.shared
        let home = try home(), now = Date()
        let copies = [home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft"),
                      home.appendingPathComponent("Library/Application Support/Weekleft/snapshot.json")]
        try file(copies[0].appendingPathComponent("activity.json")); try file(copies[1])
        for url in [copies[0].appendingPathComponent("activity.json"), copies[0], copies[1]] { try age(url, days: 40, now: now) }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let view = HStack(alignment: .firstTextBaseline) {
                LegacyCopiesList(urls: copies)
                Spacer(minLength: 8)
                Button(L("Переместить в Корзину")) {}
            }.font(.system(size: 13)).foregroundStyle(.secondary).padding(16).frame(width: 640, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 640, height: 130)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("legacy-\(scheme == .light ? "light" : "dark").png"))
            window.contentView = nil
        }
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
        let found = LegacySharedData.find(group: group, current: current, home: home, now: later)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["Weekleft", "snapshot.json"])
        XCTAssertFalse(found.contains { $0.path.hasPrefix(current.path) })
        let trash = home.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let remaining = LegacySharedData.moveToTrash(found) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(LegacySharedData.find(group: group, current: current, home: home, now: later), [])
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
        XCTAssertEqual(LegacySharedData.find(group: nil, current: support, home: home, now: later), [])
        // A development build still using the previous group keeps it.
        let devCurrent = home.appendingPathComponent("Library/Group Containers/group.com.weekleft.shared/Weekleft", isDirectory: true)
        XCTAssertEqual(LegacySharedData.find(group: "group.com.weekleft.shared", current: devCurrent, home: home, now: later).map(\.lastPathComponent), ["snapshot.json"])
    }
}
