import AppKit
import Foundation

/// The capture operations the coordinator needs; ContextCapture is the production implementation.
protocol ContextProviding: AnyObject, Sendable {
    func sampleColor(_ anchor: TargetAnchor) async throws -> PickedColor
    func capture(_ anchor: TargetAnchor) async -> CapturedContext
    func supplement(_ context: CapturedContext, anchor: TargetAnchor, plan: AcquisitionPlan) async -> CapturedContext
    func forget(_ id: UUID)
}

extension ContextCapture: ContextProviding {}

/// Turns gesture events into one result per executed action. Owns sessions, follow-ups,
/// the saved library; never touches visuals beyond the presentation protocol.
@MainActor final class ActionCoordinator {
    private let presentation: PointOutPresentation
    private let capture: ContextProviding
    private let engine: ExplanationEngine
    let library: SavedLibrary
    let colorHistory: ColorHistory
    private let colorSource: (TargetAnchor) -> (app: String, window: String)
    private let home: String
    private let sourceObserver: ResultSourceObserving?
    private let prepareAIAction: @Sendable () async throws -> Void
    private let cancelAIAction: @Sendable (UUID) async -> Void
    /// Diagnostics sink: event name, millisecond values, labels. Never receives captured content.
    var record: (String, [String: Double], [String: String]) -> Void = { _, _, _ in }

    private var anchor: TargetAnchor?
    private var preparation: Task<CapturedContext, Never>?
    private var executed = false

    private final class Session {
        let id: UUID
        let action: PointOutAction
        let anchor: TargetAnchor
        var context: CapturedContext?
        var answer = ""
        var subtitle: String?
        var finished = false
        var exchanges: [FollowUpExchange] = []
        var savedID: UUID?
        var task: Task<Void, Never>?
        /// Bumped by every new task or cancel, so late callbacks of an older task are ignored.
        var generation = 0
        var firstTextRecorded = false
        init(id: UUID, action: PointOutAction, anchor: TargetAnchor) {
            self.id = id; self.action = action; self.anchor = anchor
        }
    }
    private var sessions: [UUID: Session] = [:]

    init(presentation: PointOutPresentation, capture: ContextProviding, engine: ExplanationEngine,
         library: SavedLibrary, colorHistory: ColorHistory? = nil,
         home: String = ActionRules.homeLanguage(),
         colorSource: ((TargetAnchor) -> (app: String, window: String))? = nil,
         sourceObserver: ResultSourceObserving? = nil,
         prepareAIAction: @escaping @Sendable () async throws -> Void = {},
         cancelAIAction: @escaping @Sendable (UUID) async -> Void = { _ in }) {
        self.presentation = presentation
        self.capture = capture
        self.engine = engine
        self.library = library
        let colorHistory = colorHistory ?? ColorHistory()
        self.colorHistory = colorHistory
        self.colorSource = colorSource ?? { Self.localColorSource($0) }
        self.home = home
        self.sourceObserver = sourceObserver
        self.prepareAIAction = prepareAIAction
        self.cancelAIAction = cancelAIAction
        sourceObserver?.onChange = { [weak self] id, point, visible in
            guard let self, self.sessions[id] != nil else { return }
            self.presentation.updateResultSource(id, at: point, visible: visible)
        }
        sourceObserver?.onClosed = { [weak self] id in
            guard let self, self.sessions[id] != nil else { return }
            self.forget(id)
            self.presentation.removeResult(id)
        }
        presentation.onCancel = { [weak self] id in self?.cancel(id) }
        presentation.onForget = { [weak self] id in self?.forget(id) }
        presentation.onFollowUp = { [weak self] id, question in self?.followUp(id, question: question) }
        presentation.onLibraryEdit = { [weak self] edit in self?.edit(edit) }
        presentation.onAssetEdit = { [weak self] edit in self?.editAsset(edit) }
        publishLibrary()
        Task { [weak self] in
            do { try await library.reload(); self?.publishLibrary() }
            catch { self?.record("library_load_failed", [:], [:]) }
        }
        Task { [weak self] in
            do { try await colorHistory.reload(); self?.publishLibrary() }
            catch { self?.record("color_history_load_failed", [:], [:]) }
        }
    }

    // MARK: Gestures

