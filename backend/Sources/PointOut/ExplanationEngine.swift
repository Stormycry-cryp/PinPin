import Foundation

struct PreparedEvidence: Sendable {
    var context: CapturedContext
    var metrics: [String: Double]
    var route: String
    var jevModel: String?
}

final class ExplanationEngine: @unchecked Sendable {
    let session: URLSession
    let credentials: @Sendable () throws -> PointOutCredentials
    let jevTimeout: TimeInterval
    let totalTimeout: TimeInterval
    let preconnection: GatewayPreconnection

    init(session: URLSession? = nil,
         credentials: @escaping @Sendable () throws -> PointOutCredentials = { try PointOutCredentials.load() },
         jevTimeout: TimeInterval = 2.5, totalTimeout: TimeInterval = 20,
         preconnectionInterval: TimeInterval = 30) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = totalTimeout
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
        self.credentials = credentials; self.jevTimeout = jevTimeout; self.totalTimeout = totalTimeout
        self.preconnection = GatewayPreconnection(session: self.session, credentials: credentials,
                                                 interval: preconnectionInterval)
    }

    /// Shared selection/image decision path. The callback consumes the frozen frame at most once.
    func prepare(context: CapturedContext, action: PointOutAction, configuration: PointOutCredentials? = nil,
                 supplement: @escaping @Sendable (AcquisitionPlan) async -> CapturedContext) async throws -> PreparedEvidence {
        try Task.checkCancellation()
        if context.source == "selection_too_large" { throw ModelClientError.outputLimit }
        if context.source == "ax_secure_content" { throw ModelClientError.noTarget }
        var metrics: [String: Double] = ["jev_ms": 0, "jev_requests": 0, "supplement_ms": 0, "expanded_requested": 0]
        if context.hasSelection {
            guard context.targetText.count <= 4000 else { throw ModelClientError.outputLimit }
            let start = ProcessInfo.processInfo.systemUptime
            let local: AcquisitionPlan = action == .explain && context.canCaptureVisual ? .selectionContext : .useCurrent
            var selected = await supplement(local)
            guard selected.sessionID == context.sessionID else { throw CancellationError() }
            selected.targetText = context.targetText; selected.passageText = context.targetText
            try Task.checkCancellation()
            metrics["supplement_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return PreparedEvidence(context: selected, metrics: metrics, route: "selection", jevModel: nil)
        }
        guard let image = context.imageData, !image.isEmpty, let point = context.pointInImage, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else {
            if context.screenCapturePermissionMissing { throw ModelClientError.screenCapturePermission }
            throw ModelClientError.noTarget
        }
        var plan = AcquisitionPlan.useCurrent
        var route = "local_only_available"
        var model: String?
        if context.canExpandVisual {
            let start = ProcessInfo.processInfo.systemUptime
            metrics["jev_requests"] = 1
            do {
                let settings = try configuration ?? loadConfiguration()
                let activity = preconnection.beginActivity(configuration: settings)
                defer { preconnection.endActivity(token: activity) }
                let decision = try await JevClient(session: session).decide(context: context, action: action,
                    allowed: [.useCurrent, .expandVisual], configuration: settings, timeout: min(jevTimeout, totalTimeout))
                plan = decision.plan; model = decision.model; route = "jev:\(plan.rawValue)"
            } catch {
                try Task.checkCancellation()
                if case .authentication = error as? ModelClientError { throw error }
                if case .http(402) = error as? ModelClientError { throw error }
                route = "local_\(Self.fallbackReason(error))"
            }
            metrics["jev_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        metrics["expanded_requested"] = plan == .expandVisual ? 1 : 0
        let start = ProcessInfo.processInfo.systemUptime
        var current = await supplement(plan)
        try Task.checkCancellation()
        guard current.sessionID == context.sessionID else { throw CancellationError() }
        // An unavailable supplement keeps the already valid local image; it cannot turn into text-only evidence.
        if current.imageData?.isEmpty != false || current.pointInImage.map({ !$0.x.isFinite || !$0.y.isFinite || !(0...1).contains($0.x) || !(0...1).contains($0.y) }) != false {
            current = context
        }
        current.targetText = ""; current.passageText = ""; current.surroundingText = ""
        metrics["supplement_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        metrics["expanded_applied"] = current.source == "visual_window" ? 1 : 0
        return PreparedEvidence(context: current, metrics: metrics, route: route, jevModel: model)
    }

    func explain(context: CapturedContext,
                 supplement: @escaping @Sendable (AcquisitionPlan) async -> CapturedContext,
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ExplanationResult {
        let started = ProcessInfo.processInfo.systemUptime
        return try await withModelTimeout(seconds: totalTimeout) { [self] in
            let configuration = try loadConfiguration()
            let prepared = try await prepare(context: context, action: .explain, configuration: configuration, supplement: supplement)
            let current = prepared.context
            let answerStart = ProcessInfo.processInfo.systemUptime
            let remaining = totalTimeout - (answerStart - started)
            guard remaining > 0 else { throw ModelClientError.timeout }
            let hasImage = current.imageData != nil && current.pointInImage != nil
            let activity = preconnection.beginActivity(configuration: configuration)
            defer { preconnection.endActivity(token: activity) }
            let answer = try await DeepSeekClient(session: session).answer(context: current, includeImage: hasImage,
                configuration: configuration, timeout: remaining, onText: onText)
            if answer.text.trimmingCharacters(in: .whitespacesAndNewlines) == unreadableSentinel { throw ModelClientError.noTarget }
            var metrics = prepared.metrics
            metrics["answer_first_text_ms"] = answer.firstTextMilliseconds
            metrics["first_text_ms"] = (answerStart - started) * 1000 + answer.firstTextMilliseconds
            metrics["total_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            metrics["thinking_disabled_requested"] = 0
            metrics["thinking_enabled_requested"] = 1
            metrics["reasoning_effort_low_requested"] = 1
            metrics["reasoning_content_nonempty"] = answer.reasoningObserved ? 1 : 0
            metrics["image_sent"] = hasImage ? 1 : 0
            var kept = current; kept.originalImageData = nil
            return ExplanationResult(text: answer.text, metrics: metrics, route: prepared.route,
                                     jevModel: prepared.jevModel, answerModel: answer.model, context: kept)
        }
    }

    private static func fallbackReason(_ error: Error) -> String {
        if let error = error as? ModelClientError {
            switch error {
            case .http(let code): return "jev_http_\(code)"
            case .timeout: return "jev_timeout"
            default: return "jev_invalid_response"
            }
        }
        return (error as? URLError)?.code == .timedOut ? "jev_timeout" : "jev_unavailable"
    }
}
