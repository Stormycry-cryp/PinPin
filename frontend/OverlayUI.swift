import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// 每个结果独立持有卡片和草稿。样式、交互和动效依据 design-system.md v4 §11。
@MainActor final class OverlayPresentation: PointOutPresentation {
    var onCancel: ((UUID) -> Void)?
    var onForget: ((UUID) -> Void)?
    var onFollowUp: ((UUID, String) -> Void)?
    var onLibraryEdit: ((LibraryEdit) -> Void)?
    var onAssetEdit: ((AssetEdit) -> Void)?
    var onWheelSettingsChange: ((WheelSettings) async -> Bool)?
    var onSubscriptionAction: ((SubscriptionControlAction) -> Void)?

    private let wheel: POWheelController
    private let markers: POMarkerController
    private let presentsOnScreen: Bool

    private struct ResultState {
        let feature: POFeature
        var point: CGPoint
        let sample: Bool
        let hasMarker: Bool
        var text = ""
        var subtitle: String?
        var question: String?
        var finished = false
        var answering = false
        var stableText = ""
        var stableQuestion: String?
        var pendingDraft = ""
        var draft = ""
        var pendingNotice: String?
        var pickedColor: PickedColor?
        var colorPersistence: AssetPersistenceState?
        var saved: SavedItem?
        var suggestions: [String] = []
        var ballState: POBallState { feature == .pickColor || (finished && !answering) ? .done : .working }
    }

    /// 卡片随结果保留；用户删除或来源销毁时释放，失败卡片关闭后直接释放。
    @MainActor private final class Card {
        let window: POFloatingWindow
        let model = POCardModel()
        var isOpen = false
        var peeked = false
        var dialogMode = false
        var leaveTask: Task<Void, Never>?
        var ball: CGRect
        var positionOffset = CGVector.zero

        init(ball: CGRect, presentsOnScreen: Bool) {
            self.ball = ball
            window = POFloatingWindow(level: .statusBar, allSpaces: false, presentsOnScreen: presentsOnScreen)
            window.placement = { [weak self] size in
                guard let self else { return .zero }
                let origin = POFloatingWindow.growingUp(from: self.ball, windowSize: size)
                return CGPoint(x: origin.x + self.positionOffset.dx, y: origin.y + self.positionOffset.dy)
            }
        }

        deinit { leaveTask?.cancel() }
    }

    private var results: [UUID: ResultState] = [:]
    private var cards: [UUID: Card] = [:]
    /// 从后到前排列，应用切换隐藏时仍保留顺序；流式更新和悬停不改变顺序。
    private var cardOrder: [UUID] = []
    private var pendingFresh: [UUID] = []
    private var pendingFailures: [(id: UUID, message: String, kind: ResultFailureKind?, point: CGPoint)] = []
    private var outsideMonitor: Any?
    private var cardMouseMonitor: Any?

    private let libraryModel = POLibraryModel()
    private var library: POFloatingWindow?
    private var permission: POFloatingWindow?
    private let permissionModel = POPermissionModel()
    private var permissionTimer: Timer?
    private var previewTimer: Timer?
    private var previewTasks: [UUID: Task<Void, Never>] = [:]
    /// 当前生效的轮盘设置（R145）；颜色另由 POFeatureColors 提供给小球和卡片。
    private var wheelSettings = WheelSettings.defaults
    private let appearancePreference: POAppearancePreference
    private let settingsModel = POSettingsModel()
    private var settingsWindow: POFloatingWindow?
    private let subscriptionModel = POSubscriptionModel()
    private var subscriptionWindow: POFloatingWindow?

    /// 离屏检查使用真实视图和窗口，但禁止上屏、键盘激活和事件监听。
    init(presentsOnScreen: Bool = true, appearanceDefaults: UserDefaults? = nil) {
        appearancePreference = POAppearancePreference(defaults: appearanceDefaults ?? (presentsOnScreen ? .standard : nil))
        self.presentsOnScreen = presentsOnScreen
        wheel = POWheelController(presentsOnScreen: presentsOnScreen)
        markers = POMarkerController(presentsOnScreen: presentsOnScreen)
        markers.onOpen = { [weak self] id in self?.open(id, dialog: true, peek: false) }
        markers.onPeek = { [weak self] id in self?.open(id, dialog: false, peek: true) }
        markers.onClose = { [weak self] id in self?.removeResult(id) }
        markers.onRemoved = { [weak self] id in self?.removeResult(id) }
        libraryModel.announces = presentsOnScreen
        libraryModel.onDelete = { [weak self] id in self?.deleteAsset(id) }
        libraryModel.onAddTag = { [weak self] id, tag in self?.onLibraryEdit?(.addTag(id, tag)) }
        libraryModel.onRemoveTag = { [weak self] id, tag in self?.onLibraryEdit?(.removeTag(id, tag)) }
        libraryModel.onClose = { [weak self] in self?.library?.hide() }
        settingsModel.onPreview = { [weak self] settings in self?.applyWheelSettings(settings) }
        settingsModel.presentsColorEditorOnScreen = presentsOnScreen
        settingsModel.onClose = { [weak self] in
            self?.settingsModel.finishEditing()
            self?.settingsWindow?.hide()
        }
        settingsModel.onToggleAppearance = { [weak self] in self?.appearancePreference.toggle() }
        settingsModel.onShowAssets = { [weak self] in self?.showLibrary(near: nil) }
        settingsModel.onShowSubscription = { [weak self] in
            guard let self, !self.settingsModel.isSample else { return }
            self.showSubscription()
        }
        subscriptionModel.onClose = { [weak self] in self?.subscriptionWindow?.hide() }
        subscriptionModel.onAction = { [weak self] action in self?.onSubscriptionAction?(action) }
    }

