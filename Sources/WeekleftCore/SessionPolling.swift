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
    public init(panelVisible: Bool, hasActiveSessions: Bool) {
        events = panelVisible ? 1 : hasActiveSessions ? 2 : 5
        // Catalog observations expire at 60 seconds: keep the idle poll below it.
        catalog = panelVisible || hasActiveSessions ? 15 : 45
        titles = panelVisible || hasActiveSessions ? 15 : 45
    }
}
