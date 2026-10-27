import XCTest
@testable import PointOut

private actor ReplyTextRecorder {
    private var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
    func all() -> [String] { texts }
}

final class ReplyCoachingTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() { session.invalidateAndCancel(); ModelStubURLProtocol.handler = nil }
    private func engine(total: Double = 20) -> ExplanationEngine {
        ExplanationEngine(session: session, credentials: { try PointOutCredentials(gatewayBaseURL: URL(string: "https://reply.invalid/ping/v1")!, accessToken: "fake") },
                          jevTimeout: 0.01, totalTimeout: total)
    }
    private func local() -> CapturedContext {
        CapturedContext(sessionID: UUID(), targetText: "selected fragment", surroundingText: "", appName: "Public fixture", windowTitle: "Visible chat",
                        source: "ax_selection", canExpandVisual: true, canCaptureVisual: true, imageData: Data([1]), imageMIME: "image/jpeg",
                        originalImageData: Data([2]), pointInImage: CGPoint(x: 0.2, y: 0.4))
    }
    private func window(_ original: CapturedContext) -> CapturedContext {
        var result = original; result.canExpandVisual = false; result.imageData = Data([3]); result.originalImageData = Data([4, 5, 6]); return result
    }
    private static func judgment(intent: String = "seek_support", strategy: String = "承接", intentProbability: Double = 1) -> [String: Any] {
        func choice(_ selected: String, _ keys: [String], probability: Double = 1) -> [String: Any] {
            let other = keys.first { $0 != selected }!
            return ["type": "choice", "choice": selected, "probabilities": Dictionary(uniqueKeysWithValues: keys.map {
                ($0, $0 == selected ? probability : $0 == other ? 1 - probability : 0)
            })]
        }
        return ["model": "jev-1.14", "answers": ["intent": choice(intent, Array(ReplyCoachingPolicy.intents.keys), probability: intentProbability),
                                                  "reply_strategy": choice(strategy, Array(ReplyCoachingPolicy.strategies.keys))]]
    }
    private static func json(_ body: [String: Any], status: Int = 200, delay: Double = 0) -> ModelStubURLProtocol.Response {
        .init(status: status, chunks: [try! JSONSerialization.data(withJSONObject: body)], delay: delay)
    }
    func testJevRetainsSelectedProbabilityRatherThanIndependentConfidence() async throws {
        var body = Self.judgment(intentProbability: 0.834321)
        var answers = body["answers"] as! [String: [String: Any]]
        answers["intent"]!["confidence"] = 0.99
        body["answers"] = answers
        let response = Self.json(body)
        ModelStubURLProtocol.handler = { _ in response }
        let decision = try await JevIntentClient(session: session).decide(context: window(local()),
            configuration: PointOutCredentials(gatewayBaseURL: URL(string: "https://reply.invalid/ping/v1")!, accessToken: "fake"), timeout: 1)
        XCTAssertEqual(decision.intent, "seek_support")
        XCTAssertEqual(decision.intentProbability, 0.834321)
        XCTAssertNil(ReplyCoachingContext(intent: "seek_support", strategy: "承接").intentProbability)
    }
    func testFormatterUsesOnlyRetainedProbabilityAndRoundsAtDisplayBoundary() {
        let raw = "对方意图：可能想倾诉（99%）\n建议回复：我在。"
        for (probability, percent) in [(0.0, 0), (1.0, 100), (0.625, 63), (0.834321, 83)] {
            XCTAssertEqual(ReplyCoachingFormatter.format(raw, intentProbability: probability),
                "对方意图：可能想倾诉（\(percent)%）\n建议回复：我在。")
        }
        let invalidProbabilities: [Double?] = [nil, -.infinity, .nan, -0.01, 1.01]
        for probability in invalidProbabilities {
            XCTAssertEqual(ReplyCoachingFormatter.format(raw, intentProbability: probability), "对方意图：可能想倾诉\n建议回复：我在。")
        }
        XCTAssertEqual(ReplyCoachingFormatter.format("对方意图：尚不确定 (5.2%) \r\n建议回复：你指哪一件事？", intentProbability: 0.625),
            "对方意图：尚不确定（63%）\n建议回复：你指哪一件事？")
        XCTAssertEqual(ReplyCoachingFormatter.format("对方意图：尚不确定", intentProbability: 0.625, isFinal: true), "对方意图：尚不确定（63%）")
    }
    func testFormatterBuffersFirstLineAcrossEveryChunkAndPreservesSentinel() {
        XCTAssertEqual(ReplyCoachingFormatter.format(" ", intentProbability: 0.834321), "")
        let first = "对方意图：可能想倾诉（99%）"
        for count in 1...first.count {
            XCTAssertEqual(ReplyCoachingFormatter.format(String(first.prefix(count)), intentProbability: 0.834321), "")
        }
        let expectedFirst = "对方意图：可能想倾诉（83%）\n"
        XCTAssertEqual(ReplyCoachingFormatter.format(first + "\n", intentProbability: 0.834321), expectedFirst)
        XCTAssertEqual(ReplyCoachingFormatter.format(first + "\n建议回复：我", intentProbability: 0.834321), expectedFirst + "建议回复：我")
        for count in 1...unreadableSentinel.count {
            let partial = String(unreadableSentinel.prefix(count))
            XCTAssertEqual(ReplyCoachingFormatter.format(partial, intentProbability: 0.834321), partial)
        }
    }
    func testInitialAnswerStreamsOnlyFormattedFirstLineThenReplyAndReturnsSameText() async throws {
        let original = local(), full = window(original), texts = ReplyTextRecorder()
        ModelStubURLProtocol.handler = { request in
            request.url!.lastPathComponent == "decision" ? Self.json(Self.judgment(intentProbability: 0.834321)) :
                StubStream.sse(["对方", "意图：可能想倾诉（99%）", "\n建议回复：", "我在。"])
        }
        let result = try await engine().replyCoach(context: original, supplement: { _ in full }, onText: { await texts.append($0) })
        let snapshots = await texts.all()
        XCTAssertEqual(snapshots, ["对方意图：可能想倾诉（83%）\n建议回复：", "对方意图：可能想倾诉（83%）\n建议回复：我在。"])
        XCTAssertEqual(result.text, snapshots.last)
        XCTAssertEqual(result.context?.replyCoaching?.intentProbability, 0.834321)
        XCTAssertGreaterThanOrEqual(result.metrics["answer_first_text_ms"]!, 0)
        XCTAssertLessThanOrEqual(result.metrics["answer_first_text_ms"]!, result.metrics["answer_total_ms"]!)
    }
    func testUnreadableAnswerKeepsOriginalStreamAndNoTargetError() async throws {
        let original = local(), full = window(original), texts = ReplyTextRecorder()
        ModelStubURLProtocol.handler = { request in
            request.url!.lastPathComponent == "decision" ? Self.json(Self.judgment()) : StubStream.sse(["无法读取", "所指内容"])
        }
        do {
            _ = try await engine().replyCoach(context: original, supplement: { _ in full }, onText: { await texts.append($0) })
            XCTFail("Unreadable content must fail")
        } catch { XCTAssertEqual(error as? ModelClientError, .noTarget) }
        let snapshots = await texts.all()
        XCTAssertEqual(snapshots, ["无法读取", unreadableSentinel])
    }
    func testWhitespacePrefixDoesNotEmitBeforeVisibleFirstLine() async throws {
        let original = local(), full = window(original), texts = ReplyTextRecorder()
        ModelStubURLProtocol.handler = { request in
            request.url!.lastPathComponent == "decision" ? Self.json(Self.judgment(intentProbability: 0.625)) :
                StubStream.sse([" ", "\t", "对方意图：想倾诉", "\n建议回复：我在。"])
        }
        let result = try await engine().replyCoach(context: original, supplement: { _ in full }, onText: { await texts.append($0) })
        let snapshots = await texts.all()
        XCTAssertEqual(snapshots, ["对方意图：想倾诉（63%）\n建议回复：我在。"])
        XCTAssertEqual(result.text, snapshots.first)
        XCTAssertGreaterThanOrEqual(result.metrics["first_text_ms"]!, result.metrics["answer_first_text_ms"]!)
    }
    func testOneFrozenWindowTwoQuestionsOneJevOneLowAnswerWithUnmarkedImage() async throws {
        let original = local(), expanded = window(local())
        var frame = expanded; frame.sessionID = original.sessionID
        let expectedFrame = frame, log = RequestLog(), supplements = RequestLog()
        ModelStubURLProtocol.handler = { request in
            let body = StubStream.body(request); log.append(body)
            if request.url!.lastPathComponent == "decision" {
                XCTAssertEqual(request.timeoutInterval, 8)
                let questions = body["questions"] as! [String: Any]
                XCTAssertEqual(Set(questions.keys), ["intent", "reply_strategy"])
                for name in ["intent", "reply_strategy"] {
                    let instructions = (questions[name] as! [String: Any])["instructions"] as! String
                    XCTAssertTrue(instructions.contains("main message area of the currently open conversation"))
                    XCTAssertTrue(instructions.contains("other participant's latest message"))
                    XCTAssertTrue(instructions.contains("Ignore sidebar conversation lists, other conversations and toolbars."))
                    XCTAssertTrue(instructions.contains("do not attribute the user's outgoing messages to the other participant"))
                    XCTAssertTrue(instructions.contains("choose unclear and keep those details unknown"))
                }
                let asset = (body["assets"] as! [String: [String: Any]])["screen"]!
                XCTAssertEqual(asset["data_base64"] as? String, Data([4, 5, 6]).base64EncodedString())
                return Self.json(Self.judgment())
            }
            XCTAssertEqual(body["max_tokens"] as? Int, 1600)
            XCTAssertEqual(body["thinking"] as? [String: String], ["type": "enabled"])
            XCTAssertEqual(body["reasoning_effort"] as? String, "low")
            XCTAssertTrue(StubStream.system(body).contains("从当前打开聊天的主体消息区域理解最近对方发言及相关可见上下文"))
            XCTAssertTrue(StubStream.system(body).contains("无法辨认双方或当前对方消息时按unclear处理，并保留未知"))
            let content = (body["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
            XCTAssertEqual((content[1]["image_url"] as! [String: String])["url"], "data:image/jpeg;base64," + Data([4, 5, 6]).base64EncodedString())
            XCTAssertEqual((StubStream.input(body)["evidence"] as! [String: Any])["text"] as? String, "")
            XCTAssertTrue(StubStream.system(body).contains("每次回答及追问都只输出以下两行"))
            XCTAssertTrue(StubStream.system(body).contains("一条可直接复制的自然回复"))
            XCTAssertTrue(StubStream.system(body).contains("意图行不输出概率、百分比或置信度数值"))
            XCTAssertNil((StubStream.input(body)["reply_coaching"] as? [String: Any])?["intentProbability"])
            return StubStream.sse(["对方意图：可能想找人倾诉", "\n建议回复：我在，你慢慢说。"])
        }
        let result = try await engine().replyCoach(context: original, supplement: { plan in
            XCTAssertEqual(plan, .expandVisual); supplements.append(["frame": 1]); return expectedFrame
        }, onText: { _ in })
        XCTAssertEqual(log.count, 2); XCTAssertEqual(supplements.count, 1)
        XCTAssertEqual(result.context?.replyCoaching?.intent, "seek_support")
        XCTAssertEqual(result.context?.replyCoaching?.intentProbability, 1)
        XCTAssertEqual(result.context?.imageData, Data([4, 5, 6])); XCTAssertNil(result.context?.originalImageData)
        XCTAssertEqual(result.context?.targetText, ""); XCTAssertEqual(result.jevModel, "jev-1.14")
    }
    func testMalformedOrFailedMandatoryJevNeverFallsBackToWriter() async throws {
        var fixtures: [ModelStubURLProtocol.Response] = [Self.json(Self.judgment(), status: 401), Self.json(Self.judgment(), status: 403), Self.json(Self.judgment(), status: 503)]
        var wrongModel = Self.judgment(); wrongModel["model"] = "jev-other"; fixtures.append(Self.json(wrongModel))
        for mutation in ["bool", "sum", "notmax", "type", "keys", "unknown-intent", "confidence-bool", "extra-question"] {
            var body = Self.judgment(), answers = Self.judgment()["answers"] as! [String: [String: Any]]
            var intent = answers["intent"]!, probabilities = intent["probabilities"] as! [String: Any]
            switch mutation {
            case "bool": probabilities["seek_support"] = true
            case "sum": probabilities["seek_support"] = 0.8
            case "notmax": intent["choice"] = "unclear"
            case "type": intent["type"] = "text"
            case "keys": probabilities.removeValue(forKey: "unclear")
            case "unknown-intent": intent["choice"] = "made_up"
            case "confidence-bool": intent["confidence"] = true
            default: answers["acquisition"] = [:]
            }
            intent["probabilities"] = probabilities; answers["intent"] = intent; body["answers"] = answers; fixtures.append(Self.json(body))
        }
        for response in fixtures {
            let requests = RequestLog(), original = local(), full = window(local())
            ModelStubURLProtocol.handler = { request in
                XCTAssertEqual(request.url!.lastPathComponent, "decision"); requests.append(StubStream.body(request)); return response
            }
            do { _ = try await engine().replyCoach(context: original, supplement: { _ in var result = full; result.sessionID = original.sessionID; return result }, onText: { _ in XCTFail("No late text") }); XCTFail("Jev must be required") }
            catch { XCTAssertEqual(requests.count, 1) }
        }
    }
    func testNotChatStopsBeforeDeepSeekAndUnclearMayExplainUncertainty() async throws {
        for intent in ["not_chat", "unclear"] {
            let requests = RequestLog(), original = local(), full = window(local())
            ModelStubURLProtocol.handler = { request in
                requests.append(StubStream.body(request))
                return request.url!.lastPathComponent == "decision" ? Self.json(Self.judgment(intent: intent, strategy: "澄清")) :
                    StubStream.sse(["对方意图：目前无法确定\n建议回复：你指哪一件事？"])
            }
            do {
                let result = try await engine().replyCoach(context: original, supplement: { _ in var result = full; result.sessionID = original.sessionID; return result }, onText: { _ in })
                XCTAssertEqual(intent, "unclear"); XCTAssertEqual(requests.count, 2)
                XCTAssertEqual(result.text, "对方意图：目前无法确定（100%）\n建议回复：你指哪一件事？")
            } catch { XCTAssertEqual(intent, "not_chat"); XCTAssertEqual(error as? ModelClientError, .noTarget); XCTAssertEqual(requests.count, 1) }
        }
    }
    func testCancellationDuringFrozenExpansionSendsNothing() async throws {
        let original = local(), started = expectation(description: "same frame requested"), requests = RequestLog()
        ModelStubURLProtocol.handler = { request in requests.append(StubStream.body(request)); throw ModelClientError.invalidResponse }
        let task = Task { try await engine().replyCoach(context: original, supplement: { _ in
            started.fulfill(); try? await Task.sleep(nanoseconds: 1_000_000_000); return original
        }, onText: { _ in XCTFail("No cancelled callback") }) }
        await fulfillment(of: [started], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertEqual(requests.count, 0) }
    }
    func testCancellationDuringJevAndDeadlineDoNotSendWriter() async throws {
        for cancel in [true, false] {
            let original = local(), full = window(local()), requests = RequestLog(), began = expectation(description: "Jev started")
            ModelStubURLProtocol.handler = { request in requests.append(StubStream.body(request)); began.fulfill(); return Self.json(Self.judgment(), delay: 0.2) }
            let current = engine(total: cancel ? 20 : 0.04)
            let task = Task { try await current.replyCoach(context: original, supplement: { _ in var result = full; result.sessionID = original.sessionID; return result }, onText: { _ in XCTFail("No late writer") }) }
            await fulfillment(of: [began], timeout: 2); if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Must stop") } catch { XCTAssertEqual(requests.count, 1) }
        }
    }
    func testFollowupReusesItsOwnFrozenContextWithoutJevOrOtherSessionState() async throws {
        let log = RequestLog(), original = local()
        var context = window(original); context.imageData = context.originalImageData; context.originalImageData = nil
        context.replyCoaching = ReplyCoachingContext(intent: "set_boundary", strategy: "收线", intentProbability: 0.745)
        ModelStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.lastPathComponent, "explanation"); let body = StubStream.body(request); log.append(body)
            XCTAssertEqual(StubStream.input(body)["reply_coaching"] as? [String: String], ["intent": "set_boundary", "reply_strategy": "收线"])
            XCTAssertEqual(StubStream.input(body)["previous_result"] as? String, "A previous")
            XCTAssertEqual((StubStream.input(body)["earlier"] as! [[String: String]]).count, 2)
            XCTAssertFalse(StubStream.system(body).contains("箭头尖端的对象"))
            return StubStream.sse(["对方意图：希望暂时不被打扰\n建议回复：好，你先忙。"])
        }
        let result = try await engine().replyCoachFollowUp(context: context, previous: "A previous", earlier: (0..<4).map { FollowUpExchange(question: "A\($0)", answer: "answer") }, question: "如何自然一点", onText: { _ in })
        XCTAssertEqual(log.count, 1); XCTAssertEqual(result.context?.sessionID, original.sessionID); XCTAssertNil(result.jevModel)
        XCTAssertEqual(result.context?.replyCoaching?.intentProbability, 0.745)
        XCTAssertEqual(result.text, "对方意图：希望暂时不被打扰（75%）\n建议回复：好，你先忙。")
    }
    func testTwoConcurrentSessionsKeepTheirOwnJudgmentImageAndFollowup() async throws {
        let a = local(), b = local(), log = RequestLog()
        var first = window(a), second = window(b)
        first.originalImageData = Data([65]); second.originalImageData = Data([66])
        let fullA = first, fullB = second
        ModelStubURLProtocol.handler = { request in
            let body = StubStream.body(request); log.append(body)
            if request.url!.lastPathComponent == "decision" {
                let asset = (body["assets"] as! [String: [String: Any]])["screen"]!
                let isA = asset["data_base64"] as? String == Data([65]).base64EncodedString()
                return Self.json(Self.judgment(intent: isA ? "request_action" : "set_boundary", strategy: isA ? "澄清" : "收线", intentProbability: isA ? 0.834321 : 0.625))
            }
            let content = (body["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
            let url = (content[1]["image_url"] as! [String: String])["url"]!
            let isA = url.hasSuffix(Data([65]).base64EncodedString()), input = StubStream.input(body)
            XCTAssertEqual((input["reply_coaching"] as! [String: String])["intent"], isA ? "request_action" : "set_boundary")
            if !(input["question"] as! String).isEmpty { XCTAssertEqual(input["previous_result"] as? String, isA ? "A previous" : "B previous") }
            return StubStream.sse([isA ? "对方意图：请求帮忙\n建议回复：A draft" : "对方意图：希望暂停\n建议回复：B draft"])
        }
        let engineA = engine(), engineB = engine()
        async let initialA = engineA.replyCoach(context: a, supplement: { _ in fullA }, onText: { _ in })
        async let initialB = engineB.replyCoach(context: b, supplement: { _ in fullB }, onText: { _ in })
        let (resultA, resultB) = try await (initialA, initialB)
        async let followA = engineA.replyCoachFollowUp(context: resultA.context!, previous: "A previous", earlier: [], question: "A question", onText: { _ in })
        async let followB = engineB.replyCoachFollowUp(context: resultB.context!, previous: "B previous", earlier: [], question: "B question", onText: { _ in })
        let (answerA, answerB) = try await (followA, followB)
        XCTAssertEqual(answerA.text, "对方意图：请求帮忙（83%）\n建议回复：A draft")
        XCTAssertEqual(answerB.text, "对方意图：希望暂停（63%）\n建议回复：B draft")
        XCTAssertEqual(log.count, 6); XCTAssertEqual(log.all.filter { $0["questions"] != nil }.count, 2)
    }
}
