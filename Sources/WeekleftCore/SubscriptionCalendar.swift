import Foundation

public enum SubscriptionCalendar {
    public static func calendar(locale: Locale = L10n.locale, timeZone: TimeZone = .current) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = locale; result.timeZone = timeZone
        return result
    }
    public static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }
    public static func days(in month: Date, calendar: Calendar) -> [Date] {
        let start = monthStart(month, calendar: calendar)
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -leading, to: start)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    public static func month(_ month: Int, year: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!
    }
}
