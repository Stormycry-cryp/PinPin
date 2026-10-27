import XCTest
@testable import PointOut

/// Thread-safe recorder for requests seen by the URL stub.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    func append(_ body: [String: Any]) { lock.withLock { bodies.append(body) } }
    var all: [[String: Any]] { lock.withLock { bodies } }
    var count: Int { lock.withLock { bodies.count } }
}

enum StubStream {
    static func sse(_ deltas: [String], finish: String = "stop") -> ModelStubURLProtocol.Response {
        var events: [String] = []
        for delta in deltas {
            let data = try! JSONSerialization.data(withJSONObject: ["model": DeepSeekClient.model,
                                                                    "choices": [["index": 0, "delta": ["content": delta]]]])
            events.append("data: \(String(decoding: data, as: UTF8.self))\n\n")
        }
        events.append("data: {\"model\":\"\(DeepSeekClient.model)\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n")
        events.append("data: [DONE]\n\n")
        return .init(contentType: "text/event-stream", chunks: [Data(events.joined().utf8)])
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                result.append(contentsOf: buffer.prefix(read))
            }
            data = result
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    /// The JSON text part of the user message.
    static func input(_ body: [String: Any]) -> [String: Any] {
        let messages = body["messages"] as? [[String: Any]] ?? []
        let content = messages.last?["content"] as? [[String: Any]] ?? []
        let text = content.first?["text"] as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    static func system(_ body: [String: Any]) -> String {
        ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    }
}

final class ActionPipelineTests: XCTestCase {
    private var session: URLSession!
    private let log = RequestLog()

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        ModelStubURLProtocol.handler = nil
    }

    private func engine() -> ExplanationEngine {
        ExplanationEngine(session: session, credentials: { try PointOutCredentials(accessToken: "test-gateway-token") },
                          jevTimeout: 1, totalTimeout: 3)
    }

