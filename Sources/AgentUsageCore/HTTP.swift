import Foundation

public struct HTTPResult: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: Date?

    public init(status: Int, body: Data, retryAfter: Date? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

public protocol HTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

public struct SessionHTTP: HTTPSending {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        var request = request
        if request.timeoutInterval <= 0 || request.timeoutInterval > 60 {
            request.timeoutInterval = 20
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResult(status: http?.statusCode ?? 0, body: data, retryAfter: Self.retryDate(http))
    }

    private static func retryDate(_ response: HTTPURLResponse?) -> Date? {
        guard let header = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(header) {
            return Date().addingTimeInterval(seconds)
        }
        return DateParse.iso(header)
    }
}

enum ProviderError: Error, Sendable {
    case signedOut(String)
    case unauthorized
    case limited(Date?)
    case http(Int)
    case message(String)
}

enum API {
    static func send(_ http: any HTTPSending, _ request: URLRequest) async throws -> HTTPResult {
        do {
            return try await http.send(request)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.message("Couldn't reach the service")
        }
    }

    static func ok(_ result: HTTPResult) throws -> Data {
        switch result.status {
        case 200..<300:
            return result.body
        case 401:
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.limited(result.retryAfter ?? Date().addingTimeInterval(5 * 60))
        default:
            throw ProviderError.http(result.status)
        }
    }

    static func get(_ url: URL, bearer: String, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agent-usage", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agent-usage", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    static func postForm(_ url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let body = fields.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agent-usage", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum Snap {
    static func ready(
        id: String,
        parsed: ParsedQuota,
        days: [DayBar] = [],
        unit: ChartUnit = .tokens,
        note: String? = nil,
        now: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: ProviderID.name(id),
            symbol: ProviderID.symbol(id),
            status: .ready,
            fetchedAt: now,
            headline: parsed.headline,
            extras: parsed.extras,
            days: days,
            chartUnit: unit,
            chartNote: note
        )
    }

    static func signedOut(id: String, _ message: String, now: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: ProviderID.name(id),
            symbol: ProviderID.symbol(id),
            status: .signedOut(message),
            fetchedAt: now
        )
    }

    static func failed(id: String, _ message: String, retryAfter: Date? = nil, now: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            name: ProviderID.name(id),
            symbol: ProviderID.symbol(id),
            status: .failed(message),
            fetchedAt: now,
            retryAfter: retryAfter
        )
    }
}

public enum SnapshotMerge {
    /// A failed refresh keeps the last ready card and marks it stale. Signed-out replaces it.
    public static func apply(previous: [ProviderSnapshot], fresh: [ProviderSnapshot]) -> [ProviderSnapshot] {
        fresh.map { snap in
            guard case .failed = snap.status,
                  let old = previous.first(where: { $0.id == snap.id && $0.status == .ready })
            else { return snap }
            var kept = old
            kept.stale = true
            kept.retryAfter = snap.retryAfter
            return kept
        }
    }
}

public enum SnapshotCache {
    public static func load(_ url: URL) -> [ProviderSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProviderSnapshot].self, from: data)) ?? []
    }

    public static func save(_ snapshots: [ProviderSnapshot], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