    func receive(_ event: GestureEvent) {
        switch event {
        case .began(let next):
            if !executed { preparation?.cancel(); if let anchor { capture.forget(anchor.id) } }
            preparation = nil
            executed = false
            anchor = next
            presentation.showWheel(at: next.presentationPoint)
            record("wheel_shown", ["input_to_main_ms": (ProcessInfo.processInfo.systemUptime - next.startedAt) * 1000], [:])
            // Only bounded local capture while the wheel is up; no model request until an action runs.
            let capture = self.capture
            preparation = Task { await capture.capture(next) }
            engine.preconnection.preconnect()
        case .moved(let pointer):
            presentation.updateWheel(pointer: pointer)
        case .released(let pointer):
            let releasedAt = ProcessInfo.processInfo.systemUptime
            guard let current = anchor, !executed, let action = presentation.updateWheel(pointer: pointer) else { return }
            executed = true
            start(action, anchor: current, releasedAt: releasedAt)
        case .clearAllMarkers:
            if !executed { preparation?.cancel(); if let anchor { capture.forget(anchor.id) } }
            preparation = nil
            // This wheel session is consumed; its paired release cannot execute anything.
            executed = true
            presentation.clearAllMarkers()
        case .closed, .permissionLost:
            presentation.hideWheel()
            if !executed { preparation?.cancel(); if let anchor { capture.forget(anchor.id) } }
            anchor = nil
        }
    }

    // MARK: Actions

    private func start(_ action: PointOutAction, anchor: TargetAnchor, releasedAt: TimeInterval) {
        record("action_triggered", ["wheel_to_release_ms": (releasedAt - anchor.startedAt) * 1000],
               ["action": action.rawValue])
        let session = Session(id: anchor.id, action: action, anchor: anchor)
        insert(session)
        presentation.beginResult(session.id, action: action, at: anchor.presentationPoint, processID: anchor.processID)
        sourceObserver?.track(anchor)
        if action == .pickColor {
            preparation?.cancel()
            preparation = nil
            capture.forget(anchor.id)
        }
        let prepared = preparation
        preparation = nil
        let capture = self.capture
        session.generation += 1
        let generation = session.generation
        session.task = Task { [weak self] in
            await ModelUsageContext.run(id: session.id) {
                if action == .pickColor {
                    await self?.runPickColor(session, generation: generation, releasedAt: releasedAt)
                    return
                }
                let context: CapturedContext
                if let prepared {
                    context = await withTaskCancellationHandler { await prepared.value } onCancel: { prepared.cancel() }
                } else {
                    context = await capture.capture(anchor)
                }
                guard let self, !Task.isCancelled, self.isCurrent(session, generation) else { return }
                if action == .save {
                    await self.runSave(session, context: context, generation: generation, releasedAt: releasedAt)
                } else {
                    await self.runAnswer(session, context: context, generation: generation, releasedAt: releasedAt)
                }
            }
        }
    }

