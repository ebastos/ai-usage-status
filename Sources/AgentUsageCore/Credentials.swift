import Darwin
import Foundation
import LocalAuthentication
import Security

@_silgen_name("flock")
private func cFlock(_ fd: Int32, _ operation: Int32) -> Int32

struct OAuthTokens: Sendable {
    var access: String
    var refresh: String
    var expires: Date?
    var accountID: String?
    var clientID: String?
    var issuer: String?
    var entryKey: String?
    var idToken: String?
}

enum OAuthBody {
    /// A short OAuth `error` code, such as `invalid_grant`. Never a token or a description.
    static func errorCode(_ data: Data) -> String? {
        guard let object = JSONValue.object(from: data) else { return nil }
        let raw = JSONValue.firstString(object, "error")
            ?? JSONValue.string(JSONValue.dict(object["error"])?["code"])
        guard let raw, raw.count < 40, raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return raw
    }

    static func tokens(from data: Data) -> (access: String, refresh: String?, idToken: String?, expiresIn: Double?)? {
        guard let root = JSONValue.object(from: data) else { return nil }
        let nested = JSONValue.firstObject(root, "token", "data")
        let object = JSONValue.firstString(root, "access_token", "accessToken") != nil ? root : (nested ?? root)
        guard let access = JSONValue.firstString(object, "access_token", "accessToken") else { return nil }
        return (
            access,
            JSONValue.firstString(object, "refresh_token", "refreshToken"),
            JSONValue.firstString(object, "id_token", "idToken"),
            JSONValue.firstDouble(object, "expires_in", "expiresIn")
        )
    }
}

enum SecretFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var failed = false
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                failed = data.isEmpty == false
                return
            }
            var offset = 0
            while offset < data.count {
                let wrote = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if wrote < 0 {
                    failed = true
                    break
                }
                offset += wrote
            }
        }
        Darwin.fsync(fd)
        Darwin.close(fd)
        guard !failed else {
            Darwin.unlink(tmp.path)
            throw POSIXError(.EIO)
        }
        if Darwin.rename(tmp.path, url.path) != 0 {
            Darwin.unlink(tmp.path)
            throw POSIXError(.EIO)
        }
    }
}

enum JSONFile {
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JSONValue.object(from: data)
    }

    static func patch(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        let original = try Data(contentsOf: url)
        guard var object = JSONValue.object(from: original) else {
            throw ProviderError.message("Credentials file is unreadable")
        }
        change(&object)
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try SecretFile.write(encoded, to: url)
    }
}

enum FileLock {
    static func exclusively<T: Sendable>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        let fd = Darwin.open(url.path, O_RDWR)
        guard fd >= 0 else { throw ProviderError.message("Couldn't lock credentials") }
        let deadline = Date().addingTimeInterval(5)
        while cFlock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                Darwin.close(fd)
                throw ProviderError.message("Couldn't lock credentials")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        do {
            let value = try await body()
            _ = cFlock(fd, LOCK_UN)
            Darwin.close(fd)
            return value
        } catch {
            _ = cFlock(fd, LOCK_UN)
            Darwin.close(fd)
            throw error
        }
    }
}

/// One refresh at a time for credentials that don't live in a file (Claude's keychain item).
actor RefreshTurnstile {
    static let claude = RefreshTurnstile()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - text.count % 4) % 4
        text.append(contentsOf: String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: text) else { return nil }
        return JSONValue.object(from: data)
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = JSONValue.double(payload(token)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum KeychainStore {
    static let claudeService = "Claude Code-credentials"

    static func read(service: String, allowPrompt: Bool) async -> Result<Data, ProviderError> {
        if allowPrompt {
            return await offThread { readSync(service: service, allowPrompt: true) }
        }
        // SecItemCopyMatching cannot be cancelled. A task group would still wait
        // for that call after the timeout, so the CLI races it on a side thread
        // and resumes exactly once.
        let fallback = Result<Data, ProviderError>.failure(
            .signedOut("Keychain is locked. Open Agent Usage and allow access.")
        )
        return await withCheckedContinuation { continuation in
            let gate = FirstResume()
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(continuation, with: readSync(service: service, allowPrompt: false))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                gate.resume(continuation, with: fallback)
            }
        }
    }

    /// Resumes a continuation on the first caller. Later callers are ignored.
    private final class FirstResume: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func resume<T: Sendable>(_ continuation: CheckedContinuation<T, Never>, with value: sending T) {
            lock.lock()
            let first = !resumed
            resumed = true
            lock.unlock()
            if first {
                continuation.resume(returning: value)
            }
        }
    }

    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func readSync(service: String, allowPrompt: Bool) -> Result<Data, ProviderError> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .failure(.signedOut(ProviderID.signInHint(ProviderID.claude)))
            }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.signedOut(ProviderID.signInHint(ProviderID.claude)))
        case errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed:
            return .failure(.signedOut("Keychain is locked. Open Agent Usage and allow access."))
        default:
            return .failure(.message("Keychain read failed"))
        }
    }

    static func update(service: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }
}

