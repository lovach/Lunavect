import Foundation
import Combine

/// Explicit product events only. No API accepts session IDs, paths, titles or error text.
public enum UsageEvent: Sendable {
    public enum Outcome: String, Sendable { case success, failed }
    case appLaunched
    case sessionNavigation(ProviderID, SessionClient, Outcome)

    var fields: (String, [String: String]) {
        switch self {
        case .appLaunched: return ("app_launched", [:])
        case .sessionNavigation(let provider, let client, let outcome):
            return ("session_navigation_result", ["provider": provider.rawValue, "client": client.rawValue, "outcome": outcome.rawValue])
        }
    }
}

public struct UsageAnalyticsConfiguration: Sendable {
    public let token: String
    public let endpoint: URL
    public init?(token: String, host: String) {
        guard token.range(of: "^phc_[A-Za-z0-9]{16,160}$", options: .regularExpression) != nil,
              host == "https://eu.i.posthog.com" else { return nil }
        self.token = token; self.endpoint = URL(string: host + "/batch/")!
    }
    public static func bundled(_ bundle: Bundle = .main) -> Self? {
        Self(token: bundle.object(forInfoDictionaryKey: "LunavectAnalyticsToken") as? String ?? "",
             host: bundle.object(forInfoDictionaryKey: "LunavectAnalyticsHost") as? String ?? "")
    }
}

/// Opt-in, bounded, best-effort delivery. Never starts a request before consent.
/// Events awaiting delivery stay in memory only and disappear at process exit.
@MainActor public final class UsageAnalytics: ObservableObject {
    public typealias Transport = @Sendable (URLRequest) async throws -> Int
    @Published public private(set) var enabled: Bool
    public let configured: Bool
    public var hasDecision: Bool { defaults.object(forKey: Self.decisionKey) != nil }
    public var queuedCount: Int { queue.count }
    static let decisionKey = "usageAnalytics.allowed.v1"
    private let defaults: UserDefaults
    private let configuration: UsageAnalyticsConfiguration?
    private let transport: Transport
    private let now: () -> Date
    private let automaticDelivery: Bool
    private let context: [String: String]
    private var queue: [Envelope] = []
    private var scheduled: Task<Void, Never>?
    private var request: Task<Int, Error>?
    private var generation = UUID()
    private var failures = 0
    private struct Envelope { let id: UUID; let time: Date; let event: UsageEvent }

    public init(defaults: UserDefaults, configuration: UsageAnalyticsConfiguration?,
                version: String, build: String,
                automaticDelivery: Bool = true, now: @escaping () -> Date = Date.init,
                transport: @escaping Transport = { try await UsageAnalytics.deliver($0) }) {
        self.defaults = defaults; self.configuration = configuration; self.configured = configuration != nil
        self.enabled = defaults.bool(forKey: Self.decisionKey)
        self.transport = transport; self.now = now; self.automaticDelivery = automaticDelivery
        func numeric(_ value: String) -> String {
            value.range(of: "^[0-9.]{1,24}$", options: .regularExpression) == nil ? "unknown" : value
        }
        context = ["app_version": numeric(version), "app_build": numeric(build),
                   "os_major": String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                   "surface": "macos_app", "schema_version": "1"]
    }

    public func setEnabled(_ value: Bool) {
        guard configured else { return }
        guard value != enabled || !hasDecision else { return }
        stop(); enabled = value; defaults.set(value, forKey: Self.decisionKey)
        if value { launch() }
    }

    public func launch() { record(.appLaunched) }

    public func record(_ event: UsageEvent) {
        guard enabled, configured else { return }
        queue.removeAll { now().timeIntervalSince($0.time) > 86_400 }
        if queue.count >= 100 { queue.removeFirst() }
        queue.append(Envelope(id: UUID(), time: now(), event: event))
        schedule(after: 30)
    }

    private func schedule(after seconds: UInt64) {
        guard automaticDelivery, scheduled == nil, enabled, !queue.isEmpty else { return }
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self else { return }; self.scheduled = nil
            await self.flush()
        }
    }

    public func flush() async {
        guard enabled, request == nil, let configuration else { return }
        queue.removeAll { now().timeIntervalSince($0.time) > 86_400 }
        let batch = Array(queue.prefix(50)), epoch = generation
        guard !batch.isEmpty else { return }
        let events: [[String: Any]] = batch.map { entry in
            let (name, fields) = entry.event.fields
            var properties: [String: Any] = context.merging(fields, uniquingKeysWith: { _, new in new })
            properties["$geoip_disable"] = true; properties["$process_person_profile"] = false
            // PostHog requires distinct_id: use this event's ID, never an installation or person ID.
            let hour = Date(timeIntervalSince1970: floor(entry.time.timeIntervalSince1970 / 3_600) * 3_600)
            return ["event": name, "distinct_id": entry.id.uuidString, "uuid": entry.id.uuidString,
                    "timestamp": ISO8601DateFormatter().string(from: hour), "properties": properties]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["api_key": configuration.token, "batch": events]) else { return }
        var outbound = URLRequest(url: configuration.endpoint)
        outbound.httpMethod = "POST"; outbound.httpBody = data; outbound.timeoutInterval = 10
        outbound.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outbound.setValue("Lunavect-Usage/1", forHTTPHeaderField: "User-Agent")
        let send = transport
        let pending = Task { try await send(outbound) }; request = pending
        let status = try? await pending.value
        guard generation == epoch, enabled else { return }
        request = nil
        let success = status.map { (200..<300).contains($0) } ?? false
        let permanent = status.map { (400..<500).contains($0) && $0 != 408 && $0 != 429 } ?? false
        failures = success || permanent ? 0 : failures + 1
        if success || permanent || failures >= 4 {
            let ids = Set(batch.map(\.id)); queue.removeAll { ids.contains($0.id) }; failures = 0
        }
        schedule(after: failures == 0 ? 30 : UInt64(min(900, 60 * (1 << failures))))
    }

    public func stop() {
        generation = UUID(); scheduled?.cancel(); scheduled = nil; request?.cancel(); request = nil
        queue.removeAll(); failures = 0
    }

    nonisolated public static func deliver(_ request: URLRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
