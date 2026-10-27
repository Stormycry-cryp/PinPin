import XCTest
@testable import PointOut

@MainActor final class FakePresentation: PointOutPresentation {
    var nextAction: PointOutAction?
    var events: [String] = []
    var texts: [UUID: String] = [:]
    var subtitles: [UUID: String] = [:]
    var finished: [UUID: Bool] = [:]
    var failures: [UUID: String] = [:]
    var failureKinds: [UUID: ResultFailureKind] = [:]
    var saved: [UUID: SavedItem] = [:]
    var pickedColors: [UUID: PickedColor] = [:]
    var library: [SavedItem] = []
    var assets: [AssetRecord] = []
    var colorPersistence: [UUID: AssetPersistenceState] = [:]
    var onColorPersistence: ((UUID, AssetPersistenceState) -> Void)?
    var resultIDs: Set<UUID> = []
    var sourceStates: [UUID: (CGPoint, Bool)] = [:]
    var onResultUpdate: ((UUID, String) -> Void)?
    var onResultFinish: ((UUID) -> Void)?

    var onCancel: ((UUID) -> Void)?
    var onForget: ((UUID) -> Void)?
    var onFollowUp: ((UUID, String) -> Void)?
    var onAssetEdit: ((AssetEdit) -> Void)?
    var onLibraryEdit: ((LibraryEdit) -> Void)?
    var onWheelSettingsChange: ((WheelSettings) async -> Bool)?

    func showWheel(at point: CGPoint) { events.append("wheel") }
    func updateWheel(pointer: CGPoint) -> PointOutAction? { nextAction }
    func hideWheel() { events.append("hide") }
    func updateWheelSettings(_ settings: WheelSettings) {}
    func showSettings() { events.append("settings") }
    func beginResult(_ id: UUID, action: PointOutAction, at point: CGPoint, processID: pid_t) {
        resultIDs.insert(id)
        events.append("begin:\(action.rawValue)")
        finished[id] = nil
    }
    func updateResultSource(_ id: UUID, at point: CGPoint, visible: Bool) {
        sourceStates[id] = (point, visible)
    }
    func removeResult(_ id: UUID) {
        guard resultIDs.remove(id) != nil else { return }; onForget?(id)
    }
    func updateResult(_ id: UUID, text: String, subtitle: String?) {
        texts[id] = text
        if let subtitle { subtitles[id] = subtitle }
        onResultUpdate?(id, text)
    }
    func finishResult(_ id: UUID) { finished[id] = true; onResultFinish?(id) }
    func failResult(_ id: UUID, message: String, kind: ResultFailureKind?) { failures[id] = message; failureKinds[id] = kind }
    func showSaved(_ id: UUID, item: SavedItem, suggestions: [String]) { saved[id] = item }
    func showPickedColor(_ id: UUID, color: PickedColor) { pickedColors[id] = color }
    func closeCard() { events.append("close") }
    func clearAllMarkers() {
        events.append("clear")
        let removed = resultIDs
        resultIDs.removeAll()
        for id in removed { onForget?(id) }
    }
    func updateAssets(_ items: [AssetRecord]) { assets = items }
    func updateColorPersistence(_ resultID: UUID, state: AssetPersistenceState) {
        colorPersistence[resultID] = state; onColorPersistence?(resultID, state)
    }
    func updateLibrary(_ items: [SavedItem]) { library = items }
    func showLibrary(near point: CGPoint?) { events.append("library") }
    func showPermissionHelp(accessibility: Bool, screenCapture: Bool) {}
}

final class FakeCapture: ContextProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [UUID: CapturedContext] = [:]
    private var _captures = 0
    private var _forgotten: [UUID] = []
    var colorSample: @Sendable (TargetAnchor) async throws -> PickedColor = { _ in PickedColor(red: 17, green: 34, blue: 51) }
    var template: CapturedContext

    init(template: CapturedContext) { self.template = template }
    var captures: Int { lock.withLock { _captures } }
    var forgotten: [UUID] { lock.withLock { _forgotten } }
    var retainedIDs: Set<UUID> { lock.withLock { Set(contexts.keys) } }

    func sampleColor(_ anchor: TargetAnchor) async throws -> PickedColor { try await colorSample(anchor) }

    func capture(_ anchor: TargetAnchor) async -> CapturedContext {
        lock.withLock {
            _captures += 1
            var context = template
            context.sessionID = anchor.id
            contexts[anchor.id] = context
            return context
        }
    }
    func supplement(_ context: CapturedContext, anchor: TargetAnchor, plan: AcquisitionPlan) async -> CapturedContext { context }
    func forget(_ id: UUID) {
        lock.withLock {
            _forgotten.append(id)
            contexts[id] = nil
        }
    }
}

/// Reuses the model stub payloads, but releases each response explicitly instead of using timed delays.
private final class HeldCoordinatorResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: (HeldCoordinatorURLProtocol, ModelStubURLProtocol.Response)] = [:]
    var onRequest: (String) -> Void = { _ in }

    static func key(_ request: URLRequest) -> String {
        let input = StubStream.input(StubStream.body(request))
        if let question = input["question"] as? String { return question }
        return (input["evidence"] as? [String: Any])?["text"] as? String ?? "missing evidence"
    }

    func hold(_ transport: HeldCoordinatorURLProtocol, key: String, response: ModelStubURLProtocol.Response) {
        lock.withLock { pending[key] = (transport, response) }
        onRequest(key)
    }

    func respond(_ key: String) throws {
        let (transport, response) = try XCTUnwrap(lock.withLock { pending.removeValue(forKey: key) })
        transport.deliver(response)
    }
}

