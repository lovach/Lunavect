import XCTest
@testable import WeekleftCore
final class SubscriptionCalendarTests: XCTestCase {
    func testLeapMonthAndSixWeekGrid() {
        let cal = SubscriptionCalendar.calendar(locale: Locale(identifier: "ru_RU"), timeZone: TimeZone(identifier: "Europe/Vienna")!)
        let month = SubscriptionCalendar.month(2, year: 2028, calendar: cal)
        let days = SubscriptionCalendar.days(in: month, calendar: cal)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(cal.component(.weekday, from: days[0]), cal.firstWeekday)
        XCTAssertEqual(days.filter { cal.isDate($0, equalTo: month, toGranularity: .month) }.count, 29)
        XCTAssertEqual(Set(days).count, 42)
    }
    func testGridUsesCalendarDaysAcrossDaylightSavingTime() {
        let cal = SubscriptionCalendar.calendar(locale: Locale(identifier: "de_DE"), timeZone: TimeZone(identifier: "Europe/Vienna")!)
        let days = SubscriptionCalendar.days(in: SubscriptionCalendar.month(3, year: 2026, calendar: cal), calendar: cal)
        for (first, second) in zip(days, days.dropFirst()) {
            XCTAssertEqual(cal.dateComponents([.day], from: first, to: second).day, 1)
        }
        let december = SubscriptionCalendar.month(12, year: 2026, calendar: cal)
        let next = cal.date(byAdding: .month, value: 1, to: SubscriptionCalendar.monthStart(december, calendar: cal))!
        XCTAssertEqual(cal.component(.year, from: next), 2027)
        XCTAssertEqual(cal.component(.month, from: next), 1)
    }
    func testSupportedLocalesProduceWeekdaysAndMonths() {
        for code in ["ru", "en", "de", "es", "fr", "zh-Hans"] {
            let cal = SubscriptionCalendar.calendar(locale: Locale(identifier: code))
            XCTAssertEqual(cal.standaloneMonthSymbols.count, 12)
            XCTAssertEqual(cal.shortStandaloneWeekdaySymbols.count, 7)
        }
    }
}
