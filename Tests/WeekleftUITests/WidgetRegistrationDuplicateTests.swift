import XCTest
import SwiftUI
@testable import Weekleft

/// R3-01: with a second installed copy of Lunavect the app used to skip every
/// confirmation of its widget registration and said so only in a log. It now
/// shows the other copy in Settings and still confirms its own registration
/// unless macOS uses the other copy's widget. LaunchServices, PlugInKit and the
/// file system are injected answers; nothing here registers or looks up anything.
private let ownFixture = WidgetRegistrationTarget(app: URL(fileURLWithPath: "/Users/fixture/Applications/Lunavect.app"), version: "200")
private let otherFixture = URL(fileURLWithPath: "/Applications/Lunavect.app")
private let otherExtensionFixture = otherFixture.appendingPathComponent("Contents/PlugIns/LunavectWidget.appex").path

@MainActor final class WidgetRegistrationDuplicateTests: XCTestCase {
    private let own = ownFixture
    private let other = otherFixture

    private func defaults(stamp: String?) -> UserDefaults {
        let name = "WidgetRegistrationDuplicateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if let stamp { defaults.set(stamp, forKey: WidgetRegistration.stampKey) }
        return defaults
    }
    private func service(defaults: UserDefaults, log: RegistrationLog, status: WidgetRegistrationStatus,
                         copies: @escaping @Sendable () -> [URL], host: @escaping @Sendable () -> WidgetHostLookup,
                         exists: @escaping @Sendable (String) -> Bool = { _ in true }) -> WidgetRegistration {
        WidgetRegistration(defaults: defaults, target: own,
                           repair: { _ in log.add("repair"); return true }, reassert: { _ in log.add("reassert"); return true },
                           reload: { log.add("reload") }, pause: {}, settle: { _ in }, registeredCopies: copies,
                           widgetHost: { log.add("host"); return host() }, fileExists: exists, status: status)
    }

    func testRunningCopyStillConfirmsWhileTheOtherCopyIsNotTheWidgetHost() async {
        let log = RegistrationLog(), status = WidgetRegistrationStatus()
        let copies = [own.app, other], ownExtension = ownFixture.extensionURL.path
        let registration = service(defaults: defaults(stamp: own.stamp), log: log, status: status,
                                   copies: { copies }, host: { .extensions([ownExtension]) })
        registration.start(); await registration.waitUntilFinished()
        XCTAssertEqual(log.events.filter { $0 != "host" }, ["reassert", "reload", "reassert", "reload"])
        XCTAssertEqual(status.otherCopies, [other], "Settings names the other copy")
        XCTAssertFalse(status.confirmationSkipped)
        // No widget registered at all: registering the running copy cannot switch to the other one.
        let none = RegistrationLog()
        let unregistered = service(defaults: defaults(stamp: own.stamp), log: none, status: status, copies: { copies }, host: { .extensions([]) })
        unregistered.start(); await unregistered.waitUntilFinished()
        XCTAssertEqual(none.events.filter { $0 == "reassert" }.count, 2)
    }

    func testDuplicateThatHostsTheWidgetOrAnUnknownHostKeepsTheRegistration() async {
        for host in [WidgetHostLookup.extensions([otherExtensionFixture]), .extensions([own.extensionURL.path, otherExtensionFixture]), .unknown] {
            let log = RegistrationLog(), status = WidgetRegistrationStatus()
            let registration = service(defaults: defaults(stamp: own.stamp), log: log, status: status, copies: { [ownFixture.app, otherFixture] }, host: { host })
            registration.start(); await registration.waitUntilFinished()
            XCTAssertFalse(log.events.contains("reassert"), "\(host): a duplicate that would win is left alone")
            XCTAssertFalse(log.events.contains("reload"), "\(host)")
            XCTAssertEqual(status.otherCopies, [other], "\(host)")
            XCTAssertTrue(status.confirmationSkipped, "\(host)")
            XCTAssertEqual(log.events.filter { $0 == "host" }.count, 2, "\(host): both checks look again")
        }
    }

    func testVersionChangeRepairFollowsTheSameRule() async {
        let winning = RegistrationLog(), status = WidgetRegistrationStatus(), stale = defaults(stamp: "old-build")
        let skipped = service(defaults: stale, log: winning, status: status, copies: { [ownFixture.app, otherFixture] }, host: { .extensions([otherExtensionFixture]) })
        skipped.start(); await skipped.waitUntilFinished()
        XCTAssertFalse(winning.events.contains("repair"), "No extension restart while the duplicate would win")
        XCTAssertEqual(stale.string(forKey: WidgetRegistration.stampKey), "old-build", "Retried on the next launch")
        let ownHost = RegistrationLog()
        let ownExtension = ownFixture.extensionURL.path
        let repaired = service(defaults: stale, log: ownHost, status: status, copies: { [ownFixture.app, otherFixture] }, host: { .extensions([ownExtension]) })
        repaired.start(); await repaired.waitUntilFinished()
        XCTAssertEqual(ownHost.events.filter { $0 != "host" }, ["repair", "reload", "reload", "reassert", "reload", "reassert", "reload"],
                       "Repair, then the quiet confirmations")
        XCTAssertEqual(stale.string(forKey: WidgetRegistration.stampKey), own.stamp)
    }

