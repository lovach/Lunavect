import XCTest
@testable import WeekleftCore

/// Owner report 28.09: Claude Code was signed out ("API Usage Billing" on /usage) and
/// the state was visible only in Settings → Connections.
final class SignInAttentionTests: XCTestCase {
    private func capability(_ provider: ProviderID) -> ClientIntegrationIssue.Capability { provider == .codex ? .rateLimits : .usageProbe }
    private func snapshot(_ provider: ProviderID, issue: String?) -> UsageSnapshot { UsageSnapshot(provider: provider, issue: issue) }

    /// Every typed state and every saved app message: exactly the sign-in states are
    /// recognized, with the repair the Connections card offers for the same message.
    func testRecognizesTheSignInStatesTheConnectionsCardRepairs() throws {
        let allReasons: [ClientIntegrationIssue.Reason] = [.unsupportedResponse, .unsupportedOperation, .missingClient, .clientPathUnavailable,
            .timedOut, .signInRequired, .setupRequired, .disabled, .configurationChanged, .waitingForData, .staleData, .sourceUnavailable,
            .incompleteCatalog, .limitReached, .windowInactive, .usageFetchFailed, .workspaceTrustRequired, .subscriptionUnavailable]
        var messages: [(ProviderID, String)] = []
        for provider in ProviderID.allCases {
            messages += allReasons.map { (provider, ClientIntegrationIssue(provider: provider, capability: capability(provider), reason: $0).message) }
        }
        let usage: [UsageError] = [.invalidResponse, .missingCLI, .timeout, .notSignedIn, .waitingForClaude, .statusLineDisabled,
                                   .claudeQuotaStale, .claudeCLIUnavailable, .claudeSignInRequired, .claudeUsageUnavailable]
        messages += usage.map { (.claude, $0.errorDescription!) } + usage.map { (.codex, $0.errorDescription!) }
        var recognized: Set<ClientIntegrationIssue.Reason> = []
        for (provider, message) in messages {
            let card = ClientIntegrationIssue.legacy(message, provider: provider, capability: capability(provider))
            let attention = SignInAttention(snapshot(provider, issue: message))
            // The card shows its button for these repairs; the attention exists exactly for the sign-in reasons.
            XCTAssertEqual(attention != nil, card.map { SignInAttention.reasons.contains($0.reason) } ?? false, message)
            guard let attention else { continue }
            recognized.insert(attention.reason)
            XCTAssertEqual(attention.provider, provider)
            XCTAssertEqual(attention.repair, card?.repair, message)
            XCTAssertTrue([.signIn, .reviewUsage].contains(attention.repair), "The Connections card offers no button for \(attention.repair)")
            XCTAssertEqual(attention.message, L(message))
            XCTAssertEqual(attention.request, ConnectionRepairRequest(provider: provider, repair: attention.repair))
        }
        XCTAssertEqual(recognized, SignInAttention.reasons)
        XCTAssertEqual(SignInAttention(snapshot(.claude, issue: UsageError.claudeSignInRequired.errorDescription))?.repair, .reviewUsage)
        XCTAssertEqual(SignInAttention(snapshot(.codex, issue: UsageError.notSignedIn.errorDescription))?.repair, .signIn)
        XCTAssertNil(SignInAttention(snapshot(.claude, issue: nil)))
        XCTAssertNil(SignInAttention(snapshot(.claude, issue: "API Usage Billing")), "Raw client text is never recognized")
    }

