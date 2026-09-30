import Foundation

enum CodexUsage {
    static let usageURLs = [
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        URL(string: "https://chatgpt.com/backend-api/codex/usage")!,
    ]

    static func decode(_ data: Data, now: Date) -> ParsedQuota {
        guard let root = JSONValue.object(from: data) else { return ParsedQuota(headline: nil, extras: []) }
        let rate = JSONValue.firstObject(root, "rate_limit", "rateLimit") ?? root
        var windows: [QuotaWindow] = []
        var seen = Set<String>()
        if let primary = JSONValue.firstObject(rate, "primary_window", "primaryWindow"),
           let window = makeWindow(primary, fallbackID: "primary", seen: &seen, now: now) {
            windows.append(window)
        }
        if let secondary = JSONValue.firstObject(rate, "secondary_window", "secondaryWindow"),
           let window = makeWindow(secondary, fallbackID: "secondary", seen: &seen, now: now) {
            windows.append(window)
        }
        let additional = JSONValue.firstArray(root, "additional_rate_limits", "additionalRateLimits")
            ?? JSONValue.firstArray(rate, "additional_rate_limits", "additionalRateLimits")
            ?? []
        for item in additional {
            guard let object = JSONValue.dict(item) else { continue }
            let name = JSONValue.firstString(object, "limit_name", "name", "meter_name") ?? ""
            if let nested = JSONValue.firstObject(object, "rate_limit", "rateLimit") {
                for key in ["primary_window", "primaryWindow", "secondary_window", "secondaryWindow"] {
                    guard let child = JSONValue.dict(nested[key]),
                          var window = makeWindow(child, fallbackID: "extra-\(slug(name))", seen: &seen, now: now) else { continue }
                    if !isGenericCodex(name) { window.label = name }
                    windows.append(window)
                }
                continue
            }
            guard !isGenericCodex(name),
                  var window = makeWindow(object, fallbackID: "extra-\(slug(name))", seen: &seen, now: now) else { continue }
            window.label = name
            windows.append(window)
        }
        var parsed = QuotaPick.split(windows)
        if let credits = JSONValue.dict(root["credits"]) ?? JSONValue.dict(rate["credits"]) {
            let balance = JSONValue.string(credits["balance"]) ?? JSONValue.firstDouble(credits, "balance").map { Format.dollars($0) }
            let hasCredits = JSONValue.bool(credits["has_credits"]) == true
            if hasCredits || (balance != nil && balance != "0" && balance != "$0.00") {
                if let balance, !balance.isEmpty {
                    parsed.extras.append(QuotaWindow(id: "credits", label: "Credits", amountText: balance))
                }
            }
        }
        return parsed
    }

    static func fetch(home: URL, support: URL, http: any HTTPSending, now: Date) async throws -> ProviderSnapshot {
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.codex))
        }
        let session = try await FileLock.exclusively(authURL) {
            try await ensureAccess(authURL: authURL, http: http, now: now, force: false)
        }
        let data = try await usageData(session: session, authURL: authURL, http: http, now: now)
        let parsed = decode(data, now: now)
        let days = await Task.detached {
            LocalHistory.codexWeek(home: home, support: support, now: now)
        }.value
        return Snap.ready(id: ProviderID.codex, parsed: parsed, days: days, now: now)
    }

    private static func usageData(
        session: OAuthTokens,
        authURL: URL,
        http: any HTTPSending,
        now: Date
    ) async throws -> Data {
        let first = try await fetchUsage(session, http: http)
        if first.status != 401 {
            return try API.ok(first)
        }
        let refreshed = try await FileLock.exclusively(authURL) {
            try await ensureAccess(authURL: authURL, http: http, now: now, force: true)
        }
        return try API.ok(try await fetchUsage(refreshed, http: http))
    }

    private static func ensureAccess(authURL: URL, http: any HTTPSending, now: Date, force: Bool) async throws -> OAuthTokens {
        guard var creds = CodexAuth.read(authURL) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.codex))
        }
        let fresh = creds.expires.map { $0 > now.addingTimeInterval(60) } ?? false
        if fresh && !force { return creds }
        creds = try await CodexAuth.refresh(creds, http: http, now: now)
        try CodexAuth.write(creds, to: authURL, now: now)
        return creds
    }

    private static func fetchUsage(_ tokens: OAuthTokens, http: any HTTPSending) async throws -> HTTPResult {
        var headers: [String: String] = [:]
        if let account = tokens.accountID, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        var last = HTTPResult(status: 404, body: Data())
        for url in usageURLs {
            last = try await API.send(http, API.get(url, bearer: tokens.access, headers: headers))
            if last.status != 404 { return last }
        }
        return last
    }

    private static func makeWindow(
        _ object: [String: Any],
        fallbackID: String,
        seen: inout Set<String>,
        now: Date
    ) -> QuotaWindow? {
        guard let used = JSONValue.firstDouble(object, "used_percent", "usedPercent") else { return nil }
        let seconds = JSONValue.firstDouble(object, "limit_window_seconds", "limitWindowSeconds")
            ?? JSONValue.firstDouble(object, "window_minutes", "windowMinutes").map { $0 * 60 }
        let resetsAt: Date?
        if let raw = JSONValue.firstDouble(object, "reset_at", "resets_at", "resetAt") {
            resetsAt = DateParse.unix(raw)
        } else if let after = JSONValue.firstDouble(object, "reset_after_seconds", "resetAfterSeconds") {
            resetsAt = now.addingTimeInterval(after)
        } else {
            resetsAt = nil
        }
        let baseID: String
        if let seconds, abs(seconds - 18_000) < 1 {
            baseID = "five_hour"
        } else if let seconds, abs(seconds - 604_800) < 1 {
            baseID = "seven_day"
        } else {
            baseID = fallbackID
        }
        return QuotaWindow(
            id: uniqueID(baseID, seen: &seen),
            label: durationLabel(seconds),
            usedPercent: used,
            resetsAt: resetsAt,
            window: seconds
        )
    }

    private static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "Window" }
        if abs(seconds - 18_000) < 1 { return "Session (5-hour)" }
        if abs(seconds - 604_800) < 1 { return "Weekly" }
        if abs(seconds - 86_400) < 1 { return "Daily" }
        let hours = seconds / 3600
        if hours >= 48 { return "\(Int((hours / 24).rounded()))-day" }
        if hours >= 1 { return "\(Int(hours.rounded()))-hour" }
        return "Window"
    }

    private static func isGenericCodex(_ name: String) -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty || cleaned == "codex" || cleaned == "code"
    }
}
