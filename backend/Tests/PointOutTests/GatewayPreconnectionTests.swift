import XCTest
@testable import PointOut

/// A separate protocol and per-host fixtures avoid the model tests' global handler.
private final class PreconnectionURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (PreconnectionURLProtocol) -> Void] = [:]
    var stopped: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host!]
        Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() { stopped?() }

    func respond(status: Int = 200, body: Data = Data("unparsed health body".utf8)) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    func redirect(to target: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target.absoluteString])!
        var redirected = request
        redirected.url = target
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PreconnectionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}

private final class PreconnectionFixture: @unchecked Sendable {
    let host = "preconnection-\(UUID().uuidString.lowercased()).example"
    let session: URLSession
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var waiting: [PreconnectionURLProtocol] = []
    private var behavior: ((PreconnectionURLProtocol) -> Void)?

    init(headers: [String: String] = [:]) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreconnectionURLProtocol.self]
        config.httpAdditionalHeaders = headers
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        PreconnectionURLProtocol.lock.lock()
        PreconnectionURLProtocol.handlers[host] = { [weak self] stub in
            guard let self else { return }
            self.lock.lock()
            self.recorded.append(stub.request)
            self.waiting.append(stub)
            let callback = self.behavior
            self.lock.unlock()
            callback?(stub)
        }
        PreconnectionURLProtocol.lock.unlock()
    }

    var configuration: PointOutCredentials {
        try! PointOutCredentials(gatewayBaseURL: URL(string: "https://\(host)/ping/v1")!, accessToken: "private-fixture-token")
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var latest: PreconnectionURLProtocol? { lock.lock(); defer { lock.unlock() }; return waiting.last }
    func onRequest(_ callback: @escaping (PreconnectionURLProtocol) -> Void) {
        lock.lock(); behavior = callback; lock.unlock()
    }
    func close() {
        session.invalidateAndCancel()
        PreconnectionURLProtocol.lock.lock()
        PreconnectionURLProtocol.handlers.removeValue(forKey: host)
        PreconnectionURLProtocol.lock.unlock()
    }
}

final class GatewayPreconnectionTests: XCTestCase {
    private var fixtures: [PreconnectionFixture] = []
    private func fixture(headers: [String: String] = [:]) -> PreconnectionFixture {
        let fixture = PreconnectionFixture(headers: headers)
        fixtures.append(fixture)
        return fixture
    }
    override func tearDown() { fixtures.forEach { $0.close() }; fixtures = [] }