    private func stub(_ deltas: [String] = ["少即是多。"], finish: String = "stop") {
        let log = self.log
        ModelStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url, DeepSeekClient.endpoint, "Selection actions and saved descriptions use the answer route")
            log.append(StubStream.body(request))
            return StubStream.sse(deltas, finish: finish)
        }
    }

    private func selection(_ text: String) -> CapturedContext {
        CapturedContext(sessionID: UUID(), targetText: text, surroundingText: "", appName: "Notes", windowTitle: "Doc",
                        source: "ax_selection", passageText: text)
    }

    private func visual(expand: Bool = false) -> CapturedContext {
        CapturedContext(sessionID: UUID(), targetText: "", surroundingText: "", appName: "Figma", windowTitle: "Doc",
                        source: "visual_local", canExpandVisual: expand, imageData: Data([1, 2, 3]),
                        imageMIME: "image/png", originalImageData: Data([4, 5, 6]), pointInImage: CGPoint(x: 0.3, y: 0.6))
    }

    func testTranslateSelectionSendsFixedDirectionAndStreamsWithSubtitle() async throws {
        stub(["少即", "是多。"])
        let context = selection("Less is more, and that is the whole point.")
        let seen = RequestLog()
        let result = try await engine().translate(context: context, home: "zh-Hans", supplement: { plan in
            XCTAssertEqual(plan, .useCurrent); return context
        }, onText: { text, subtitle in seen.append(["text": text, "subtitle": subtitle ?? ""]) })
        XCTAssertEqual(result.text, "少即是多。")
        XCTAssertEqual(result.subtitle, "英 → 中")
        XCTAssertEqual(result.route, "selection")
        XCTAssertEqual(result.metrics["jev_requests"], 0)
        XCTAssertEqual(seen.all.last?["subtitle"] as? String, "英 → 中")
        let body = try XCTUnwrap(log.all.first)
        XCTAssertEqual(body["model"] as? String, DeepSeekClient.model)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertTrue(StubStream.system(body).contains("译成简体中文"))
        let evidence = try XCTUnwrap(StubStream.input(body)["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["text"] as? String, context.targetText)
        XCTAssertNil(evidence["context"])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.last.flatMap { ($0["content"] as? [Any])?.count }, 1)
    }

    func testImageTranslationUsesOneScopeDecisionAndOneExpansionWithoutInventingLanguageSubtitle() async throws {
        let original = visual(expand: true)
        let events = RequestLog()
        ModelStubURLProtocol.handler = { request in
            let body = StubStream.body(request)
            if request.url == JevClient.endpoint {
                events.append(["event": "jev"])
                XCTAssertTrue(((body["state"] as? [String: Any])?["task"] as? String)?.contains("translate") == true)
                let response: [String: Any] = ["model": JevClient.model, "answers": ["acquisition": ["type": "choice", "choice": "expand_visual", "probabilities": ["use_current": 0.1, "expand_visual": 0.9]]]]
                return .init(chunks: [try JSONSerialization.data(withJSONObject: response)])
            }
            events.append(["event": "answer"])
            XCTAssertEqual(request.url, DeepSeekClient.endpoint)
            let evidence = StubStream.input(body)["evidence"] as! [String: Any]
            XCTAssertEqual(evidence["text"] as? String, "")
            XCTAssertEqual((evidence["point_in_image"] as? [String: Any])?["x"] as? Double, 0.1)
            XCTAssertTrue(StubStream.system(body).contains("只用于理解"))
            XCTAssertTrue(StubStream.system(body).contains("箭头尖端"))
            let content = (body["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
            XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64,BwgJ")
            return StubStream.sse(["翻译结果"])
        }
        let result = try await engine().translate(context: original, home: "zh-Hans", supplement: { plan in
            XCTAssertEqual(plan, .expandVisual); events.append(["event": "supplement"])
            var expanded = original; expanded.source = "visual_window"; expanded.imageData = Data([7, 8, 9])
            expanded.pointInImage = CGPoint(x: 0.1, y: 0.4)
            return expanded
        }, onText: { _, subtitle in XCTAssertNil(subtitle) })
        XCTAssertEqual(events.all.compactMap { $0["event"] as? String }, ["jev", "supplement", "answer"])
        XCTAssertEqual(result.route, "jev:expand_visual")
        XCTAssertNil(result.subtitle)
        XCTAssertEqual(result.metrics["image_sent"], 1)
        XCTAssertNil(result.context?.originalImageData)
    }

    func testImageRewriteUsesOnlyOriginalPointAndKeepsImageForFollowUp() async throws {
        stub(["改写后的文字。"])
        let original = visual()
        let result = try await engine().rewrite(context: original, supplement: { plan in
            XCTAssertEqual(plan, .useCurrent); return original
        }, onText: { _, subtitle in XCTAssertNil(subtitle) })
        let body = try XCTUnwrap(log.all.first)
        XCTAssertTrue(StubStream.system(body).contains("不翻译、改写或复述整窗"))
        XCTAssertEqual(body["max_tokens"] as? Int, 1000)
        XCTAssertEqual(result.context?.imageData, original.imageData)
        XCTAssertEqual(result.context?.pointInImage, original.pointInImage)
        XCTAssertNil(result.context?.originalImageData)
    }

    func testNothingToReadStopsBeforeAnyRequest() async {
        stub()
        let empty = selection("")
        do {
            _ = try await engine().translate(context: empty, home: "zh-Hans", supplement: { _ in XCTFail("No frame"); return empty }, onText: { _, _ in })
            XCTFail("No text and no visual must fail")
        } catch { XCTAssertEqual(error as? ModelClientError, .noTarget) }
        XCTAssertEqual(log.count, 0)
    }

    func testSentinelAndTruncationAreFailures() async {
        let context = selection("x y z")
        stub([unreadableSentinel])
        do {
            _ = try await engine().rewrite(context: context, supplement: { _ in context }, onText: { _, _ in })
            XCTFail("Sentinel must fail")
        } catch { XCTAssertEqual(error as? ModelClientError, .noTarget) }
        stub(["部分"], finish: "length")
        do {
            _ = try await engine().rewrite(context: context, supplement: { _ in context }, onText: { _, _ in })
            XCTFail("Truncated output must fail")
        } catch { XCTAssertEqual(error as? ModelClientError, .outputLimit) }
    }

    func testOversizedSelectionFailsInsteadOfSilentlyCuttingTheUnit() async {
        stub(["好"])
        let context = selection(String(repeating: "字", count: 4001))
        do {
            _ = try await engine().rewrite(context: context, supplement: { _ in XCTFail("Oversized selection"); return context }, onText: { _, _ in })
            XCTFail("Must preserve complete selection")
        } catch { XCTAssertEqual(error as? ModelClientError, .outputLimit) }
        XCTAssertEqual(log.count, 0)
    }

    func testFollowUpCarriesOriginalImagePreviousResultAndQuestionWithoutNewDecision() async throws {
        stub(["比如重复支付只扣一次。"])
        let context = visual()
        let result = try await engine().followUp(action: .explain, context: context, previous: "重复执行结果相同。",
                                                 earlier: [FollowUpExchange(question: "q0", answer: "a0")], question: "举个例子？", onText: { _ in })
        XCTAssertEqual(result.text, "比如重复支付只扣一次。")
        let body = try XCTUnwrap(log.all.first)
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        let input = StubStream.input(body)
        XCTAssertEqual(input["previous_result"] as? String, "重复执行结果相同。")
        XCTAssertEqual(input["question"] as? String, "举个例子？")
        XCTAssertEqual((input["earlier"] as? [[String: String]])?.first?["question"], "q0")
        XCTAssertEqual((input["evidence"] as? [String: Any])?["text"] as? String, "")
        let content = (body["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
        XCTAssertEqual((content[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64,AQID")
        XCTAssertEqual(log.count, 1)
    }

    func testSavedSelectionPreservesOriginalAndImageDescriptionUsesOneGeneration() async throws {
        stub([#"{"text":"","tags":["工作","工作"]}"#])
        let context = selection("周五前确认发布清单")
        let saved = try await engine().describeSaved(context: context, existing: ["工作"], home: "zh-Hans")
        XCTAssertEqual(saved.text, context.targetText)
        XCTAssertEqual(saved.tags, ["工作"])
        let input = StubStream.input(try XCTUnwrap(log.all.first))
        XCTAssertEqual(input["existing_tags"] as? [String], ["工作"])
        stub([#"{"text":"一个蓝色按钮。","tags":["界面"]}"#])
        let image = try await engine().describeSaved(context: visual(), existing: [], home: "zh-Hans")
        XCTAssertEqual(image.text, "一个蓝色按钮。")
        XCTAssertEqual(image.tags, ["界面"])
        XCTAssertEqual(log.count, 2)
    }

    func testSavedDescriptionRejectsInvalidJSONAndUnreadableContent() async {
        for text in ["好的，这是标签", #"{"text":"无法读取所指内容","tags":[]}"#] {
            stub([text])
            do {
                _ = try await engine().describeSaved(context: visual(), existing: [])
                XCTFail("Invalid description cannot be saved as successful enrichment")
            } catch { XCTAssertTrue(error as? ModelClientError == .invalidResponse || error as? ModelClientError == .noTarget) }
        }
    }

    func testProbeParsesActionsWithoutNetwork() {
        let request = ActionProbe.parse(["PinPin", "--action", "translate", "--text", "idempotent", "--passage", "保证 idempotent。"])
        XCTAssertEqual(request?.action, "translate")
        XCTAssertEqual(request.map(ActionProbe.context(for:))?.targetText, "idempotent")
        XCTAssertNil(ActionProbe.parse(["PinPin", "--action", "translate"]))
        XCTAssertEqual(ActionProbe.parse(["PinPin", "--action", "follow-up", "--for", "rewrite", "--text", "a"])?.forAction, .rewrite)
    }
}