enum ClaudeAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    static func load(allowPrompt: Bool) async -> Result<OAuthTokens, ProviderError> {
        switch await KeychainStore.read(service: KeychainStore.claudeService, allowPrompt: allowPrompt) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let tokens = tokens(from: data) else {
                return .failure(.signedOut(ProviderID.signInHint(ProviderID.claude)))
            }
            return .success(tokens)
        }
    }

    static func tokens(from data: Data) -> OAuthTokens? {
        guard let root = JSONValue.object(from: data) else { return nil }
        let oauth = JSONValue.dict(root["claudeAiOauth"]) ?? root
        guard let access = JSONValue.firstString(oauth, "accessToken", "access_token") else { return nil }
        let refresh = JSONValue.firstString(oauth, "refreshToken", "refresh_token") ?? ""
        let expires = JSONValue.firstDouble(oauth, "expiresAt", "expires_at").map(DateParse.unix)
        return OAuthTokens(access: access, refresh: refresh, expires: expires)
    }

    static func refreshedData(original: Data, access: String, refresh: String?, expiresAt: Date) -> Data? {
        guard var root = JSONValue.object(from: original) else { return nil }
        var oauth = JSONValue.dict(root["claudeAiOauth"]) ?? [:]
        oauth["accessToken"] = access
        if let refresh, !refresh.isEmpty {
            oauth["refreshToken"] = refresh
        }
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }

    static func refresh(_ current: OAuthTokens, http: any HTTPSending, allowPrompt: Bool, now: Date) async throws -> OAuthTokens {
        guard !current.refresh.isEmpty else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.claude))
        }
        let request = try API.postJSON(tokenURL, body: [
            "grant_type": "refresh_token",
            "refresh_token": current.refresh,
            "client_id": clientID,
        ])
        let result = try await API.send(http, request)
        guard (200..<300).contains(result.status),
              let body = JSONValue.object(from: result.body),
              let access = JSONValue.firstString(body, "access_token")
        else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.claude))
        }
        let refresh = JSONValue.firstString(body, "refresh_token") ?? current.refresh
        let lifetime = JSONValue.firstDouble(body, "expires_in") ?? 3600
        let expires = now.addingTimeInterval(lifetime)
        if case .success(let original) = await KeychainStore.read(service: KeychainStore.claudeService, allowPrompt: allowPrompt),
           let updated = refreshedData(original: original, access: access, refresh: refresh, expiresAt: expires) {
            _ = KeychainStore.update(service: KeychainStore.claudeService, data: updated)
        }
        return OAuthTokens(access: access, refresh: refresh, expires: expires)
    }
}

enum CodexAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static func read(_ url: URL) -> OAuthTokens? {
        guard let root = JSONFile.object(at: url), let tokens = JSONValue.dict(root["tokens"]) else { return nil }
        guard let access = JSONValue.string(tokens["access_token"]), !access.isEmpty else { return nil }
        let refresh = JSONValue.string(tokens["refresh_token"]) ?? ""
        var account = JSONValue.string(tokens["account_id"])
        if account == nil, let payload = JWT.payload(access),
           let auth = JSONValue.dict(payload["https://api.openai.com/auth"]) {
            account = JSONValue.string(auth["chatgpt_account_id"])
        }
        return OAuthTokens(access: access, refresh: refresh, expires: JWT.expiry(access), accountID: account)
    }

    static func write(_ tokens: OAuthTokens, to url: URL, now: Date) throws {
        try JSONFile.patch(url) { root in
            var nested = JSONValue.dict(root["tokens"]) ?? [:]
            nested["access_token"] = tokens.access
            if !tokens.refresh.isEmpty {
                nested["refresh_token"] = tokens.refresh
            }
            if let idToken = tokens.idToken, !idToken.isEmpty {
                nested["id_token"] = idToken
            }
            root["tokens"] = nested
            root["last_refresh"] = DateParse.isoString(now)
        }
    }

    static func refresh(_ current: OAuthTokens, http: any HTTPSending, now: Date) async throws -> OAuthTokens {
        guard !current.refresh.isEmpty else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.codex))
        }
        let body: [String: Any] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": current.refresh,
            "scope": "openid profile email",
        ]
        var result = try await API.send(http, try API.postJSON(tokenURL, body: body))
        // 415 means the endpoint wants a form body. A 400 may already have rejected the grant, so it is not retried.
        if result.status == 415 {
            result = try await API.send(http, API.postForm(tokenURL, fields: [
                ("client_id", clientID),
                ("grant_type", "refresh_token"),
                ("refresh_token", current.refresh),
                ("scope", "openid profile email"),
            ]))
        }
        guard (200..<300).contains(result.status), let minted = OAuthBody.tokens(from: result.body) else {
            let hint = ProviderID.signInHint(ProviderID.codex)
            if let code = OAuthBody.errorCode(result.body) {
                throw ProviderError.signedOut("\(hint) (\(code))")
            }
            throw ProviderError.signedOut(hint)
        }
        return OAuthTokens(
            access: minted.access,
            refresh: minted.refresh ?? current.refresh,
            expires: now.addingTimeInterval(minted.expiresIn ?? 3600),
            accountID: current.accountID,
            idToken: minted.idToken ?? current.idToken
        )
    }
}

