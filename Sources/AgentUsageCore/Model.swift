import Foundation

public struct QuotaWindow: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var label: String
    public var usedPercent: Double?
    public var amountText: String?
    public var resetsAt: Date?
    public var window: TimeInterval?
    public var detail: String?

    public init(
        id: String,
        label: String,
        usedPercent: Double? = nil,
        amountText: String? = nil,
        resetsAt: Date? = nil,
        window: TimeInterval? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.amountText = amountText
        self.resetsAt = resetsAt
        self.window = window
        self.detail = detail
    }
}

public struct DayBar: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var date: Date
    public var amount: Double?

    public init(id: String, date: Date, amount: Double?) {
        self.id = id
        self.date = date
        self.amount = amount
    }
}

public enum ChartUnit: String, Codable, Sendable {
    case tokens
    case credits
}

public enum ProviderStatus: Equatable, Sendable, Codable {
    case ready
    case signedOut(String)
    case failed(String)
}

public struct ProviderSnapshot: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var symbol: String
    public var status: ProviderStatus
    public var fetchedAt: Date?
    public var stale: Bool
    public var headline: QuotaWindow?
    public var extras: [QuotaWindow]
    public var days: [DayBar]
    public var chartUnit: ChartUnit
    public var chartNote: String?
    public var retryAfter: Date?

    public init(
        id: String,
        name: String,
        symbol: String,
        status: ProviderStatus,
        fetchedAt: Date? = nil,
        stale: Bool = false,
        headline: QuotaWindow? = nil,
        extras: [QuotaWindow] = [],
        days: [DayBar] = [],
        chartUnit: ChartUnit = .tokens,
        chartNote: String? = nil,
        retryAfter: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.status = status
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.headline = headline
        self.extras = extras
        self.days = days
        self.chartUnit = chartUnit
        self.chartNote = chartNote
        self.retryAfter = retryAfter
    }
}

public enum ProviderID {
    public static let claude = "claude"
    public static let codex = "codex"
    public static let zai = "zai"
    public static let openrouter = "openrouter"
    public static let grok = "grok"
    public static let all = [claude, codex, zai, openrouter, grok]

    public static func name(_ id: String) -> String {
        switch id {
        case claude: return "Claude"
        case codex: return "Codex"
        case zai: return "Z.ai"
        case openrouter: return "OpenRouter"
        case grok: return "Grok"
        default: return id
        }
    }

    public static func symbol(_ id: String) -> String {
        switch id {
        case claude: return "sparkle"
        case codex: return "terminal"
        case zai: return "z.square"
        case openrouter: return "point.3.connected.trianglepath.dotted"
        case grok: return "bolt.fill"
        default: return "circle"
        }
    }

    public static func shortName(_ id: String) -> String {
        switch id {
        case openrouter: return "Router"
        default: return name(id)
        }
    }

    public static func signInHint(_ id: String) -> String {
        switch id {
        case claude: return "Run claude and sign in"
        case codex: return "Run codex login"
        case zai: return "Add a Z.ai key in ZCode or OpenCode"
        case openrouter: return "Add an OpenRouter key in OpenCode"
        case grok: return "Run grok login"
        default: return "Sign in"
        }
    }
}

public struct ParsedQuota: Equatable, Sendable {
    public var headline: QuotaWindow?
    public var extras: [QuotaWindow]

    public init(headline: QuotaWindow?, extras: [QuotaWindow]) {
        self.headline = headline
        self.extras = extras
    }
}

enum QuotaPick {
    /// Longest window is the headline. Equal lengths prefer `seven_day`, then `weekly`.
    static func split(_ windows: [QuotaWindow]) -> ParsedQuota {
        guard let headline = windows.max(by: { rank($0) < rank($1) }) else {
            return ParsedQuota(headline: nil, extras: [])
        }
        return ParsedQuota(headline: headline, extras: windows.filter { $0.id != headline.id })
    }

    private static func rank(_ window: QuotaWindow) -> (TimeInterval, Int) {
        let length = window.window ?? 0
        let tie: Int
        switch window.id {
        case "seven_day": tie = 3
        case "weekly": tie = 2
        default: tie = 1
        }
        return (length, tie)
    }
}
