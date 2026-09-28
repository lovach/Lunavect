import XCTest
@testable import Weekleft
@testable import WeekleftCore

/// R2-R-01: every hook record is a temporary file plus a rename, two directory
/// changes, and busy clients write several records a second. Changes within one
/// window cost one read; a stop or provider change cancels a pending window.
/// The window is a barrier the test releases, so no count depends on timing.
@MainActor final class SessionStoreChangeCoalescingTests: XCTestCase {
    private final class Windows {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var opened: XCTestExpectation?
        func releaseAll() { let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
    }
    private var reads = 0
    private var readFinished: XCTestExpectation?
    private let windows = Windows()

    private func store(watching: Bool = false, directory: URL? = nil) throws -> SessionStore {
        let root = try directory ?? temporaryDirectory()
        let suite = "Lunavect.ChangeCoalescing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var dependencies = SessionStore.Dependencies(events: { [unowned self] _, _, _ in
            reads += 1; readFinished?.fulfill(); return []
        })
        let windows = windows
        dependencies.changeWindow = { await withCheckedContinuation { continuation in
            Task { @MainActor in windows.waiting.append(continuation); windows.opened?.fulfill() }
        } }
        dependencies.watchesEvents = watching
        let store = SessionStore(directory: root, defaults: defaults, isolated: true, now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 dependencies: dependencies)
        // Release any window still waiting so no task outlives the test.
        addTeardownBlock { @MainActor [windows] in store.stop(); windows.releaseAll() }
        store.useProviders([.claude])
        return store
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lunavect-r2-S-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private func openWindow(_ body: () throws -> Void) async throws {
        let opened = expectation(description: "Change window opened")
        opened.assertForOverFulfill = false  // extra windows are counted, not a crash
        windows.opened = opened
        try body()
        await fulfillment(of: [opened], timeout: 5)
        windows.opened = nil
    }
    private func releaseAndRead() async {
        let finished = expectation(description: "Coalesced read finished")
        finished.assertForOverFulfill = false  // extra reads are counted, not a crash
        readFinished = finished
        windows.releaseAll()
        await fulfillment(of: [finished], timeout: 5)
        readFinished = nil
        await settle()
    }

    func testABurstOfDirectoryChangesWithinOneWindowCostsOneRead() async throws {
        let store = try store()
        try await openWindow { for _ in 0..<20 { store.directoryChanged() } }
        await settle()
        XCTAssertEqual(windows.waiting.count, 1, "One window for the whole burst")
        XCTAssertEqual(reads, 0, "Nothing is read before the window ends")
        await releaseAndRead()
        XCTAssertEqual(reads, 1)
        // A later change opens a new window and is read again.
        try await openWindow { store.directoryChanged(); store.directoryChanged() }
        await releaseAndRead()
        XCTAssertEqual(reads, 2)
        // A direct request still reads at once.
        await store.readEvents()
        XCTAssertEqual(reads, 3)
    }

    func testStopOrAProviderChangeCancelsAPendingWindow() async throws {
        let store = try store()
        try await openWindow { store.directoryChanged() }
        store.useProviders([.codex])
        windows.releaseAll(); await settle()
        XCTAssertEqual(reads, 0, "A window from the previous provider set never reads")
        try await openWindow { store.directoryChanged() }
        await releaseAndRead()
        XCTAssertEqual(reads, 1, "The new generation reads normally")

        try await openWindow { store.directoryChanged() }
        store.stop()
        windows.releaseAll(); await settle()
        store.directoryChanged(); await settle()
        XCTAssertEqual(reads, 1, "After stop a pending or new change never reads")
        XCTAssertTrue(windows.waiting.isEmpty, "A stopped store opens no window")
    }

    /// The directory watcher goes through the window: writing a record through the
    /// helper's own capture opens one window, and the read waits for it.
    func testTheDirectoryWatcherUsesTheWindow() async throws {
        let root = try temporaryDirectory()
        let store = try store(watching: true, directory: root)
        let initial = expectation(description: "Initial refresh read")
        initial.assertForOverFulfill = false
        readFinished = initial
        store.start(clientResolver: { ClientExecutableResolver(discoverCodex: { nil }, discoverClaude: { nil }) })
        await fulfillment(of: [initial], timeout: 5)
        readFinished = nil; await settle()
        let before = reads
        try await openWindow {
            try SessionHooks.capture(Data(#"{"session_id":"watched","hook_event_name":"UserPromptSubmit","cwd":"/Users/fixture"}"#.utf8),
                                     provider: .claude, at: root, client: .terminal, isInternal: { _ in false }, isAlive: { _ in true })
        }
        await settle()
        XCTAssertEqual(reads, before, "The watcher does not read before its window ends")
        await releaseAndRead()
        XCTAssertEqual(reads, before + 1)
    }
}
