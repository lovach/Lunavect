import Foundation

public struct SessionPolling: Equatable {
    public let events: TimeInterval
    public let catalog: TimeInterval
    public let titles: TimeInterval
    /// Policy changes may bring a poll forward, but never postpone an existing
    /// deadline. Frequent active/idle transitions therefore cannot starve discovery.
    public static func nextCatalogDeadline(now: Date, lastPoll: Date?, scheduled: Date?, interval: TimeInterval) -> Date {
        max(now, min(scheduled ?? .distantFuture, (lastPoll ?? now).addingTimeInterval(interval)))
    }
    public static let idleCatalogInterval: TimeInterval = 45
    public init(panelVisible: Bool, hasActiveSessions: Bool) {
        events = panelVisible ? 1 : hasActiveSessions ? 2 : 5
        // Catalog observations last `AgentSession.catalogLifetime`, two idle polls
        // plus margin, so one failed poll cannot blank the list.
        catalog = panelVisible || hasActiveSessions ? 15 : Self.idleCatalogInterval
        titles = panelVisible || hasActiveSessions ? 15 : 45
    }
}
