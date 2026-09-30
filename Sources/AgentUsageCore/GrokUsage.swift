import Foundation

enum GrokUsage {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    static func decode(_ data: Data, now: Date) -> ParsedQuota {
        guard let root = JSONValue.object(from: data) else { return ParsedQuota(headline: nil, extras: []) }
        let config = JSONValue.firstObject(root, "config", "data") ?? root
        let nested = JSONValue.dict(config["config"]) ?? config
        var extras: [QuotaWindow] = []
        let period = JSONValue.firstObject(nested, "currentPeriod", "current_period")
        let start = timestamp(period?["start"] ?? period?["startTime"] ?? nested["billingPeriodStart"])
        let end = timestamp(period?["end"] ?? period?["endTime"] ?? period?["billingPeriodEnd"])
        let window = start.flatMap { began in end.map { $0.timeIntervalSince(began) } }
        let headline: QuotaWindow?
        if let percent = JSONValue.firstDouble(nested, "creditUsagePercent", "credit_usage_percent") {
            headline = QuotaWindow(
                id: "weekly",
                label: "Weekly",
                usedPercent: percent,
                resetsAt: end,
                window: (window ?? 0) > 0 ? window : nil
            )
        } else {
            headline = nil
        }
        for item in JSONValue.firstArray(nested, "productUsage", "product_usage") ?? [] {
            guard let object = JSONValue.dict(item),
                  let percent = JSONValue.firstDouble(object, "usagePercent", "usage_percent", "percent") else { continue }
            let name = JSONValue.firstString(object, "name", "product", "displayName") ?? "Product"
            extras.append(QuotaWindow(id: "product-\(slug(name))", label: name, usedPercent: percent))
        }
        if let limit = JSONValue.firstDouble(nested, "monthlyLimit", "monthly_limit"), limit > 0 {
            let used = JSONValue.firstDouble(nested, "includedUsed", "used", "totalUsed") ?? 0
            extras.append(QuotaWindow(
                id: "monthly",
                label: "Monthly",
                usedPercent: used / limit * 100,
                detail: "\(Format.dollars(used / 100)) / \(Format.dollars(limit / 100))"
            ))
        }
        if let cap = JSONValue.firstDouble(nested, "onDemandCap", "on_demand_cap"), cap > 0 {
            let used = JSONValue.firstDouble(nested, "onDemandUsed", "on_demand_used") ?? 0
            extras.append(QuotaWindow(id: "on_demand", label: "On-demand", usedPercent: used / cap * 100))
        }
        if let prepaid = JSONValue.firstDouble(nested, "prepaidBalance", "prepaid_balance"), prepaid != 0 {
            extras.append(QuotaWindow(id: "prepaid", label: "Prepaid", amountText: Format.dollars(prepaid / 100)))
        }
        return ParsedQuota(headline: headline, extras: extras)
    }

    static func fetch(home: URL, http: any HTTPSending, now: Date) async throws -> ProviderSnapshot {
        let authURL = home.appendingPathComponent(".grok/auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.grok))
        }
        let session = try await FileLock.exclusively(authURL) {
            try await ensureAccess(authURL: authURL, http: http, now: now, force: false)
        }
        let data = try await billingData(session: session, authURL: authURL, home: home, http: http, now: now)
        let parsed = decode(data, now: now)
        return Snap.ready(
            id: ProviderID.grok,
            parsed: parsed,
            days: [],
            note: "Grok doesn't keep a small local token log, so this week isn't charted.",
            now: now
        )
    }

    private static func billingData(
        session: OAuthTokens,
        authURL: URL,
        home: URL,
        http: any HTTPSending,
        now: Date
    ) async throws -> Data {
        let first = try await API.send(http, request(session.access, home: home))
        if first.status != 401 {
            return try API.ok(first)
        }
        let refreshed = try await FileLock.exclusively(authURL) {
            try await ensureAccess(authURL: authURL, http: http, now: now, force: true)
        }
        return try API.ok(try await API.send(http, request(refreshed.access, home: home)))
    }

    private static func ensureAccess(authURL: URL, http: any HTTPSending, now: Date, force: Bool) async throws -> OAuthTokens {
        guard var creds = GrokAuth.read(authURL) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.grok))
        }
        let fresh = creds.expires.map { $0 > now.addingTimeInterval(60) } ?? false
        if fresh && !force { return creds }
        creds = try await GrokAuth.refresh(creds, http: http, now: now)
        try GrokAuth.write(creds, to: authURL)
        return creds
    }

    private static func request(_ access: String, home: URL) -> URLRequest {
        var headers = ["x-grok-client-identifier": "grok-shell"]
        if let version = grokVersion(home: home) {
            headers["x-grok-client-version"] = version
        }
        return API.get(billingURL, bearer: access, headers: headers)
    }

    private static func grokVersion(home: URL) -> String? {
        guard let root = JSONFile.object(at: home.appendingPathComponent(".grok/version.json")) else { return nil }
        return JSONValue.string(root["version"])
    }

    private static func timestamp(_ any: Any?) -> Date? {
        if let text = JSONValue.string(any) { return DateParse.iso(text) ?? DateParse.shanghai(text) }
        if let raw = JSONValue.double(any) { return DateParse.unix(raw) }
        return nil
    }
}
