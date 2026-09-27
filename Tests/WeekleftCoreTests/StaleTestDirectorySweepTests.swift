import XCTest
import Darwin

/// Socket tests create `/tmp/lunavect-test-<UUID>` outside TMPDIR (a Unix socket
/// path must fit `sun_path`) and remove it in `defer`. A crashed or killed test
/// process leaves the directory behind, so this best-effort sweep removes such
/// leftovers: only real directories with the prefix, owned by the current user
/// and unmodified for longer than the age limit. Links are never followed.
enum StaleTestDirectories {
    static let prefix = "lunavect-test-"

    @discardableResult
    static func sweep(root: URL = URL(fileURLWithPath: "/tmp"), prefix: String = prefix,
                      olderThan age: TimeInterval = 3600, now: Date = Date(), owner: uid_t = getuid()) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasPrefix(prefix) {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }
}

final class StaleTestDirectorySweepTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Leftovers of earlier crashed runs; directories of a running suite are
        // seconds old and stay untouched.
        StaleTestDirectories.sweep()
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stale sweep " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func testOnlyOldOwnedPrefixedDirectoriesAreRemoved() throws {
        let root = try fixtureRoot()
        let stale = root.appendingPathComponent("lunavect-test-stale")
        try FileManager.default.createDirectory(at: stale.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("socket fixture".utf8).write(to: stale.appendingPathComponent("peer.sock"))
        try age(stale, by: 2 * 3600)
        let fresh = root.appendingPathComponent("lunavect-test-fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        let unrelated = root.appendingPathComponent("lunavect-ide-501")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try age(unrelated, by: 2 * 3600)
        let file = root.appendingPathComponent("lunavect-test-file")
        try Data().write(to: file)
        try age(file, by: 2 * 3600)
        // A planted link must be neither followed nor treated as our directory.
        let target = root.appendingPathComponent("keep-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try age(target, by: 2 * 3600)
        let link = root.appendingPathComponent("lunavect-test-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var times = [timeval(tv_sec: time(nil) - 7200, tv_usec: 0), timeval(tv_sec: time(nil) - 7200, tv_usec: 0)]
        XCTAssertEqual(lutimes(link.path, &times), 0)

        XCTAssertEqual(StaleTestDirectories.sweep(root: root), ["lunavect-test-stale"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for kept in [fresh, unrelated, file, target.appendingPathComponent("keep.txt")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testDirectoriesOfAnotherOwnerAreLeftAlone() throws {
        let root = try fixtureRoot()
        let stale = root.appendingPathComponent("lunavect-test-other-owner")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try age(stale, by: 2 * 3600)
        XCTAssertEqual(StaleTestDirectories.sweep(root: root, owner: getuid() &+ 1), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(StaleTestDirectories.sweep(root: root.appendingPathComponent("missing")), [])
    }
}
