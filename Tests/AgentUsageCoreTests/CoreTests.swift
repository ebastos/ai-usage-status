import XCTest
@testable import AgentUsageCore

final class PaceAndFormatTests: XCTestCase {
    func testReferencePace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week: TimeInterval = 7 * 86_400
        let claude = PaceMath.make(
            usedPercent: 31,
            resetsAt: now.addingTimeInterval(15 * 3600 + 59 * 60),
            window: week,
            now: now
        )
        XCTAssertEqual(claude?.expectedPercent, 90)
        XCTAssertEqual(claude?.aheadPercent, 59)
        XCTAssertEqual(claude?.label, "59% ahead of pace")
        XCTAssertEqual(claude?.expectedLabel, "Expected 90% used")

        let codex = PaceMath.make(
            usedPercent: 18,
            resetsAt: now.addingTimeInterval(4 * 86_400 + 22 * 3600),
            window: week,
            now: now
        )
        XCTAssertEqual(codex?.expectedPercent, 30)
        XCTAssertEqual(codex?.aheadPercent, 12)
        XCTAssertEqual(codex?.label, "12% ahead of pace")
    }

    func testBehindPaceMissingWindowAndPastReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let week: TimeInterval = 7 * 86_400
        let behind = PaceMath.make(usedPercent: 80, resetsAt: now.addingTimeInterval(week / 2), window: week, now: now)
        XCTAssertEqual(behind?.expectedPercent, 50)
        XCTAssertEqual(behind?.aheadPercent, -30)
        XCTAssertEqual(behind?.label, "30% behind pace")

        XCTAssertNil(PaceMath.make(usedPercent: 10, resetsAt: now, window: 0, now: now))

        let past = PaceMath.make(usedPercent: 40, resetsAt: now.addingTimeInterval(-10), window: week, now: now)
        XCTAssertEqual(past?.expectedPercent, 100)
        XCTAssertEqual(past?.aheadPercent, 60)
        XCTAssertEqual(past?.label, "60% ahead of pace")
    }

    func testFormat() {
        XCTAssertEqual(Format.tokens(186_000_000), "186M")
        XCTAssertEqual(Format.tokens(56_300_000), "56.3M")
        XCTAssertEqual(Format.tokens(0), "0")
        XCTAssertEqual(Format.tokens(1_500_000_000), "1.5B")
        XCTAssertEqual(Format.remaining(8 * 60), "8m")
        XCTAssertEqual(Format.remaining(59 * 60), "59m")
        XCTAssertEqual(Format.remaining(15 * 3600 + 59 * 60), "15h 59m")
        XCTAssertEqual(Format.remaining(3600 + 19 * 60), "1h 19m")
        XCTAssertEqual(Format.remaining(4 * 86_400 + 22 * 3600), "4d 22h")
        XCTAssertEqual(Format.dollars(4.5), "$4.50")
        XCTAssertEqual(Format.dollars(125), "$125")
    }
}

final class DecoderTests: XCTestCase {
    func testClaudeWindows() throws {
        let json = """
        {
          "five_hour": {"utilization": 15, "resets_at": "2026-09-29T16:00:00Z"},
          "seven_day": {"utilization": 31, "resets_at": "2026-09-30T06:00:00Z"},
          "limits": [{
            "kind": "weekly_scoped",
            "utilization": 46,
            "resets_at": "2026-09-30T06:00:00Z",
            "scope": {"model": {"display_name": "Fable"}}
          }],
          "extra_usage": {"is_enabled": false, "utilization": 90}
        }
        """.data(using: .utf8)!
        let parsed = ClaudeUsage.decode(json, now: DateParse.iso("2026-09-29T12:00:00Z")!)
        XCTAssertEqual(parsed.headline?.id, "seven_day")
        XCTAssertEqual(parsed.headline?.usedPercent, 31)
        XCTAssertEqual(parsed.extras.map(\.label), ["Session (5-hour)", "Fable Weekly"])
        XCTAssertFalse(parsed.extras.contains { $0.id == "extra_usage" })
    }

