import SwiftUI
#if SWIFT_PACKAGE
import WeekleftCore
#endif

struct SubscriptionDatePicker: View {
    let provider: ProviderID
    @Binding var selection: Date
    @State private var presented = false
    var body: some View {
        HStack(spacing: 8) {
            Text(L("До")).foregroundStyle(.secondary)
            Button { presented = true } label: {
                HStack(spacing: 9) {
                    InterfaceIcon(.calendar).foregroundStyle(.blue)
                    Text(selection.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))
                    InterfaceIcon(.down, size: 12).foregroundStyle(.secondary)
                }.padding(.horizontal, 9).padding(.vertical, 5)
            }.buttonStyle(.bordered)
                .accessibilityLabel(L("Дата окончания подписки {0}", provider.title))
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    SubscriptionCalendarView(provider: provider, selection: $selection) { presented = false }
                }
        }
    }
}

struct SubscriptionCalendarView: View {
    let provider: ProviderID
    @Binding var selection: Date
    var onClose: () -> Void
    @State private var displayedMonth: Date
    init(provider: ProviderID, selection: Binding<Date>, onClose: @escaping () -> Void) {
        self.provider = provider; _selection = selection; self.onClose = onClose
        _displayedMonth = State(initialValue: selection.wrappedValue)
    }
    private var calendar: Calendar { SubscriptionCalendar.calendar() }
    private var month: Int { calendar.component(.month, from: displayedMonth) }
    private var year: Int { calendar.component(.year, from: displayedMonth) }
    private var monthBinding: Binding<Int> {
        Binding(get: { month }, set: { displayedMonth = SubscriptionCalendar.month($0, year: year, calendar: calendar) })
    }
    private var yearBinding: Binding<Int> {
        Binding(get: { year }, set: { displayedMonth = SubscriptionCalendar.month(month, year: $0, calendar: calendar) })
    }
    private func moveMonth(_ delta: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: delta, to: SubscriptionCalendar.monthStart(displayedMonth, calendar: calendar))!
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Дата окончания подписки {0}", provider.title)).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Button { moveMonth(-1) } label: { InterfaceIcon(.back).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel(L("Предыдущий месяц"))
                Picker(L("Месяц"), selection: monthBinding) {
                    ForEach(1...12, id: \.self) { index in Text(calendar.standaloneMonthSymbols[index - 1]).tag(index) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Picker(L("Год"), selection: yearBinding) {
                    ForEach((min(year, calendar.component(.year, from: Date())) - 10)...(max(year, calendar.component(.year, from: Date())) + 20), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }.labelsHidden().frame(width: 80)
                Button { moveMonth(1) } label: { InterfaceIcon(.forward).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel(L("Следующий месяц"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let weekday = (calendar.firstWeekday - 1 + index) % 7
                    Text(calendar.shortStandaloneWeekdaySymbols[weekday]).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).frame(height: 20).accessibilityHidden(true)
                }
                ForEach(SubscriptionCalendar.days(in: displayedMonth, calendar: calendar), id: \.self) { date in day(date) }
            }
            Divider()
            HStack {
                Button(L("Сегодня")) { displayedMonth = Date() }.buttonStyle(.link)
                Spacer()
                Button(L("Готово"), action: onClose).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 340)
    }
    private func day(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let today = calendar.isDateInToday(date)
        let currentMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        return Button {
            selection = date
            if !currentMonth { displayedMonth = date }
        } label: {
            Text(String(calendar.component(.day, from: date)))
                .font(.system(size: 12, weight: selected || today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : currentMonth ? .primary : .secondary)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(today && !selected ? Color.accentColor : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(date.formatted(.dateTime.day().month(.wide).year().locale(L10n.locale)))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
