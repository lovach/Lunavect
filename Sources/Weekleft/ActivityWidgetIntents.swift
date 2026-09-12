import AppIntents
import WidgetKit
#if SWIFT_PACKAGE
import WeekleftCore
#endif

extension ActivityPeriod: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    public static var caseDisplayRepresentations: [ActivityPeriod: DisplayRepresentation] = [
        .day: "Day", .week: "Week", .month: "Month"
    ]
}
extension ActivitySource: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    public static var caseDisplayRepresentations: [ActivitySource: DisplayRepresentation] = [
        .all: "Claude + Codex", .claude: "Claude", .codex: "Codex", .comparison: "Claude + Codex"
    ]
}
struct SelectActivityPointIntent: AppIntent {
    static var title: LocalizedStringResource = "Select activity point"
    static var openAppWhenRun = false
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

