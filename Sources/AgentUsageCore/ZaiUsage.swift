import Foundation

enum ZaiUsage {
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let resetURL = URL(string: "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")!

    static func decodeQuota(_ data: Data, now: Date, calendar: Calendar = .current) -> ParsedQuota {
        guard let root = JSONValue.object(from: data) else { return ParsedQuota(headline: nil, extras: []) }
        let payload = JSONValue.dict(root["data"]) ?? root
        let limits = JSONValue.firstArray(payload, "limits") ?? JSONValue.firstArray(root, "limits") ?? []
        var ranked: [QuotaWindow] = []
        var extras: [QuotaWindow] = []
        var seen = Set<String>()
        for item in limits {
            guard let object = JSONValue.dict(item), let window = limitWindow(object, seen: &seen, now: now, calendar: calendar) else { continue }
            if window.id == "five_hour" || window.id == "seven_day" {
                ranked.append(window)
            } else {
                extras.append(window)
            }
        }
        // The weekly token pool is the headline when it exists, even though a calendar month is longer.
        guard !ranked.isEmpty else {
            return QuotaPick.split(extras)
        }
        var parsed = QuotaPick.split(ranked)
        parsed.extras.append(contentsOf: extras)
        return parsed
    }

    static func decodeResets(_ data: Data) -> [QuotaWindow] {
        guard let root = JSONValue.object(from: data) else { return [] }
        let payload = JSONValue.dict(root["data"]) ?? root
        var rows: [QuotaWindow] = []
        let five = countAvailable(payload["fiveHourResets"] ?? payload["five_hour_resets"])
        let week = countAvailable(payload["weekResets"] ?? payload["week_resets"])
        if five > 0 {
            rows.append(QuotaWindow(id: "five_hour_resets", label: "5-hour resets", amountText: "\(five) left"))
        }
        if week > 0 {
            rows.append(QuotaWindow(id: "week_resets", label: "Weekly resets", amountText: "\(week) left"))
        }
        return rows
    }

    /// Hourly or daily points. `x_time` is a Shanghai wall clock; it is converted to an absolute instant and then to a local day.
    static func modelDays(_ data: Data, calendar: Calendar) -> [String: Double] {
        guard let root = JSONValue.object(from: data) else { return [:] }
        let payload = JSONValue.dict(root["data"]) ?? root
        var totals: [String: Double] = [:]
        func add(time: String, tokens: Double) {
            guard tokens > 0, let date = bucketDate(time) else { return }
            totals[Format.dayKey(date, calendar: calendar), default: 0] += tokens
        }
        let rows = JSONValue.array(root["data"]) ?? JSONValue.firstArray(payload, "list", "records", "items") ?? []
        for row in rows {
            guard let object = JSONValue.dict(row) else { continue }
            let time = JSONValue.firstString(object, "x_time", "xTime", "time") ?? ""
            let tokens = JSONValue.firstDouble(object, "tokens_usage", "tokensUsage", "tokens") ?? 0
            add(time: time, tokens: tokens)
        }
        let times = JSONValue.firstArray(payload, "x_time", "xTime")
        let series = JSONValue.firstArray(payload, "tokens_usage", "tokensUsage")
        if let times, let series {
            for (time, value) in zip(times, series) {
                if let text = JSONValue.string(time), let tokens = JSONValue.double(value) {
                    add(time: text, tokens: tokens)
                }
            }
        }
        return totals
    }

