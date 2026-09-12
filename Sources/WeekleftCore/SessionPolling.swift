import Foundation

public struct SessionPolling: Equatable {
    public let events: TimeInterval
    public let catalog: TimeInterval
    public let titles: TimeInterval
    public init(panelVisible: Bool, hasActiveSessions: Bool) {
        events = panelVisible ? 1 : hasActiveSessions ? 2 : 5
        // Catalog observations expire at 60 seconds: keep the idle poll below it.
        catalog = panelVisible || hasActiveSessions ? 15 : 45
        titles = panelVisible || hasActiveSessions ? 15 : 45
    }
}
