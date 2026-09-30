import Foundation

public struct UsageService: Sendable {
    public var home: URL
    public var support: URL
    public var allowKeychainPrompt: Bool
    public var http: any HTTPSending

    public init(home: URL, allowKeychainPrompt: Bool, support: URL? = nil, http: any HTTPSending = SessionHTTP()) {
        self.home = home
        self.allowKeychainPrompt = allowKeychainPrompt
        self.http = http
        if let support {
            self.support = support
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.support = base.appendingPathComponent("AgentUsage", isDirectory: true)
        }
    }

    public func fetch(ids: [String] = ProviderID.all, now: Date = Date()) async -> [ProviderSnapshot] {
        let ids = ids.isEmpty ? [] : ids
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return await withTaskGroup(of: ProviderSnapshot.self) { group in
            for id in ids {
                group.addTask {
                    await self.one(id, now: now)
                }
            }
            var byID: [String: ProviderSnapshot] = [:]
            for await snapshot in group {
                byID[snapshot.id] = snapshot
            }
            return ids.map { byID[$0] ?? Snap.failed(id: $0, "Unavailable", now: now) }
        }
    }

    private func one(_ id: String, now: Date) async -> ProviderSnapshot {
        do {
            switch id {
            case ProviderID.claude:
                return try await ClaudeUsage.fetch(home: home, support: support, allowPrompt: allowKeychainPrompt, http: http, now: now)
            case ProviderID.codex:
                return try await CodexUsage.fetch(home: home, support: support, http: http, now: now)
            case ProviderID.zai:
                return try await ZaiUsage.fetch(home: home, http: http, now: now)
            case ProviderID.openrouter:
                return try await OpenRouterUsage.fetch(home: home, support: support, http: http, now: now)
            case ProviderID.grok:
                return try await GrokUsage.fetch(home: home, http: http, now: now)
            default:
                return Snap.failed(id: id, "Unknown provider", now: now)
            }
        } catch let error as ProviderError {
            return Self.snapshot(id: id, error: error, now: now)
        } catch {
            return Snap.failed(id: id, "Couldn't reach the service", now: now)
        }
    }

    private static func snapshot(id: String, error: ProviderError, now: Date) -> ProviderSnapshot {
        switch error {
        case .signedOut(let message):
            return Snap.signedOut(id: id, message, now: now)
        case .unauthorized:
            return Snap.signedOut(id: id, ProviderID.signInHint(id), now: now)
        case .limited(let until):
            return Snap.failed(id: id, "Rate limited", retryAfter: until, now: now)
        case .http(let status):
            return Snap.failed(id: id, "The service returned HTTP \(status)", now: now)
        case .message(let text):
            return Snap.failed(id: id, text, now: now)
        }
    }
}