    /// The heading is the one the diagnostics sheet shows for the same saved message.
    func testOwnerCaseUsesTheDiagnosticsHeading() throws {
        let message = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message
        let saved = UsageSnapshot(provider: .claude, weekly: try QuotaWindow(usedPercent: 41, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(86400)),
                                  fetchedAt: Date().addingTimeInterval(-3600), source: "Claude Code /usage", issue: message)
        let attention = try XCTUnwrap(SignInAttention(saved))
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
                                              snapshot: saved, sessionIssue: nil)
        XCTAssertEqual(diagnostic.state, .sourceError)
        XCTAssertEqual(attention.title, L(diagnostic.title))
        XCTAssertEqual(diagnostic.repair, attention.repair)
        XCTAssertEqual(attention.repair.title, "Войти снова")
        XCTAssertEqual(attention.notificationBody, L("Лимиты {0} не обновляются. Нажмите, чтобы войти снова.", "Claude"))
        let setup = try XCTUnwrap(SignInAttention(snapshot(.claude, issue: UsageError.claudeSignInRequired.errorDescription)))
        XCTAssertEqual(setup.title, L("{0} ждёт входа или настройки", "Claude Code"))
        XCTAssertEqual(setup.notificationBody, L("Лимиты {0} не обновляются. Нажмите, чтобы завершить настройку.", "Claude"))
        let codex = try XCTUnwrap(SignInAttention(snapshot(.codex, issue: UsageError.notSignedIn.errorDescription)))
        XCTAssertEqual(codex.title, L("{0} не вошёл в аккаунт", "Codex"))
        XCTAssertEqual(codex.consequence, L("Лимиты {0} не обновляются.", "Codex"))
        // Russian source text: the catalog keys carry the client and the provider.
        XCTAssertEqual(L10n.text("{0} не вошёл в аккаунт", language: "ru", arguments: ["Codex"]), "Codex не вошёл в аккаунт")
        XCTAssertEqual(L10n.text("Лимиты {0} не обновляются.", language: "en", arguments: ["Claude"]), "Claude limits are not updating.")
    }

    func testOnlyConnectedProvidersInAppOrder() {
        let claude = snapshot(.claude, issue: ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message)
        let codex = snapshot(.codex, issue: UsageError.notSignedIn.errorDescription)
        XCTAssertEqual(SignInAttention.all([codex, claude], providers: [.codex, .claude]).map(\.provider), [.claude, .codex])
        XCTAssertEqual(SignInAttention.all([codex, claude], providers: [.codex]).map(\.provider), [.codex])
        XCTAssertEqual(SignInAttention.all([codex], providers: ProviderID.allCases).map(\.provider), [.codex])
        XCTAssertEqual(SignInAttention.all([claude, codex], providers: []), [])
    }

    func testRepairRequestIsReadBackExactlyAndTakenOnce() {
        let repairs: [ConnectionDiagnostic.Repair] = [.install, .signIn, .events, .refresh, .reviewUsage, .checkSignIn, .reviewClient, .chooseClient]
        for provider in ProviderID.allCases {
            for repair in repairs {
                let request = ConnectionRepairRequest(provider: provider, repair: repair)
                XCTAssertEqual(ConnectionRepairRequest(rawValue: request.rawValue), request)
            }
        }
        for invalid in ["", "claude", "claude.", ".signIn", "claude.signIn.extra", "gemini.signIn", "claude.unknown", "CLAUDE.signIn", "claude..signIn"] {
            XCTAssertNil(ConnectionRepairRequest(rawValue: invalid), invalid)
        }
        var stored = "claude.signIn"
        XCTAssertEqual(ConnectionRepairRequest.take(&stored, connected: [.claude]), ConnectionRepairRequest(provider: .claude, repair: .signIn))
        XCTAssertEqual(stored, "")
        XCTAssertNil(ConnectionRepairRequest.take(&stored, connected: [.claude]), "Taken once")
        stored = "codex.signIn"
        XCTAssertNil(ConnectionRepairRequest.take(&stored, connected: [.claude]), "A provider disconnected meanwhile is not opened")
        XCTAssertEqual(stored, "", "and its request does not wait for a later visit")
        stored = "garbage"
        XCTAssertNil(ConnectionRepairRequest.take(&stored, connected: ProviderID.allCases))
        XCTAssertEqual(stored, "")
    }

    /// State machine: entering announces, polls and a restart do not, leaving re-arms.
    func testNoticeTrackerAnnouncesOnceForEachEntry() throws {
        let signedOut = try XCTUnwrap(SignInAttention(snapshot(.claude, issue:
            ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .subscriptionUnavailable).message)))
        let prompt = try XCTUnwrap(SignInAttention(snapshot(.claude, issue: UsageError.claudeSignInRequired.errorDescription)))
        let codex = try XCTUnwrap(SignInAttention(snapshot(.codex, issue: UsageError.notSignedIn.errorDescription)))
        var tracker = SignInNoticeTracker()
        XCTAssertEqual(tracker.update([signedOut], announce: true), [signedOut])
        XCTAssertEqual(tracker.update([signedOut], announce: true), [], "Every poll sees the same state")
        XCTAssertEqual(tracker.update([prompt], announce: true), [], "Another sign-in reason is the same state")
        tracker = try JSONDecoder().decode(SignInNoticeTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(tracker.update([prompt, codex], announce: true), [codex], "A restart keeps Claude told; Codex enters now")
        XCTAssertEqual(tracker.update([codex], announce: true), [], "Claude left the state")
        XCTAssertEqual(tracker.update([signedOut, codex], announce: true), [signedOut], "and entered it again")
        XCTAssertEqual(tracker.update([], announce: false), [])
        XCTAssertEqual(tracker.update([signedOut], announce: false), [], "Notifications off: nothing is sent")
        XCTAssertEqual(tracker.update([signedOut], announce: true), [signedOut], "and nothing was used up")
        XCTAssertEqual(tracker.notified, [.claude])
    }

    /// Properties over random sequences (fixed seed), instead of a copy of the rule:
    /// an announcement needs presence and permission; no second one without leaving;
    /// a present, announceable state has been announced since it was last absent;
    /// saving and reading the tracker between steps changes nothing.
    func testNoticeTrackerPropertiesOverRandomSequences() throws {
        var generator = SplitMix64(seed: 0x5EED_2809)
        let attention: [ProviderID: SignInAttention] = [
            .claude: try XCTUnwrap(SignInAttention(snapshot(.claude, issue: UsageError.claudeSignInRequired.errorDescription))),
            .codex: try XCTUnwrap(SignInAttention(snapshot(.codex, issue: UsageError.notSignedIn.errorDescription)))]
        for _ in 0..<300 {
            var tracker = SignInNoticeTracker(), restarted = SignInNoticeTracker()
            var announcedSinceAbsent: [ProviderID: Bool] = [:]
            for _ in 0..<Int(generator.next() % 40) {
                let present = ProviderID.allCases.filter { _ in generator.next() % 3 != 0 }
                let announce = generator.next() % 4 != 0
                let current = present.compactMap { attention[$0] }
                let sent = tracker.update(current, announce: announce)
                restarted = try JSONDecoder().decode(SignInNoticeTracker.self, from: JSONEncoder().encode(restarted))
                XCTAssertEqual(restarted.update(current, announce: announce), sent)
                XCTAssertEqual(Set(sent.map(\.provider)).count, sent.count)
                for provider in ProviderID.allCases {
                    guard present.contains(provider) else { announcedSinceAbsent[provider] = false; continue }
                    let now = sent.contains { $0.provider == provider }
                    if now { XCTAssertTrue(announce); XCTAssertFalse(announcedSinceAbsent[provider] ?? false, "Repeated without leaving") }
                    announcedSinceAbsent[provider] = (announcedSinceAbsent[provider] ?? false) || now
                    if announce { XCTAssertTrue(announcedSinceAbsent[provider] ?? false, "A present state was never announced") }
                }
            }
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
