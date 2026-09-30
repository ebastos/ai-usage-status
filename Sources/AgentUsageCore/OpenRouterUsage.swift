import Foundation

enum OpenRouterUsage {
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    struct Period: Equatable {
        var resetsAt: Date
        var window: TimeInterval
    }

    static func period(reset: String, now: Date) -> Period? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch reset.lowercased() {
        case "daily", "day":
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return Period(resetsAt: end, window: 86_400)
        case "weekly", "week":
            let start = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: now)
            var delta = (9 - weekday) % 7
            if delta == 0 { delta = 7 }
            let end = calendar.date(byAdding: .day, value: delta, to: start) ?? start.addingTimeInterval(7 * 86_400)
            return Period(resetsAt: end, window: 7 * 86_400)
        case "monthly", "month":
            let parts = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: parts) ?? calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return Period(resetsAt: end, window: end.timeIntervalSince(start))
        default:
            return nil
        }
    }

    static func decode(_ data: Data, now: Date) -> ParsedQuota {
        guard let root = JSONValue.object(from: data) else { return ParsedQuota(headline: nil, extras: []) }
        let payload = JSONValue.dict(root["data"]) ?? root
        let limit = JSONValue.firstDouble(payload, "limit")
        let daily = JSONValue.firstDouble(payload, "usage_daily", "usageDaily") ?? 0
        let weekly = JSONValue.firstDouble(payload, "usage_weekly", "usageWeekly") ?? 0
        let monthly = JSONValue.firstDouble(payload, "usage_monthly", "usageMonthly") ?? 0
        guard let limit, limit > 0 else {
            return ParsedQuota(
                headline: QuotaWindow(id: "weekly", label: "This week", amountText: Format.dollars(weekly)),
                extras: [
                    QuotaWindow(id: "daily", label: "Today", amountText: Format.dollars(daily)),
                    QuotaWindow(id: "monthly", label: "This month", amountText: Format.dollars(monthly)),
                ]
            )
        }
        let remaining = JSONValue.firstDouble(payload, "limit_remaining", "limitRemaining")
        let used = remaining.map { max(0, limit - $0) } ?? JSONValue.firstDouble(payload, "usage") ?? 0
        let percent = used / limit * 100
        let resetName = JSONValue.firstString(payload, "limit_reset", "limitReset") ?? ""
        let span = period(reset: resetName, now: now)
        let label: String
        switch resetName.lowercased() {
        case "daily", "day": label = "Daily"
        case "weekly", "week": label = "Weekly"
        case "monthly", "month": label = "Monthly"
        default: label = "Cap"
        }
        return ParsedQuota(
            headline: QuotaWindow(
                id: resetName.isEmpty ? "cap" : resetName.lowercased(),
                label: label,
                usedPercent: percent,
                resetsAt: span?.resetsAt,
                window: span?.window
            ),
            extras: []
        )
    }

    static func balance(from data: Data) -> Double? {
        guard let root = JSONValue.object(from: data) else { return nil }
        let payload = JSONValue.dict(root["data"]) ?? root
        guard let credits = JSONValue.firstDouble(payload, "total_credits", "totalCredits") else { return nil }
        let spent = JSONValue.firstDouble(payload, "total_usage", "totalUsage") ?? 0
        return credits - spent
    }

    static func fetch(home: URL, support: URL, http: any HTTPSending, now: Date) async throws -> ProviderSnapshot {
        guard let key = StoredKey.openRouter(home: home) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.openrouter))
        }
        let body = try API.ok(try await API.send(http, API.get(keyURL, bearer: key)))
        var parsed = decode(body, now: now)
        if let credits = try? await API.send(http, API.get(creditsURL, bearer: key)),
           (200..<300).contains(credits.status),
           let balance = balance(from: credits.body) {
            parsed.extras.append(QuotaWindow(id: "balance", label: "Balance", amountText: Format.dollars(balance)))
        }
        let payload = JSONValue.dict(JSONValue.object(from: body)?["data"]) ?? JSONValue.object(from: body) ?? [:]
        if let daily = JSONValue.firstDouble(payload, "usage_daily", "usageDaily") {
            let day = Format.dayKey(now, calendar: .current)
            CreditSamples.store(day: day, value: daily, url: support.appendingPathComponent("openrouter-samples.json"))
        }
        let days = CreditSamples.week(url: support.appendingPathComponent("openrouter-samples.json"), now: now)
        return Snap.ready(
            id: ProviderID.openrouter,
            parsed: parsed,
            days: days,
            unit: .credits,
            note: "Sampled while this app is open. Days before that are blank.",
            now: now
        )
    }
}