    func testTrashDiskImagesAndMissingPathsAreNotDuplicates() async {
        let log = RegistrationLog(), status = WidgetRegistrationStatus()
        let copies = [own.app, URL(fileURLWithPath: "/Users/fixture/.Trash/Lunavect.app"),
                      URL(fileURLWithPath: "/Volumes/Lunavect 0.2.5/Lunavect.app"), URL(fileURLWithPath: "/Applications/Gone/Lunavect.app")]
        let registration = service(defaults: defaults(stamp: own.stamp), log: log, status: status, copies: { copies },
                                   host: { XCTFail("No lookup without a duplicate"); return .unknown },
                                   exists: { $0 != "/Applications/Gone/Lunavect.app" })
        registration.start(); await registration.waitUntilFinished()
        XCTAssertEqual(log.events, ["reassert", "reload", "reassert", "reload"])
        XCTAssertEqual(status.otherCopies, [])
        XCTAssertFalse(status.confirmationSkipped)
    }

    /// The first check may still see a copy that is gone by the second (an ejected
    /// installer image, a copy moved to the Trash): the second check still runs.
    func testALaterCheckRunsAfterTheDuplicateIsGone() async {
        let log = RegistrationLog(), status = WidgetRegistrationStatus(), calls = RegistrationLog()
        let registration = service(defaults: defaults(stamp: own.stamp), log: log, status: status, copies: {
            calls.add("copies")
            return calls.events.count == 1 ? [ownFixture.app, otherFixture] : [ownFixture.app]
        }, host: { .extensions([otherExtensionFixture]) })
        registration.start(); await registration.waitUntilFinished()
        XCTAssertEqual(log.events, ["host", "reassert", "reload"])
        XCTAssertEqual(status.otherCopies, [], "The notice disappears once the copy is gone")
        XCTAssertFalse(status.confirmationSkipped)
    }

    /// Opt-in visual check of the Settings notice: LUNAVECT_RENDER_WIDGET_DUPLICATE=<directory>
    /// (LUNAVECT_PREVIEW_LANGUAGE selects the language in debug builds).
    func testRenderDuplicateNoticeForInspection() throws {
        guard let output = ProcessInfo.processInfo.environment["LUNAVECT_RENDER_WIDGET_DUPLICATE"] else {
            throw XCTSkip("Set LUNAVECT_RENDER_WIDGET_DUPLICATE to inspect the Settings notice")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = ProcessInfo.processInfo.environment["LUNAVECT_PREVIEW_LANGUAGE"] ?? "system"
        for skipped in [false, true] {
            for scheme in [ColorScheme.light, .dark] {
                let status = WidgetRegistrationStatus()
                status.update(otherCopies: [otherFixture], confirmationSkipped: skipped)
                let view = WidgetDuplicateCopyNotice(status: status).padding(20).frame(width: 640, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                host.frame = CGRect(x: 0, y: 0, width: 640, height: 200)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(
                    "duplicate-\(language)-\(skipped ? "skipped" : "confirming")-\(scheme == .light ? "light" : "dark").png"))
                window.contentView = nil
            }
        }
    }

    func testPluginKitListingNamesTheRegisteredExtensions() {
        let output = """
             com.weekleft.app.widget(200)\tF1C5A6E4-1234-4F2B-9C0D-5E6F7A8B9C0D\t2026-09-27 10:00:00 +0000\t/Users/fixture/Applications/Lunavect.app/Contents/PlugIns/LunavectWidget.appex
        +    com.weekleft.app.widget(191)\t0A1B2C3D-1234-4F2B-9C0D-5E6F7A8B9C0D\t2026-09-20 09:00:00 +0000\t/Applications/Lunavect 2.app/Contents/PlugIns/LunavectWidget.appex

        (2 plug-ins)
        """
        XCTAssertEqual(WidgetRegistrationSystem.hostExtensions(fromPluginKitOutput: output),
                       ["/Users/fixture/Applications/Lunavect.app/Contents/PlugIns/LunavectWidget.appex",
                        "/Applications/Lunavect 2.app/Contents/PlugIns/LunavectWidget.appex"])
        XCTAssertEqual(WidgetRegistrationSystem.hostExtensions(fromPluginKitOutput: "\n(no matches)\n"), [])
    }
}

private final class RegistrationLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ event: String) { lock.withLock { items.append(event) } }
    var events: [String] { lock.withLock { items } }
}
