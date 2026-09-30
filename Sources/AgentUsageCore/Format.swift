import Foundation

public enum Format {
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// `15h 59m`, `4d 22h`, `1h 19m`, `8m`.
    public static func remaining(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "now" }
        let seconds = Int(interval.rounded())
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func tokens(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded <= 0 { return "0" }
        if rounded >= 1_000_000_000 { return compact(rounded / 1_000_000_000) + "B" }
        if rounded >= 1_000_000 { return compact(rounded / 1_000_000) + "M" }
        if rounded >= 10_000 { return compact(rounded / 1_000) + "K" }
        return String(Int(rounded))
    }

    public static func dollars(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "$%.0f", value.rounded())
        }
        return String(format: "$%.2f", value)
    }

    public static func chartAmount(_ value: Double, unit: ChartUnit) -> String {
        switch unit {
        case .tokens: return tokens(value)
        case .credits: return dollars(value)
        }
    }

    public static func usedLine(_ window: QuotaWindow, now: Date, includeResetsWord: Bool) -> String {
        var parts: [String] = []
        if let used = window.usedPercent {
            parts.append("\(percent(used)) used")
        } else if let amount = window.amountText {
            parts.append(amount)
        }
        if let resetsAt = window.resetsAt {
            let left = remaining(resetsAt.timeIntervalSince(now))
            parts.append(includeResetsWord ? "resets in \(left)" : left)
        }
        if parts.isEmpty, let detail = window.detail {
            return detail
        }
        return parts.joined(separator: " · ")
    }

    public static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func compact(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        if abs(tenths - tenths.rounded()) < 0.001 {
            return String(Int(tenths.rounded()))
        }
        return String(format: "%.1f", tenths)
    }
}

public enum DateParse {
    public static func iso(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Seconds, or milliseconds when the magnitude is past year 2286 in seconds.
    public static func unix(_ value: Double) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    public static func shanghai(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return iso(text)
    }

    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