    private func runPickColor(_ session: Session, generation: Int, releasedAt: TimeInterval) async {
        do {
            let color = try await capture.sampleColor(session.anchor)
            guard !Task.isCancelled, isCurrent(session, generation) else { return }
            let source = colorSource(session.anchor)
            let colorRecord = ColorRecord(id: session.id, color: color, createdAt: Date(), appName: source.app, windowTitle: source.window)
            session.answer = color.hex
            session.finished = true
            presentation.showPickedColor(session.id, color: color)
            presentation.updateColorPersistence(session.id, state: .saving)
            presentation.finishResult(session.id)
            persistColor(colorRecord)
            record("pickColor_completed", ["release_to_complete_ms": (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000],
                   ["source": "native_screen_pixel", "color_space": color.colorSpace])
        } catch {
            guard !Task.isCancelled, isCurrent(session, generation), !(error is CancellationError) else { return }
            remove(session.id)
            presentation.failResult(session.id, message: Self.message(for: error, action: .pickColor), kind: Self.failureKind(error))
            record("pickColor_failed", ["release_to_failure_ms": (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000], [:])
        }
    }

    private func runAnswer(_ session: Session, context: CapturedContext, generation: Int, releasedAt: TimeInterval) async {
        let id = session.id, anchor = session.anchor, capture = self.capture
        let supplement: @Sendable (AcquisitionPlan) async -> CapturedContext = { plan in
            await capture.supplement(context, anchor: anchor, plan: plan)
        }
        let stream: @Sendable (String, String?) async -> Void = { [weak self] text, subtitle in
            await self?.streamed(id, generation: generation, text: text, subtitle: subtitle, releasedAt: releasedAt)
        }
        do {
            try await prepareAIAction()
            try Task.checkCancellation()
            let result: ExplanationResult
            switch session.action {
            case .explain:
                result = try await engine.explain(context: context, supplement: supplement, onText: { await stream($0, nil) })
            case .translate:
                result = try await engine.translate(context: context, home: home, supplement: supplement, onText: stream)
            case .rewrite:
                result = try await engine.rewrite(context: context, supplement: supplement, onText: stream)
            case .replyCoach:
                result = try await engine.replyCoach(context: context, supplement: supplement, onText: { await stream($0, nil) })
            case .save, .pickColor:
                return
            }
            guard !Task.isCancelled, isCurrent(session, generation) else { return }
            session.answer = result.text
            session.subtitle = result.subtitle
            session.context = result.context ?? context
            session.finished = true
            presentation.updateResult(id, text: result.text, subtitle: result.subtitle)
            presentation.finishResult(id)
            var values = result.metrics
            values["release_to_complete_ms"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
            record(Self.eventName(session.action, "completed"), values,
                   ["route": result.route, "jev_model": result.jevModel ?? "none",
                    "answer_model": result.answerModel ?? "unknown", "source": context.source])
        } catch {
            if !(error is CloudProcessingConsentError) { await cancelAIAction(id) }
            guard !Task.isCancelled, isCurrent(session, generation), !(error is CancellationError) else { return }
            if error is CloudProcessingConsentError {
                remove(id)
                presentation.removeResult(id)
                return
            }
            remove(id)
            presentation.failResult(id, message: Self.message(for: error, action: session.action), kind: Self.failureKind(error))
            record(Self.eventName(session.action, "failed"),
                   ["release_to_failure_ms": (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000],
                   ["source": context.source])
        }
    }

    private func streamed(_ id: UUID, generation: Int, text: String, subtitle: String?, releasedAt: TimeInterval) {
        guard let session = sessions[id], session.generation == generation else { return }
        presentation.updateResult(id, text: text, subtitle: subtitle ?? session.subtitle)
        if !session.firstTextRecorded, !text.isEmpty {
            session.firstTextRecorded = true
            record(Self.eventName(session.action, "first_text"),
                   ["release_to_first_text_ms": (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000], [:])
        }
    }

    private func runSave(_ session: Session, context: CapturedContext, generation: Int, releasedAt: TimeInterval) async {
        let id = session.id, anchor = session.anchor, capture = self.capture
        do {
            #if PINPIN_APP_STORE
            // A local collection does not spend AI quota or call either provider.
            let unit = ResolvedUnit(context: context, text: context.targetText,
                                    metrics: [:], route: "local_save", jevModel: nil)
            capture.forget(anchor.id)
            #else
            let unit = try await engine.resolveUnit(context, action: .save) { plan in
                await capture.supplement(context, anchor: anchor, plan: plan)
            }
            #endif
            guard !Task.isCancelled, isCurrent(session, generation) else { return }
            let image = unit.context.hasSelection ? nil : unit.context.originalImageData
            if !unit.context.hasSelection && image == nil { throw ModelClientError.noTarget }
            let item: SavedItem?
            do { item = try await library.add(text: unit.text, image: image, point: unit.context.pointInImage,
                                             appName: unit.context.appName, windowTitle: unit.context.windowTitle) }
            catch { throw ModelClientError.persistence }
            guard let item, !Task.isCancelled, isCurrent(session, generation) else { return }
            var kept = unit.context; kept.originalImageData = nil
            session.context = kept; session.savedID = item.id; session.answer = item.text; session.finished = true
            publishLibrary()
            presentation.showSaved(id, item: item, suggestions: suggestions(for: item))
            var metrics = unit.metrics
            metrics["release_to_saved_ms"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
            record("save_completed", metrics, ["source": unit.context.source])
            #if !PINPIN_APP_STORE
            do {
                let description = try await engine.describeSaved(context: kept, existing: library.topTags(), home: home)
                guard !Task.isCancelled, isCurrent(session, generation),
                      let updated = try await library.enrich(item.id, description) else { return }
                session.answer = updated.text
                publishLibrary()
                presentation.showSaved(id, item: updated, suggestions: suggestions(for: updated))
            } catch {
                // The durable image/text collection remains valid even if enrichment fails.
                record("save_enrichment_failed", [:], [:])
            }
            #endif
        } catch {
            guard !Task.isCancelled, isCurrent(session, generation), !(error is CancellationError) else { return }
            remove(id)
            presentation.failResult(id, message: Self.message(for: error, action: .save), kind: Self.failureKind(error))
        }
    }

    /// Existing tags the user may add with one click, most used first.
    private func suggestions(for item: SavedItem) -> [String] {
        let chosen = Set(item.tags.map { $0.lowercased() })
        return Array(library.topTags().filter { !chosen.contains($0.lowercased()) }.prefix(4))
    }

    // MARK: Follow-up and library

    private func followUp(_ id: UUID, question raw: String) {
        // A color card has copy controls only; stale or synthetic follow-up callbacks stay local.
        if sessions[id]?.action == .pickColor { return }
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = sessions[id], session.finished, !question.isEmpty else {
            presentation.failResult(id, message: "这条结果已经不能追问了。")
            return
        }
        session.task?.cancel()
        session.generation += 1
        let generation = session.generation
        let context = session.context ?? CapturedContext(sessionID: id, targetText: session.answer, surroundingText: "",
                                                         appName: "", windowTitle: "", source: "saved")
        let previous = session.answer, earlier = session.exchanges, action = session.action, engine = self.engine
        let started = ProcessInfo.processInfo.systemUptime
        let usageID = UUID()
        session.task = Task { [weak self] in
            await ModelUsageContext.run(id: usageID) {
                do {
                    guard let self else { return }
                    try await self.prepareAIAction()
                    try Task.checkCancellation()
                    let stream: @Sendable (String) async -> Void = { [weak self] text in
                        await self?.followUpStreamed(id, generation: generation, text: text)
                    }
                    let result: ExplanationResult
                    if action == .replyCoach {
                        result = try await engine.replyCoachFollowUp(context: context, previous: previous, earlier: earlier, question: question, onText: stream)
                    } else {
                        result = try await engine.followUp(action: action, context: context, previous: previous, earlier: earlier, question: question, onText: stream)
                    }
                    guard !Task.isCancelled, let session = self.sessions[id], session.generation == generation else { return }
                    session.exchanges.append(FollowUpExchange(question: question, answer: result.text))
                    if session.exchanges.count > 4 { session.exchanges.removeFirst() }
                    session.answer = result.text
                    self.presentation.updateResult(id, text: result.text, subtitle: session.subtitle)
                    self.presentation.finishResult(id)
                    var values = result.metrics
                    values["submit_to_complete_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    self.record("follow_up_completed", values, ["action": action.rawValue, "answer_model": result.answerModel ?? "unknown"])
                } catch {
                    if !(error is CloudProcessingConsentError) { await self?.cancelAIAction(usageID) }
                    guard let self, !Task.isCancelled, let session = self.sessions[id], session.generation == generation,
                          !(error is CancellationError) else { return }
                    self.presentation.failResult(id, message: Self.message(for: error, action: action))
                    self.record("follow_up_failed", ["submit_to_failure_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000],
                                ["action": action.rawValue])
                }
            }
        }
    }

    private func followUpStreamed(_ id: UUID, generation: Int, text: String) {
        guard let session = sessions[id], session.generation == generation else { return }
        presentation.updateResult(id, text: text, subtitle: session.subtitle)
    }

    private func edit(_ edit: LibraryEdit) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let changed: SavedItem?
                switch edit {
                case let .setTags(id, tags):
                    changed = try await library.setTags(id, tags)
                case let .addTag(id, tag):
                    changed = try await library.addTag(id, tag)
                case let .removeTag(id, tag):
                    changed = try await library.removeTag(id, tag)
                case .delete(let id):
                    try await library.delete(id)
                    changed = nil
                }
                // A newer edit may already have been acknowledged while this task resumed.
                if let changed, let item = library.item(changed.id) {
                    for session in sessions.values where session.savedID == item.id {
                        presentation.showSaved(session.id, item: item, suggestions: suggestions(for: item))
                    }
                }
                publishLibrary()
            } catch { record("library_edit_failed", [:], [:]) }
        }
    }

    private func publishLibrary() {
        presentation.updateLibrary(library.items)
        presentation.updateAssets(AssetRecord.merged(saved: library.items, colors: colorHistory.items))
    }

    private func persistColor(_ record: ColorRecord) {
        // Completion is independent of the card's lifetime; closing a finished card keeps its history.
        Task { [weak self, colorHistory] in
            do {
                try await colorHistory.add(record)
                self?.publishLibrary()
                if self?.sessions[record.id] != nil {
                    self?.presentation.updateColorPersistence(record.id, state: .saved)
                }
            } catch {
                if self?.sessions[record.id] != nil {
                    self?.presentation.updateColorPersistence(record.id, state: .failed)
                }
                self?.record("color_history_save_failed", [:], [:])
            }
        }
    }

    private func editAsset(_ edit: AssetEdit) {
        switch edit {
        case .delete(.saved(let id)): self.edit(.delete(id))
        case .delete(.color(let id)):
            Task { [weak self] in
                guard let self else { return }
                do { try await colorHistory.delete(id); publishLibrary() }
                catch { record("asset_edit_failed", [:], [:]) }
            }
        }
    }

    /// Only local source metadata; absent window titles stay empty without any AX or image capture.
    private static func localColorSource(_ anchor: TargetAnchor) -> (app: String, window: String) {
        let app = NSRunningApplication(processIdentifier: anchor.processID)?.localizedName ?? ""
        guard let windowID = anchor.windowID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == anchor.processID
              }) else { return (app, "") }
        return (app, window[kCGWindowName as String] as? String ?? "")
    }

    /// Menu entry: the asset board, retaining the existing presentation host.
    func showLibrary(near point: CGPoint?) {
        publishLibrary()
        presentation.showLibrary(near: point)
    }

    /// The host calls this once during termination; no source notifications survive shutdown.
    func stopSourceObservation() { sourceObserver?.stop() }

    // MARK: Sessions

    private func cancel(_ id: UUID) {
        guard let session = sessions[id] else { return }
        session.task?.cancel()
        session.task = nil
        session.generation += 1
        if !session.finished { remove(id) }
    }

    private func forget(_ id: UUID) {
        sessions[id]?.task?.cancel()
        remove(id)
    }

    private func insert(_ session: Session) {
        sessions[session.id]?.task?.cancel()
        sessions[session.id] = session
    }

    private func remove(_ id: UUID) {
        sessions[id] = nil
        sourceObserver?.forget(id)
        capture.forget(id)
    }

    private func isCurrent(_ session: Session, _ generation: Int) -> Bool {
        sessions[session.id] === session && session.generation == generation
    }

    /// Exposed for tests: whether a result is still kept.
    func hasSession(_ id: UUID) -> Bool { sessions[id] != nil }

    // MARK: Text

    private static func eventName(_ action: PointOutAction, _ phase: String) -> String {
        // Keep the established explanation event names for existing log readers.
        action == .explain ? "explanation_\(phase)" : "\(action.rawValue)_\(phase)"
    }

    private static func failureKind(_ error: Error) -> ResultFailureKind {
        if let error = error as? PixelSamplingError {
            return error == .permissionDenied ? .screenCapturePermission : .noReadableTarget
        }
        guard let error = error as? ModelClientError else { return .temporaryService }
        switch error {
        case .screenCapturePermission: return .screenCapturePermission
        case .noTarget: return .noReadableTarget
        case .authentication, .credentialsUnavailable, .credentialsPermissions: return .authentication
        case .persistence: return .persistence
        default: return .temporaryService
        }
    }

    static func message(for error: Error, action: PointOutAction) -> String {
        #if PINPIN_APP_STORE
        if let error = error as? ModelClientError {
            switch error {
            case .authentication, .credentialsUnavailable, .credentialsPermissions:
                return "订阅连接已失效，请打开订阅并刷新状态后重试。"
            default: break
            }
        }
        #endif
        if case .noTarget = error as? ModelClientError {
            switch action {
            case .explain: return "无法识别指向的内容。"
            case .translate: return "这里没有读到可以翻译的文字。"
            case .rewrite: return "这里没有读到可以改写的文字。"
            case .save: return "这里没有读到可以收藏的内容。"
            case .pickColor: return "这里没有读到可以取色的屏幕像素。"
            case .replyCoach: return "这里没有读到可以分析的聊天内容。"
            }
        }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "没能完成，请重试。"
    }
}