    func testClaudeExtraUsageWhenEnabled() throws {
        let json = """
        {"extra_usage": {"is_enabled": true, "utilization": 12, "monthly_limit": 20, "used_credits": 3}}
        """.data(using: .utf8)!
        let parsed = ClaudeUsage.decode(json, now: Date())
        XCTAssertEqual(parsed.extras.map(\.label), ["Extra usage"])
        XCTAssertEqual(parsed.extras.first?.usedPercent, 12)
        XCTAssertEqual(parsed.extras.first?.detail, "$3.00 / $20.00")
    }

    func testCodexPicksTheLongerWindow() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1000},
            "secondary_window": {"used_percent": 18, "limit_window_seconds": 604800, "reset_at": 2000}
          },
          "additional_rate_limits": [
            {"limit_name": "codex", "used_percent": 18, "limit_window_seconds": 604800, "reset_at": 2000},
            {"limit_name": "gpt-5", "used_percent": 9, "limit_window_seconds": 604800, "reset_at": 2000}
          ]
        }
        """.data(using: .utf8)!
        let parsed = CodexUsage.decode(json, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(parsed.headline?.id, "seven_day")
        XCTAssertEqual(parsed.headline?.usedPercent, 18)
        XCTAssertEqual(parsed.headline?.label, "Weekly")
        XCTAssertEqual(parsed.extras.map(\.label), ["Session (5-hour)", "gpt-5"])
    }

    func testZaiUnitsAndFractionPercent() {
        let json = """
        {"data": {"level": "coding", "limits": [
          {"unit": 3, "type": "TOKENS_LIMIT", "percentage": 15, "nextResetTime": 1790000000000},
          {"unit": 6, "type": "TOKENS_LIMIT", "percentage": 0.31, "nextResetTime": 1791000000000},
          {"unit": 5, "type": "TOOL", "percentage": 40, "currentValue": 12, "usage": 100, "nextResetTime": 1792000000000},
          {"unit": 9, "type": "TIME_LIMIT", "percentage": 5, "nextResetTime": 1792000000000}
        ]}}
        """.data(using: .utf8)!
        let now = DateParse.iso("2026-09-29T00:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = ZaiUsage.decodeQuota(json, now: now, calendar: calendar)
        XCTAssertEqual(parsed.headline?.id, "seven_day")
        XCTAssertEqual(parsed.headline?.usedPercent ?? 0, 31, accuracy: 0.001)
        XCTAssertEqual(parsed.extras.first { $0.id == "five_hour" }?.label, "Session (5-hour)")
        let tools = parsed.extras.first { $0.label == "MCP tools" }
        XCTAssertEqual(tools?.detail, "12/100")
        XCTAssertNotNil(tools?.window)
        let unknown = parsed.extras.first { $0.label == "Time Limit" }
        XCTAssertEqual(unknown?.usedPercent, 5)
        XCTAssertNil(unknown?.window)
        XCTAssertEqual(ZaiUsage.scaledPercent(31), 31)
        XCTAssertEqual(ZaiUsage.scaledPercent(0), 0)
    }

    func testZaiResetPacksAndModelBuckets() {
        let resets = """
        {"data": {"fiveHourResets": [{"available": true}, {"available": false}, {"available": true}], "weekResets": [{"available": true}]}}
        """.data(using: .utf8)!
        let rows = ZaiUsage.decodeResets(resets)
        XCTAssertEqual(rows.map(\.amountText), ["2 left", "1 left"])

        let usage = """
        {"data": [
          {"x_time": "2026-09-28 08:00:00", "tokens_usage": 100},
          {"x_time": "2026-09-28 09:00:00", "tokens_usage": 50}
        ]}
        """.data(using: .utf8)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ZaiUsage.modelDays(usage, calendar: utc)["2026-09-28"], 150)
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(ZaiUsage.modelDays(usage, calendar: losAngeles)["2026-09-27"], 150)

        let start = DateParse.iso("2026-09-23T00:00:00Z")!
        let url = ZaiUsage.modelURL(start: start, end: start.addingTimeInterval(3600))
        XCTAssertTrue(url?.absoluteString.contains("+") == true)
        XCTAssertFalse(url?.absoluteString.contains("%20") == true)
    }

    func testOpenRouterCapAndUncappedKey() throws {
        let now = DateParse.iso("2026-09-30T15:00:00Z")!
        let capped = """
        {"data": {"limit": 100, "limit_remaining": 40, "limit_reset": "monthly", "usage_daily": 1, "usage_weekly": 4, "usage_monthly": 60}}
        """.data(using: .utf8)!
        let monthly = OpenRouterUsage.decode(capped, now: now)
        XCTAssertEqual(monthly.headline?.usedPercent, 60)
        XCTAssertEqual(monthly.headline?.label, "Monthly")
        let period = try XCTUnwrap(OpenRouterUsage.period(reset: "monthly", now: now))
        XCTAssertEqual(period.resetsAt.timeIntervalSince1970, DateParse.iso("2026-10-01T00:00:00Z")!.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(period.window, 30 * 86_400, accuracy: 1)
        XCTAssertEqual(monthly.headline?.resetsAt?.timeIntervalSince1970 ?? 0, period.resetsAt.timeIntervalSince1970, accuracy: 1)

        let weekly = try XCTUnwrap(OpenRouterUsage.period(reset: "weekly", now: now))
        XCTAssertEqual(weekly.resetsAt.timeIntervalSince1970, DateParse.iso("2026-10-05T00:00:00Z")!.timeIntervalSince1970, accuracy: 1)
        let monday = DateParse.iso("2026-10-05T15:00:00Z")!
        let next = try XCTUnwrap(OpenRouterUsage.period(reset: "weekly", now: monday))
        XCTAssertEqual(next.resetsAt.timeIntervalSince1970, DateParse.iso("2026-10-12T00:00:00Z")!.timeIntervalSince1970, accuracy: 1)

        let open = """
        {"data": {"limit": null, "usage_daily": 1.25, "usage_weekly": 4.5, "usage_monthly": 20}}
        """.data(using: .utf8)!
        let uncapped = OpenRouterUsage.decode(open, now: now)
        XCTAssertNil(uncapped.headline?.usedPercent)
        XCTAssertNil(uncapped.headline?.window)
        XCTAssertEqual(uncapped.headline?.amountText, "$4.50")
        XCTAssertEqual(uncapped.extras.map(\.amountText), ["$1.25", "$20.00"])
    }

    func testGrokBillingPayload() {
        let json = """
        {"config": {
          "creditUsagePercent": 22,
          "currentPeriod": {"start": "2026-09-22T00:00:00Z", "end": "2026-09-29T00:00:00Z"},
          "productUsage": [{"name": "Grok 4", "usagePercent": 10}],
          "monthlyLimit": 2000,
          "includedUsed": 500,
          "prepaidBalance": 250
        }}
        """.data(using: .utf8)!
        let parsed = GrokUsage.decode(json, now: DateParse.iso("2026-09-28T00:00:00Z")!)
        XCTAssertEqual(parsed.headline?.usedPercent, 22)
        XCTAssertEqual(parsed.headline?.window, 7 * 86_400)
        XCTAssertEqual(parsed.extras.first { $0.label == "Grok 4" }?.usedPercent, 10)
        let monthly = parsed.extras.first { $0.id == "monthly" }
        XCTAssertEqual(monthly?.usedPercent, 25)
        XCTAssertEqual(monthly?.detail, "$5.00 / $20.00")
        XCTAssertEqual(parsed.extras.first { $0.id == "prepaid" }?.amountText, "$2.50")
    }

    func testFailedCodexRefreshDoesNotRequireAFileWrite() async throws {
        struct ScriptedHTTP: HTTPSending {
            func send(_ request: URLRequest) async throws -> HTTPResult {
                HTTPResult(status: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))
            }
        }
        let current = OAuthTokens(access: "old-access", refresh: "old-refresh", expires: Date(timeIntervalSince1970: 0))
        do {
            _ = try await CodexAuth.refresh(current, http: ScriptedHTTP(), now: Date())
            XCTFail("refresh should fail")
        } catch let error as ProviderError {
            if case .signedOut = error {} else { XCTFail("expected signed out") }
        }
    }
}

final class HistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClaudeLogSumsCacheTokensAndSkipsOtherRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let line = """
        {"type":"assistant","timestamp":"2026-09-28T12:00:00Z","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":4,"cache_creation_input_tokens":8}}}
        {"type":"user","timestamp":"2026-09-28T12:00:00Z","message":{"usage":{"input_tokens":100}}}
        {"type":"assistant","timestamp":"2026-09-01T12:00:00Z","message":{"usage":{"input_tokens":999}}}
        """
        let days = SessionLog.claudeDays(Data(line.utf8), calendar: calendar)
        XCTAssertEqual(days["2026-09-28"], 15)
        XCTAssertEqual(days["2026-09-01"], 999)
        let now = DateParse.iso("2026-09-29T15:00:00Z")!
        let bars = WeekChart.make(ending: now, amounts: days, missingZero: true, calendar: calendar)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.first { $0.id == "2026-09-27" }?.amount, 0)
        XCTAssertEqual(bars.first { $0.id == "2026-09-28" }?.amount, 15)
        XCTAssertNil(bars.first { $0.id == "2026-09-01" })
    }

    func testCodexUsesTurnDeltaNotCumulativeTotal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let withLast = """
        {"timestamp":"2026-09-28T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100,"input_tokens":1},"total_token_usage":{"total_tokens":100}}}}
        {"timestamp":"2026-09-28T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":40},"total_token_usage":{"total_tokens":140}}}}
        """
        XCTAssertEqual(SessionLog.codexDays(Data(withLast.utf8), calendar: calendar)["2026-09-28"], 140)

        let cumulative = """
        {"timestamp":"2026-09-28T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}
        {"timestamp":"2026-09-28T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":150}}}}
        """
        XCTAssertEqual(SessionLog.codexDays(Data(cumulative.utf8), calendar: calendar)["2026-09-28"], 150)
    }

    func testHistoryCacheSkipsUnchangedFilesAndOldMtime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateParse.iso("2026-09-29T15:00:00Z")!
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let recent = projects.appendingPathComponent("recent.jsonl")
        let body = #"{"type":"assistant","timestamp":"2026-09-28T12:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        try Data(body.utf8).write(to: recent)
        let old = projects.appendingPathComponent("old.jsonl")
        try Data(body.utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-9 * 86_400)],
            ofItemAtPath: old.path
        )
        let cache = root.appendingPathComponent("cache.json")
        let counter = CallCount()
        let parse: (Data) -> [String: Double] = { data in
            counter.value += 1
            return SessionLog.claudeDays(data, calendar: calendar)
        }
        let first = LocalHistory.week(root: projects, cacheFile: cache, now: now, calendar: calendar, parse: parse)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(first.first { $0.id == "2026-09-28" }?.amount, 10)
        XCTAssertEqual(first.first { $0.id == "2026-09-27" }?.amount, 0)
        _ = LocalHistory.week(root: projects, cacheFile: cache, now: now, calendar: calendar, parse: parse)
        XCTAssertEqual(counter.value, 1)
    }

    func testOpenRouterSamplesOverwriteAndLeaveGaps() throws {
        let url = root.appendingPathComponent("samples.json")
        CreditSamples.store(day: "2026-09-29", value: 1, url: url)
        CreditSamples.store(day: "2026-09-29", value: 2.5, url: url)
        XCTAssertEqual(CreditSamples.load(url)["2026-09-29"], 2.5)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateParse.iso("2026-09-29T12:00:00Z")!
        let bars = CreditSamples.week(url: url, now: now, calendar: calendar)
        XCTAssertEqual(bars.first { $0.id == "2026-09-29" }?.amount, 2.5)
        XCTAssertNil(bars.first { $0.id == "2026-09-28" }?.amount)
    }

    func testCredentialPatchPreservesUnknownKeysAndMode() throws {
        let url = root.appendingPathComponent("auth.json")
        let original = #"{"keep":"yes","tokens":{"access_token":"a","refresh_token":"b"}}"#
        try Data(original.utf8).write(to: url)
        try JSONFile.patch(url) { root in
            var tokens = JSONValue.dict(root["tokens"]) ?? [:]
            tokens["access_token"] = "c"
            root["tokens"] = tokens
        }
        let saved = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONValue.object(from: saved))
        XCTAssertEqual(JSONValue.string(object["keep"]), "yes")
        let tokens = try XCTUnwrap(JSONValue.dict(object["tokens"]))
        XCTAssertEqual(JSONValue.string(tokens["access_token"]), "c")
        XCTAssertEqual(JSONValue.string(tokens["refresh_token"]), "b")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value & 0o777, 0o600)
    }

    func testSnapshotMergeKeepsLastGoodAndReplacesSignedOut() {
        let ready = ProviderSnapshot(id: "claude", name: "Claude", symbol: "sparkle", status: .ready, fetchedAt: Date(timeIntervalSince1970: 10), headline: QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 31))
        let failed = ProviderSnapshot(id: "claude", name: "Claude", symbol: "sparkle", status: .failed("Rate limited"), retryAfter: Date(timeIntervalSince1970: 99))
        let merged = SnapshotMerge.apply(previous: [ready], fresh: [failed])
        XCTAssertEqual(merged.first?.status, .ready)
        XCTAssertEqual(merged.first?.stale, true)
        XCTAssertEqual(merged.first?.headline?.usedPercent, 31)
        XCTAssertEqual(merged.first?.retryAfter, Date(timeIntervalSince1970: 99))

        let signedOut = ProviderSnapshot(id: "claude", name: "Claude", symbol: "sparkle", status: .signedOut("Run claude and sign in"))
        let replaced = SnapshotMerge.apply(previous: [ready], fresh: [signedOut])
        XCTAssertEqual(replaced.first?.status, .signedOut("Run claude and sign in"))
    }
}

final class ProviderListTests: XCTestCase {
    func testOrderKeepsCustomSequenceAndAppendsNewIDs() {
        let order = ProviderList.normalizedOrder("grok,claude,nope")
        XCTAssertEqual(order, ["grok", "claude", "codex", "zai", "openrouter"])
    }

    func testEnabledFollowsOrderAndEmptyMeansNone() {
        let order = ["grok", "claude", "codex", "zai", "openrouter"]
        XCTAssertEqual(ProviderList.enabled(order: order, enabledRaw: nil), order)
        XCTAssertEqual(ProviderList.enabled(order: order, enabledRaw: ""), [])
        XCTAssertEqual(
            ProviderList.enabled(order: order, enabledRaw: "claude,grok"),
            ["grok", "claude"]
        )
    }

    func testVisibleMoveLeavesDisabledSlotsAlone() {
        let full = ["claude", "codex", "zai", "openrouter", "grok"]
        let moved = ProviderList.applyVisible(["claude", "grok", "zai", "openrouter"], to: full)
        XCTAssertEqual(moved, ["claude", "codex", "grok", "zai", "openrouter"])
        XCTAssertEqual(ProviderList.moved(full, from: 4, by: -1), ["claude", "codex", "zai", "grok", "openrouter"])
    }
}

private final class CallCount: @unchecked Sendable {
    var value = 0
}
