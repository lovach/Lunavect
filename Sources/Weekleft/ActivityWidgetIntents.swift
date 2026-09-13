import AppIntents
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

// These literals are deferred LocalizedStringResource values. Keep their native
// Localizable.strings table in both targets that compile this file; the system
// editor resolves its own locale rather than the app's in-process L() language.
extension ActivityPeriod: AppEnum {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    public static let caseDisplayRepresentations: [ActivityPeriod: DisplayRepresentation] = [
        .day: "Day", .week: "Week", .month: "Month"
    ]
}
extension ActivitySource: AppEnum {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    public static let caseDisplayRepresentations: [ActivitySource: DisplayRepresentation] = [
        .all: "Claude + Codex", .claude: "Claude", .codex: "Codex", .comparison: "Claude + Codex"
    ]
}
struct SelectActivityPointIntent: AppIntent {
    static let title: LocalizedStringResource = "Select activity point"
    static let openAppWhenRun = false
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Period") var period: ActivityPeriod
    @Parameter(title: "Source") var source: ActivitySource
    @Parameter(title: "Widget") var kind: String
    init() {}
    init(date: Date?, period: ActivityPeriod, source: ActivitySource, kind: String) {
        self.date = date; self.period = period; self.source = source; self.kind = kind
    }
    func perform() async throws -> some IntentResult {
        guard ActivityWidgetSelection.kinds.contains(kind) else { return .result() }
        try ActivityWidgetSelection.write(date, kind: kind, period: period, source: source)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        return .result()
    }
}