    deinit {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let cardMouseMonitor { NSEvent.removeMonitor(cardMouseMonitor) }
        for task in previewTasks.values { task.cancel() }
        previewTimer?.invalidate()
        permissionTimer?.invalidate()
    }

    // MARK: Wheel

    func showWheel(at point: CGPoint) {
        for id in cardOrder where cards[id]?.peeked == true { collapse(id) }
        wheel.show(at: point)
    }

    @discardableResult func updateWheel(pointer: CGPoint) -> PointOutAction? {
        wheel.update(pointer: pointer)
    }

    func hideWheel() {
        stopPreviewPolling()
        wheel.hide()
        let fresh = pendingFresh
        pendingFresh.removeAll()
        for id in fresh where results[id] != nil { open(id, dialog: false, peek: false) }
        let failures = pendingFailures
        pendingFailures.removeAll()
        for failure in failures {
            presentFailure(failure.message, kind: failure.kind, at: failure.point, id: failure.id)
        }
    }

    // MARK: Results

    func beginResult(_ id: UUID, action: PointOutAction, at point: CGPoint, processID: pid_t) {
        startResult(id, feature: action, at: point, owner: processID, sample: false)
    }

    private func startResult(_ id: UUID, feature: POFeature, at point: CGPoint, owner: pid_t, sample: Bool) {
        markers.add(id, feature: feature, at: point, owner: owner, sample: sample)
        results[id] = ResultState(feature: feature, point: point, sample: sample, hasMarker: true)
        markers.setState(id, feature == .pickColor ? .done : .working)
        if wheel.isVisible { pendingFresh.append(id) }
        else { open(id, dialog: false, peek: false) }
    }

    func updateResult(_ id: UUID, text: String, subtitle: String?) {
        guard var state = results[id], state.feature != .pickColor else { return }
        state.text = text
        if let subtitle { state.subtitle = subtitle }
        results[id] = state
        present(id)
    }

    func finishResult(_ id: UUID) {
        guard var state = results[id], state.feature != .pickColor else { return }
        state.finished = true
        state.answering = false
        state.stableText = state.text
        state.stableQuestion = state.question
        state.pendingDraft = ""
        results[id] = state
        markers.setState(id, state.ballState)
        present(id)
    }

    func failResult(_ id: UUID, message: String, kind: ResultFailureKind?) {
        guard var state = results[id] else { return }
        if state.finished {
            state.answering = false
            state.text = state.stableText
            state.question = state.stableQuestion
            state.draft = state.pendingDraft
            state.pendingDraft = ""
            state.pendingNotice = message
            results[id] = state
            markers.setState(id, state.ballState)
            present(id, reset: true)
        } else {
            let hidden = markers.isHiddenBySource(id)
            pendingFresh.removeAll { $0 == id }
            markers.remove(id)
            results[id] = nil
            discardCard(id)
            if hidden { return }
            if wheel.isVisible { pendingFailures.append((id, message, kind, state.point)) }
            else { presentFailure(message, kind: kind, at: state.point, id: id) }
        }
    }

    func showSaved(_ id: UUID, item: SavedItem, suggestions: [String]) {
        guard var state = results[id] else { return }
        state.saved = item
        state.suggestions = suggestions
        state.text = item.text
        state.finished = true
        state.answering = false
        state.stableText = item.text
        results[id] = state
        markers.setState(id, .done)
        present(id)
    }

    func showPickedColor(_ id: UUID, color: PickedColor) {
        guard var state = results[id], state.feature == .pickColor else { return }
        state.pickedColor = color
        state.finished = true
        state.answering = false
        results[id] = state
        markers.setState(id, .done)
        present(id)
    }

    /// 菜单只操作最上面的可见卡片；其他卡片和请求不受影响。
    func closeCard() {
        guard let id = cardOrder.last(where: { isCardVisible($0) }) else { return }
        guard var state = results[id] else { collapse(id); return }
        if !state.finished { removeResult(id); return }
        if state.answering {
            state.answering = false
            state.text = state.stableText
            state.question = state.stableQuestion
            state.pendingDraft = ""
            results[id] = state
            markers.setState(id, state.ballState)
            previewTasks.removeValue(forKey: id)?.cancel()
            onCancel?(id)
        }
        collapse(id)
    }

    private func collapse(_ id: UUID) {
        guard let card = cards[id] else { return }
        card.leaveTask?.cancel()
        card.leaveTask = nil
        card.isOpen = false
        card.peeked = false
        card.dialogMode = false
        cardOrder.removeAll { $0 == id }
        card.window.hide()
        card.model.didDismiss()
        if let state = results[id], state.hasMarker {
            markers.setSuppressed(id, false)
        } else {
            results[id] = nil
            cards[id] = nil
            card.window.dispose()
            previewTasks.removeValue(forKey: id)?.cancel()
        }
        updateMouseWatch()
    }

    private func discardCard(_ id: UUID) {
        guard let card = cards.removeValue(forKey: id) else { return }
        card.leaveTask?.cancel()
        card.model.didDismiss()
        card.window.dispose()
        cardOrder.removeAll { $0 == id }
        updateMouseWatch()
    }

    func removeResult(_ id: UUID) {
        pendingFresh.removeAll { $0 == id }
        pendingFailures.removeAll { $0.id == id }
        previewTasks.removeValue(forKey: id)?.cancel()
        markers.remove(id)
        let existed = results.removeValue(forKey: id) != nil
        discardCard(id)
        if existed { onForget?(id) }
    }

