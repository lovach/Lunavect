import XCTest
@testable import WeekleftCore

final class ClientConnectionTests: XCTestCase {
    func testInstalledClientsConfirmExistingSignInWithoutReadingOutput() async throws {
        guard ProcessInfo.processInfo.environment["LUNAVECT_LIVE_CONNECTION"] == "1" else {
            throw XCTSkip("Opt-in check of existing official-client sign-in")
        }
        for provider in ProviderID.allCases {
            let path = try XCTUnwrap(provider == .claude ? SessionSources.discoverClaude() : CodexProvider.discoverCLI())
            let state = await ClientConnection.signInState(provider, executable: path)
            XCTAssertEqual(state, .signedIn, provider.rawValue)
        }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lunavect-ConnectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func executable(_ script: String, at url: URL) throws {
        try ("#!/bin/bash\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func testOfficialLoginIsExecutedWithoutInterpolatingPathsOrMessages() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("client '$(printf injected)")
        let args = dir.appendingPathComponent("arguments")
        try executable("printf '%s\\n' \"$@\" > \(SessionHooks.quote(args.path))\n", at: client)
        for provider in ProviderID.allCases {
            let script = try ClientConnection.script(provider: provider, action: .signIn, executable: client.path,
                heading: "Example '$(exit 23)' `exit 24`", completion: "Done", environment: [:])
            let file = try ClientConnection.writeLauncher(script, provider: provider, action: .signIn, directory: dir)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: args), provider == .claude ? "auth\nlogin\n" : "login\n")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        }
    }
    func testSignInStatusUsesOnlyExitStatusAndDoesNotSaveOutput() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("client")
        for (code, expected) in [(0, ClientConnection.SignInState.signedIn), (1, .signedOut), (2, .unavailable)] {
            try executable("printf 'sensitive-fixture-output'\nprintf 'sensitive-fixture-error' >&2\nexit \(code)\n", at: client)
            for provider in ProviderID.allCases {
                let result = await ClientConnection.signInState(provider, executable: client.path)
                XCTAssertEqual(result, expected)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["client"])
    }
    func testHungStatusCheckTerminatesOnlyItsOwnProcess() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = dir.appendingPathComponent("hung")
        try executable("trap '' TERM\nwhile :; do :; done\n", at: client)
        let start = Date()
        let result = await ClientConnection.signInState(.claude, executable: client.path, timeout: 0.2)
        XCTAssertEqual(result, .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testInstallersAreOfficialAndDoNotRunAfterDownloadFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let curl = dir.appendingPathComponent("failing-curl"), marker = dir.appendingPathComponent("must-not-execute")
        // Simulate a failed download that nevertheless leaves executable content.
        // Neither vendor installer may run that partial response.
        try executable("printf '%s\\n' \(SessionHooks.quote("/usr/bin/touch " + SessionHooks.quote(marker.path))) > \"${@: -1}\"\nexit 22\n", at: curl)
        for provider in ProviderID.allCases {
            let script = try ClientConnection.script(provider: provider, action: .install, executable: nil,
                heading: "Install", completion: "Done", environment: ["ANTHROPIC_API_KEY": "must-not-copy", "CODEX_ACCESS_TOKEN": "must-not-copy"])
            XCTAssertTrue(script.contains(provider == .claude ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh"))
            XCTAssertTrue(script.contains("set -euo pipefail"))
            XCTAssertTrue(script.contains("--fail"))
            XCTAssertTrue(script.contains("--proto-redir '=https'"))
            XCTAssertFalse(script.contains("must-not-copy"))
            XCTAssertFalse(script.contains("sudo"))
            XCTAssertFalse(script.contains("auth.json"))
            let fixture = script.replacingOccurrences(of: "/usr/bin/curl", with: SessionHooks.quote(curl.path))
            let file = try ClientConnection.writeLauncher(fixture, provider: provider, action: .install, directory: dir)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 22)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}

final class LocalConnectionRecoveryTests: XCTestCase {
    private struct InjectedFailure: Error {}
    private func fixture(_ provider: ProviderID = .claude) throws -> ClientConnection.LocalSetup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-connection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("settings.json")
        try Data(
            #"{"permissions":{"allow":["Read"]},"statusLine":{"type":"command","command":"my-hud","padding":2},"hooks":{"Stop":[{"matcher":"mine","hooks":[{"type":"command","command":"my-hook","timeout":9}]}]}}"#
                .utf8
        ).write(to: config)
        return ClientConnection.LocalSetup(provider: provider, executable: "/bin/sh", configURL: config,
            bridgeDirectory: root.appendingPathComponent("bridge"), backupDirectory: root.appendingPathComponent("backups"))
    }
    private func read(_ setup: ClientConnection.LocalSetup) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: setup.configURL)) as? [String: Any])
    }
    private func edit(_ setup: ClientConnection.LocalSetup, _ body: (inout [String: Any]) -> Void) throws {
        var root = try read(setup); body(&root)
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: setup.configURL)
    }
    private func assertUserSettings(_ setup: ClientConnection.LocalSetup, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try read(setup)
        XCTAssertEqual((root["permissions"] as? [String: [String]])?["allow"], ["Read"], file: file, line: line)
        let groups = (root["hooks"] as? [String: [[String: Any]]])?["Stop"] ?? []
        let ownGroup = groups.first { $0["matcher"] as? String == "mine" }
        XCTAssertEqual((ownGroup?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "my-hook", file: file, line: line)
    }
    func testConnectRecoversAfterEveryWriteAndBoundaryFailure() throws {
        for point in ClientConnection.LocalStep.allCases {
            let setup = try fixture()
            var reached = false
            XCTAssertThrowsError(try setup.apply(.connect) { step in
                if step == point { reached = true; throw InjectedFailure() }
            }) { error in
                let failure = error as? ClientConnection.LocalFailure
                XCTAssertEqual(failure?.state, setup.inspect())
                if [.beforeHooks, .hooksBackup, .hooksWrite].contains(point) {
                    XCTAssertEqual(failure?.state.statusLine, .ready)
                    XCTAssertEqual(failure?.state.hooks, .absent)
                }
            }
            XCTAssertTrue(reached, "Uncovered checkpoint: \(point)")
            XCTAssertTrue(try setup.apply(.connect).connected)
            try assertUserSettings(setup)
            let connected = try Data(contentsOf: setup.configURL)
            let prior = try Data(contentsOf: setup.bridgeDirectory.appendingPathComponent("previous-statusline.json"))
            XCTAssertTrue(try setup.apply(.connect).connected)
            XCTAssertEqual(try Data(contentsOf: setup.configURL), connected)
            XCTAssertEqual(try Data(contentsOf: setup.bridgeDirectory.appendingPathComponent("previous-statusline.json")), prior)
            XCTAssertTrue(try setup.apply(.disconnect).disconnected)
            XCTAssertEqual((try read(setup)["statusLine"] as? [String: Any])?["command"] as? String, "my-hud")
        }
    }
    func testDisconnectRecoversAfterEveryWriteAndBoundaryFailure() throws {
        for point in ClientConnection.LocalStep.allCases where point != .statusLinePrevious {
            let setup = try fixture()
            let original = try read(setup) as NSDictionary
            try setup.apply(.connect)
            var reached = false
            XCTAssertThrowsError(try setup.apply(.disconnect) { step in
                if step == point { reached = true; throw InjectedFailure() }
            }) { error in
                let failure = error as? ClientConnection.LocalFailure
                XCTAssertEqual(failure?.state, setup.inspect())
                if [.beforeHooks, .hooksBackup, .hooksWrite].contains(point) {
                    XCTAssertEqual(failure?.state.statusLine, .ready)
                    XCTAssertEqual(failure?.state.hooks, .ready)
                }
                if [.statusLineBackup, .statusLineWrite].contains(point) {
                    XCTAssertEqual(failure?.state.statusLine, .ready)
                    XCTAssertEqual(failure?.state.hooks, .absent)
                }
            }
            XCTAssertTrue(reached, "Uncovered checkpoint: \(point)")
            XCTAssertTrue(try setup.apply(.disconnect).disconnected)
            XCTAssertEqual(try read(setup) as NSDictionary, original)
            let disconnected = try Data(contentsOf: setup.configURL)
            XCTAssertTrue(try setup.apply(.disconnect).disconnected)
            XCTAssertEqual(try Data(contentsOf: setup.configURL), disconnected)
        }
    }
    func testExternalSettingsBetweenComponentsSurviveConnectAndDisconnect() throws {
        let setup = try fixture()
        try setup.apply(.connect) { step in
            if step == .beforeHooks { try self.edit(setup) { $0["external"] = "new-value" } }
        }
        try edit(setup) { root in
            var status = root["statusLine"] as! [String: Any]
            status["padding"] = 8; status["refreshInterval"] = 25; root["statusLine"] = status
        }
        try setup.apply(.disconnect) { step in
            if step == .beforeHooks { try self.edit(setup) { $0["external"] = "newer-value" } }
        }
        let root = try read(setup), status = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertEqual(root["external"] as? String, "newer-value")
        XCTAssertEqual(status["padding"] as? Int, 8)
        XCTAssertEqual(status["refreshInterval"] as? Int, 25)
        XCTAssertEqual(status["command"] as? String, "my-hud")
        try assertUserSettings(setup)
    }
    func testExternalChangeImmediatelyBeforeConfigWriteStopsAndRetryPreservesIt() throws {
        for operation in [ClientConnection.LocalOperation.connect, .disconnect] {
            for point in [ClientConnection.LocalStep.statusLineWrite, .hooksWrite] {
                let setup = try fixture()
                if operation == .disconnect { try setup.apply(.connect) }
                XCTAssertThrowsError(try setup.apply(operation) { step in
                    if step == point { try self.edit(setup) { $0["external"] = "changed-before-write" } }
                }) { error in
                    XCTAssertTrue((error as? ClientConnection.LocalFailure)?.cause is SessionError)
                }
                XCTAssertEqual(try read(setup)["external"] as? String, "changed-before-write")
                _ = try setup.apply(operation)
                XCTAssertEqual(try read(setup)["external"] as? String, "changed-before-write")
                try assertUserSettings(setup)
            }
        }
    }
    func testMalformedSecondComponentFailsPreparationWithoutChangingStatusLine() throws {
        let setup = try fixture()
        try edit(setup) { $0["hooks"] = ["Stop": "unsupported-format"] }
        let original = try Data(contentsOf: setup.configURL)
        XCTAssertThrowsError(try setup.apply(.connect))
        XCTAssertEqual(try Data(contentsOf: setup.configURL), original)
        XCTAssertEqual(setup.inspect().hooks, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.bridgeDirectory.path))
    }
    func testFinalVerificationCannotReportSuccessAfterExternalRemoval() throws {
        let setup = try fixture()
        XCTAssertThrowsError(try setup.apply(.connect) { step in
            if step == .verify { try self.edit(setup) { $0.removeValue(forKey: "hooks") } }
        }) { error in
            XCTAssertEqual((error as? ClientConnection.LocalFailure)?.state.statusLine, .ready)
            XCTAssertEqual((error as? ClientConnection.LocalFailure)?.state.hooks, .absent)
        }
        XCTAssertTrue(try setup.apply(.connect).connected)
    }
    func testMissingPreviousHUDCannotBeReportedReadyOrOverwritten() throws {
        let setup = try fixture()
        try setup.apply(.connect)
        let config = try Data(contentsOf: setup.configURL)
        try FileManager.default.removeItem(at: setup.bridgeDirectory.appendingPathComponent("previous-statusline.json"))
        XCTAssertEqual(setup.inspect().statusLine, .partial)
        XCTAssertFalse(setup.inspect().connected)
        XCTAssertThrowsError(try setup.apply(.connect))
        XCTAssertThrowsError(try setup.apply(.disconnect))
        XCTAssertEqual(try Data(contentsOf: setup.configURL), config)
    }
    func testReplacingHUDDuringPartialConnectIsPreservedOnRetryAndDisconnect() throws {
        let setup = try fixture()
        XCTAssertThrowsError(try setup.apply(.connect) { if $0 == .beforeHooks { throw InjectedFailure() } })
        try edit(setup) { $0["statusLine"] = ["type": "command", "command": "new-user-hud", "padding": 3] }
        try setup.apply(.connect)
        try setup.apply(.disconnect)
        XCTAssertEqual((try read(setup)["statusLine"] as? [String: Any])?["command"] as? String, "new-user-hud")
    }
    func testCodexHasOnlyHooksAndRecoversWithoutStatusLineWrites() throws {
        for operation in [ClientConnection.LocalOperation.connect, .disconnect] {
            for point in [ClientConnection.LocalStep.prepare, .beforeHooks, .hooksBackup, .hooksWrite, .verify] {
                let setup = try fixture(.codex)
                if operation == .disconnect { try setup.apply(.connect) }
                XCTAssertThrowsError(try setup.apply(operation) { if $0 == point { throw InjectedFailure() } })
                let state = try setup.apply(operation)
                XCTAssertNil(state.statusLine)
                XCTAssertTrue(operation == .connect ? state.connected : state.disconnected)
                XCTAssertFalse(FileManager.default.fileExists(atPath: setup.bridgeDirectory.path))
                XCTAssertEqual((try read(setup)["statusLine"] as? [String: Any])?["command"] as? String, "my-hud")
            }
        }
    }
}

