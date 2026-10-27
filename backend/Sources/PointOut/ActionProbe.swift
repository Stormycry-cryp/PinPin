import Foundation

/// Command-line entry for checking every action against the real gateway without the UI:
///
///     PinPin --action translate --text "Less is more."
///     PinPin --action rewrite --text "我们这边的话可能大概下周会把这个东西弄好。"
///     PinPin --action tags --text "周五前确认发布清单" --existing-tags "工作,待办"
///     PinPin --action follow-up --for explain --text "幂等" --previous "…" --question "举个例子？"
///
/// `--text` is always an explicit selection.
/// Output is one JSON object; nothing is stored.
enum ActionProbe {
    struct Request: Equatable {
        var action: String
        var text: String
        var passage = ""
        var home: String?
        var previous = ""
        var question = ""
        var forAction: PointOutAction = .explain
        var existingTags: [String] = []
    }

    static func parse(_ arguments: [String]) -> Request? {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let action = value("--action"), let text = value("--text") else { return nil }
        var request = Request(action: action, text: text)
        request.passage = value("--passage") ?? ""
        request.home = value("--home")
        request.previous = value("--previous") ?? ""
        request.question = value("--question") ?? ""
        if let name = value("--for"), let action = PointOutAction(rawValue: name) { request.forAction = action }
        request.existingTags = (value("--existing-tags") ?? "").split(separator: ",").map(String.init)
        return request
    }

    static func context(for request: Request) -> CapturedContext {
        return CapturedContext(sessionID: UUID(), targetText: request.text,
                               surroundingText: "", appName: "PinPin CLI", windowTitle: "",
                               source: "ax_selection",
                               passageText: request.text)
    }

    static func run(_ request: Request, engine: ExplanationEngine = ExplanationEngine()) async throws -> [String: Any] {
        let context = context(for: request)
        let home = request.home ?? ActionRules.homeLanguage()
        let supplement: @Sendable (AcquisitionPlan) async -> CapturedContext = { _ in context }
        let result: ExplanationResult
        switch request.action {
        case "explain":
            result = try await engine.explain(context: context, supplement: supplement, onText: { _ in })
        case "translate":
            result = try await engine.translate(context: context, home: home, supplement: supplement, onText: { _, _ in })
        case "rewrite":
            result = try await engine.rewrite(context: context, supplement: supplement, onText: { _, _ in })
        case "follow-up":
            guard !request.previous.isEmpty, !request.question.isEmpty else { throw ModelClientError.noTarget }
            result = try await engine.followUp(action: request.forAction, context: context, previous: request.previous,
                                               earlier: [], question: request.question, onText: { _ in })
        case "tags":
            let started = ProcessInfo.processInfo.systemUptime
            let tags = try await engine.suggestTags(text: request.text, appName: "PinPin CLI", windowTitle: "",
                                                    existing: request.existingTags, home: home)
            return ["action": "tags", "tags": tags,
                    "metrics": ["total_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]]
        default:
            throw ModelClientError.noTarget
        }
        return ["action": request.action, "text": result.text, "subtitle": result.subtitle ?? "",
                "route": result.route, "metrics": result.metrics,
                "jevModel": result.jevModel ?? "none", "answerModel": result.answerModel ?? "unknown"]
    }
}