    func clearAllMarkers() {
        pendingFresh.removeAll()
        pendingFailures.removeAll()
        hideWheel()
        let ids = Array(results.keys)
        let hadContent = !ids.isEmpty || !cards.isEmpty
        for id in ids { removeResult(id) }
        for id in Array(cards.keys) { discardCard(id) }
        markers.removeAll()
        if hadContent { announce("已清除全部标注") }
    }

    // MARK: Ball → short card → dialog

    private func makeCard(_ id: UUID, at point: CGPoint) -> Card {
        let card = Card(ball: POMarkerController.ballRect(for: point), presentsOnScreen: presentsOnScreen)
        cards[id] = card
        card.model.announces = presentsOnScreen
        card.model.onClose = { [weak self] in self?.collapse(id) }
        card.model.onOpen = { [weak self] in self?.openDialog(id) }
        card.model.onFollowUp = { [weak self] question in self?.submitFollowUp(id, question: question) ?? false }
        card.model.onDraftChanged = { [weak self] draft in
            guard let self, self.results[id] != nil else { return }
            self.results[id]?.draft = draft
        }
        card.model.onAddTag = { [weak self] tag in self?.editTag(id, tag: tag, adding: true) }
        card.model.onRemoveTag = { [weak self] tag in self?.editTag(id, tag: tag, adding: false) }
        card.model.onUnsave = { [weak self] in self?.unsave(id) }
        card.model.onShowLibrary = { [weak self] in self?.showLibraryFromCard(id) }
        card.window.setContent(POCardView(model: card.model))
        card.window.container.onHover = { [weak self] inside in self?.cardHover(id, inside: inside) }
        card.window.onHidden = { [weak card] in card?.model.isShown = false }
        return card
    }

    private func open(_ id: UUID, dialog: Bool, peek: Bool) {
        guard let state = results[id] else { return }
        let card = cards[id] ?? makeCard(id, at: state.point)
        if card.isOpen {
            if dialog { openDialog(id) }
            return
        }
        card.isOpen = true
        card.peeked = peek
        card.dialogMode = dialog
        markers.setSuppressed(id, true)
        cardOrder.removeAll { $0 == id }
        cardOrder.append(id)
        present(id, reset: true)
        updateMouseWatch()
    }

    private func openDialog(_ id: UUID) {
        guard let card = cards[id], card.isOpen else { return }
        card.leaveTask?.cancel()
        card.leaveTask = nil
        card.peeked = false
        card.dialogMode = true
        if card.model.canExpand && !card.model.expanded {
            withAnimation(POMotion.expand) { card.model.expanded = true }
            if card.window.isVisible { card.window.show() }
        }
        bringToFront(id)
    }

    private func cardHover(_ id: UUID, inside: Bool) {
        guard let card = cards[id] else { return }
        card.model.setHover(inside)
        card.leaveTask?.cancel()
        card.leaveTask = nil
        guard !inside, card.peeked, !card.dialogMode else { return }
        card.leaveTask = Task { @MainActor [weak self, weak card] in
            try? await Task.sleep(nanoseconds: UInt64(POMotion.leaveDelay * 1_000_000_000))
            guard let self, let card, !Task.isCancelled, self.cards[id] === card,
                  card.peeked, !card.model.hovering, !card.dialogMode, card.model.draft.isEmpty else { return }
            self.collapse(id)
        }
    }

