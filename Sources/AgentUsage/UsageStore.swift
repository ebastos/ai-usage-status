import AgentUsageCore
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var refreshing = false

    private let service: UsageService
    private let cacheURL: URL
    private var timer: Timer?
    /// Providers with a fetch still running. A slow keychain prompt must not block the others.
    private var inFlight: Set<String> = []

    init(service: UsageService? = nil) {
        let resolved = service ?? UsageService(
            home: FileManager.default.homeDirectoryForCurrentUser,
            allowKeychainPrompt: true
        )
        self.service = resolved
        self.cacheURL = resolved.support.appendingPathComponent("snapshots.json")
        snapshots = SnapshotCache.load(cacheURL)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh(force: false)
    }

    func refresh(force: Bool) {
        let enabled = Self.enabledIDs()
        let now = Date()
        let due = enabled.filter { id in
            if inFlight.contains(id) { return false }
            guard !force, let until = snapshots.first(where: { $0.id == id })?.retryAfter else { return true }
            return until <= now
        }
        for id in due {
            inFlight.insert(id)
            Task {
                let snapshot = await service.fetch(ids: [id], now: Date()).first
                    ?? ProviderSnapshot(
                        id: id,
                        name: ProviderID.name(id),
                        symbol: ProviderID.symbol(id),
                        status: .failed("Unavailable"),
                        fetchedAt: Date()
                    )
                self.absorb(snapshot)
                self.inFlight.remove(id)
                self.refreshing = !self.inFlight.isEmpty
                SnapshotCache.save(self.snapshots, to: self.cacheURL)
            }
        }
        refreshing = !inFlight.isEmpty
        // Drop cards whose provider was just turned off, even when nothing is due.
        snapshots = enabled.compactMap { id in snapshots.first { $0.id == id } }
    }

    private func absorb(_ snapshot: ProviderSnapshot) {
        let enabled = Self.enabledIDs()
        let merged = SnapshotMerge.apply(previous: snapshots, fresh: [snapshot]).first ?? snapshot
        var byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        if enabled.contains(merged.id) {
            byID[merged.id] = merged
        }
        snapshots = enabled.compactMap { byID[$0] }
    }

    func menuText(enabled: [String]) -> String {
        enabled.compactMap { id -> String? in
            guard let snapshot = snapshots.first(where: { $0.id == id }),
                  snapshot.status == .ready,
                  let headline = snapshot.headline else { return nil }
            if let used = headline.usedPercent {
                return "\(ProviderID.shortName(id)) \(Format.percent(used))"
            }
            if let amount = headline.amountText {
                return "\(ProviderID.shortName(id)) \(amount)"
            }
            return nil
        }.joined(separator: " · ")
    }

    static func enabledIDs() -> [String] {
        let order = ProviderList.normalizedOrder(UserDefaults.standard.string(forKey: "providerOrder") ?? "")
        return ProviderList.enabled(order: order, enabledRaw: UserDefaults.standard.string(forKey: "enabledProviders"))
    }
}