    private func warmer(_ fixture: PreconnectionFixture, clock: PreconnectionClock = PreconnectionClock(),
                        interval: TimeInterval = 30, timeout: TimeInterval = 3) -> GatewayPreconnection {
        GatewayPreconnection(session: fixture.session, credentials: { fixture.configuration },
                             interval: interval, timeout: timeout, clock: { clock.now() })
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    func testRequestIsSameOriginHTTPSHealthWithoutTokenCookiesOrBody() async throws {
        let fixture = fixture(headers: ["Authorization": "Bearer session-secret", "Cookie": "session=private"])
        let sent = expectation(description: "health request")
        fixture.onRequest { stub in sent.fulfill(); stub.respond(status: 503, body: Data("not JSON".utf8)) }
        let warmer = warmer(fixture)
        warmer.preconnect()
        await fulfillment(of: [sent], timeout: 1)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://\(fixture.host)/ping/health")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.timeoutInterval, 3)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").isEmpty)
        XCTAssertTrue((request.value(forHTTPHeaderField: "Cookie") ?? "").isEmpty)
        XCTAssertFalse(String(describing: request.allHTTPHeaderFields).contains("private"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testConfigurationReadIsBackgroundAndConcurrentCallsCoalesce() async {
        let fixture = fixture()
        let reading = expectation(description: "background read")
        let sent = expectation(description: "one request")
        let release = DispatchSemaphore(value: 0)
        let firstRead = LockedPreconnectionValue(true)
        let readCount = LockedPreconnectionValue(0)
        let warmer = GatewayPreconnection(session: fixture.session, credentials: {
            XCTAssertFalse(Thread.isMainThread)
            readCount.mutate { $0 += 1 }
            if firstRead.swap(false) {
                reading.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            return fixture.configuration
        })
        fixture.onRequest { _ in sent.fulfill() }
        await MainActor.run { for _ in 0..<100 { warmer.preconnect() } }
        await fulfillment(of: [reading], timeout: 1)
        await settle()
        XCTAssertEqual(readCount.get(), 1, "overlapping gesture events must share configuration I/O")
        XCTAssertEqual(fixture.requests.count, 0, "preconnect must return before file I/O completes")
        release.signal()
        await fulfillment(of: [sent], timeout: 1)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { warmer.preconnect() } }
        }
        await settle()
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testTransportFailureIsSilentAndThrottledUntilIntervalExpires() async {
        let fixture = fixture()
        let clock = PreconnectionClock()
        let first = expectation(description: "first attempt")
        fixture.onRequest { stub in
            first.fulfill()
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.notConnectedToInternet))
        }
        let warmer = warmer(fixture, clock: clock)
        warmer.preconnect()
        await fulfillment(of: [first], timeout: 1)
        await settle()
        clock.set(129)
        warmer.preconnect()
        await settle()
        XCTAssertEqual(fixture.requests.count, 1)
        let retry = expectation(description: "retry after idle interval")
        fixture.onRequest { stub in retry.fulfill(); stub.respond() }
        clock.set(130)
        warmer.preconnect()
        await fulfillment(of: [retry], timeout: 1)
    }

    func testThrottleUsesCompletionTimeAndAcceptsAnyHTTPStatusAndUnparsedBody() async {
        let fixture = fixture()
        let clock = PreconnectionClock()
        let first = expectation(description: "held request")
        fixture.onRequest { _ in first.fulfill() }
        let warmer = warmer(fixture, clock: clock)
        warmer.preconnect()
        await fulfillment(of: [first], timeout: 1)
        clock.set(200)
        fixture.latest?.respond(status: 404, body: Data(repeating: 0xFF, count: 64_000))
        await settle()
        clock.set(229)
        warmer.preconnect()
        await settle()
        XCTAssertEqual(fixture.requests.count, 1)
        let retry = expectation(description: "completion plus interval")
        fixture.onRequest { stub in retry.fulfill(); stub.respond(status: 500) }
        clock.set(230)
        warmer.preconnect()
        await fulfillment(of: [retry], timeout: 1)
    }

    func testModelRequestStartsOnSharedSessionWhilePreconnectionIsStillPending() async throws {
        let fixture = fixture()
        let warmStarted = expectation(description: "preconnection held")
        let answerStarted = expectation(description: "model request runs independently")
        fixture.onRequest { stub in
            if stub.request.url?.path == "/ping/health" { warmStarted.fulfill() }
            else { answerStarted.fulfill(); stub.respond(body: Data("answer".utf8)) }
        }
        let warmer = warmer(fixture)
        warmer.preconnect()
        await fulfillment(of: [warmStarted], timeout: 1)
        let token = warmer.beginActivity(configuration: fixture.configuration)
        let operation = Task {
            defer { warmer.endActivity(token: token) }
            return try await fixture.session.data(for: modelRequest(configuration: fixture.configuration,
                route: .explanation, body: ["fixture": true], timeout: 1))
        }
        await fulfillment(of: [answerStarted], timeout: 0.5)
        let (data, _) = try await operation.value
        XCTAssertEqual(data, Data("answer".utf8))
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testActiveModelsSuppressPreconnectionAndEachCompletionRestartsIdleInterval() async {
        let fixture = fixture()
        let clock = PreconnectionClock()
        let warmer = warmer(fixture, clock: clock)
        let first = warmer.beginActivity(configuration: fixture.configuration)
        let second = warmer.beginActivity(configuration: fixture.configuration)
        warmer.preconnect()
        await settle()
        XCTAssertTrue(fixture.requests.isEmpty)
        warmer.endActivity(token: first)
        clock.set(200)
        warmer.preconnect()
        await settle()
        XCTAssertTrue(fixture.requests.isEmpty)
        warmer.endActivity(token: second)
        clock.set(229)
        warmer.preconnect()
        await settle()
        XCTAssertTrue(fixture.requests.isEmpty)
        let sent = expectation(description: "idle after last model completion")
        fixture.onRequest { stub in sent.fulfill(); stub.respond() }
        clock.set(230)
        warmer.preconnect()
        await fulfillment(of: [sent], timeout: 1)
    }

    func testConfigurationSwitchCancelsOldWarmupAndDoesNotCarryItsThrottle() async {
        let old = fixture()
        let next = fixture()
        let clock = PreconnectionClock()
        let oldStarted = expectation(description: "old warmup")
        let oldCancelled = expectation(description: "obsolete warmup cancelled")
        let nextStarted = expectation(description: "new warmup")
        old.onRequest { stub in stub.stopped = { oldCancelled.fulfill() }; oldStarted.fulfill() }
        // Reuse a single session with fixtures routed by hostname.
        let configuration = LockedPreconnectionValue(old.configuration)
        let warmer = GatewayPreconnection(session: old.session, credentials: { configuration.get() },
                                          interval: 30, clock: { clock.now() })
        warmer.preconnect()
        await fulfillment(of: [oldStarted], timeout: 1)
        configuration.set(next.configuration)
        next.onRequest { stub in nextStarted.fulfill(); stub.respond() }
        warmer.preconnect()
        await fulfillment(of: [nextStarted, oldCancelled], timeout: 1)
        XCTAssertEqual(old.requests.count, 1)
        XCTAssertEqual(next.requests.count, 1)
    }

    func testStaleConfigurationReadCannotOverrideNewModelGateway() async {
        let old = fixture()
        let next = fixture()
        let reading = expectation(description: "old configuration read blocked")
        let release = DispatchSemaphore(value: 0)
        let warmer = GatewayPreconnection(session: old.session, credentials: {
            reading.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return old.configuration
        })
        warmer.preconnect()
        await fulfillment(of: [reading], timeout: 1)
        let token = warmer.beginActivity(configuration: next.configuration)
        warmer.endActivity(token: token)
        release.signal()
        await settle()
        XCTAssertTrue(old.requests.isEmpty)
        XCTAssertTrue(next.requests.isEmpty)
    }

    func testOldOrDuplicateActivityCompletionCannotRefreshNewGatewayThrottle() async {
        let old = fixture()
        let next = fixture()
        let clock = PreconnectionClock()
        let warmer = GatewayPreconnection(session: old.session, credentials: { next.configuration },
                                          interval: 30, clock: { clock.now() })
        let oldToken = warmer.beginActivity(configuration: old.configuration)
        let nextToken = warmer.beginActivity(configuration: next.configuration)
        warmer.endActivity(token: nextToken)
        clock.set(200)
        warmer.endActivity(token: oldToken)
        warmer.endActivity(token: nextToken)
        let sent = expectation(description: "old completions do not affect new gateway")
        next.onRequest { stub in sent.fulfill(); stub.respond() }
        warmer.preconnect()
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertTrue(old.requests.isEmpty)
    }

    func testHardDeadlineCancelsAResponseThatNeverCompletes() async {
        let fixture = fixture()
        let cancelled = expectation(description: "hard timeout cancelled transport")
        fixture.onRequest { stub in
            stub.stopped = { cancelled.fulfill() }
            let response = HTTPURLResponse(url: stub.request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: Data("unfinished body".utf8))
        }
        let warmer = warmer(fixture, timeout: 0.05)
        warmer.preconnect()
        await fulfillment(of: [cancelled], timeout: 0.8)
        await settle()
        warmer.preconnect()
        await settle()
        XCTAssertEqual(fixture.requests.count, 1, "timeouts are throttled too")
    }

    func testCredentialsFailuresAreBackgroundSilentAndThrottled() async {
        let fixture = fixture()
        let clock = PreconnectionClock()
        let count = LockedPreconnectionValue(0)
        let reading = expectation(description: "failed configuration read")
        let warmer = GatewayPreconnection(session: fixture.session, credentials: {
            XCTAssertFalse(Thread.isMainThread)
            count.set(count.get() + 1)
            reading.fulfill()
            throw ModelClientError.credentialsPermissions
        }, interval: 30, clock: { clock.now() })
        warmer.preconnect()
        await fulfillment(of: [reading], timeout: 1)
        await settle()
        for _ in 0..<10 { warmer.preconnect() }
        await settle()
        XCTAssertEqual(count.get(), 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testStopDuringConfigurationReadPreventsTasksAfterSessionInvalidation() async {
        let fixture = fixture()
        let reading = expectation(description: "configuration read entered")
        let returned = expectation(description: "configuration read returned")
        let proceed = DispatchSemaphore(value: 0)
        let count = LockedPreconnectionValue(0)
        let warmer = GatewayPreconnection(session: fixture.session, credentials: {
            count.set(count.get() + 1)
            reading.fulfill()
            _ = proceed.wait(timeout: .now() + 2)
            returned.fulfill()
            return fixture.configuration
        })
        warmer.preconnect()
        await fulfillment(of: [reading], timeout: 1)
        warmer.stop()
        fixture.session.invalidateAndCancel()
        proceed.signal()
        await fulfillment(of: [returned], timeout: 1)
        await settle()
        warmer.preconnect()
        await settle()
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(count.get(), 1)
    }

    func testRedirectDelegateRefusesSameAndCrossOriginTargets() {
        let fixture = fixture()
        let delegate = GatewayPreconnectionDelegate {}
        let task = fixture.session.dataTask(with: fixture.configuration.gatewayBaseURL)
        defer { task.cancel() }
        for target in ["https://\(fixture.host)/ping/v1/explanation", "https://other.example/collect"] {
            let response = HTTPURLResponse(url: fixture.configuration.gatewayBaseURL, statusCode: 307,
                                           httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var called = false
            delegate.urlSession(fixture.session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: target)!)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testRedirectFixtureFollowsWithoutGuardAndPreconnectionRefusesBothOrigins() async throws {
        let control = fixture()
        let controlTarget = URL(string: "https://\(control.host)/redirected")!
        control.onRequest { stub in
            if stub.request.url == controlTarget { stub.respond() }
            else { stub.redirect(to: controlTarget) }
        }
        _ = try await control.session.data(from: control.configuration.gatewayBaseURL)
        XCTAssertEqual(control.requests.count, 2, "the fixture must actually exercise URLSession redirects")

        for sameOrigin in [true, false] {
            let fixture = fixture()
            let sent = expectation(description: "redirecting health response")
            let target = URL(string: sameOrigin ? "https://\(fixture.host)/redirected" : "https://other.example/collect")!
            fixture.onRequest { stub in
                guard stub.request.url?.path == "/ping/health" else {
                    XCTFail("preconnection followed a redirect"); stub.respond(); return
                }
                stub.redirect(to: target)
                sent.fulfill()
            }
            let warmer = warmer(fixture)
            warmer.preconnect()
            await fulfillment(of: [sent], timeout: 1)
            await settle()
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }
}

private final class LockedPreconnectionValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&value); lock.unlock() }
    func swap(_ value: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let previous = self.value; self.value = value; return previous
    }
}
