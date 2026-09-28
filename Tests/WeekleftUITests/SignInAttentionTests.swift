import AppKit
import UserNotifications
import XCTest
import WeekleftCore
@testable import Weekleft

/// Owner report 28.09: "why am I not told anywhere, as a user, to sign in". The
/// signed-out state reaches the limits popover, the sessions panel, the menu bar
/// descriptions and one notification; every action is the Connections card's repair.
final class SignInAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let signedOut = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message

    private func claude(issue: String?, saved: Bool = true) throws -> UsageSnapshot {
        guard saved else { return UsageSnapshot(provider: .claude, issue: issue) }
        return UsageSnapshot(provider: .claude,
            weekly: try QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
            fiveHour: try QuotaWindow(usedPercent: 12, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
            fetchedAt: now.addingTimeInterval(-120), source: "Claude Code /usage", issue: issue)
    }
    private func codex() throws -> UsageSnapshot {
        UsageSnapshot(provider: .codex, weekly: try QuotaWindow(usedPercent: 30, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                      fetchedAt: now.addingTimeInterval(-60), source: "Codex app-server")
    }

    /// The menu bar value keeps the saved-data mark every source failure has; the
    /// entry names the state for the popover, the tooltip and VoiceOver.
    func testLimitEntriesNameTheSignedOutClient() throws {
        let preferences = MenuBarLimitsPreferences(enabled: true)
        let entries = MenuBarLimitEntry.make(snapshots: [try claude(issue: signedOut), try codex()], providers: ProviderID.allCases,
                                             preferences: preferences, now: now)
        let attention = try XCTUnwrap(entries.first?.attention)
        XCTAssertEqual(attention.reason, .subscriptionUnavailable)
        XCTAssertTrue(entries[0].value.hasSuffix("*"), "Saved values keep their mark: \(entries[0].value)")
        XCTAssertTrue(entries[0].detail.components(separatedBy: "\n").contains(attention.title))
        XCTAssertNil(entries[1].attention)
        XCTAssertFalse(entries[1].detail.contains(attention.title))
        let empty = try XCTUnwrap(MenuBarLimitEntry.make(snapshots: [try claude(issue: signedOut, saved: false)], providers: [.claude],
                                                        preferences: preferences, now: now).first)
        XCTAssertEqual(empty.value, "—")
        XCTAssertEqual(empty.attention?.repair, .signIn)
        var other = try claude(issue: nil)
        other.issue = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .usageFetchFailed).message
        XCTAssertNil(MenuBarLimitEntry.make(snapshots: [other], providers: [.claude], preferences: preferences, now: now).first?.attention,
                     "Other source failures keep only their mark")
    }

    /// The popover's button closes it and asks for the same repair; an app that did
    /// not wire the route still leads to settings instead of doing nothing.
    @MainActor func testPopoverButtonOpensTheRepairOrSettings() throws {
        _ = NSApplication.shared
        let suite = "Lunavect.SignInPopover." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = LanguageSettings(defaults: defaults, reloadWidgets: {})
        var closes = 0
        let presenter = MenuBarPopoverPresenter(isShown: { _ in false }, show: { _, _ in }, close: { _ in closes += 1 })
        var requests: [ConnectionRepairRequest] = [], settings = 0
        let routed = MenuBarLimitsController(onRepair: { requests.append($0) }, language: language, defaults: defaults,
                                             autosaveName: nil, presenter: presenter) { settings += 1 }
        defer { routed.stop() }
        let request = ConnectionRepairRequest(provider: .claude, repair: .signIn)
        routed.repair(request)
        XCTAssertEqual(requests, [request]); XCTAssertEqual(settings, 0); XCTAssertEqual(closes, 1)
        let unwired = MenuBarLimitsController(language: language, defaults: defaults, autosaveName: nil, presenter: presenter) { settings += 1 }
        defer { unwired.stop() }
        unwired.repair(request)
        XCTAssertEqual(settings, 1)
    }

    /// The panel notice follows the state: a closed notice stays closed while the
    /// state lasts, returns after the client recovered and was signed out again, and
    /// is not removed when the panel closes.
    @MainActor func testPanelNoticeFollowsTheStateAndItsClosing() throws {
        let panel = SessionPanelState(isVisible: true)
        let out = [try claude(issue: signedOut), try codex()]
        panel.observeSignIn(out, providers: ProviderID.allCases)
        XCTAssertEqual(panel.signInNotices.map(\.provider), [.claude])
        panel.isVisible = false
        XCTAssertEqual(panel.signInNotices.map(\.provider), [.claude], "The state outlives one presentation")
        panel.observeSignIn(out, providers: [.codex])
        XCTAssertEqual(panel.signInNotices, [], "A disconnected provider is not shown")
        panel.observeSignIn(out, providers: ProviderID.allCases)
        panel.closeSignIn(.claude)
        XCTAssertEqual(panel.signInNotices, [])
        var prompt = out; prompt[0].issue = UsageError.claudeSignInRequired.errorDescription
        panel.observeSignIn(prompt, providers: ProviderID.allCases)
        XCTAssertEqual(panel.signInNotices, [], "Closed while the client stays signed out")
        panel.observeSignIn([try claude(issue: nil), try codex()], providers: ProviderID.allCases)
        XCTAssertEqual(panel.signInNotices, [])
        panel.observeSignIn(out, providers: ProviderID.allCases)
        XCTAssertEqual(panel.signInNotices.map(\.reason), [.subscriptionUnavailable], "Signed out again after recovering")
    }

    /// One notification per entry into the state, through the injected sender only;
    /// polls, a restart and another sign-in reason do not repeat it. The Limits
    /// switch and the delivery channels decide, and nothing is used up while off.
    @MainActor func testSignInNotificationIsSentOncePerEntry() throws {
        let suite = "Lunavect.SignInNotice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [UNNotificationRequest] = []
        func features() -> AppFeatures {
            let f = AppFeatures(defaults: defaults, now: { self.now }, playSound: { _ in },
                                sendBanner: { request, callback in requests.append(request); callback(nil) })
            f.banners = true; f.sounds = true; f.notificationAllowed = true
            return f
        }
        let out = [try claude(issue: signedOut)], recovered = [try claude(issue: nil)]
        let first = features()
        first.observeLimits(out, providers: [.claude])
        let attention = try XCTUnwrap(SignInAttention(out[0]))
        XCTAssertEqual(requests.map(\.content.title), [attention.title])
        XCTAssertEqual(requests.first?.content.body, attention.notificationBody)
        XCTAssertEqual(requests.first?.identifier, "sign-in:claude")
        XCTAssertEqual(requests.first?.content.userInfo["repair"] as? String, "claude.signIn")
        XCTAssertNil(requests.first?.content.userInfo["sessionID"])
        XCTAssertNotNil(requests.first?.content.sound)
        for _ in 0..<3 { first.observeLimits(out, providers: [.claude]) }
        var prompt = out; prompt[0].issue = UsageError.claudeSignInRequired.errorDescription
        first.observeLimits(prompt, providers: [.claude])
        XCTAssertEqual(requests.count, 1)
        first.stop()

        let second = features()
        second.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 1, "A restart in the same state stays quiet")
        second.observeLimits(recovered, providers: [.claude])
        second.observeLimits(out, providers: [])
        XCTAssertEqual(requests.count, 1, "Disconnected providers are not announced")
        second.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 2, "Entering again after leaving is announced")
        second.observeLimits(recovered, providers: [.claude])
        second.limits = false
        second.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 2, "Limit notices are off")
        second.limits = true
        second.banners = false; second.sounds = false
        second.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 2, "No channel")
        second.banners = true
        second.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 3, "Not used up while it could not be delivered")
        second.stop()

        let isolated = AppFeatures(defaults: defaults, sendBanner: { request, _ in requests.append(request) }, isolated: true)
        isolated.banners = true; isolated.notificationAllowed = true
        isolated.observeLimits(recovered, providers: [.claude]); isolated.observeLimits(out, providers: [.claude])
        XCTAssertEqual(requests.count, 3, "Previews and fixtures never notify")
    }

    /// A click on the notice opens the same repair; session notices keep their route.
    @MainActor func testNotificationClickOpensTheRepair() throws {
        let suite = "Lunavect.SignInClick." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = AppFeatures(defaults: defaults, sendBanner: { _, _ in })
        defer { features.stop() }
        var repairs: [ConnectionRepairRequest] = [], sessions: [String] = []
        features.onRepair = { repairs.append($0) }
        features.onOpenSession = { sessions.append($0) }
        features.receiveNotificationResponse(sessionID: nil, repair: "claude.reviewUsage")
        features.receiveNotificationResponse(sessionID: nil, repair: "claude.")
        features.receiveNotificationResponse(sessionID: "s-1")
        XCTAssertEqual(repairs, [ConnectionRepairRequest(provider: .claude, repair: .reviewUsage)])
        XCTAssertEqual(sessions, ["s-1"])
    }

    /// The sessions item names the state in its tooltip and VoiceOver label, like the
    /// update notice; nothing new is drawn. A private status bar keeps it off screen.
    @MainActor func testSessionStatusItemNamesTheSignedOutClient() throws {
        _ = NSApplication.shared
        let item = NSStatusBar().statusItem(withLength: NSStatusItem.variableLength)
        let animator = MenuBarAnimator(statusItem: item, canRenderAnimation: { _ in false })
        let button = try XCTUnwrap(item.button)
        animator.update(icon: .system, onlyWhileWorking: true, running: 1, waiting: 0)
        let plain = button.toolTip
        let attention = try XCTUnwrap(SignInAttention(try claude(issue: signedOut)))
        animator.setSignInAttention([attention])
        XCTAssertEqual(button.toolTip, [plain, attention.title].compactMap { $0 }.joined(separator: "\n"))
        XCTAssertTrue(button.accessibilityLabel()?.hasSuffix(". " + attention.title) == true)
        animator.update(icon: .system, onlyWhileWorking: true, running: 2, waiting: 0)
        XCTAssertTrue(button.toolTip?.hasSuffix("\n" + attention.title) == true, "Kept across status updates")
        animator.setSignInAttention([])
        XCTAssertFalse(button.toolTip?.contains(attention.title) == true)
    }
}
