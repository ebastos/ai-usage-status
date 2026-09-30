# Agent Usage

macOS 14 menu bar app and CLI that shows quota for Claude, Codex, Z.ai, OpenRouter, and Grok. Swift 6 package. The bundled app is an `LSUIElement` agent (`Support/Info.plist`).

## Commands

- Test: `swift test`
- CLI: `swift run agent-usage` (`--json` prints ISO-8601 snapshots; exit 1 when none are `.ready`)
- Window: `swift run AgentUsage --window`
- Menu bar bundle: `scripts/build-app.sh` (release binary, copies `Support/Info.plist`, ad-hoc `codesign`)

## Layout

- `Sources/AgentUsageCore` — providers, credentials, history, formatting. New quota behavior goes here.
- `Sources/AgentUsage` — SwiftUI menu bar, dashboard, settings. Reads `UsageStore`; does not call providers.
- `Sources/AgentUsageCLI` — table or JSON. Builds `UsageService` with `allowKeychainPrompt: false`.
- `Tests/AgentUsageCoreTests/CoreTests.swift` — the only test file. The UI has no tests.

## Decisions

### Where the change goes

| Question | → Core | → App or CLI |
| --- | --- | --- |
| Quota, auth, history, formatting, provider list rules | Yes | — |
| Menu bar, settings, window placement | — | `AgentUsage` |
| stdout table or process exit code | — | `AgentUsageCLI` |

### Parsing JSON

| Question | → `JSONValue` | → `Codable` |
| --- | --- | --- |
| A provider HTTP body (camelCase and snake_case aliases) | Yes | — |
| The snapshot cache (`ProviderSnapshot` in `snapshots.json`) | — | Yes, `.iso8601` dates |

### Which window is the headline

`QuotaPick.split` picks the longest `window`. Equal lengths prefer id `seven_day`, then `weekly`. Everything else is `extras`. Rank by window length, not by percent used.

### HTTP

| Question | → `API` + `HTTPSending` | → `URLSession` |
| --- | --- | --- |
| Any provider request | `API.get` / `postJSON` / `postForm`, then `API.send` and `API.ok` | — |
| A test | A local `HTTPSending` (`ScriptedHTTP` in `CoreTests`) | — |

## Adding a provider

1. Add the id in `ProviderID` (`all`, `name`, `symbol`, `signInHint`, and `shortName` when the menu bar label differs). Settings, order, and the dashboard read `ProviderID.all`. Leave the view lists alone.
2. Add `Sources/AgentUsageCore/<Name>Usage.swift` with `decode(_:now:) -> ParsedQuota` and `fetch(...) async throws -> ProviderSnapshot`. Return `Snap.ready`. Throw `ProviderError`; `UsageService.one` maps it to signed-out or failed.
3. Add the `case` in `UsageService.one`.
4. Read credentials with the existing helpers. Claude: `KeychainStore` service `Claude Code-credentials` (only the app sets `allowKeychainPrompt: true`). Codex: `~/.codex/auth.json` via `CodexAuth` under `FileLock`. Grok: `~/.grok/auth.json` via `GrokAuth` under `FileLock`. Z.ai and OpenRouter: `StoredKey` (Z.ai plan key in `~/.zcode`, else OpenCode or Kilo `auth.json`). New secret files go through `SecretFile.write` (mode `0600`). Update tokens with `JSONFile.patch` so unknown keys stay.
5. Add a fixture test on `decode` in `DecoderTests`. Pass a fixed `now`.

```swift
let parsed = GrokUsage.decode(data, now: now)
return Snap.ready(id: ProviderID.grok, parsed: parsed, days: [], now: now)
```

```swift
let percent = JSONValue.firstDouble(object, "usagePercent", "usage_percent", "percent")
```

## Do / don't

- **Do not** call `URLSession` or `SecItemCopyMatching` from a provider. **Do** take `http: any HTTPSending`. Claude keychain reads go through `KeychainStore.read`; the CLI races a 4s timeout because that call cannot be cancelled.
- **Do not** replace a ready card when refresh fails. **Do** throw `ProviderError` and let `SnapshotMerge.apply` keep the last `.ready` card, set `stale`, and copy `retryAfter`. `.signedOut` replaces the card. Use `ProviderID.signInHint` for the message.
- **Do not** treat `enabledProviders == ""` as all providers. **Do** call `ProviderList.enabled`: `nil` means every id, `""` means none. `normalizedOrder` drops unknown ids and appends any id missing from `ProviderID.all`.
- **Do not** read JSON booleans with `as? Bool`. **Do** use `JSONValue.bool` (`CFBoolean`). `JSONValue.double` accepts a number or a numeric string.
- **Do not** refresh OAuth from two tasks at once, and **do not** put tokens in errors or logs. **Do** hold `FileLock.exclusively` (Codex and Grok files) or `RefreshTurnstile.claude` (keychain). Refresh when expiry is inside 60 seconds, and once more after HTTP 401. User-visible OAuth failures use `OAuthBody.errorCode` only.
- **Do not** let SwiftUI pick the `--window` size. **Do** leave `host.sizingOptions = []` and place the window with `AppDelegate.place` so it stays on the display under the pointer.

## Domain rules

- Percents are 0–100 `Double`s. Z.ai may send a fraction; `ZaiUsage.scaledPercent` maps `0.31` to `31`.
- Grok `monthlyLimit`, `includedUsed`, and `prepaidBalance` are cents (`value / 100` into `Format.dollars`). OpenRouter usage and Claude extra-usage credits are already dollars.
- `DateParse.unix` treats values above `10_000_000_000` as milliseconds. `DateParse.shanghai` parses `yyyy-MM-dd HH:mm:ss` in Asia/Shanghai.
- `PaceMath.make` returns nil when `window <= 0`. `aheadPercent` is rounded expected minus rounded used. Positive means more quota left than the clock suggests.
- Week bars: Claude and Codex local logs use `WeekChart.make(..., missingZero: true)` (absent days are `0`). OpenRouter credit samples leave gaps as `nil`. A Codex row with `last_token_usage` counts that turn; cumulative `total_token_usage` is only the fallback.
- The app refreshes each enabled provider on its own task (`UsageStore.inFlight`) every 60 seconds, and skips a provider until `retryAfter`. A slow keychain prompt must not block the others.
- Provider enums, `API`, `Snap`, `JSONValue`, and `ProviderError` stay internal. The app and CLI use the `public` types: `UsageService`, `ProviderSnapshot`, `Format`, `ProviderList`, `SnapshotCache`, `SnapshotMerge`.