    /// 一个全局监听处理外部点击，一个本地监听处理卡片层级；不拦截事件。
    private func updateMouseWatch() {
        let hasVisible = cards.values.contains { $0.window.isVisible }
        guard hasVisible && presentsOnScreen else {
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
            if let cardMouseMonitor { NSEvent.removeMonitor(cardMouseMonitor) }
            outsideMonitor = nil
            cardMouseMonitor = nil
            return
        }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.outsideClick(optionHeld: event.modifierFlags.contains(.option)) }
            }
        }
        if cardMouseMonitor == nil {
            cardMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.cardClicked(window: event.window) }
                return event
            }
        }
    }

    private func outsideClick(optionHeld: Bool) {
        guard !optionHeld else { return }
        for id in cardOrder {
            guard let card = cards[id], isCardVisible(id) else { continue }
            if card.model.content.isFailure || (!card.dialogMode && card.model.draft.isEmpty) { collapse(id) }
        }
    }

    private func isCardVisible(_ id: UUID) -> Bool {
        guard let card = cards[id], card.window.isVisible else { return false }
        return !presentsOnScreen || card.window.panel.isOnActiveSpace
    }

    private func cardClicked(window: NSWindow?) {
        guard let window, let id = cardOrder.last(where: { cards[$0]?.window.panel === window }) else { return }
        bringToFront(id)
    }

    private func bringToFront(_ id: UUID) {
        guard let card = cards[id], card.window.isVisible else { return }
        cardOrder.removeAll { $0 == id }
        cardOrder.append(id)
        card.window.panel.orderFrontRegardless()
    }

    /// 宿主按源窗口提供绝对位置和可见性，不以当前前台应用代替来源。
    func updateResultSource(_ id: UUID, at point: CGPoint, visible: Bool) {
        guard var state = results[id], point.x.isFinite, point.y.isFinite else { return }
        let wasHidden = markers.isHiddenBySource(id)
        let moved = state.point != point
        state.point = point
        results[id] = state
        markers.updateSource(id, at: point, visible: visible)
        if let card = cards[id] {
            if moved {
                let offset = card.window.externalPositionOffset
                card.positionOffset.dx += offset.dx
                card.positionOffset.dy += offset.dy
                card.ball = POMarkerController.ballRect(for: point)
                card.window.relayout()
            }
            if !visible && !wasHidden {
                if card.peeked { collapse(id) }
                else {
                    card.leaveTask?.cancel()
                    card.leaveTask = nil
                    card.model.inputFocused = false
                    card.model.suspendNotice()
                    card.window.hide()
                }
            } else if visible && wasHidden, card.isOpen {
                present(id)
                // 恢复一张卡片时保持其他已打开卡片原有的前后顺序。
                for openID in cardOrder where cards[openID]?.window.isVisible == true {
                    cards[openID]?.window.panel.orderFrontRegardless()
                }
            }
        }
        updateMouseWatch()
    }

    // MARK: Card rendering

    private func content(of state: ResultState) -> POCardContent {
        if let color = state.pickedColor { return .pickedColor(color) }
        if state.feature == .pickColor { return .pickingColor }
        if let item = state.saved { return .saved(item, suggestions: state.suggestions) }
        if state.text.isEmpty && !state.answering { return .loading(state.feature) }
        return .answer(state.feature, text: state.text, subtitle: state.subtitle)
    }

    private func present(_ id: UUID, reset: Bool = false) {
        guard let state = results[id], let card = cards[id],
              card.isOpen, !markers.isHiddenBySource(id) else { return }
        let model = card.model
        let next = content(of: state)
        if !model.collapsible { model.collapsible = true }
        if reset || next.phase != model.content.phase {
            let apply = {
                model.reset(to: next, question: state.question, answering: state.answering,
                            sample: state.sample, dialog: card.dialogMode, draft: state.draft)
            }
            if card.window.isVisible, let swap = POMotion.swap { withAnimation(swap, apply) } else { apply() }
        } else {
            if model.content != next { model.content = next }
            if model.question != state.question { model.question = state.question }
            if model.answering != state.answering { model.answering = state.answering }
            if model.draft != state.draft { model.draft = state.draft }
            if card.dialogMode && model.canExpand && !model.expanded {
                withAnimation(POMotion.expand) { model.expanded = true }
            }
        }
        if model.colorPersistence != state.colorPersistence { model.colorPersistence = state.colorPersistence }
        // 已显示的卡片由现有 POSizeSink 合并尺寸变化；流式包不强制同步布局或重启淡入。
        if !card.window.isVisible {
            model.isShown = true
            card.window.show()
        }
        if let notice = state.pendingNotice {
            results[id]?.pendingNotice = nil
            model.flash(notice, long: true)
        }
    }

    private func presentFailure(_ message: String, kind: ResultFailureKind?, at point: CGPoint, id: UUID = UUID()) {
        let card = makeCard(id, at: point)
        card.model.reset(to: .failure(message, kind), question: nil, answering: false, sample: false, dialog: false)
        card.model.collapsible = false
        card.model.isShown = true
        card.isOpen = true
        cardOrder.append(id)
        card.window.show()
        updateMouseWatch()
    }

    // MARK: Card actions

    private func submitFollowUp(_ id: UUID, question: String) -> Bool {
        guard var state = results[id], state.finished, !state.answering, state.saved == nil, state.feature != .pickColor,
              state.sample || onFollowUp != nil else { return false }
        state.answering = true
        state.question = question
        state.pendingDraft = question
        state.pendingNotice = nil
        state.text = ""
        state.draft = ""
        results[id] = state
        markers.setState(id, .working)
        present(id)
        if state.sample { previewFollowUp(id) } else { onFollowUp?(id, question) }
        return true
    }

    private func editTag(_ id: UUID, tag: String, adding: Bool) {
        guard var state = results[id], var item = state.saved else { return }
        if state.sample {
            if adding {
                if !item.tags.contains(tag) { item.tags.append(tag) }
            } else { item.tags.removeAll { $0 == tag } }
            state.saved = item
            results[id] = state
            if let i = libraryModel.items.firstIndex(where: { $0.id == item.id }) { libraryModel.items[i] = item }
            present(id)
        } else {
            onLibraryEdit?(adding ? .addTag(item.id, tag) : .removeTag(item.id, tag))
        }
    }

    private func unsave(_ id: UUID) {
        guard let state = results[id], let item = state.saved else { return }
        removeResult(id)
        if state.sample { libraryModel.items.removeAll { $0.id == item.id } }
        else { onLibraryEdit?(.delete(item.id)) }
        announce("已取消收藏")
    }

    private func showLibraryFromCard(_ id: UUID) {
        guard let card = cards[id] else { return }
        let frame = card.window.panel.frame
        collapse(id)
        openLibrary { size in
            guard let screen = POFloatingWindow.screen(containing: CGPoint(x: frame.midX, y: frame.midY)) else { return frame.origin }
            let visible = screen.visibleFrame.insetBy(dx: POMetrics.screenInset, dy: POMetrics.screenInset)
            let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            let top = min(frame.maxY, visible.maxY)
            return NSPoint(x: x, y: max(top - size.height, visible.minY))
        }
    }

    // MARK: 资产看板

    func updateAssets(_ items: [AssetRecord]) {
        libraryModel.isSample = false
        libraryModel.receive(items)
        synchronizeSavedResults(libraryModel.items)
    }

    func updateColorPersistence(_ resultID: UUID, state: AssetPersistenceState) {
        guard results[resultID]?.feature == .pickColor else { return }
        guard results[resultID]?.colorPersistence != state else { return }
        results[resultID]?.colorPersistence = state
        present(resultID)
    }

    func updateLibrary(_ items: [SavedItem]) {
        libraryModel.isSample = false
        libraryModel.items = items
        synchronizeSavedResults(items)
    }

    private func synchronizeSavedResults(_ items: [SavedItem]) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (id, state) in results where !state.sample {
            guard let saved = state.saved else { continue }
            guard let current = byID[saved.id] else { removeResult(id); continue }
            if current != saved { results[id]?.saved = current; present(id) }
        }
    }

    /// 菜单或结果卡打开同一个看板；更新数据不重建窗口。
    func showLibrary(near point: CGPoint?) {
        openLibrary { size in
            let reference = point ?? NSEvent.mouseLocation
            guard let screen = POFloatingWindow.screen(containing: reference) else { return .zero }
            let visible = screen.visibleFrame.insetBy(dx: POMetrics.screenInset, dy: POMetrics.screenInset)
            let x = min(max((point?.x ?? visible.midX) - size.width / 2, visible.minX), visible.maxX - size.width)
            let top = point.map { min($0.y - 6, visible.maxY) } ?? (visible.maxY - visible.height * 0.12)
            return NSPoint(x: x, y: max(top - size.height, visible.minY))
        }
    }

    private func openLibrary(placement: @escaping (CGSize) -> NSPoint) {
        let window = library ?? makeLibraryWindow()
        library = window
        window.placement = { [weak window] size in
            if let window, window.isVisible {
                let frame = window.panel.frame
                return NSPoint(x: frame.minX, y: frame.maxY - size.height)
            }
            return placement(size)
        }
        window.show()
        window.panel.makeKey()
    }

    private func makeLibraryWindow() -> POFloatingWindow {
        let window = POFloatingWindow(level: .normal, presentsOnScreen: presentsOnScreen)
        window.panel.isFloatingPanel = false
        window.panel.isMovable = true
        window.panel.isMovableByWindowBackground = false
        window.setContent(POAssetBoardView(model: libraryModel))
        window.onHidden = { [weak self] in self?.libraryModel.suspendNotice() }
        return window
    }

    private func deleteAsset(_ id: AssetRecord.ID) {
        if let onAssetEdit { onAssetEdit(.delete(id)) }
        else if case .saved(let uuid) = id { onLibraryEdit?(.delete(uuid)) }
    }

    // MARK: Wheel settings (R145, design-system.md §21)

    /// 幂等：宿主在保存前回传同一份设置时不重复刷新。小球和卡片立即换色；
    /// 打开中的轮盘保留本次手势的格子、颜色和命中几何，关闭后才换。
    /// 面板里已预览、还没交给宿主的改动比外来设置新（例如晚到的启动读取），此时外来设置不覆盖它；
    /// 这次改动随后整份交给宿主保存。
    func updateWheelSettings(_ settings: WheelSettings) {
        guard settings.isValid, !settingsModel.hasUnsentEdit else { return }
        applyWheelSettings(settings)
        settingsModel.receive(settings)
    }

    private func applyWheelSettings(_ settings: WheelSettings) {
        guard settings != wheelSettings else { return }
        wheelSettings = settings
        if POFeatureColors.shared.apply(settings.colors) { markers.recolor() }
        wheel.update(settings: settings)
    }

    func showSettings() {
        openSettings(sample: false, near: NSEvent.mouseLocation)
    }

    /// 不随失去焦点关闭：用户可以一边开着设置一边试轮盘。关闭用 ×、Esc 或再次从菜单打开。
    private func openSettings(sample: Bool, near point: CGPoint) {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        settingsModel.isSample = sample
        settingsModel.onPersist = sample ? nil : onWheelSettingsChange
        settingsModel.receive(wheelSettings)
        settingsModel.prepare()
        window.placement = { [weak window] size in
            // 设置内容重新布局时保留用户移动后的位置。
            if let window, window.isVisible {
                let frame = window.panel.frame
                return NSPoint(x: frame.minX, y: frame.maxY - size.height)
            }
            guard let screen = POFloatingWindow.screen(containing: point) else { return .zero }
            let f = screen.visibleFrame
            return NSPoint(x: f.midX - size.width / 2, y: max(f.minY, f.maxY - f.height * 0.16 - size.height))
        }
        window.show()
        if presentsOnScreen {
            // 显式打开时恢复应用并重新置前；可见窗口的普通布局不会改变窗口顺序。
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            window.panel.orderFrontRegardless()
            window.panel.makeKey()
        }
    }

    private func makeSettingsWindow() -> POFloatingWindow {
        let window = POFloatingWindow(level: .normal, radius: POSettingsMetrics.windowRadius,
                                      presentsOnScreen: presentsOnScreen)
        window.panel.isFloatingPanel = false
        window.panel.isMovable = true
        // 仅顶部留白启动原生移动，保留 SwiftUI 控件自身的拖放手势。
        window.panel.isMovableByWindowBackground = false
        window.setContent(POSettingsView(model: settingsModel))
        settingsModel.colorEditorAnchor = { [weak window] in window?.panel.frame }
        window.onHidden = { [weak self] in self?.settingsModel.finishEditing() }
        return window
    }

    // MARK: Subscription

    func updateSubscription(_ state: SubscriptionPanelState) {
        subscriptionModel.receive(state)
    }

    func showSubscription() {
        let point = NSEvent.mouseLocation
        let window = subscriptionWindow ?? makeSubscriptionWindow()
        subscriptionWindow = window
        window.placement = { [weak window] size in
            if let window, window.isVisible {
                let frame = window.panel.frame
                return NSPoint(x: frame.minX, y: frame.maxY - size.height)
            }
            guard let screen = POFloatingWindow.screen(containing: point) else { return .zero }
            let frame = screen.visibleFrame
            return NSPoint(x: frame.midX - size.width / 2, y: max(frame.minY, frame.midY - size.height / 2))
        }
        window.show()
        if presentsOnScreen {
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            window.panel.orderFrontRegardless()
            window.panel.makeKey()
        }
        subscriptionModel.perform(.refresh)
    }

    private func makeSubscriptionWindow() -> POFloatingWindow {
        let window = POFloatingWindow(level: .normal, radius: POSubscriptionMetrics.radius,
                                      presentsOnScreen: presentsOnScreen)
        window.panel.isFloatingPanel = false
        window.panel.isMovable = true
        window.panel.isMovableByWindowBackground = false
        window.setContent(POSubscriptionView(model: subscriptionModel))
        return window
    }

    // MARK: Permission help

    func showPermissionHelp(accessibility: Bool, screenCapture: Bool) {
        permissionModel.accessibility = accessibility
        permissionModel.screenCapture = screenCapture
        let window = permission ?? makePermissionWindow()
        permission = window
        window.show()

        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ax = AXIsProcessTrusted()
                let sc = CGPreflightScreenCaptureAccess()
                if ax != self.permissionModel.accessibility { self.permissionModel.accessibility = ax }
                if sc != self.permissionModel.screenCapture { self.permissionModel.screenCapture = sc }
            }
        }
    }

    private func makePermissionWindow() -> POFloatingWindow {
        let window = POFloatingWindow(level: .statusBar, presentsOnScreen: presentsOnScreen)
        window.setContent(POPermissionView(model: permissionModel) { [weak self] in self?.hidePermission() })
        window.placement = { size in
            let mouse = NSEvent.mouseLocation
            guard let screen = POFloatingWindow.screen(containing: mouse) else { return .zero }
            let f = screen.visibleFrame
            return NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18 - size.height)
        }
        return window
    }

    private func hidePermission() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        permission?.hide()
    }

    private func announce(_ text: String) {
        guard presentsOnScreen else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Preview (independent; no network, no global permissions, nothing is stored)

    /// names: wheel, ball, loading, explanation, expanded, followup, translation, rewrite, saved,
    /// saved-image, search, markers, multiple, failure, permission-failure, settings.
    /// Every preview card carries a small sample badge; settings edits in the preview are not saved.
    func previewComponent(_ name: String, at point: CGPoint) {
        POSamples.registerImages()
        stopPreviewPolling()
        for id in Array(results.keys) { removeResult(id) }
        for id in Array(cards.keys) { discardCard(id) }
        switch name {
        case "wheel":
            previewWheel(at: point)
        case "loading":
            presentSample(.explain, text: "", at: point, finished: false)
        case "explanation":
            presentSample(.explain, text: POSamples.explanation, at: point)
        case "expanded":
            presentSample(.explain, text: POSamples.explanation, at: point, dialog: true)
        case "followup":
            presentSample(.explain, text: POSamples.followUpAnswer, question: POSamples.followUpQuestion,
                          at: point, dialog: true)
        case "ball":
            previewBall(at: point)
        case "translation":
            presentSample(.translate, text: POSamples.translation, subtitle: "英 → 中", at: point)
        case "rewrite":
            presentSample(.rewrite, text: POSamples.rewrite, at: point)
        case "saved":
            libraryModel.receive(POSamples.savedList.map(AssetRecord.saved))
            libraryModel.isSample = true
            presentSample(.save, text: POSamples.savedItem.text, saved: POSamples.savedItem,
                          suggestions: ["待办", "稍后读"], at: point)
        case "saved-image":
            libraryModel.receive(POSamples.savedList.map(AssetRecord.saved))
            libraryModel.isSample = true
            presentSample(.save, text: POSamples.imageItem.text, saved: POSamples.imageItem,
                          suggestions: ["学习"], at: point)
        case "failure":
            presentFailure("这里没有读到可以翻译的文字。", kind: .noReadableTarget, at: point)
        case "permission-failure":
            presentFailure("开启屏幕录制后，才能识别没有选中的内容。", kind: .screenCapturePermission, at: point)
        case "search":
            libraryModel.receive(POSamples.savedList.map(AssetRecord.saved))
            libraryModel.isSample = true
            openLibrary { size in POFloatingWindow.besideAnchor(point, windowSize: size) }
        case "markers":
            previewMarkers(at: point)
        case "multiple":
            previewMultiple(at: point)
        case "settings":
            openSettings(sample: true, near: point)
        default:
            presentFailure("没有这个预览组件", kind: nil, at: point)
        }
    }

    private func presentSample(_ feature: POFeature, text: String, subtitle: String? = nil, question: String? = nil,
                               saved: SavedItem? = nil, suggestions: [String] = [],
                               at point: CGPoint, finished: Bool = true, dialog: Bool = false) {
        let id = UUID()
        var state = ResultState(feature: feature, point: point, sample: true, hasMarker: false)
        state.text = text
        state.subtitle = subtitle
        state.question = question
        state.finished = finished
        state.stableText = text
        state.stableQuestion = question
        state.saved = saved
        state.suggestions = suggestions
        results[id] = state
        open(id, dialog: dialog, peek: false)
    }

    private func stopPreviewPolling() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Polls the pointer locally (no event taps) only while the preview wheel is visible.
    /// 在中心取消区外松开即可按角度执行，生成对应的示例结果。
    private func previewWheel(at point: CGPoint) {
        wheel.show(at: point)
        var wasDown = NSEvent.pressedMouseButtons & 1 == 1
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.wheel.isVisible else { self.stopPreviewPolling(); return }
                let hit = self.wheel.update(pointer: NSEvent.mouseLocation)
                let down = NSEvent.pressedMouseButtons & 1 == 1
                // 预览中松开左键也代表松开 Option：关闭轮盘并打开对应卡片。
                if wasDown && !down, let hit { self.startSample(hit, at: point); self.hideWheel(); return }
                wasDown = down
            }
        }
    }

    private func startSample(_ feature: POFeature, at point: CGPoint) {
        let id = UUID()
        startResult(id, feature: feature, at: point, owner: 0, sample: true)
        if feature == .pickColor {
            showPickedColor(id, color: PickedColor(red: 46, green: 94, blue: 158))
            return
        }
        previewTasks.removeValue(forKey: id)?.cancel()
        previewTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.results[id] != nil else { return }
            switch feature {
            case .pickColor:
                self.showPickedColor(id, color: PickedColor(red: 46, green: 94, blue: 158))
            case .save:
                self.libraryModel.receive(POSamples.savedList.map(AssetRecord.saved))
                self.libraryModel.isSample = true
                self.showSaved(id, item: POSamples.savedItem, suggestions: ["待办", "稍后读"])
            case .translate:
                self.updateResult(id, text: POSamples.translation, subtitle: "英 → 中")
                self.finishResult(id)
            case .rewrite:
                self.updateResult(id, text: POSamples.rewrite, subtitle: nil)
                self.finishResult(id)
            case .explain:
                self.updateResult(id, text: POSamples.explanation, subtitle: nil)
                self.finishResult(id)
            case .replyCoach:
                self.updateResult(id, text: POSamples.replyCoach, subtitle: nil)
                self.finishResult(id)
            }
            self.previewTasks[id] = nil
        }
    }

    /// A sample follow-up streams a fixed answer after a short wait.
    private func previewFollowUp(_ id: UUID) {
        guard let feature = results[id]?.feature else { return }
        previewTasks.removeValue(forKey: id)?.cancel()
        previewTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, self.results[id]?.answering == true else { return }
            self.updateResult(id, text: POSamples.followUp(for: feature), subtitle: nil)
            self.finishResult(id)
            self.previewTasks[id] = nil
        }
    }

    /// One sample ball at rest: rest on it 1s for the short card, click for the dialog.
    private func previewBall(at point: CGPoint) {
        for id in markers.markers.map(\.id) { removeResult(id) }
        let id = UUID()
        markers.add(id, feature: .explain, at: point, owner: 0, sample: true)
        var state = ResultState(feature: .explain, point: point, sample: true, hasMarker: true)
        state.text = POSamples.explanation
        state.stableText = POSamples.explanation
        state.finished = true
        results[id] = state
        markers.setState(id, .done)
    }

    /// Sample balls around the point: two finished, one still working. Rest on a ball 1s for its short
    /// card, click for the dialog, hover for its close badge. Option + double-click needs the host
    /// event tap, so it is not part of the preview.
    private func previewMarkers(at point: CGPoint) {
        for id in markers.markers.map(\.id) { removeResult(id) }
        let samples: [(POFeature, CGVector, String)] = [
            (.explain, CGVector(dx: -120, dy: 40), POSamples.explanation),
            (.translate, CGVector(dx: 0, dy: 0), POSamples.translation),
            (.rewrite, CGVector(dx: 90, dy: -60), POSamples.rewrite),
        ]
        for (feature, offset, text) in samples {
            let id = UUID()
            let at = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
            markers.add(id, feature: feature, at: at, owner: 0, sample: true)
            var state = ResultState(feature: feature, point: at, sample: true, hasMarker: true)
            state.text = text
            state.stableText = text
            state.finished = feature != .rewrite
            state.subtitle = feature == .translate ? "英 → 中" : nil
            if feature == .rewrite { state.text = "" }
            results[id] = state
            markers.setState(id, state.ballState)
        }
    }

    /// 左侧解释对话框、右侧翻译短卡片、上方生成中的改写小球，均使用正常结果路径。
    private func previewMultiple(at point: CGPoint) {
        let frame = POFloatingWindow.screen(containing: point)?.visibleFrame
            ?? CGRect(x: point.x - 640, y: point.y - 400, width: 1280, height: 800)
        let left = CGPoint(x: frame.midX - 340, y: frame.midY - 90)
        let right = CGPoint(x: left.x + 350, y: left.y)
        let top = CGPoint(x: frame.midX, y: min(frame.maxY - 60, frame.midY + 160))
        let a = UUID(), b = UUID(), c = UUID()
        startResult(a, feature: .explain, at: left, owner: 0, sample: true)
        updateResult(a, text: POSamples.explanation, subtitle: nil)
        finishResult(a)
        open(a, dialog: true, peek: false)
        startResult(b, feature: .translate, at: right, owner: 0, sample: true)
        updateResult(b, text: POSamples.translation, subtitle: "英 → 中")
        finishResult(b)
        startResult(c, feature: .rewrite, at: top, owner: 0, sample: true)
        collapse(c)
    }

    #if PINPIN_UI_TESTING
    // 检查正常事件处理路径的实际模型、窗口和回调；不替代 WindowServer 的实机焦点验收。
    func testModel(_ id: UUID) -> POCardModel? { cards[id]?.model }
    func testWindow(_ id: UUID) -> POFloatingWindow? { cards[id]?.window }
    var testResultIDs: Set<UUID> { Set(results.keys) }
    var testCardIDs: Set<UUID> { Set(cards.keys) }
    var testVisibleIDs: Set<UUID> { Set(cards.filter { $0.value.window.isVisible }.keys) }
    var testOrder: [UUID] { cardOrder }
    var testMarkerIDs: Set<UUID> { Set(markers.markers.map(\.id)) }
    var testPreviewTaskCount: Int { previewTasks.count }
    var testLeaveTaskCount: Int { cards.values.filter { $0.leaveTask != nil }.count }
    var testMouseMonitorCount: Int { (outsideMonitor == nil ? 0 : 1) + (cardMouseMonitor == nil ? 0 : 1) }
    var testRestingMarkerPanels: [POPanel] {
        markers.markers.filter { cards[$0.id]?.isOpen != true }.map(\.panel)
    }
    func testOpen(_ id: UUID, dialog: Bool = false, peek: Bool = false) { open(id, dialog: dialog, peek: peek) }
    func testRemove(_ id: UUID) { removeResult(id) }
    func testOutside(optionHeld: Bool = false) { outsideClick(optionHeld: optionHeld) }
    func testClick(_ id: UUID) { cardClicked(window: cards[id]?.window.panel) }
    func testSourcePoint(_ id: UUID) -> CGPoint? { results[id]?.point }
    func testMarkerPoint(_ id: UUID) -> CGPoint? { markers.marker(id)?.point }
    func testHover(_ id: UUID, inside: Bool) { cardHover(id, inside: inside) }
    func testHasLeaveTask(_ id: UUID) -> Bool { cards[id]?.leaveTask != nil }
    var testWheel: POWheelController { wheel }
    var testAssetModel: POLibraryModel { libraryModel }
    var testAssetWindow: POFloatingWindow? { library }
    var testSettingsModel: POSettingsModel { settingsModel }
    var testSettingsWindow: POFloatingWindow? { settingsWindow }
    var testSubscriptionModel: POSubscriptionModel { subscriptionModel }
    var testSubscriptionWindow: POFloatingWindow? { subscriptionWindow }
    var testWheelSettings: WheelSettings { wheelSettings }
    func testMarkerView(_ id: UUID) -> POMarkerView? { markers.marker(id)?.view }
    func testMarkerTint(_ id: UUID) -> CGColor? { markers.marker(id)?.view.testGlyphColor }
    #endif

}