    static func fetch(home: URL, http: any HTTPSending, now: Date) async throws -> ProviderSnapshot {
        guard let key = StoredKey.zai(home: home) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.zai))
        }
        let quota = try API.ok(try await API.send(http, API.get(quotaURL, bearer: key)))
        var parsed = decodeQuota(quota, now: now)
        if let resets = try? await API.send(http, API.get(resetURL, bearer: key)),
           (200..<300).contains(resets.status) {
            parsed.extras.append(contentsOf: decodeResets(resets.body))
        }
        let days = await modelWeek(key: key, http: http, now: now)
        let note = days.isEmpty ? "7-day tokens are unavailable." : nil
        return Snap.ready(id: ProviderID.zai, parsed: parsed, days: days, note: note, now: now)
    }

    private static func modelWeek(key: String, http: any HTTPSending, now: Date) async -> [DayBar] {
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        guard let url = modelURL(start: start, end: now) else { return [] }
        guard let result = try? await API.send(http, API.get(url, bearer: key)),
              (200..<300).contains(result.status) else { return [] }
        let amounts = modelDays(result.body, calendar: calendar)
        return WeekChart.make(ending: now, amounts: amounts, missingZero: true, calendar: calendar)
    }

    static func modelURL(start: Date, end: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var components = URLComponents(string: "https://api.z.ai/api/monitor/usage/model-usage")
        components?.queryItems = [
            URLQueryItem(name: "startTime", value: formatter.string(from: start)),
            URLQueryItem(name: "endTime", value: formatter.string(from: end)),
        ]
        guard let raw = components?.url?.absoluteString else { return nil }
        return URL(string: raw.replacingOccurrences(of: "%20", with: "+"))
    }

    private static func limitWindow(
        _ object: [String: Any],
        seen: inout Set<String>,
        now: Date,
        calendar: Calendar
    ) -> QuotaWindow? {
        let unit = Int(JSONValue.firstDouble(object, "unit") ?? -1)
        let type = JSONValue.firstString(object, "type", "limitType") ?? "Limit"
        let percent = scaledPercent(JSONValue.firstDouble(object, "percentage", "percent", "utilization"))
        let resetRaw = JSONValue.firstDouble(object, "nextResetTime", "next_reset_time")
        let resetsAt = resetRaw.map(DateParse.unix)
        let current = JSONValue.firstDouble(object, "currentValue", "current_value")
        let usage = JSONValue.firstDouble(object, "usage")
        switch unit {
        case 3:
            return QuotaWindow(id: uniqueID("five_hour", seen: &seen), label: "Session (5-hour)", usedPercent: percent, resetsAt: resetsAt, window: 5 * 3600)
        case 6:
            return QuotaWindow(id: uniqueID("seven_day", seen: &seen), label: "Weekly", usedPercent: percent, resetsAt: resetsAt, window: 7 * 86_400)
        case 5:
            let detail = current.flatMap { used in usage.map { "\(Int(used))/\(Int($0))" } }
            return QuotaWindow(
                id: uniqueID("tools", seen: &seen),
                label: "MCP tools",
                usedPercent: percent,
                resetsAt: resetsAt,
                window: monthLength(containing: resetsAt ?? now, calendar: calendar),
                detail: detail
            )
        default:
            guard percent != nil || detailText(current: current, usage: usage) != nil else { return nil }
            return QuotaWindow(
                id: uniqueID(slug(type), seen: &seen),
                label: prettyType(type),
                usedPercent: percent,
                resetsAt: resetsAt,
                detail: detailText(current: current, usage: usage)
            )
        }
    }

    /// Z.ai has shipped this field both as 0...1 and as 0...100. Values above 1 are already percents.
    static func scaledPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value > 0 && value <= 1 { return value * 100 }
        return value
    }

    static func countAvailable(_ any: Any?) -> Int {
        if let number = JSONValue.double(any) { return Int(number) }
        guard let rows = JSONValue.array(any) else { return 0 }
        return rows.reduce(0) { sum, item in
            guard let object = JSONValue.dict(item) else { return sum }
            if JSONValue.bool(object["available"]) == true || JSONValue.bool(object["isAvailable"]) == true {
                return sum + 1
            }
            return sum
        }
    }

    private static func bucketDate(_ text: String) -> Date? {
        if text.count <= 10 { return DateParse.shanghai(text + " 12:00:00") }
        return DateParse.shanghai(text)
    }

    private static func monthLength(containing date: Date, calendar: Calendar) -> TimeInterval {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 86_400)
        return end.timeIntervalSince(start)
    }

    private static func detailText(current: Double?, usage: Double?) -> String? {
        guard let current, let usage else { return nil }
        return "\(Int(current))/\(Int(usage))"
    }

    private static func prettyType(_ type: String) -> String {
        type.split(separator: "_").map { word in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
