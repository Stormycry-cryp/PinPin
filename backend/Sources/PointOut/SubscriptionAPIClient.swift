import Foundation
import Security

enum SubscriptionError: Error, LocalizedError, Equatable {
    case invalidConfiguration, identityUnavailable, unverifiedTransaction, invalidResponse
    case sessionExpired, authentication, http(Int), transport, secureStorage, productUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "订阅服务地址无效。"
        case .identityUnavailable: return "暂时无法验证 App Store 身份，请点恢复购买后重试。"
        case .unverifiedTransaction: return "无法验证 App Store 购买信息，请重试。"
        case .invalidResponse: return "订阅服务返回信息异常，请稍后重试。"
        case .sessionExpired, .authentication: return "订阅会话已失效，请刷新订阅状态。"
        case .http, .transport: return "暂时无法连接订阅服务，请稍后重试。"
        case .secureStorage: return "无法安全保存订阅会话，请稍后重试。"
        case .productUnavailable: return "暂时无法加载月度订阅，请稍后重试。"
        }
    }
}

struct SubscriptionSession: Codable, Sendable, Equatable {
    let accessToken: String
    let expiresAt: Date
    let appAccountToken: UUID

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresAt = "expires_at", appAccountToken = "app_account_token"
    }
}

struct SubscriptionSnapshot: Codable, Sendable, Equatable {
    enum Plan: String, Codable, Sendable { case free, pro }
    let plan: Plan
    let periodStart: Date
    let periodEnd: Date
    let limit: Int
    let committed: Int
    let reserved: Int
    let remaining: Int

    enum CodingKeys: String, CodingKey {
        case plan, limit, committed, reserved, remaining
        case periodStart = "period_start", periodEnd = "period_end"
    }
}

protocol SubscriptionServicing: Sendable {
    func ensureSession() async throws -> SubscriptionSession
    func invalidateSession() async throws
    func fetchState() async throws -> SubscriptionSnapshot
    func submitTransaction(signedTransaction: String) async throws -> SubscriptionSnapshot
}

/// Tests supply an in-memory vault. Only an explicitly constructed production client uses Keychain.
protocol SubscriptionSessionVault: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

struct KeychainSubscriptionSessionVault: SubscriptionSessionVault {
    let account: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.pointout.app.subscription.session",
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SubscriptionError.secureStorage }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SubscriptionError.secureStorage }
        } else if status != errSecSuccess { throw SubscriptionError.secureStorage }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SubscriptionError.secureStorage }
    }
}

/// Subscription requests never follow redirects, so neither JWS nor Bearer can move to another endpoint.
final class SubscriptionRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class SubscriptionCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SubscriptionSession?
    func update(_ session: SubscriptionSession?) { lock.lock(); self.session = session; lock.unlock() }
    func credentials(baseURL: URL, now: Date) throws -> PointOutCredentials {
        lock.lock(); let value = session; lock.unlock()
        guard let value, value.expiresAt > now.addingTimeInterval(15) else { throw SubscriptionError.sessionExpired }
        return try PointOutCredentials(gatewayBaseURL: baseURL, accessToken: value.accessToken)
    }
}

