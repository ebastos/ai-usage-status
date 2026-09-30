import Foundation

enum ClaudeUsage {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func decode(_ data: Data, now: Date) -> ParsedQuota {
        guard let root = JSONValue.object(from: data) else { return ParsedQuota(headline: nil, extras: []) }
        var ranked: [QuotaWindow] = []
        if let five = JSONValue.dict(root["five_hour"]),
           let window = window(id: "five_hour", label: "Session (5-hour)", object: five, length: 5 * 3600) {
            ranked.append(window)
        }
        if let week = JSONValue.dict(root["seven_day"]),
           let window = window(id: "seven_day", label: "Weekly", object: week, length: 7 * 86_400) {
            ranked.append(window)
        }
        for (key, label) in [("seven_day_sonnet", "Sonnet Weekly"), ("seven_day_opus", "Opus Weekly")] {
            if let object = JSONValue.dict(root[key]),
               let window = window(id: key, label: label, object: object, length: 7 * 86_400) {
                ranked.append(window)
            }
        }
        var seen = Set(ranked.map(\.id))
        for item in JSONValue.array(root["limits"]) ?? [] {
            guard let object = JSONValue.dict(item) else { continue }
            let kind = JSONValue.string(object["kind"]) ?? ""
            guard kind == "weekly_scoped" || kind.contains("scoped") else { continue }
            let name = displayName(object) ?? "Model"
            let id = uniqueID("weekly_\(slug(name))", seen: &seen)
            if let window = window(id: id, label: "\(name) Weekly", object: object, length: 7 * 86_400) {
                ranked.append(window)
            }
        }
        var parsed = QuotaPick.split(ranked)
        if let extra = JSONValue.dict(root["extra_usage"]), JSONValue.bool(extra["is_enabled"]) == true {
            let used = JSONValue.firstDouble(extra, "utilization", "used_percent")
            var detail: String?
            if let limit = JSONValue.firstDouble(extra, "monthly_limit"),
               let credits = JSONValue.firstDouble(extra, "used_credits") {
                detail = "\(Format.dollars(credits)) / \(Format.dollars(limit))"
            }
            parsed.extras.append(QuotaWindow(
                id: "extra_usage",
                label: "Extra usage",
                usedPercent: used,
                resetsAt: JSONValue.firstString(extra, "resets_at").flatMap(DateParse.iso),
                detail: detail
            ))
        }
        return parsed
    }

    static func fetch(home: URL, support: URL, allowPrompt: Bool, http: any HTTPSending, now: Date) async throws -> ProviderSnapshot {
        let tokens = try await RefreshTurnstile.claude.run { () async throws -> OAuthTokens in
            let loaded = try await ClaudeAuth.load(allowPrompt: allowPrompt).get()
            if let expires = loaded.expires, expires > now.addingTimeInterval(60) {
                return loaded
            }
            return try await ClaudeAuth.refresh(loaded, http: http, allowPrompt: allowPrompt, now: now)
        }
        let data = try await usageData(access: tokens.access, allowPrompt: allowPrompt, http: http, now: now)
        let parsed = decode(data, now: now)
        let days = await Task.detached {
            LocalHistory.claudeWeek(home: home, support: support, now: now)
        }.value
        return Snap.ready(id: ProviderID.claude, parsed: parsed, days: days, now: now)
    }

    private static func usageData(access: String, allowPrompt: Bool, http: any HTTPSending, now: Date) async throws -> Data {
        let result = try await API.send(http, request(access))
        if result.status != 401 {
            return try API.ok(result)
        }
        let refreshed = try await RefreshTurnstile.claude.run {
            let loaded = try await ClaudeAuth.load(allowPrompt: allowPrompt).get()
            return try await ClaudeAuth.refresh(loaded, http: http, allowPrompt: allowPrompt, now: now)
        }
        return try API.ok(try await API.send(http, request(refreshed.access)))
    }

    private static func request(_ access: String) -> URLRequest {
        API.get(usageURL, bearer: access, headers: [
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
        ])
    }

    private static func window(id: String, label: String, object: [String: Any], length: TimeInterval) -> QuotaWindow? {
        guard let used = JSONValue.firstDouble(object, "utilization", "used_percent") else { return nil }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: used,
            resetsAt: reset(object),
            window: length
        )
    }

    private static func reset(_ object: [String: Any]) -> Date? {
        if let text = JSONValue.firstString(object, "resets_at", "resetsAt") { return DateParse.iso(text) }
        if let raw = JSONValue.firstDouble(object, "resets_at", "resetsAt") { return DateParse.unix(raw) }
        return nil
    }

    private static func displayName(_ object: [String: Any]) -> String? {
        if let scope = JSONValue.dict(object["scope"]), let model = JSONValue.dict(scope["model"]) {
            if let name = JSONValue.firstString(model, "display_name", "name") { return name }
        }
        return JSONValue.firstString(object, "display_name", "name")
    }
}

func slug(_ text: String) -> String {
    let cleaned = text.lowercased().map { character -> Character in
        character.isLetter || character.isNumber ? character : "-"
    }
    return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func uniqueID(_ base: String, seen: inout Set<String>) -> String {
    if seen.insert(base).inserted { return base }
    var number = 2
    while true {
        let candidate = "\(base)-\(number)"
        if seen.insert(candidate).inserted { return candidate }
        number += 1
    }
}
