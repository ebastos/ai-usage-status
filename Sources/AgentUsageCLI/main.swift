import AgentUsageCore
import Foundation

@main
struct AgentUsageCLI {
    static func main() async {
        let snapshots = await UsageService(
            home: FileManager.default.homeDirectoryForCurrentUser,
            allowKeychainPrompt: false
        ).fetch()
        if CommandLine.arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshots), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            printTable(snapshots)
        }
        let ready = snapshots.contains { if case .ready = $0.status { return true } else { return false } }
        exit(ready ? 0 : 1)
    }

    private static func printTable(_ snapshots: [ProviderSnapshot]) {
        let now = Date()
        for snapshot in snapshots {
            switch snapshot.status {
            case .ready:
                let line = snapshot.headline.map { Format.usedLine($0, now: now, includeResetsWord: true) } ?? "no quota reported"
                print("\(snapshot.name)\t\(line)\(snapshot.stale ? "\tstale" : "")")
                for extra in snapshot.extras {
                    print("  \(extra.label)\t\(Format.usedLine(extra, now: now, includeResetsWord: false))")
                }
            case .signedOut(let message):
                print("\(snapshot.name)\tsigned out: \(message)")
            case .failed(let message):
                print("\(snapshot.name)\tfailed: \(message)")
            }
        }
    }
}