actor SubscriptionAPIClient: SubscriptionServicing {
    nonisolated static let defaultBaseURL = URL(string: "https://gateway.example.com/pinpin/v1")!
    private struct StoredSession: Codable { let baseURL: URL; let session: SubscriptionSession }
    nonisolated let baseURL: URL
    private nonisolated let credentials = SubscriptionCredentialCache()
    private nonisolated let now: @Sendable () -> Date
    private let vault: any SubscriptionSessionVault
    private let identityProvider: @Sendable () async throws -> String
    private let transport: URLSession
    private let redirectPolicy = SubscriptionRedirectPolicy()
    private var session: SubscriptionSession?
    private var didReadVault = false
    private var sessionTask: Task<SubscriptionSession, Error>?
    private var generation = 0

    init(baseURL: URL = SubscriptionAPIClient.defaultBaseURL,
         vault: (any SubscriptionSessionVault)? = nil,
         identityProvider: @escaping @Sendable () async throws -> String = { try await NativeSubscriptionStoreKit.signedAppTransaction() },
         protocolClasses: [AnyClass]? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard (try? PointOutCredentials(gatewayBaseURL: baseURL, accessToken: "validation")) != nil else {
            throw SubscriptionError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.vault = vault ?? KeychainSubscriptionSessionVault(account: baseURL.absoluteString)
        self.identityProvider = identityProvider
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCookieAndCredentialStorageDisabled()
        configuration.protocolClasses = protocolClasses
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        transport = URLSession(configuration: configuration)
    }

    deinit { sessionTask?.cancel(); transport.invalidateAndCancel() }

    nonisolated func currentGatewayCredentials() throws -> PointOutCredentials {
        try credentials.credentials(baseURL: baseURL, now: now())
    }

    func ensureSession() async throws -> SubscriptionSession {
        if !didReadVault {
            didReadVault = true
            if let data = try vault.read(), let stored = try? Self.decoder().decode(StoredSession.self, from: data),
               stored.baseURL == baseURL, valid(stored.session) {
                session = stored.session
                credentials.update(stored.session)
            }
        }
        if let session, valid(session) { return session }
        credentials.update(nil)
        let expectedGeneration = generation
        let task: Task<SubscriptionSession, Error>
        if let pending = sessionTask { task = pending }
        else {
            task = Task { [identityProvider] in
                let signed = try await identityProvider()
                guard !signed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SubscriptionError.identityUnavailable }
                let data = try await self.request(path: "session", method: "POST", token: nil,
                                                  body: ["signed_app_transaction": signed])
                guard let value = try? Self.decoder().decode(SubscriptionSession.self, from: data), self.valid(value) else {
                    throw SubscriptionError.invalidResponse
                }
                return value
            }
            sessionTask = task
        }
        do {
            let value = try await task.value
            guard generation == expectedGeneration else { throw SubscriptionError.sessionExpired }
            if session != value {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try vault.write(encoder.encode(StoredSession(baseURL: baseURL, session: value)))
                session = value
                credentials.update(value)
            }
            sessionTask = nil
            return value
        } catch {
            if generation == expectedGeneration { sessionTask = nil }
            throw error
        }
    }

    func invalidateSession() throws {
        generation += 1
        sessionTask?.cancel(); sessionTask = nil
        session = nil; credentials.update(nil); didReadVault = true
        try vault.delete()
    }

    func fetchState() async throws -> SubscriptionSnapshot {
        try await authorized(path: "state", method: "GET", body: nil)
    }

    func submitTransaction(signedTransaction: String) async throws -> SubscriptionSnapshot {
        guard !signedTransaction.isEmpty else { throw SubscriptionError.unverifiedTransaction }
        return try await authorized(path: "transaction", method: "POST", body: ["signed_transaction": signedTransaction])
    }

    /// Release an unfinished action using only the already loaded identity. Failure leaves its lease to expire.
    func cancelAction(_ id: UUID) async throws {
        guard let identity = session, valid(identity) else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await self.request(path: "actions/cancel", method: "POST", token: identity.accessToken,
                                           body: ["action_id": id.uuidString.lowercased()], timeout: 3)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw SubscriptionError.transport
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func authorized(path: String, method: String, body: [String: String]?) async throws -> SubscriptionSnapshot {
        var identity = try await ensureSession()
        for attempt in 0...1 {
            do {
                let data = try await request(path: path, method: method, token: identity.accessToken, body: body)
                guard let value = try? Self.decoder().decode(SubscriptionSnapshot.self, from: data),
                      value.periodStart < value.periodEnd, value.periodEnd > now(),
                      value.limit >= 0, value.committed >= 0, value.reserved >= 0,
                      value.remaining >= 0, value.remaining <= value.limit else { throw SubscriptionError.invalidResponse }
                // An account/session change during an in-flight request must not publish stale entitlement.
                guard session?.accessToken == identity.accessToken else { throw SubscriptionError.sessionExpired }
                credentials.update(session)
                return value
            } catch SubscriptionError.authentication {
                if session?.accessToken == identity.accessToken { try invalidateSession() }
                guard attempt == 0 else { throw SubscriptionError.authentication }
                identity = try await ensureSession()
            }
        }
        throw SubscriptionError.authentication
    }

    private func valid(_ session: SubscriptionSession) -> Bool {
        session.expiresAt > now().addingTimeInterval(15) &&
        !session.accessToken.isEmpty && session.accessToken.utf8.allSatisfy { (33...126).contains($0) }
    }

    private func request(path: String, method: String, token: String?, body: [String: String]?,
                         timeout: TimeInterval = 30) async throws -> Data {
        let url = baseURL.appendingPathComponent("subscription").appendingPathComponent(path)
        guard sameOrigin(url) else { throw SubscriptionError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do { result = try await transport.data(for: request, delegate: redirectPolicy) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SubscriptionError.transport }
        guard let response = result.1 as? HTTPURLResponse, let responseURL = response.url, sameOrigin(responseURL) else {
            throw SubscriptionError.invalidResponse
        }
        if response.statusCode == 401 { throw SubscriptionError.authentication }
        guard (200...299).contains(response.statusCode) else { throw SubscriptionError.http(response.statusCode) }
        return result.0
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == baseURL.host?.lowercased() &&
        (url.port ?? 443) == (baseURL.port ?? 443) && url.user == nil && url.password == nil
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw SubscriptionError.invalidResponse }
            return date
        }
        return decoder
    }
}

private extension URLSessionConfiguration {
    func urlCookieAndCredentialStorageDisabled() {
        httpCookieStorage = nil; urlCredentialStorage = nil; httpShouldSetCookies = false
    }
}
