import XCTest
@testable import PointOut

private final class SubscriptionTestVault: SubscriptionSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func write(_ data: Data) throws { lock.lock(); value = data; lock.unlock() }
    func delete() throws { lock.lock(); value = nil; lock.unlock() }
}

private final class SubscriptionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_893_456_000) // 2030-01-01 UTC
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class SubscriptionHTTPProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (SubscriptionHTTPProtocol) -> Void] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url!.host!]; Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() {}
    func respond(_ status: Int = 200, json: String, url: URL? = nil) {
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func redirect(to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": url.absoluteString])!
        var redirected = request; redirected.url = url
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SubscriptionHTTPFixture: @unchecked Sendable {
    let host = "subscription-\(UUID().uuidString.lowercased()).example"
    let vault = SubscriptionTestVault()
    let clock = SubscriptionTestClock()
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var identityReads = 0
    private var handler: ((SubscriptionHTTPProtocol, Int) -> Void)?
    var baseURL: URL { URL(string: "https://\(host)/ping/v1")! }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var identityCount: Int { lock.lock(); defer { lock.unlock() }; return identityReads }

    init() {
        SubscriptionHTTPProtocol.lock.lock()
        SubscriptionHTTPProtocol.handlers[host] = { [weak self] request in
            guard let self else { return }
            self.lock.lock()
            self.recorded.append(request.request)
            let count = self.recorded.count
            let handler = self.handler
            self.lock.unlock()
            handler?(request, count)
        }
        SubscriptionHTTPProtocol.lock.unlock()
    }
    deinit {
        SubscriptionHTTPProtocol.lock.lock()
        SubscriptionHTTPProtocol.handlers[host] = nil
        SubscriptionHTTPProtocol.lock.unlock()
    }
    func onRequest(_ handler: @escaping (SubscriptionHTTPProtocol, Int) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func client(vault: (any SubscriptionSessionVault)? = nil) throws -> SubscriptionAPIClient {
        try SubscriptionAPIClient(baseURL: baseURL, vault: vault ?? self.vault, identityProvider: { [self] in
            recordIdentityRead()
            return "offline-fixture-app-jws"
        }, protocolClasses: [SubscriptionHTTPProtocol.self], now: { [clock] in clock.now() })
    }
    private func recordIdentityRead() { lock.lock(); identityReads += 1; lock.unlock() }
    static func session(_ token: String = "fixture-token", expiry: String = "2030-01-01T01:00:00.000Z") -> String {
        "{\"access_token\":\"\(token)\",\"expires_at\":\"\(expiry)\",\"app_account_token\":\"93F6AB06-A947-4548-877E-FA970C0548CF\"}"
    }
    static let state = "{\"plan\":\"free\",\"period_start\":\"2030-01-01T00:00:00Z\",\"period_end\":\"2030-02-01T00:00:00Z\",\"limit\":20,\"committed\":2,\"reserved\":1,\"remaining\":17}"
}

final class SubscriptionAPIClientTests: XCTestCase {
    /// JWS strings are intentionally fake. These tests verify HTTP/session behavior, not Apple signing or purchases.
    func testActualHTTPRequestsAndCredentialSynchronization() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in
            request.respond(json: request.request.url!.lastPathComponent == "session" ? SubscriptionHTTPFixture.session() : SubscriptionHTTPFixture.state)
        }
        let client = try fixture.client()
        XCTAssertThrowsError(try client.currentGatewayCredentials())
        let state = try await client.fetchState()
        XCTAssertEqual(state.remaining, 17)
        _ = try await client.submitTransaction(signedTransaction: "offline-fixture-transaction-jws")
        let requests = fixture.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/ping/v1/subscription/session", "/ping/v1/subscription/state", "/ping/v1/subscription/transaction"])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertFalse(requests[2].httpShouldHandleCookies)
        XCTAssertEqual(try body(requests[0])["signed_app_transaction"], "offline-fixture-app-jws")
        XCTAssertEqual(try body(requests[2])["signed_transaction"], "offline-fixture-transaction-jws")
        XCTAssertEqual(try client.currentGatewayCredentials().accessToken, "fixture-token")
        XCTAssertNotNil(try fixture.vault.read())
    }

    func test401RebuildsOnceAndRepeated401ClearsCredentials() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in
            if request.request.url!.lastPathComponent == "session" { request.respond(json: SubscriptionHTTPFixture.session()) }
            else { request.respond(401, json: "{}") }
        }
        let client = try fixture.client()
        do { _ = try await client.fetchState(); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .authentication) }
        XCTAssertEqual(fixture.identityCount, 2)
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertThrowsError(try client.currentGatewayCredentials())
        XCTAssertNil(try fixture.vault.read())
    }

    func test401RecoveryPublishesNewBearer() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, count in
            if request.request.url!.lastPathComponent == "session" {
                request.respond(json: SubscriptionHTTPFixture.session(count == 1 ? "old" : "new"))
            } else if request.request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                request.respond(401, json: "{}")
            } else { request.respond(json: SubscriptionHTTPFixture.state) }
        }
        let client = try fixture.client()
        _ = try await client.fetchState()
        XCTAssertEqual(try client.currentGatewayCredentials().accessToken, "new")
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testConcurrentSessionCreationHasOneIdentityAndHTTPRequest() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session()) }
        let client = try fixture.client()
        try await withThrowingTaskGroup(of: SubscriptionSession.self) { group in
            for _ in 0..<12 { group.addTask { try await client.ensureSession() } }
            for try await value in group { XCTAssertEqual(value.accessToken, "fixture-token") }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.identityCount, 1)
    }

    func testRestoredSessionExpiryAndGatewayIsolation() async throws {
        let first = SubscriptionHTTPFixture()
        first.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session()) }
        let original = try first.client()
        _ = try await original.ensureSession()
        let restored = try first.client()
        _ = try await restored.ensureSession()
        XCTAssertEqual(first.requests.count, 1)
        first.clock.advance(3_600)
        XCTAssertThrowsError(try original.currentGatewayCredentials())
        first.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session("renewed", expiry: "2030-01-01T03:00:00Z")) }
        let expired = try first.client()
        _ = try await expired.ensureSession()
        XCTAssertEqual(first.requests.count, 2)
        XCTAssertEqual(try expired.currentGatewayCredentials().accessToken, "renewed")

        let other = SubscriptionHTTPFixture()
        other.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session("other-origin")) }
        let isolated = try other.client(vault: first.vault)
        _ = try await isolated.ensureSession()
        XCTAssertEqual(other.requests.count, 1)
        XCTAssertNil(other.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try isolated.currentGatewayCredentials().accessToken, "other-origin")
    }

    func testInvalidConfigurationAndCrossOriginResponseRejected() async throws {
        for text in ["http://example.com/ping/v1", "https://user:secret@example.com", "https://example.com/?token=x", "https://example.com/#x"] {
            XCTAssertThrowsError(try SubscriptionAPIClient(baseURL: URL(string: text)!, vault: SubscriptionTestVault()))
        }
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in
            request.respond(json: SubscriptionHTTPFixture.session(), url: URL(string: "https://foreign.example/session")!)
        }
        let client = try fixture.client()
        do { _ = try await client.ensureSession(); XCTFail("Expected origin rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidResponse) }
        XCTAssertNil(try fixture.vault.read())
    }

    func testRedirectPolicyNeverForwardsSensitiveRequest() {
        let policy = SubscriptionRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://gateway.example/subscription/session")!
        let task = session.dataTask(with: original)
        for target in ["https://foreign.example/collect", "http://gateway.example/collect", "https://gateway.example/other"] {
            var request = URLRequest(url: URL(string: target)!)
            request.httpBody = Data("fixture-jws".utf8)
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            policy.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!, newRequest: request) { redirected in
                XCTAssertNil(redirected)
            }
        }
    }

    func testActualRedirectDoesNotForwardJWSToAnotherHost() async throws {
        let origin = SubscriptionHTTPFixture(); let destination = SubscriptionHTTPFixture()
        origin.onRequest { request, _ in request.redirect(to: destination.baseURL.appendingPathComponent("collect")) }
        destination.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session()) }
        let client = try origin.client()
        do { _ = try await client.ensureSession(); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .http(307)) }
        XCTAssertEqual(origin.requests.count, 1)
        XCTAssertTrue(destination.requests.isEmpty)
        XCTAssertNil(try origin.vault.read())
    }

    func testEmptyIdentityCannotCreateAnAnonymousFreeSession() async throws {
        let fixture = SubscriptionHTTPFixture()
        let client = try SubscriptionAPIClient(baseURL: fixture.baseURL, vault: fixture.vault,
                                              identityProvider: { "  " }, protocolClasses: [SubscriptionHTTPProtocol.self])
        do { _ = try await client.ensureSession(); XCTFail("Expected identity rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .identityUnavailable) }
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertNil(try fixture.vault.read())
        XCTAssertThrowsError(try client.currentGatewayCredentials())
    }

    func testExpiredSessionAndInvalidSnapshotNeverBecomeAuthorizedState() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session(expiry: "2029-12-31T23:00:00Z")) }
        let client = try fixture.client()
        do { _ = try await client.ensureSession(); XCTFail("Expected expiry rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidResponse) }
        XCTAssertThrowsError(try client.currentGatewayCredentials())
        fixture.onRequest { request, _ in
            if request.request.url!.lastPathComponent == "session" { request.respond(json: SubscriptionHTTPFixture.session()) }
            else { request.respond(json: SubscriptionHTTPFixture.state.replacingOccurrences(of: "\"remaining\":17", with: "\"remaining\":1000")) }
        }
        do { _ = try await client.fetchState(); XCTFail("Expected malformed snapshot rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidResponse) }
    }

    func testCancelActionPostsLowercaseIdentityUsingTheLoadedSession() async throws {
        let fixture = SubscriptionHTTPFixture()
        let action = UUID(uuidString: "A7CD20BE-1965-4F43-B086-FA970C0548CF")!
        fixture.onRequest { request, _ in
            request.respond(json: request.request.url!.lastPathComponent == "session"
                ? SubscriptionHTTPFixture.session() : "{\"action_id\":\"\(action.uuidString.lowercased())\",\"state\":\"cancelled\"}")
        }
        let client = try fixture.client()
        _ = try await client.ensureSession()
        let reads = fixture.vault.readCount
        try await client.cancelAction(action)
        XCTAssertEqual(fixture.requests.count, 2)
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(request.url?.path, "/ping/v1/subscription/actions/cancel")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try body(request), ["action_id": action.uuidString.lowercased()])
        XCTAssertEqual(request.timeoutInterval, 3)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(fixture.identityCount, 1)
        XCTAssertEqual(fixture.vault.readCount, reads)
    }

    func testCancelActionWithoutLoadedSessionDoesNotReadVaultOrCreateIdentity() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session()) }
        let original = try fixture.client()
        _ = try await original.ensureSession()
        let reads = fixture.vault.readCount
        // Even a valid session in the vault is not loaded solely to cancel an action.
        let fresh = try fixture.client()
        try await fresh.cancelAction(UUID())
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.identityCount, 1)
        XCTAssertEqual(fixture.vault.readCount, reads)
        XCTAssertThrowsError(try fresh.currentGatewayCredentials())
    }

    func testCancelActionWithExpiredSessionDoesNotRefreshIdentity() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in request.respond(json: SubscriptionHTTPFixture.session()) }
        let client = try fixture.client()
        _ = try await client.ensureSession()
        let reads = fixture.vault.readCount
        fixture.clock.advance(3_600)
        try await client.cancelAction(UUID())
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.identityCount, 1)
        XCTAssertEqual(fixture.vault.readCount, reads)
    }

    func testCancelAction401And404DoNotRenewOrRetryTheSession() async throws {
        for status in [401, 404] {
            let fixture = SubscriptionHTTPFixture()
            fixture.onRequest { request, _ in
                if request.request.url!.lastPathComponent == "session" {
                    request.respond(json: SubscriptionHTTPFixture.session())
                } else { request.respond(status, json: "{}") }
            }
            let client = try fixture.client()
            _ = try await client.ensureSession()
            let reads = fixture.vault.readCount
            do { try await client.cancelAction(UUID()); XCTFail("Expected cancellation rejection") }
            catch { XCTAssertEqual(error as? SubscriptionError, status == 401 ? .authentication : .http(404)) }
            XCTAssertEqual(fixture.requests.count, 2)
            XCTAssertEqual(fixture.identityCount, 1)
            XCTAssertEqual(fixture.vault.readCount, reads)
            XCTAssertEqual(try client.currentGatewayCredentials().accessToken, "fixture-token")
        }
    }

    func testCancelActionRedirectNeverForwardsBearerToAnotherHost() async throws {
        let origin = SubscriptionHTTPFixture(); let destination = SubscriptionHTTPFixture()
        origin.onRequest { request, _ in
            if request.request.url!.lastPathComponent == "session" {
                request.respond(json: SubscriptionHTTPFixture.session())
            } else { request.redirect(to: destination.baseURL.appendingPathComponent("collect")) }
        }
        destination.onRequest { request, _ in request.respond(json: "{}") }
        let client = try origin.client()
        _ = try await client.ensureSession()
        do { try await client.cancelAction(UUID()); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? SubscriptionError, .http(307)) }
        XCTAssertEqual(origin.requests.count, 2)
        XCTAssertTrue(destination.requests.isEmpty)
        XCTAssertEqual(origin.identityCount, 1)
    }

    func testCancelActionHungResponseStopsAtTheBoundedDeadline() async throws {
        let fixture = SubscriptionHTTPFixture()
        fixture.onRequest { request, _ in
            if request.request.url!.lastPathComponent == "session" {
                request.respond(json: SubscriptionHTTPFixture.session())
            }
            // The cancel request intentionally never responds; the three-second deadline must cancel it.
        }
        let client = try fixture.client()
        _ = try await client.ensureSession()
        let started = ProcessInfo.processInfo.systemUptime
        do { try await client.cancelAction(UUID()); XCTFail("Expected cancellation timeout") }
        catch { XCTAssertEqual(error as? SubscriptionError, .transport) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4.5)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.identityCount, 1)
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        let data: Data
        if let direct = request.httpBody { data = direct }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else { throw SubscriptionError.invalidResponse }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