enum GrokAuth {
    static func read(_ url: URL) -> OAuthTokens? {
        guard let root = JSONFile.object(at: url) else { return nil }
        var best: OAuthTokens?
        var bestExpiry: Date = .distantPast
        for (key, value) in root {
            guard let entry = JSONValue.dict(value),
                  let access = JSONValue.string(entry["key"]), !access.isEmpty,
                  let refresh = JSONValue.string(entry["refresh_token"]), !refresh.isEmpty
            else { continue }
            let expires = JSONValue.string(entry["expires_at"]).flatMap(DateParse.iso)
            let candidate = OAuthTokens(
                access: access,
                refresh: refresh,
                expires: expires,
                clientID: JSONValue.string(entry["oidc_client_id"]),
                issuer: JSONValue.string(entry["oidc_issuer"]) ?? "https://auth.x.ai",
                entryKey: key
            )
            let stamp = expires ?? .distantPast
            if best == nil || stamp > bestExpiry {
                best = candidate
                bestExpiry = stamp
            }
        }
        return best
    }

    static func write(_ tokens: OAuthTokens, to url: URL) throws {
        guard let entryKey = tokens.entryKey else { return }
        try JSONFile.patch(url) { root in
            var entry = JSONValue.dict(root[entryKey]) ?? [:]
            entry["key"] = tokens.access
            if !tokens.refresh.isEmpty {
                entry["refresh_token"] = tokens.refresh
            }
            if let expires = tokens.expires {
                entry["expires_at"] = DateParse.isoString(expires)
            }
            root[entryKey] = entry
        }
    }

    static func refresh(_ current: OAuthTokens, http: any HTTPSending, now: Date) async throws -> OAuthTokens {
        guard !current.refresh.isEmpty, let clientID = current.clientID, let issuer = current.issuer else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.grok))
        }
        let endpoint = try await tokenEndpoint(issuer: issuer, http: http)
        guard let url = URL(string: endpoint) else {
            throw ProviderError.message("Couldn't refresh Grok")
        }
        var result = try await API.send(http, API.postForm(url, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refresh),
            ("client_id", clientID),
        ]))
        if result.status == 415 {
            result = try await API.send(http, try API.postJSON(url, body: [
                "grant_type": "refresh_token",
                "refresh_token": current.refresh,
                "client_id": clientID,
            ]))
        }
        guard (200..<300).contains(result.status) else {
            let hint = ProviderID.signInHint(ProviderID.grok)
            if let code = OAuthBody.errorCode(result.body) {
                throw ProviderError.signedOut("\(hint) (\(code))")
            }
            throw ProviderError.signedOut(hint)
        }
        guard let root = JSONValue.object(from: result.body) else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.grok))
        }
        let object = JSONValue.firstObject(root, "token", "data") ?? root
        guard let access = JSONValue.firstString(object, "access_token", "key") else {
            throw ProviderError.signedOut(ProviderID.signInHint(ProviderID.grok))
        }
        let refresh = JSONValue.firstString(object, "refresh_token") ?? current.refresh
        let expires: Date
        if let absolute = JSONValue.firstDouble(object, "expires_at") {
            expires = DateParse.unix(absolute)
        } else if let text = JSONValue.firstString(object, "expires_at"), let date = DateParse.iso(text) {
            expires = date
        } else {
            expires = now.addingTimeInterval(JSONValue.firstDouble(object, "expires_in") ?? 1800)
        }
        var updated = current
        updated.access = access
        updated.refresh = refresh
        updated.expires = expires
        return updated
    }

    private static func tokenEndpoint(issuer: String, http: any HTTPSending) async throws -> String {
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        guard let url = URL(string: base + "/.well-known/openid-configuration") else {
            throw ProviderError.message("Couldn't refresh Grok")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = try await API.send(http, request)
        guard let object = JSONValue.object(from: try API.ok(result)),
              let endpoint = JSONValue.string(object["token_endpoint"]), !endpoint.isEmpty
        else {
            throw ProviderError.message("Couldn't refresh Grok")
        }
        return endpoint
    }
}

enum StoredKey {
    static func zai(home: URL) -> String? {
        let config = home.appendingPathComponent(".zcode/v2/config.json")
        if let root = JSONFile.object(at: config),
           let providers = JSONValue.dict(root["provider"]),
           let plan = JSONValue.dict(providers["builtin:zai-coding-plan"]),
           let options = JSONValue.dict(plan["options"]),
           let key = JSONValue.string(options["apiKey"]), !key.isEmpty {
            return key
        }
        return named("zai", home: home)
    }

    static func openRouter(home: URL) -> String? {
        named("openrouter", home: home)
    }

    private static func named(_ name: String, home: URL) -> String? {
        let files = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent(".local/share/kilo/auth.json"),
        ]
        for url in files {
            guard let root = JSONFile.object(at: url), let entry = JSONValue.dict(root[name]) else { continue }
            if let key = JSONValue.firstString(entry, "key", "apiKey") { return key }
        }
        return nil
    }
}
