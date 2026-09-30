import Foundation

enum SessionLog {
    static func claudeDays(_ data: Data, calendar: Calendar) -> [String: Double] {
        var totals: [String: Double] = [:]
        for object in lines(data) {
            guard JSONValue.string(object["type"]) == "assistant" else { continue }
            let message = JSONValue.dict(object["message"])
            guard let usage = JSONValue.dict(message?["usage"]) ?? JSONValue.dict(object["usage"]) else { continue }
            let tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0.0) { $0 + (JSONValue.double(usage[$1]) ?? 0) }
            guard tokens > 0, let stamp = JSONValue.string(object["timestamp"]), let date = DateParse.iso(stamp) else { continue }
            totals[Format.dayKey(date, calendar: calendar), default: 0] += tokens
        }
        return totals
    }

    static func codexDays(_ data: Data, calendar: Calendar) -> [String: Double] {
        var totals: [String: Double] = [:]
        var previousCumulative = 0.0
        for object in lines(data) {
            let payload = JSONValue.dict(object["payload"]) ?? object
            let kind = JSONValue.string(payload["type"]) ?? JSONValue.string(object["type"])
            guard kind == "token_count" else { continue }
            guard let info = JSONValue.dict(payload["info"]) ?? JSONValue.dict(object["info"]) else { continue }
            guard let stamp = JSONValue.string(object["timestamp"]) ?? JSONValue.string(payload["timestamp"]),
                  let date = DateParse.iso(stamp) else { continue }
            let delta: Double
            if let last = JSONValue.dict(info["last_token_usage"]) {
                delta = turnTokens(last)
            } else if let total = JSONValue.dict(info["total_token_usage"]) {
                let cumulative = turnTokens(total)
                delta = max(0, cumulative - previousCumulative)
                previousCumulative = cumulative
            } else {
                continue
            }
            if let total = JSONValue.dict(info["total_token_usage"]) {
                previousCumulative = turnTokens(total)
            }
            guard delta > 0 else { continue }
            totals[Format.dayKey(date, calendar: calendar), default: 0] += delta
        }
        return totals
    }

    private static func turnTokens(_ usage: [String: Any]) -> Double {
        if let total = JSONValue.double(usage["total_tokens"]), total > 0 { return total }
        return ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]
            .reduce(0.0) { $0 + (JSONValue.double(usage[$1]) ?? 0) }
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            JSONValue.object(from: Data(line.utf8))
        }
    }
}

struct HistoryIndex: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var mtime: TimeInterval
        var size: Int
        var days: [String: Double]
    }

    var files: [String: Entry] = [:]

    static func load(_ url: URL) -> HistoryIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(HistoryIndex.self, from: data) else {
            return HistoryIndex()
        }
        return index
    }

    func save(_ url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum LocalHistory {
    static let maxFileBytes = 64 * 1024 * 1024
    static let lookback: TimeInterval = 8 * 86_400

    static func week(
        root: URL,
        cacheFile: URL,
        now: Date,
        calendar: Calendar = .current,
        missingZero: Bool = true,
        parse: (Data) -> [String: Double]
    ) -> [DayBar] {
        let cutoff = now.addingTimeInterval(-lookback)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return WeekChart.make(ending: now, amounts: [:], missingZero: missingZero, calendar: calendar)
        }
        let previous = HistoryIndex.load(cacheFile)
        var index = HistoryIndex()
        var amounts: [String: Double] = [:]
        for file in jsonlFiles(root: root) {
            let stamp = fileStamp(file)
            let mtime = stamp.mtime
            let size = stamp.size
            if mtime < cutoff || size > maxFileBytes || size == 0 { continue }
            let path = file.path
            let cached = previous.files[path]
            let days: [String: Double]
            if let cached, cached.size == size, abs(cached.mtime - mtime.timeIntervalSince1970) < 2 {
                days = cached.days
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                days = parse(data)
            }
            index.files[path] = HistoryIndex.Entry(mtime: mtime.timeIntervalSince1970, size: size, days: days)
            for (day, amount) in days {
                amounts[day, default: 0] += amount
            }
        }
        index.save(cacheFile)
        return WeekChart.make(ending: now, amounts: amounts, missingZero: missingZero, calendar: calendar)
    }

    static func claudeWeek(home: URL, support: URL, now: Date, calendar: Calendar = .current) -> [DayBar] {
        week(
            root: home.appendingPathComponent(".claude/projects"),
            cacheFile: support.appendingPathComponent("claude-history.json"),
            now: now,
            calendar: calendar,
            parse: { SessionLog.claudeDays($0, calendar: calendar) }
        )
    }

    static func codexWeek(home: URL, support: URL, now: Date, calendar: Calendar = .current) -> [DayBar] {
        week(
            root: home.appendingPathComponent(".codex/sessions"),
            cacheFile: support.appendingPathComponent("codex-history.json"),
            now: now,
            calendar: calendar,
            parse: { SessionLog.codexDays($0, calendar: calendar) }
        )
    }

    private static func fileStamp(_ url: URL) -> (mtime: Date, size: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (.distantPast, 0)
        }
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return (mtime, size)
    }

    private static func jsonlFiles(root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            files.append(url)
        }
        return files
    }
}

enum CreditSamples {
    static func load(_ url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let root = JSONValue.object(from: data),
              let days = JSONValue.dict(root["days"]) else { return [:] }
        var amounts: [String: Double] = [:]
        for (key, value) in days {
            if let amount = JSONValue.double(value) { amounts[key] = amount }
        }
        return amounts
    }

    static func store(day: String, value: Double, url: URL) {
        var days = load(url)
        days[day] = value
        let payload: [String: Any] = ["days": days]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func week(url: URL, now: Date, calendar: Calendar = .current) -> [DayBar] {
        WeekChart.make(ending: now, amounts: load(url), missingZero: false, calendar: calendar)
    }
}
