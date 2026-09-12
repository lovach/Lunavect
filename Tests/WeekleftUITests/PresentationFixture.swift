import Foundation
import WeekleftCore

/// One consistent, fictional dataset for public stills and the native demo.
struct PresentationFixture {
    let now: Date
    let snapshots: [UsageSnapshot]
    let preferences: WidgetPreferences
    let history: ActivityHistory
    let details: ActivityDetails

    init(now: Date = Date(), calendar: Calendar = .current) throws {
        self.now = now
        snapshots = try [
            UsageSnapshot(provider: .claude,
                weekly: QuotaWindow(usedPercent: 32, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
                fiveHour: QuotaWindow(usedPercent: 16, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600)),
                fetchedAt: now, source: "Claude Code /usage"),
            UsageSnapshot(provider: .codex,
                weekly: QuotaWindow(usedPercent: 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400)),
                fiveHour: QuotaWindow(usedPercent: 9, durationMinutes: 300, resetsAt: now.addingTimeInterval(4 * 3600)),
                fetchedAt: now, source: "Codex app-server")
        ]
        var preferences = WidgetPreferences()
        preferences.enabledProviders = [.claude, .codex]; preferences.showFiveHour = true
        self.preferences = preferences

        let today = calendar.startOfDay(for: now)
        let recordingBegan = now.addingTimeInterval(-120)
        var records: [ActivityInterval] = []
        for day in -29...0 {
            guard let date = calendar.date(byAdding: .day, value: day, to: today) else { continue }
            for hour in [9, 10, 14, 15, 16] {
                guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else { continue }
                let seconds = Double((((day + 30) * (day + 30) * (hour + 3) + hour * 7) % 50 + 5) * 60)
                let end = min(start.addingTimeInterval(seconds), recordingBegan)
                if end > start {
                    records.append(ActivityInterval(start: start, end: end, providers: hour < 12 ? 1 : hour == 15 ? 3 : 2))
                }
            }
        }
        var history = ActivityHistory()
        // Import up to the start of live recording, not midnight: today's
        // completed work must remain visible alongside the running sessions.
        _ = history.prepareImport(now: recordingBegan)
        history.mergeRecovered(records, now: now, limited: false)
        history.append(start: recordingBegan, end: now.addingTimeInterval(-90), providers: 1, observedProviders: 3)
        history.append(start: now.addingTimeInterval(-90), end: now, providers: 3, observedProviders: 3)
        self.history = history

        var details = ActivityDetails()
        for provider in ProviderID.allCases {
            let mask = provider == .claude ? 1 : 2
            let spans = history.intervals.filter { $0.providers & mask != 0 }.map { span in
                var result = span
                result.providers = mask
                result.observedProviders = span.observedProviders.map { $0 & mask }
                return result
            }
            details.merge([ActivityDetailRecord(provider: provider,
                sessionID: provider == .claude ? "demo-working" : "demo-permission",
                title: provider == .claude ? "Build the onboarding flow" : "Review the release checklist",
                cwd: "/Users/demo/Projects/Lunavect", intervals: spans)], now: now)
        }
        self.details = details
    }

    /// Updating a different task must never restart the working task's clock.
    func sessions(stage: Int = 1, observedAt: Date? = nil) -> [AgentSession] {
        let time = observedAt ?? now
        var working = AgentSession(provider: .claude, sessionID: "demo-working", title: "Build the onboarding flow",
            cwd: "/Users/demo/Projects/Lunavect", client: .desktop, phase: .running,
            updatedAt: time, observedAt: time, runtimeConfirmed: true)
        working.turnStartedAt = now.addingTimeInterval(-72)
        var review = AgentSession(provider: .codex, sessionID: "demo-permission", title: "Review the release checklist",
            cwd: "/Users/demo/Projects/Lunavect", client: .desktop,
            phase: stage == 0 ? .running : stage == 1 ? .permission : .ready,
            updatedAt: time, observedAt: time, runtimeConfirmed: true)
        review.turnStartedAt = now.addingTimeInterval(-90)
        let ready = AgentSession(provider: .codex, sessionID: "demo-ready", title: "Polish the settings screen",
            cwd: "/Users/demo/Projects/Atlas", client: .desktop, phase: .ready,
            updatedAt: time, observedAt: time, runtimeConfirmed: true)
        return [working, review, ready]
    }
}
