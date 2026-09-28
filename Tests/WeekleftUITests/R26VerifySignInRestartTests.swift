import UserNotifications
import XCTest
import WeekleftCore
@testable import Weekleft

/// V2 (independent check of 0.2.6, U2 + e895520): the signed-out notice is sent once
/// per entry into the state, and a restart in the same state stays quiet. The saved
/// state is what the app itself writes: a failed /usage with no reading saved before
/// (a new install, or a Claude Code that uses an API key: "API Usage Billing") leaves
/// only the issue on Claude's placeholder snapshot. Isolated store, private defaults,
/// injected notification sender; nothing is persisted or delivered.
final class R26VerifySignInRestartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @MainActor func testSignedOutWithoutASavedReadingIsNotAnnouncedAgainAfterARestart() throws {
        let suite = "Lunavect.R26V2.SignInRestart." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [UNNotificationRequest] = []
        func launch() -> AppFeatures {
            let features = AppFeatures(defaults: defaults, now: { self.now }, playSound: { _ in },
                                       sendBanner: { request, callback in requests.append(request); callback(nil) })
            features.banners = true; features.sounds = true; features.notificationAllowed = true
            return features
        }
        // AppStore's failure branch: the issue is set on the existing (quota-less) snapshot.
        let signedOut = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message
        let failed = UsageSnapshot(provider: .claude, issue: signedOut)
        XCTAssertNotNil(SignInAttention(failed), "This is the signed-out state")
        XCTAssertFalse(ClaudeProvider.isTrustedSnapshot(failed), "…with no saved reading")

        let first = launch()
        first.observeLimits([failed], providers: [.claude])
        XCTAssertEqual(requests.count, 1)
        first.stop()

        // Restart: the store loads the state the first run saved.
        var preferences = WidgetPreferences(); preferences.enabledProviders = [.claude]
        let store = AppStore(state: SharedState(snapshots: [failed], preferences: preferences), savesChanges: false,
                             isolated: true, defaults: defaults)
        let loaded = store.snapshots.filter { $0.provider == .claude }
        let second = launch()
        defer { second.stop() }
        second.observeLimits(loaded, providers: [.claude])   // first emission after launch
        second.observeLimits([failed], providers: [.claude]) // the first /usage after launch fails the same way
        XCTExpectFailure("R26-V2-01: AppStore drops the untrusted Claude snapshot at launch and shows 'waiting for data'; the tracker takes that as leaving the state and announces it again", strict: true) {
            XCTAssertEqual(loaded.map(\.issue), [signedOut], "The saved signed-out state survives the restart")
            XCTAssertEqual(requests.count, 1, "A restart in the same state stays quiet")
        }
    }
}
