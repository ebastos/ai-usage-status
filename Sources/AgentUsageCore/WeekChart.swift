import Foundation

public enum WeekChart {
    public static func make(
        ending now: Date,
        amounts: [String: Double],
        missingZero: Bool,
        calendar: Calendar = .current
    ) -> [DayBar] {
        let startToday = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: startToday) ?? startToday
            let key = Format.dayKey(date, calendar: calendar)
            let amount = amounts[key] ?? (missingZero ? 0 : nil)
            return DayBar(id: key, date: date, amount: amount)
        }
    }
}