private final class HeldCoordinatorURLProtocol: URLProtocol {
    static var responses: HeldCoordinatorResponses?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(ModelStubURLProtocol.handler)
            // URLSession may expose a one-shot body stream; normalize it once for stub inspection.
            var normalized = request
            if request.httpMethod != "GET" {
                normalized.httpBody = try JSONSerialization.data(withJSONObject: StubStream.body(request))
            }
            let response = try handler(normalized)
            if request.httpMethod == "GET" { deliver(response) }
            else { try XCTUnwrap(Self.responses).hold(self, key: HeldCoordinatorResponses.key(normalized), response: response) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    func deliver(_ stub: ModelStubURLProtocol.Response) {
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": stub.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class ActionCoordinatorTests: XCTestCase {
    private var session: URLSession!
    private var folder: URL!
    private let log = RequestLog()
    private var preconnections: [GatewayPreconnection] = []

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pinpin-coordinator-\(UUID().uuidString)")
    }
    override func tearDown() async throws {
        preconnections.forEach { $0.stop() }
        preconnections.removeAll()
        session.invalidateAndCancel()
        ModelStubURLProtocol.handler = nil
        HeldCoordinatorURLProtocol.responses = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ template: CapturedContext, reply: [String] = ["少即是多。"],
                      sourceObserver: ResultSourceObserving? = nil,
                      prepareAIAction: @escaping @Sendable () async throws -> Void = {},
                      cancelAIAction: @escaping @Sendable (UUID) async -> Void = { _ in })
        -> (ActionCoordinator, FakePresentation, FakeCapture) {
        let log = self.log
        ModelStubURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/ping/health")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.isEmpty ?? true)
                XCTAssertNil(request.httpBody)
                return .init(chunks: [Data("{}".utf8)])
            }
            log.append(StubStream.body(request))
            return StubStream.sse(reply)
        }
        let presentation = FakePresentation()
        let capture = FakeCapture(template: template)
        let engine = ExplanationEngine(session: session, credentials: { try PointOutCredentials(accessToken: "test-gateway-token") },
                                       jevTimeout: 1, totalTimeout: 3)
        preconnections.append(engine.preconnection)
        let coordinator = ActionCoordinator(presentation: presentation, capture: capture, engine: engine,
                                            library: SavedLibrary(url: folder.appendingPathComponent("library.json")),
                                            colorHistory: ColorHistory(url: folder.appendingPathComponent("color-history.json")), home: "zh-Hans",
                                            sourceObserver: sourceObserver, prepareAIAction: prepareAIAction,
                                            cancelAIAction: cancelAIAction)
        return (coordinator, presentation, capture)
    }

    func testPreparationFailureStopsBeforeModelExecution() async throws {
        let (coordinator, presentation, _) = make(selection("example"), prepareAIAction: {
            throw SubscriptionError.authentication
        })
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.failures[a.id] != nil }
        XCTAssertEqual(log.count, 0)
    }

    func testInitialAndFollowUpHaveDifferentUsageIdentities() async throws {
        let (coordinator, presentation, _) = make(selection("example"))
        let headers = RequestLog()
        ModelStubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return .init(chunks: [Data("{}".utf8)]) }
            headers.append(["id": request.value(forHTTPHeaderField: "X-PinPin-Action-ID") ?? ""])
            return StubStream.sse(["translated"])
        }
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.finished[a.id] == true }
        presentation.finished[a.id] = nil
        presentation.onFollowUp?(a.id, "again")
        try await waitUntil { headers.count == 2 && presentation.finished[a.id] == true }
        let ids = headers.all.compactMap { $0["id"] as? String }
        #if PINPIN_APP_STORE
        XCTAssertEqual(ids.first, a.id.uuidString.lowercased())
        XCTAssertNotEqual(ids.first, ids.last)
        XCTAssertNotNil(UUID(uuidString: ids.last ?? ""))
        #else
        XCTAssertEqual(ids, ["", ""])
        #endif
    }

    func testDecliningCloudProcessingRemovesInitialLoadingResult() async throws {
        let (coordinator, presentation, _) = make(selection("example"), prepareAIAction: {
            throw CloudProcessingConsentError.declined
        })
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { !coordinator.hasSession(a.id) && !presentation.resultIDs.contains(a.id) }
        XCTAssertNil(presentation.failures[a.id])
        XCTAssertEqual(log.count, 0)
    }

    func testDecliningCloudProcessingOnSavedFollowUpKeepsTheSavedResult() async throws {
        let (coordinator, presentation, _) = make(selection("local collection"),
            reply: [#"{"text":"","tags":[]}"#], prepareAIAction: { throw CloudProcessingConsentError.declined })
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .save
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.saved[a.id] != nil }
        #if !PINPIN_APP_STORE
        try await waitUntil { self.log.count == 1 }
        #endif
        let before = log.count
        presentation.onFollowUp?(a.id, "explain")
        try await waitUntil { presentation.failures[a.id] == "已取消云端处理。" }
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertNotNil(presentation.saved[a.id])
        XCTAssertEqual(log.count, before)
    }

    func testModelAuthenticationFailureReleasesReservationWithoutReplayingAction() async throws {
        let cancellations = RequestLog()
        let (coordinator, presentation, _) = make(selection("example"), cancelAIAction: { id in
            cancellations.append(["id": id.uuidString])
        })
        let requests = RequestLog()
        ModelStubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return .init(chunks: [Data("{}".utf8)]) }
            requests.append(["called": true])
            return .init(status: 401, chunks: [Data("{}".utf8)])
        }
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.failures[a.id] != nil }
        XCTAssertEqual(cancellations.count, 1)
        XCTAssertEqual(cancellations.all.first?["id"] as? String, a.id.uuidString)
        XCTAssertEqual(requests.count, 1)
        #if PINPIN_APP_STORE
        XCTAssertEqual(presentation.failures[a.id], "订阅连接已失效，请打开订阅并刷新状态后重试。")
        #else
        XCTAssertTrue(presentation.failures[a.id]?.contains("访问令牌") == true)
        #endif
    }

    private func selection(_ text: String) -> CapturedContext {
        CapturedContext(sessionID: UUID(), targetText: text, surroundingText: "", appName: "Notes", windowTitle: "Doc",
                        source: "ax_selection", passageText: text)
    }

    private func makeHeld(_ text: String)
        -> (ActionCoordinator, FakePresentation, FakeCapture, HeldCoordinatorResponses) {
        preconnections.forEach { $0.stop() }
        preconnections.removeAll()
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldCoordinatorURLProtocol.self]
        session = URLSession(configuration: configuration)
        let responses = HeldCoordinatorResponses()
        HeldCoordinatorURLProtocol.responses = responses
        let (coordinator, presentation, capture) = make(selection(text))
        let log = self.log
        ModelStubURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return .init(chunks: [Data("{}".utf8)]) }
            log.append(StubStream.body(request))
            return StubStream.sse([HeldCoordinatorResponses.key(request) + ":first", ":last"])
        }
        return (coordinator, presentation, capture, responses)
    }

    private func anchor() -> TargetAnchor {
        TargetAnchor(id: UUID(), screenPoint: CGPoint(x: 100, y: 100), presentationPoint: CGPoint(x: 100, y: 700),
                     processID: 0, startedAt: ProcessInfo.processInfo.systemUptime)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for the coordinator")
    }

    func testPickColorUsesOriginalAnchorWithoutAnyModelRequestOrFollowUp() async throws {
        let (coordinator, presentation, capture) = make(selection("ignored"))
        let a = anchor()
        let sampled = expectation(description: "sample original point")
        capture.colorSample = { received in
            XCTAssertEqual(received.id, a.id)
            XCTAssertEqual(received.screenPoint, a.screenPoint)
            sampled.fulfill()
            return PickedColor(red: 17, green: 34, blue: 51)
        }
        coordinator.receive(.began(a))
        try await waitUntil { capture.captures == 1 }
        presentation.nextAction = .pickColor
        coordinator.receive(.released(CGPoint(x: 900, y: 800)))
        await fulfillment(of: [sampled], timeout: 2)
        try await waitUntil { presentation.finished[a.id] == true }
        XCTAssertEqual(presentation.pickedColors[a.id]?.hex, "#112233")
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertTrue(capture.forgotten.contains(a.id))
        XCTAssertEqual(capture.retainedIDs, [])
        presentation.onFollowUp?(a.id, "identify this color")
        await Task.yield()
        XCTAssertEqual(log.count, 0)
        XCTAssertNil(presentation.failures[a.id])
        presentation.onForget?(a.id)
        XCTAssertFalse(coordinator.hasSession(a.id))
    }

    func testPickColorCancelledAndClearedSessionsRejectLateCallbacks() async throws {
        for clearAll in [false, true] {
            let (coordinator, presentation, capture) = make(selection("ignored"))
            let a = anchor()
            let started = expectation(description: "sample started")
            let completion = CaptureCompletion<PickedColor>()
            capture.colorSample = { _ in
                await withCheckedContinuation { continuation in
                    completion.install(continuation)
                    started.fulfill()
                }
            }
            coordinator.receive(.began(a))
            presentation.nextAction = .pickColor
            coordinator.receive(.released(CGPoint(x: 900, y: 800)))
            await fulfillment(of: [started], timeout: 2)
            if clearAll { coordinator.receive(.clearAllMarkers) }
            else { presentation.onCancel?(a.id) }
            XCTAssertFalse(coordinator.hasSession(a.id))
            completion.finish(PickedColor(red: 200, green: 100, blue: 50))
            for _ in 0..<5 { await Task.yield() }
            XCTAssertNil(presentation.pickedColors[a.id])
            XCTAssertNil(presentation.finished[a.id])
            XCTAssertTrue(coordinator.colorHistory.items.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("color-history.json").path))
            XCTAssertEqual(log.count, 0)
        }
    }

    func testPickColorPermissionFailureIsLocalAndReleasesSession() async throws {
        let (coordinator, presentation, capture) = make(selection("ignored"))
        capture.colorSample = { _ in throw PixelSamplingError.permissionDenied }
        let a = anchor()
        coordinator.receive(.began(a))
        try await waitUntil { capture.captures == 1 }
        presentation.nextAction = .pickColor
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.failures[a.id] != nil }
        XCTAssertEqual(presentation.failureKinds[a.id], .screenCapturePermission)
        XCTAssertFalse(coordinator.hasSession(a.id))
        XCTAssertNil(presentation.pickedColors[a.id])
        XCTAssertEqual(log.count, 0)
    }

    func testReleaseOnTranslateStreamsAndFinishes() async throws {
        let (coordinator, presentation, capture) = make(selection("Less is more, and that is the whole point."),
                                                        reply: ["**少即**", "是多。"])
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.finished[a.id] != nil }
        XCTAssertEqual(presentation.events.prefix(2), ["wheel", "begin:translate"])
        XCTAssertEqual(presentation.texts[a.id], "**少即**是多。")
        XCTAssertEqual(presentation.subtitles[a.id], "英 → 中")
        XCTAssertEqual(presentation.finished[a.id], true)
        XCTAssertEqual(capture.captures, 1, "The wheel's local capture is reused, never repeated")


    }

    func testNoActionOrSecondReleaseNeverRequestsAModel() async throws {
        let (coordinator, presentation, _) = make(selection("text"))
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = nil
        coordinator.receive(.released(a.screenPoint))
        coordinator.receive(.closed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(log.count, 0)
        XCTAssertFalse(presentation.events.contains { $0.hasPrefix("begin") })

        let b = anchor()
        coordinator.receive(.began(b))
        presentation.nextAction = .rewrite
        coordinator.receive(.released(b.screenPoint))
        coordinator.receive(.released(b.screenPoint))
        try await waitUntil { presentation.finished[b.id] != nil }
        XCTAssertEqual(presentation.events.filter { $0.hasPrefix("begin") }, ["begin:rewrite"])
        XCTAssertEqual(log.count, 1)
    }

    func testSaveStoresBeforeTagsAndAppliesSuggestedTags() async throws {
        let (coordinator, presentation, _) = make(selection("周五前确认发布清单"), reply: [#"{"text":"","tags":["工作","待办"]}"#])
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = .save
        coordinator.receive(.released(a.screenPoint))
        #if PINPIN_APP_STORE
        try await waitUntil { presentation.saved[a.id] != nil }
        XCTAssertEqual(presentation.saved[a.id]?.tags, [])
        XCTAssertEqual(coordinator.library.items.first?.tags, [])
        XCTAssertEqual(log.count, 0)
        #else
        try await waitUntil { presentation.saved[a.id]?.tags.isEmpty == false }
        XCTAssertEqual(presentation.saved[a.id]?.tags, ["工作", "待办"])
        XCTAssertEqual(coordinator.library.items.first?.tags, ["工作", "待办"])
        #endif
        XCTAssertEqual(presentation.saved[a.id]?.text, "周五前确认发布清单")
        XCTAssertEqual(presentation.library.count, 1)

        presentation.onLibraryEdit?(.setTags(try XCTUnwrap(presentation.saved[a.id]?.id), ["学习"]))
        try await waitUntil { presentation.saved[a.id]?.tags == ["学习"] }
        XCTAssertEqual(presentation.saved[a.id]?.tags, ["学习"], "An open saved card follows tag edits")
        presentation.onLibraryEdit?(.delete(try XCTUnwrap(presentation.saved[a.id]?.id)))
        try await waitUntil { coordinator.library.items.isEmpty && presentation.library.isEmpty }
    }

    func testRapidTagIntentsBeforePresentationAcknowledgementUpdateEverySavedCardAndAssets() async throws {
        let (coordinator, presentation, _) = make(selection("同一收藏"), reply: [#"{"text":"","tags":["Old"]}"#])
        let first = anchor()
        coordinator.receive(.began(first)); presentation.nextAction = .save
        coordinator.receive(.released(first.screenPoint))
        #if PINPIN_APP_STORE
        try await waitUntil { presentation.saved[first.id] != nil }
        presentation.onLibraryEdit?(.setTags(try XCTUnwrap(presentation.saved[first.id]?.id), ["Old"]))
        #endif
        try await waitUntil { presentation.saved[first.id]?.tags == ["Old"] }
        let second = anchor()
        coordinator.receive(.began(second)); presentation.nextAction = .save
        coordinator.receive(.released(second.screenPoint))
        try await waitUntil { presentation.saved[second.id]?.tags == ["Old"] }
        let id = try XCTUnwrap(presentation.saved[first.id]?.id)
        XCTAssertEqual(presentation.saved[second.id]?.id, id)

        // All three intents arrive while the UI still displays the original complete array.
        presentation.onLibraryEdit?(.addTag(id, "A"))
        presentation.onLibraryEdit?(.addTag(id, "B"))
        presentation.onLibraryEdit?(.removeTag(id, "Old"))
        XCTAssertEqual(presentation.saved[first.id]?.tags, ["Old"])
        XCTAssertEqual(presentation.library.first?.tags, ["Old"])
        try await waitUntil {
            presentation.saved[first.id]?.tags == ["A", "B"] &&
            presentation.saved[second.id]?.tags == ["A", "B"] &&
            presentation.library.first?.tags == ["A", "B"]
        }
        let asset = presentation.assets.first { $0.id == .saved(id) }
        guard case .saved(let item) = try XCTUnwrap(asset) else { return XCTFail("Saved asset missing") }
        XCTAssertEqual(item.tags, ["A", "B"])
        let restarted = SavedLibrary(url: folder.appendingPathComponent("library.json"))
        try await restarted.reload()
        XCTAssertEqual(restarted.item(id)?.tags, ["A", "B"])
    }

    func testNothingReadableFailsWithActionSpecificMessageAndForgets() async throws {
        let empty = CapturedContext(sessionID: UUID(), targetText: "", surroundingText: "", appName: "", windowTitle: "",
                                    source: "ax_no_hit")
        let (coordinator, presentation, capture) = make(empty)
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.failures[a.id] != nil }
        XCTAssertEqual(presentation.failures[a.id], "这里没有读到可以翻译的文字。")
        XCTAssertFalse(coordinator.hasSession(a.id))
        XCTAssertEqual(capture.forgotten, [a.id])
        XCTAssertEqual(log.count, 0)
    }

    func testFollowUpUsesKeptContextAndForgetReleasesIt() async throws {
        let (coordinator, presentation, capture) = make(selection("我们这边可能大概下周会把这个弄好。"), reply: ["我们预计下周完成。"])
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = .rewrite
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.finished[a.id] != nil }
        presentation.finished[a.id] = nil
        presentation.onFollowUp?(a.id, "再正式一点")
        try await waitUntil { presentation.finished[a.id] != nil }
        XCTAssertEqual(presentation.finished[a.id], true, "Follow-up finishes using the same evidence")
        XCTAssertEqual(capture.captures, 1, "Follow-ups never capture again")
        let input = StubStream.input(try XCTUnwrap(log.all.last))
        XCTAssertEqual(input["question"] as? String, "再正式一点")
        XCTAssertEqual(input["previous_result"] as? String, "我们预计下周完成。")

        presentation.onForget?(a.id)
        XCTAssertFalse(coordinator.hasSession(a.id))
        XCTAssertEqual(capture.forgotten, [a.id])
        presentation.onFollowUp?(a.id, "还有吗")
        XCTAssertEqual(presentation.failures[a.id], "这条结果已经不能追问了。")
    }

    func testCancelDropsAnUnfinishedResultButKeepsAFinishedOne() async throws {
        let (coordinator, presentation, _) = make(selection("Less is more."))
        let a = anchor()
        coordinator.receive(.began(a))
        presentation.nextAction = .translate
        coordinator.receive(.released(a.screenPoint))
        presentation.onCancel?(a.id)
        XCTAssertFalse(coordinator.hasSession(a.id))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(presentation.finished[a.id], "A cancelled result never finishes later")

        let b = anchor()
        coordinator.receive(.began(b))
        coordinator.receive(.released(b.screenPoint))
        try await waitUntil { presentation.finished[b.id] != nil }
        presentation.onCancel?(b.id)
        XCTAssertTrue(coordinator.hasSession(b.id))
    }

    func testClearAllConsumesTheWheelSession() async throws {
        let (coordinator, presentation, _) = make(selection("text"))
        let a = anchor()
        coordinator.receive(.began(a))
        coordinator.receive(.clearAllMarkers)
        presentation.nextAction = .explain
        coordinator.receive(.released(a.screenPoint))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(presentation.events, ["wheel", "clear"])
        XCTAssertEqual(log.count, 0)
    }
    func testImageSaveAcknowledgesUnmarkedImageOnDiskThenEnrichesIt() async throws {
        let original = Data([0xff, 0xd8, 0xff, 0xd9])
        let picture = CapturedContext(sessionID: UUID(), targetText: "", surroundingText: "", appName: "Preview", windowTitle: "Public fixture",
            source: "visual_local", imageData: Data([1, 2, 3]), imageMIME: "image/jpeg", originalImageData: original,
            pointInImage: CGPoint(x: 0.2, y: 0.4))
        let (coordinator, presentation, _) = make(picture, reply: [#"{"text":"图片说明","tags":["学习"]}"#])
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .save
        coordinator.receive(.released(a.screenPoint))
        #if PINPIN_APP_STORE
        try await waitUntil { presentation.saved[a.id] != nil }
        #else
        try await waitUntil { presentation.saved[a.id]?.tags == ["学习"] }
        #endif
        let item = try XCTUnwrap(presentation.saved[a.id])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.imageURL)), original)
        XCTAssertEqual(item.pointInImage, CGPoint(x: 0.2, y: 0.4))
        #if PINPIN_APP_STORE
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(log.count, 0, "Local collection must not call either provider")
        #else
        XCTAssertEqual(item.text, "图片说明")
        XCTAssertEqual(log.count, 1, "Only enrichment requests generation when the local range already covers the source window")
        #endif
    }

    func testScreenPermissionFailureHasDedicatedKindAndMakesNoModelCall() async throws {
        var empty = selection(""); empty.screenCapturePermissionMissing = true
        let (coordinator, presentation, _) = make(empty)
        let a = anchor(); coordinator.receive(.began(a)); presentation.nextAction = .explain
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.failures[a.id] != nil }
        XCTAssertEqual(presentation.failureKinds[a.id], .screenCapturePermission)
        XCTAssertEqual(log.count, 0)
    }

    func testLocalTextSaveSurvivesUnavailableModelConfiguration() async throws {
        let presentation = FakePresentation(), capture = FakeCapture(template: selection("记录原文"))
        let engine = ExplanationEngine(session: session, credentials: { throw ModelClientError.credentialsUnavailable })
        let coordinator = ActionCoordinator(presentation: presentation, capture: capture, engine: engine,
            library: SavedLibrary(url: folder.appendingPathComponent("library.json")),
            colorHistory: ColorHistory(url: folder.appendingPathComponent("color-history.json")))
        let a = anchor(); coordinator.receive(.began(a)); presentation.nextAction = .save
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.saved[a.id] != nil }
        XCTAssertEqual(presentation.saved[a.id]?.text, "记录原文")
        let disk = SavedLibrary(url: folder.appendingPathComponent("library.json"))
        try await disk.reload()
        XCTAssertEqual(disk.items.first?.text, "记录原文")
        XCTAssertNil(presentation.failures[a.id])
    }

    func testSecondActionKeepsUnfinishedFirstResultAndBothFinishByID() async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("A original")
        let a = anchor(), b = anchor()
        let aRequested = expectation(description: "A request held")
        let bRequested = expectation(description: "B request held")
        let aFinished = expectation(description: "A finished")
        let bFinished = expectation(description: "B finished")
        responses.onRequest = { key in
            if key == "A original" { aRequested.fulfill() }
            else if key == "B original" { bRequested.fulfill() }
            else { XCTFail("Unexpected request: \(key)") }
        }
        presentation.onResultFinish = { id in
            if id == a.id { aFinished.fulfill() }
            else if id == b.id { bFinished.fulfill() }
            else { XCTFail("Unexpected result id") }
        }
        presentation.nextAction = .rewrite
        coordinator.receive(.began(a)); coordinator.receive(.released(a.screenPoint))
        await fulfillment(of: [aRequested], timeout: 2)
        capture.template = selection("B original")
        coordinator.receive(.began(b)); coordinator.receive(.released(b.screenPoint))
        await fulfillment(of: [bRequested], timeout: 2)
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertTrue(coordinator.hasSession(b.id))
        XCTAssertNil(presentation.finished[a.id])
        XCTAssertNil(presentation.finished[b.id])

        try responses.respond("B original")
        await fulfillment(of: [bFinished], timeout: 2)
        XCTAssertNil(presentation.finished[a.id], "A stays pending when B finishes first")
        try responses.respond("A original")
        await fulfillment(of: [aFinished], timeout: 2)
        XCTAssertEqual(presentation.texts[a.id], "A original:first:last")
        XCTAssertEqual(presentation.texts[b.id], "B original:first:last")
        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(presentation.failures.isEmpty)
        XCTAssertFalse(capture.forgotten.contains(a.id))
    }

    func testFollowUpOfFirstResultKeepsItsContextAndDoesNotChangeSecondResult() async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("A original")
        let a = anchor(), b = anchor()
        let aRequested = expectation(description: "A request held")
        let bRequested = expectation(description: "B request held")
        let followUpRequested = expectation(description: "A follow-up request held")
        let aFinished = expectation(description: "A finished")
        let bFinished = expectation(description: "B finished")
        let followUpFinished = expectation(description: "A follow-up finished")
        responses.onRequest = { key in
            switch key {
            case "A original": aRequested.fulfill()
            case "B original": bRequested.fulfill()
            case "A question": followUpRequested.fulfill()
            default: XCTFail("Unexpected request: \(key)")
            }
        }
        var aCompletions = 0
        presentation.onResultFinish = { id in
            if id == a.id {
                aCompletions += 1
                if aCompletions == 1 { aFinished.fulfill() } else { followUpFinished.fulfill() }
            } else if id == b.id { bFinished.fulfill() }
        }
        presentation.nextAction = .rewrite
        coordinator.receive(.began(a)); coordinator.receive(.released(a.screenPoint))
        await fulfillment(of: [aRequested], timeout: 2)
        try responses.respond("A original")
        await fulfillment(of: [aFinished], timeout: 2)
        capture.template = selection("B original")
        coordinator.receive(.began(b)); coordinator.receive(.released(b.screenPoint))
        await fulfillment(of: [bRequested], timeout: 2)
        try responses.respond("B original")
        await fulfillment(of: [bFinished], timeout: 2)
        let previousB = presentation.texts[b.id]
        var bUpdates = 0
        presentation.onResultUpdate = { id, _ in if id == b.id { bUpdates += 1 } }

        presentation.onFollowUp?(a.id, "A question")
        await fulfillment(of: [followUpRequested], timeout: 2)
        let input = StubStream.input(try XCTUnwrap(log.all.last))
        XCTAssertEqual((input["evidence"] as? [String: Any])?["text"] as? String, "A original")
        XCTAssertEqual(input["previous_result"] as? String, "A original:first:last")
        XCTAssertEqual(input["question"] as? String, "A question")
        try responses.respond("A question")
        await fulfillment(of: [followUpFinished], timeout: 2)
        XCTAssertEqual(presentation.texts[a.id], "A question:first:last")
        XCTAssertEqual(presentation.texts[b.id], previousB)
        XCTAssertEqual(bUpdates, 0)
        XCTAssertEqual(capture.captures, 2, "The follow-up reuses A's retained context")
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertTrue(coordinator.hasSession(b.id))
    }

    func testForgettingStreamingFirstResultKeepsSecondResultAndRejectsBufferedCallbacks() async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("A original")
        let a = anchor(), b = anchor()
        let aRequested = expectation(description: "A request held")
        let bRequested = expectation(description: "B request held")
        let aForgotten = expectation(description: "A forgotten after first streamed text")
        let bFinished = expectation(description: "B finished")
        let noLateA = expectation(description: "No A update or completion after forget")
        noLateA.isInverted = true
        responses.onRequest = { key in
            if key == "A original" { aRequested.fulfill() }
            else if key == "B original" { bRequested.fulfill() }
            else { XCTFail("Unexpected request: \(key)") }
        }
        var forgotA = false
        presentation.onResultUpdate = { [weak presentation] id, text in
            guard id == a.id else { return }
            if forgotA { noLateA.fulfill(); return }
            XCTAssertEqual(text, "A original:first")
            forgotA = true
            presentation?.onForget?(a.id)
            aForgotten.fulfill()
        }
        presentation.onResultFinish = { id in
            if id == b.id { bFinished.fulfill() }
            else if id == a.id { noLateA.fulfill() }
        }
        presentation.nextAction = .rewrite
        coordinator.receive(.began(a)); coordinator.receive(.released(a.screenPoint))
        await fulfillment(of: [aRequested], timeout: 2)
        capture.template = selection("B original")
        coordinator.receive(.began(b)); coordinator.receive(.released(b.screenPoint))
        await fulfillment(of: [bRequested], timeout: 2)

        // Both SSE deltas are delivered before the main actor handles A's first update. Forgetting
        // there must also suppress A's buffered second delta and completion, without touching B.
        try responses.respond("A original")
        await fulfillment(of: [aForgotten], timeout: 2)
        XCTAssertFalse(coordinator.hasSession(a.id))
        XCTAssertTrue(coordinator.hasSession(b.id))
        try responses.respond("B original")
        await fulfillment(of: [bFinished], timeout: 2)
        await fulfillment(of: [noLateA], timeout: 0.1)
        XCTAssertEqual(presentation.texts[a.id], "A original:first")
        XCTAssertNil(presentation.finished[a.id])
        XCTAssertEqual(presentation.texts[b.id], "B original:first:last")
        XCTAssertEqual(capture.forgotten.filter { $0 == a.id }, [a.id])
        XCTAssertFalse(capture.forgotten.contains(b.id))
        XCTAssertTrue(presentation.failures.isEmpty)
    }

    func testTwentyFiveCompletedResultsRetainOldestFollowUp() async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("original 0")
        let anchors = (0..<25).map { _ in anchor() }
        presentation.nextAction = .rewrite
        for (index, target) in anchors.enumerated() {
            let key = "original \(index)"
            let requested = expectation(description: "Request \(index)")
            let completed = expectation(description: "Completed \(index)")
            responses.onRequest = { actual in XCTAssertEqual(actual, key); requested.fulfill() }
            presentation.onResultFinish = { id in XCTAssertEqual(id, target.id); completed.fulfill() }
            capture.template = selection(key)
            coordinator.receive(.began(target)); coordinator.receive(.released(target.screenPoint))
            await fulfillment(of: [requested], timeout: 2)
            try responses.respond(key)
            await fulfillment(of: [completed], timeout: 2)
        }
        let oldest = anchors[0], newest = anchors[24]
        XCTAssertEqual(presentation.finished.count, 25)
        XCTAssertEqual(presentation.resultIDs.count, 25)
        XCTAssertTrue(anchors.allSatisfy { coordinator.hasSession($0.id) }, "All 25 visible results retain their sessions")
        XCTAssertEqual(capture.retainedIDs, Set(anchors.map(\.id)))
        XCTAssertTrue(capture.forgotten.isEmpty, "Creating another result never forgets an existing result")

        let previousNewest = presentation.texts[newest.id]
        presentation.onFollowUp?(oldest.id, "oldest question")
        XCTAssertNil(presentation.failures[oldest.id], "The oldest visible result remains available for follow-up")
        // Keep the original failure concrete without waiting for a request that the defective version never makes.
        guard coordinator.hasSession(oldest.id) else {
            XCTAssertEqual(log.count, 26, "25 initial results plus the oldest result's follow-up must be requested")
            return
        }
        let followUpRequested = expectation(description: "Oldest follow-up requested")
        let followUpCompleted = expectation(description: "Oldest follow-up completed")
        responses.onRequest = { key in XCTAssertEqual(key, "oldest question"); followUpRequested.fulfill() }
        presentation.onResultFinish = { id in XCTAssertEqual(id, oldest.id); followUpCompleted.fulfill() }
        await fulfillment(of: [followUpRequested], timeout: 2)
        let input = StubStream.input(try XCTUnwrap(log.all.last))
        XCTAssertEqual((input["evidence"] as? [String: Any])?["text"] as? String, "original 0")
        XCTAssertEqual(input["previous_result"] as? String, "original 0:first:last")
        XCTAssertEqual(input["question"] as? String, "oldest question")
        try responses.respond("oldest question")
        await fulfillment(of: [followUpCompleted], timeout: 2)
        XCTAssertEqual(presentation.texts[oldest.id], "oldest question:first:last")
        XCTAssertEqual(presentation.texts[newest.id], previousNewest)
        XCTAssertEqual(capture.captures, 25, "Follow-up reuses the oldest result's own evidence")
        XCTAssertEqual(log.count, 26)
    }

    func testThirtyTwoPendingResultsFinishInOriginalOrderAndRemainAvailable() async throws {
        try await finishThirtyTwoResults(reverse: false)
    }

    func testThirtyTwoPendingResultsFinishInReverseOrderAndRemainAvailable() async throws {
        try await finishThirtyTwoResults(reverse: true)
    }

    private func finishThirtyTwoResults(reverse: Bool) async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("original 0")
        let anchors = try await startThirtyTwoResults(coordinator, presentation, capture, responses)
        XCTAssertTrue(anchors.allSatisfy { coordinator.hasSession($0.id) })
        let indices = reverse ? Array(anchors.indices.reversed()) : Array(anchors.indices)
        for index in indices {
            let completed = expectation(description: "Completed \(index)")
            presentation.onResultFinish = { id in XCTAssertEqual(id, anchors[index].id); completed.fulfill() }
            try responses.respond("original \(index)")
            await fulfillment(of: [completed], timeout: 2)
        }
        for (index, target) in anchors.enumerated() {
            XCTAssertTrue(coordinator.hasSession(target.id))
            XCTAssertEqual(presentation.texts[target.id], "original \(index):first:last")
            XCTAssertEqual(presentation.finished[target.id], true)
        }
        XCTAssertEqual(capture.retainedIDs, Set(anchors.map(\.id)))
        XCTAssertTrue(capture.forgotten.isEmpty)
        XCTAssertTrue(presentation.failures.isEmpty)
        XCTAssertEqual(log.count, 32)
    }

    func testClearAllReleasesThirtyTwoSessionsThroughPresenterCallbacksAndRejectsLateResults() async throws {
        let (coordinator, presentation, capture, responses) = makeHeld("original 0")
        let anchors = try await startThirtyTwoResults(coordinator, presentation, capture, responses)
        // Exercise clear with both completed results and requests whose callbacks are still buffered.
        for index in 0..<16 {
            let completed = expectation(description: "Completed before clear \(index)")
            presentation.onResultFinish = { id in XCTAssertEqual(id, anchors[index].id); completed.fulfill() }
            try responses.respond("original \(index)")
            await fulfillment(of: [completed], timeout: 2)
        }
        let noLateResult = expectation(description: "No updates or completion after clear")
        noLateResult.isInverted = true
        presentation.onResultUpdate = { _, _ in noLateResult.fulfill() }
        presentation.onResultFinish = { _ in noLateResult.fulfill() }
        coordinator.receive(.clearAllMarkers)
        XCTAssertTrue(presentation.resultIDs.isEmpty)
        XCTAssertTrue(anchors.allSatisfy { !coordinator.hasSession($0.id) })
        XCTAssertTrue(capture.retainedIDs.isEmpty)
        XCTAssertEqual(Set(capture.forgotten), Set(anchors.map(\.id)))
        XCTAssertEqual(capture.forgotten.count, 32, "Each session is released once through its onForget callback")
        for index in 16..<32 { try responses.respond("original \(index)") }
        await fulfillment(of: [noLateResult], timeout: 0.1)
        XCTAssertEqual(presentation.finished.count, 16)
        XCTAssertTrue(anchors.allSatisfy { !coordinator.hasSession($0.id) })
        XCTAssertTrue(presentation.failures.isEmpty)
    }

    private func startThirtyTwoResults(_ coordinator: ActionCoordinator, _ presentation: FakePresentation,
                                      _ capture: FakeCapture, _ responses: HeldCoordinatorResponses) async throws -> [TargetAnchor] {
        let anchors = (0..<32).map { _ in anchor() }
        presentation.nextAction = .rewrite
        for (index, target) in anchors.enumerated() {
            let key = "original \(index)"
            let requested = expectation(description: "Held request \(index)")
            responses.onRequest = { actual in XCTAssertEqual(actual, key); requested.fulfill() }
            capture.template = selection(key)
            coordinator.receive(.began(target)); coordinator.receive(.released(target.screenPoint))
            await fulfillment(of: [requested], timeout: 2)
        }
        XCTAssertEqual(log.count, 32)
        XCTAssertEqual(capture.captures, 32)
        return anchors
    }

    func testPickedColorIsDurableAfterFinishedCardIsClearedBeforeWrite() async throws {
        for clearAll in [false, true] {
            let (coordinator, presentation, _) = make(selection("ignored"))
            let a = anchor()
            presentation.onResultFinish = { id in
                XCTAssertTrue(coordinator.colorHistory.items.isEmpty, "Showing a color must not wait for disk")
                XCTAssertEqual(presentation.colorPersistence[id], .saving)
                if clearAll { coordinator.receive(.clearAllMarkers) }
                else { presentation.onForget?(id) }
            }
            coordinator.receive(.began(a)); presentation.nextAction = .pickColor
            coordinator.receive(.released(a.screenPoint))
            try await waitUntil { coordinator.colorHistory.items.contains { $0.id == a.id } }
            XCTAssertFalse(coordinator.hasSession(a.id))
            XCTAssertEqual(presentation.pickedColors[a.id]?.hex, "#112233")
            XCTAssertTrue(presentation.assets.contains { $0.id == .color(a.id) })
            let restarted = ColorHistory(url: folder.appendingPathComponent("color-history.json"))
            try await restarted.reload()
            XCTAssertTrue(restarted.items.contains { $0.id == a.id })
            XCTAssertEqual(log.count, 0)
            // Each iteration owns a separate file so its initial history starts empty.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("color-history.json"))
        }
    }

    func testColorPersistenceFailureKeepsFinishedUsableColorAndReportsUnsaved() async throws {
        let (coordinator, presentation, _) = make(selection("ignored"))
        let file = folder.appendingPathComponent("color-history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let a = anchor()
        coordinator.receive(.began(a)); presentation.nextAction = .pickColor
        coordinator.receive(.released(a.screenPoint))
        try await waitUntil { presentation.colorPersistence[a.id] == .failed }
        XCTAssertEqual(presentation.pickedColors[a.id]?.hex, "#112233")
        XCTAssertEqual(presentation.finished[a.id], true)
        XCTAssertNil(presentation.failures[a.id])
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertTrue(coordinator.colorHistory.items.isEmpty)
        XCTAssertFalse(presentation.assets.contains { $0.id == .color(a.id) })
        XCTAssertEqual(log.count, 0)
    }

    func testAssetDeletionRoutesByTypeAndKeepsSavedTagsAndImages() async throws {
        let (coordinator, presentation, _) = make(selection("ignored"))
        let bytes = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let added = try await coordinator.library.add(text: "保留图片", image: bytes,
            appName: "Preview", windowTitle: "Image", now: Date(timeIntervalSince1970: 1))
        let saved = try XCTUnwrap(added)
        let color = ColorRecord(id: saved.id, color: PickedColor(red: 1, green: 2, blue: 3),
            createdAt: Date(timeIntervalSince1970: 2), appName: "Notes", windowTitle: "Doc")
        try await coordinator.colorHistory.add(color)
        coordinator.showLibrary(near: nil)
        XCTAssertEqual(presentation.assets.map(\.id), [.color(saved.id), .saved(saved.id)])
        presentation.onLibraryEdit?(.setTags(saved.id, ["自选"]))
        try await waitUntil { coordinator.library.item(saved.id)?.tags == ["自选"] }
        presentation.onAssetEdit?(.delete(.color(saved.id)))
        try await waitUntil { coordinator.colorHistory.items.isEmpty }
        XCTAssertEqual(coordinator.library.item(saved.id)?.tags, ["自选"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.imageURL)), bytes)
        try await coordinator.colorHistory.add(color)
        presentation.onAssetEdit?(.delete(.saved(saved.id)))
        try await waitUntil { coordinator.library.items.isEmpty }
        XCTAssertEqual(coordinator.colorHistory.items, [color])
        XCTAssertEqual(presentation.assets.map(\.id), [.color(saved.id)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.imageURL).path))
    }

    func testSourceWindowStateKeepsResultsUntilConfirmedCloseAndIgnoresLateUpdates() async throws {
        let observer = FakeResultSourceObserver()
        let (coordinator, presentation, _) = make(selection("不发模型的取色"), sourceObserver: observer)
        let a = anchor()
        presentation.nextAction = .pickColor
        coordinator.receive(.began(a)); coordinator.receive(.released(a.screenPoint))
        XCTAssertEqual(observer.tracked[a.id]?.windowID, a.windowID)
        let moved = CGPoint(x: 130, y: 720)
        observer.onChange?(a.id, moved, false)
        XCTAssertTrue(coordinator.hasSession(a.id))
        XCTAssertEqual(presentation.sourceStates[a.id]?.0, moved)
        XCTAssertEqual(presentation.sourceStates[a.id]?.1, false)
        observer.onChange?(a.id, moved, true)
        XCTAssertEqual(presentation.sourceStates[a.id]?.1, true)
        observer.onClosed?(a.id)
        XCTAssertFalse(coordinator.hasSession(a.id))
        XCTAssertFalse(presentation.resultIDs.contains(a.id))
        XCTAssertNil(observer.tracked[a.id])
        observer.onChange?(a.id, CGPoint(x: 999, y: 999), true)
        XCTAssertEqual(presentation.sourceStates[a.id]?.0, moved)
        coordinator.stopSourceObservation()
        XCTAssertEqual(observer.stops, 1)
    }

}

@MainActor private final class FakeResultSourceObserver: ResultSourceObserving {
    var onChange: ((UUID, CGPoint, Bool) -> Void)?
    var onClosed: ((UUID) -> Void)?
    var tracked: [UUID: TargetAnchor] = [:]
    var stops = 0
    func track(_ anchor: TargetAnchor) { tracked[anchor.id] = anchor }
    func forget(_ id: UUID) { tracked[id] = nil }
    func stop() { stops += 1; tracked.removeAll() }
}