// MARK: - Sample content for previews only

/// Short, general, verifiable examples. No paper attributions or metrics.
enum POSamples {
    static let replyCoach = "对方想确认进度，也希望知道什么时候能收到结果。可以先说明当前进展，再给出明确时间。\n\n可以回复：我已经整理好主要内容，正在核对细节，今天下午四点前发给你。"

    static let explanation =
        "**缓存**：把算过或取过的结果先存起来，下次直接复用，省去重复计算或读取。"
    static let translation = "少即是多。"
    static let rewrite = "建议先上线当前方案，已知问题在下个版本修复。"
    static let followUpQuestion = "举个例子？"
    static let followUpAnswer = "比如网页把图片存在本地，第二次打开同一页面时直接读取，不再重新下载。"

    static func followUp(for feature: POFeature) -> String {
        switch feature {
        case .explain: return followUpAnswer
        case .translate: return "简单就是力量。"
        case .rewrite: return "当前方案先上线，已知问题下个版本修复。"
        case .save: return followUpAnswer
        case .pickColor: return ""
        case .replyCoach: return "可以更简短地说：我下午确认后回复你。"
        }
    }

    static let savedItem = SavedItem(id: UUID(), text: "周五前确认发布清单，并同步给设计和测试。",
                                     appName: "备忘录", windowTitle: "发布计划", tags: ["工作"], createdAt: Date())
    /// An image save: the picture lives only in memory (POImageLoader.registerSample), nothing is written.
    static let imageURL = URL(fileURLWithPath: "/PinPin-sample/chart.png")
    static let imageItem = SavedItem(id: UUID(), text: "柱状图：四个季度的用户数，第三季度最高。",
                                     appName: "预览", windowTitle: "季度报告", tags: ["学习"],
                                     createdAt: Date(), imageURL: imageURL, pointInImage: CGPoint(x: 0.62, y: 0.38))
    /// A grayscale bar chart drawn in memory for the image-save preview; the tallest bar is pointed at.
    @MainActor static func registerImages() {
        let w = 640, h = 400
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.80, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 48, width: 560, height: 2))
        for (i, height) in [CGFloat(140), 190, 260, 210].enumerated() {
            ctx.setFillColor(CGColor(gray: i == 2 ? 0.22 : 0.62, alpha: 1))
            ctx.fill(CGRect(x: 80 + CGFloat(i) * 130, y: 50, width: 80, height: height))
        }
        if let image = ctx.makeImage() { POImageLoader.registerSample(image, for: imageURL) }
    }

    static let savedList: [SavedItem] = [
        savedItem,
        imageItem,
        SavedItem(id: UUID(), text: "Less is more.", appName: "Safari", windowTitle: "设计随笔",
                  tags: ["稍后读"], createdAt: Date(timeIntervalSinceNow: -3600 * 5)),
        SavedItem(id: UUID(), text: "缓存是把结果先存起来，下次直接复用。", appName: "备忘录", windowTitle: "",
                  tags: ["学习"], createdAt: Date(timeIntervalSinceNow: -86400 * 2)),
        SavedItem(id: UUID(), text: "会议改到周四下午三点。", appName: "邮件", windowTitle: "本周安排",
                  tags: ["工作", "待办"], createdAt: Date(timeIntervalSinceNow: -86400 * 6)),
    ]
}