final class ClientCapabilityDiagnosticTests: XCTestCase {
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func unsupported(_ body: () throws -> Void, capability: ClientIntegrationIssue.Capability,
                             provider: ProviderID = .codex, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ClientIntegrationIssue,
                ClientIntegrationIssue(provider: provider, capability: capability, reason: .unsupportedResponse), file: file, line: line)
        }
    }
    func testDocumentedInitializationAcceptsExtraFieldsWithoutVersionInference() throws {
        let reply = try object(#"{"id":1,"result":{"userAgent":"example/unknown-version private-path","platformOs":"future-os","newField":{"data":"PRIVATE"}}}"#)
        let result = try ClientResponseContract.codexResult(reply, capability: .initialization)
        XCTAssertEqual(result["platformOs"] as? String, "future-os")
        XCTAssertNoThrow(try ClientResponseContract.codexResult(["result": [:]], capability: .initialization))
        unsupported({ _ = try ClientResponseContract.codexResult(["result": "new-format"], capability: .initialization) }, capability: .initialization)
    }
    func testUnsupportedMethodUsesErrorCodeWithoutReadingMessage() throws {
        let reply = try object(#"{"id":1,"error":{"code":-32601,"message":"PRIVATE /Users/name/token=secret"}}"#)
        XCTAssertThrowsError(try ClientResponseContract.codexResult(reply, capability: .rateLimits)) { error in
            let issue = error as? ClientIntegrationIssue
            XCTAssertEqual(issue?.reason, .unsupportedOperation)
            XCTAssertEqual(issue?.repair, .reviewClient)
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
        XCTAssertThrowsError(try ClientResponseContract.codexResult(["error": ["code": -32000, "message": "Please login PRIVATE"]], capability: .rateLimits)) { error in
            XCTAssertEqual((error as? ClientIntegrationIssue)?.reason, .sourceUnavailable)
        }
    }
    func testThreadListFutureStatusRemainsUnknownAndMalformedShapeIsExplicit() throws {
        let result = try object(#"{"data":[{"id":"thread-one","status":{"type":"future-state"},"newField":true}],"nextCursor":null}"#)
        try ClientResponseContract.validateCodexThreadList(result)
        let rows = try SessionParser.codex(JSONSerialization.data(withJSONObject: result))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].phase, .unknown)
        XCTAssertEqual(rows[0].runtimeConfirmed, false)
        for text in [#"{"data":"new-envelope"}"#, #"{"data":[{"id":42}]}"#, #"{"data":[{"id":"ok","status":"running"}]}"#, #"{"data":[],"nextCursor":12}"#] {
            unsupported({ try ClientResponseContract.validateCodexThreadList(self.object(text)) }, capability: .sessionCatalog)
        }
    }
    func testAbsentAndNullStatusLineQuotasDoNotBecomeUnsupportedOrZero() throws {
        for text in [#"{"session_id":"fictional"}"#, #"{"rate_limits":null}"#, #"{"rate_limits":{}}"#,
                     #"{"rate_limits":{"five_hour":null,"seven_day":null}}"#, #"{"rate_limits":{"spend_limit":{"used_percentage":15}}}"#] {
            XCTAssertNil(try ClientResponseContract.claudeRateLimits(object(text)))
        }
        let limits = try XCTUnwrap(ClientResponseContract.claudeRateLimits(object(#"{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":1900000000},"future_window":{}}}"#)))
        let snapshot = try UsageParser.claude(limits)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 37)
        XCTAssertNil(snapshot.weekly)
        for text in [#"{"rate_limits":[]}"#, #"{"rate_limits":{"five_hour":"37%"}}"#] {
            unsupported({ _ = try ClientResponseContract.claudeRateLimits(self.object(text)) }, capability: .statusLine, provider: .claude)
        }
    }
    func testCodexOptionalWindowsAndUnsupportedEnvelopeStayDistinct() throws {
        try ClientResponseContract.validateCodexRateLimits(object(#"{"rateLimits":{"primary":null,"secondary":null},"future":true}"#))
        let snapshot = try UsageParser.codex(object(#"{"rateLimits":{"primary":null,"secondary":null}}"#))
        XCTAssertFalse(snapshot.hasQuota)
        for text in [#"{"newRateLimits":{}}"#, #"{"rateLimits":"unknown"}"#, #"{"rateLimits":{"primary":"25%"}}"#] {
            unsupported({ try ClientResponseContract.validateCodexRateLimits(self.object(text)) }, capability: .rateLimits)
        }
        XCTAssertThrowsError(try ClientResponseContract.validateCodexRateLimits(object(#"{"rateLimits":null,"rateLimitsByLimitId":null}"#))) { error in
            XCTAssertEqual((error as? ClientIntegrationIssue)?.reason, .waitingForData)
        }
    }
    func testTypedDiagnosticsExposeRecoveryWithoutRawTextOrCachedSuccess() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = try UsageSnapshot(provider: .codex, weekly: QuotaWindow(usedPercent: 20, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)), fetchedAt: now)
        for reason in [ClientIntegrationIssue.Reason.unsupportedResponse, .unsupportedOperation] {
            let issue = ClientIntegrationIssue(provider: .codex, capability: .sessionCatalog, reason: reason)
            let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .unavailable, eventsConfigured: true,
                snapshot: snapshot, sessionIssue: "PRIVATE /Users/person/project token=secret", now: now, sourceIssue: issue)
            XCTAssertEqual(diagnostic.repair, .reviewClient)
            XCTAssertNotEqual(diagnostic.state, .ready)
            let report = try ConnectionDiagnosticReport(appVersion: "1.0", build: "123", macOS: "26.0", connections: [diagnostic]).text()
            XCTAssertTrue(report.contains(issue.code))
            for secret in ["PRIVATE", "/Users/", "token=", "usedPercent"] { XCTAssertFalse(report.contains(secret)) }
            XCTAssertEqual(try JSONDecoder().decode(ConnectionDiagnostic.self, from: JSONEncoder().encode(diagnostic)), diagnostic)
        }
    }
    func testLegacyMappingPreservesUnsupportedReasonAndUnknownErrorsStayPrivate() throws {
        XCTAssertEqual(ClientIntegrationIssue.classify(UsageError.invalidResponse, provider: .codex, capability: .rateLimits)?.reason, .unsupportedResponse)
        XCTAssertEqual(ClientIntegrationIssue.classify(SessionError.timeout, provider: .claude, capability: .sessionCatalog)?.reason, .timedOut)
        XCTAssertNil(ClientIntegrationIssue.classify(CancellationError(), provider: .claude, capability: .authentication))
        let secretError = NSError(domain: "PRIVATE", code: 17, userInfo: [NSLocalizedDescriptionKey: "PRIVATE /Users/test token=abc"])
        let issue = try XCTUnwrap(ClientIntegrationIssue.classify(secretError, provider: .claude, capability: .usageProbe))
        XCTAssertEqual(issue.reason, .sourceUnavailable)
        XCTAssertFalse(issue.localizedDescription.contains("PRIVATE"))
        let diagnostic = ConnectionDiagnostic(provider: .codex, clientFound: true, signIn: .signedIn,
            eventsConfigured: true, snapshot: UsageSnapshot(provider: .codex, issue: UsageError.invalidResponse.errorDescription), sessionIssue: nil)
        XCTAssertEqual(diagnostic.state, .unsupportedResponse)
        XCTAssertEqual(diagnostic.repair, .reviewClient)
        let path = ConnectionDiagnostic(provider: .codex, clientFound: false, signIn: .unavailable, eventsConfigured: false,
            snapshot: nil, sessionIssue: nil, sourceIssue: .init(provider: .codex, capability: .initialization, reason: .clientPathUnavailable))
        XCTAssertEqual(path.repair, .chooseClient)
    }
}

final class ClientSignInCancellationTests: XCTestCase {
    func testCancellingSignInStopsAnUncooperativeFixturePromptly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auth-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("client"), pidURL = root.appendingPathComponent("pid")
        try Data(("#!/bin/sh\ntrap '' TERM\necho $$ > " + SessionHooks.quote(pidURL.path) + "\nwhile :; do :; done\n").utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let task = Task { await ClientConnection.signInState(.claude, executable: cli.path, timeout: 20) }
        defer { task.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: pidURL.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let state = await task.value
        XCTAssertEqual(state, .unavailable)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        XCTAssertNotEqual(kill(pid, 0), 0, "Cancelled auth fixture must not remain running")
    }
}

extension ClientCapabilityDiagnosticTests {
    func testCompletedUnsupportedUsageScreenIsNotMisclassifiedAsLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-format-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("client")
        let unsupportedScreen = "Current week (all models)\nNEW LIMIT FORMAT: 38 units\nResets someday\nEsc to cancel\n"
        try Data(("#!/bin/sh\nprintf '%s' " + SessionHooks.quote(unsupportedScreen) + "\n").utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        do {
            _ = try await ClaudeUsageProbe.fetch(cliPath: cli.path, timeout: 1, directory: root.appendingPathComponent("probe"))
            XCTFail("Unknown complete usage output must not appear as a successful snapshot")
        } catch {
            let issue = try XCTUnwrap(error as? ClientIntegrationIssue)
            XCTAssertEqual(issue.capability, .usageProbe)
            XCTAssertEqual(issue.reason, .unsupportedResponse)
            XCTAssertEqual(issue.repair, .reviewClient)
            XCTAssertFalse(issue.localizedDescription.contains("NEW LIMIT FORMAT"))
        }
    }
}

extension ClientCapabilityDiagnosticTests {
    func testCachedClaudeQuotaKeepsUnsupportedReasonAndOriginalTimestamp() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cached = try UsageSnapshot(provider: .claude, weekly: QuotaWindow(usedPercent: 48, durationMinutes: 10080,
            resetsAt: now.addingTimeInterval(3600)), fetchedAt: now, source: ClaudeUsageProbe.source)
        let unsupported = ClientIntegrationIssue(provider: .claude, capability: .usageProbe, reason: .unsupportedResponse)
        var writes = 0
        let result = try await ClaudeProvider.refresh(force: true, cached: { cached }, probe: { throw unsupported }, save: { _ in writes += 1 })
        XCTAssertEqual(result.weekly?.usedPercent, 48)
        XCTAssertEqual(result.fetchedAt, cached.fetchedAt)
        XCTAssertEqual(result.issue, unsupported.message)
        XCTAssertEqual(writes, 0)
        let diagnostic = ConnectionDiagnostic(provider: .claude, clientFound: true, signIn: .signedIn, eventsConfigured: true,
            snapshot: result, sessionIssue: nil, now: now)
        XCTAssertEqual(diagnostic.state, .unsupportedResponse)
        XCTAssertEqual(diagnostic.repair, .reviewClient)
    }
}
