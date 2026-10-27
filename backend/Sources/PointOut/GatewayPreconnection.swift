import Foundation

/// Opportunistic connection work only. It never delays capture or an actual model request.
final class GatewayPreconnection: @unchecked Sendable {
    struct ActivityToken: Sendable {
        fileprivate let id: UUID
        fileprivate let generation: UUID
    }

    private struct GatewayState {
        let baseURL: URL
        let generation = UUID()
        var lastActivity: TimeInterval?
        var warming: (id: UUID, task: URLSessionDataTask)?
    }

    private let session: URLSession
    private let credentials: @Sendable () throws -> PointOutCredentials
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var gateway: GatewayState?
    // Only live requests are retained, including ones completing after a gateway switch.
    private var activities = Set<UUID>()
    private var configurationPending = false
    private var lastConfigurationFailure: TimeInterval?
    private var revision: UInt64 = 0
    private var stopped = false

    init(session: URLSession,
         credentials: @escaping @Sendable () throws -> PointOutCredentials,
         interval: TimeInterval = 30, timeout: TimeInterval = 3,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.session = session
        self.credentials = credentials
        self.interval = interval.isFinite ? max(0, interval) : 30
        self.timeout = timeout.isFinite ? max(0.001, timeout) : 3
        self.clock = clock
    }

    deinit { gateway?.warming?.task.cancel() }

    /// Stop optional warm-ups before the session owner invalidates its URLSession.
    /// Actual model requests are owned by their callers and remain unaffected.
    func stop() {
        lock.lock()
        stopped = true
        revision &+= 1
        configurationPending = false
        let warming = gateway?.warming?.task
        gateway?.warming = nil
        lock.unlock()
        warming?.cancel()
    }

    /// Safe on the gesture thread: configuration I/O and permission checks run in the background.
    func preconnect() {
        let now = clock()
        lock.lock()
        guard !stopped, !configurationPending, activities.isEmpty,
              lastConfigurationFailure.map({ now - $0 >= interval }) ?? true else {
            lock.unlock(); return
        }
        configurationPending = true
        let expectedRevision = revision
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadAndPreconnect(expectedRevision: expectedRevision)
        }
    }

    /// Call immediately around the network operation, excluding local capture and preparation.
    func beginActivity(configuration: PointOutCredentials) -> ActivityToken {
        lock.lock()
        let obsolete = selectGateway(configuration.gatewayBaseURL)
        let token = ActivityToken(id: UUID(), generation: gateway!.generation)
        activities.insert(token.id)
        lastConfigurationFailure = nil
        lock.unlock()
        obsolete?.cancel()
        return token
    }

    func endActivity(token: ActivityToken) {
        let now = clock()
        lock.lock()
        if activities.remove(token.id) != nil, gateway?.generation == token.generation {
            let lastActivity = max(gateway?.lastActivity ?? now, now)
            gateway?.lastActivity = lastActivity
        }
        lock.unlock()
    }

    // Caller holds the lock. Keep only the current gateway; never cancel real model requests.
    private func selectGateway(_ baseURL: URL) -> URLSessionDataTask? {
        guard gateway?.baseURL != baseURL else { return nil }
        let obsolete = gateway?.warming?.task
        gateway = GatewayState(baseURL: baseURL)
        revision &+= 1
        return obsolete
    }

    private func loadAndPreconnect(expectedRevision: UInt64) {
        let configuration: PointOutCredentials
        do { configuration = try credentials() }
        catch {
            let now = clock()
            lock.lock()
            configurationPending = false
            if revision == expectedRevision { lastConfigurationFailure = now }
            lock.unlock()
            return
        }
        let healthURL = configuration.gatewayBaseURL.deletingLastPathComponent().appendingPathComponent("health")
        // PointOutCredentials validates HTTPS, userinfo, port, query and fragment before this point.
        guard healthURL.scheme?.lowercased() == "https",
              healthURL.host?.lowercased() == configuration.gatewayBaseURL.host?.lowercased(),
              healthURL.port == configuration.gatewayBaseURL.port else {
            lock.lock(); configurationPending = false; lock.unlock(); return
        }

        let now = clock()
        lock.lock()
        configurationPending = false
        // A real request may have switched configuration while the file was being read.
        guard !stopped, revision == expectedRevision else { lock.unlock(); return }
        let obsolete = selectGateway(configuration.gatewayBaseURL)
        guard activities.isEmpty, gateway?.warming == nil,
              gateway?.lastActivity.map({ now - $0 >= interval }) ?? true else {
            lock.unlock(); obsolete?.cancel(); return
        }
        var request = URLRequest(url: healthURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        // Also override session-wide authentication/cookie headers if an injected session has them.
        request.setValue("", forHTTPHeaderField: "Authorization")
        request.setValue("", forHTTPHeaderField: "Cookie")
        let id = UUID()
        let generation = gateway!.generation
        let delegate = GatewayPreconnectionDelegate { [weak self] in
            self?.finished(id: id, generation: generation)
        }
        let task = session.dataTask(with: request)
        task.delegate = delegate
        gateway?.warming = (id, task)
        lock.unlock()
        obsolete?.cancel()
        delegate.startDeadline(task: task, timeout: timeout)
        task.resume()
    }

    private func finished(id: UUID, generation: UUID) {
        let now = clock()
        lock.lock()
        if gateway?.generation == generation, gateway?.warming?.id == id {
            gateway?.warming = nil
            // Failed and cancelled attempts also cool down, preventing repeated empty requests.
            let lastActivity = max(gateway?.lastActivity ?? now, now)
            gateway?.lastActivity = lastActivity
        }
        lock.unlock()
    }
}

/// Consume without accumulating or interpreting a body. Finishing the tiny response allows
/// HTTP/1.1 connection reuse as well as HTTP/2 reuse; a hard deadline bounds a slow/large body.
final class GatewayPreconnectionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let completion: @Sendable () -> Void
    private let lock = NSLock()
    private var deadline: DispatchWorkItem?
    private var completed = false

    init(completion: @escaping @Sendable () -> Void) { self.completion = completion }

    func startDeadline(task: URLSessionDataTask, timeout: TimeInterval) {
        let work = DispatchWorkItem { [weak task] in task?.cancel() }
        lock.lock()
        if completed { lock.unlock(); return }
        deadline = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Leave TLS trust evaluation to the system, but never supply cached HTTP credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(response is HTTPURLResponse ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        deadline?.cancel(); deadline = nil
        lock.unlock()
        completion()
    }
}
