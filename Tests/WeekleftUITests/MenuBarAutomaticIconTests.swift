import XCTest
import WeekleftCore
@testable import Weekleft

final class MenuBarAutomaticIconTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func rows(_ provider: ProviderID, _ count: Int, phase: SessionPhase = .running) -> [AgentSession] {
        (0..<count).map { AgentSession(provider: provider, sessionID: "\($0)", title: "Test", cwd: "", phase: phase,
                                      updatedAt: now, observedAt: now, evidence: .localEvent) }
    }
    @MainActor private func withAppearance(_ body: (MenuBarAppearance, UserDefaults) -> Void) {
        let suite = "Lunavect.AutomaticIconTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(MenuBarAppearance(defaults: defaults), defaults)
    }
    @MainActor func testManualDefaultAndPersistence() {
        withAppearance { appearance, defaults in
            XCTAssertFalse(appearance.automaticIcon)
            appearance.icon = .lunavect
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 3), now: now), .lunavect)
            appearance.automaticIcon = true
            let restored = MenuBarAppearance(defaults: defaults)
            XCTAssertTrue(restored.automaticIcon)
            XCTAssertEqual(restored.icon, .lunavect)
        }
    }
    @MainActor func testMajorityTieReversalAndKeepLastProviderWhenIdle() {
        withAppearance { appearance, _ in
            appearance.icon = .lunavect
            appearance.automaticIcon = true
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 3) + rows(.codex, 1), now: now), .claude)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 1) + rows(.codex, 1), now: now), .claude)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 1) + rows(.codex, 2), now: now), .codex)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 2) + rows(.codex, 2), now: now), .codex)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 3, phase: .ready), now: now), .codex)
            XCTAssertEqual(appearance.icon, .lunavect, "Automatic selection must preserve the manual choice")
        }
    }
    @MainActor func testCompletedCodexAndRestartKeepCodexWithoutChangingManualChoice() {
        withAppearance { appearance, defaults in
            appearance.icon = .claude
            appearance.automaticIcon = true
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.codex, 1), now: now), .codex)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.codex, 1, phase: .ready), now: now), .codex)
            XCTAssertEqual(appearance.resolvedIcon(for: [], now: now), .codex)
            let restored = MenuBarAppearance(defaults: defaults)
            XCTAssertEqual(restored.resolvedIcon(for: [], now: now), .codex)
            restored.automaticIcon = false
            XCTAssertEqual(restored.resolvedIcon(for: [], now: now), .claude)
        }
    }
    @MainActor func testWaitingCountsButStaleAndUnconfirmedDoNot() {
        withAppearance { appearance, _ in
            appearance.automaticIcon = true
            var stale = rows(.codex, 5)
            for index in stale.indices { stale[index].observedAt = now.addingTimeInterval(-121) }
            var unconfirmed = rows(.codex, 5)
            for index in unconfirmed.indices { unconfirmed[index].runtimeConfirmed = false }
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 2, phase: .input) + rows(.codex, 1) + stale + unconfirmed, now: now), .claude)
        }
    }
    @MainActor func testInitialTieUsesManualAndCardSelectionExitsAutomaticMode() {
        withAppearance { appearance, _ in
            appearance.icon = .codex
            appearance.automaticIcon = true
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.claude, 1) + rows(.codex, 1), now: now), .codex)
            appearance.selectIcon(.claude)
            XCTAssertFalse(appearance.automaticIcon)
            XCTAssertEqual(appearance.resolvedIcon(for: rows(.codex, 5), now: now), .claude)
        }
    }
}
