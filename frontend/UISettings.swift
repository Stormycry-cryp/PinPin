import AppKit
import SwiftUI

// MARK: - Settings panel (design-system.md §21, R145–R151, R215–R217)
// Left: the wheel itself, large, drawn from the same slot geometry as the gesture wheel, with a
// compact − n + under it. Right: four small square function keys. Drag a key onto a slot to put it
// there; drag a slot onto another to swap them, or off the wheel to empty it. Clicking a key (or a
// filled slot) switches the right side to that function's details; the wheel then dims every slot
// that holds something else, so where the function sits needs no words.
// The library stays compact; each detail page has one description and a collapsed color control. Every edit
// shows at once on the wheel, the balls and the cards, then is saved silently; only a save that did
// not go through is said, at the top, with a retry key.

enum POSettingsMetrics {
    /// 1.2× the gesture wheel (outer 80, cancel 26, hub 20, gap 4, icon 17), the same proportions:
    /// clearly the large thing on the left, without filling the panel (R149).
    static let outer: CGFloat = 96
    static let inner: CGFloat = 31
    static let hub: CGFloat = 24
    static let margin: CGFloat = 10
    static let gap: CGFloat = 4.5
    static let icon: CGFloat = 20
    static var trayRadius: CGFloat { outer + margin }
    static var side: CGFloat { trayRadius * 2 }
    /// Four compact keys per row, room for three rows before scrolling (R150, R151).
    static let block: CGFloat = 42
    static let blockGap: CGFloat = 14
    static let blockRadius: CGFloat = 10
    static let blockIcon: CGFloat = 15
    static let blockLabel: CGFloat = 8.5
    static let libraryColumns = 4
    static let libraryRows = 3
    /// Inset keeps the raised keys' shadows clear of the scroll viewport edge.
    static let libraryInset: CGFloat = 8
    static var column: CGFloat { block * CGFloat(libraryColumns) + blockGap * CGFloat(libraryColumns - 1) + libraryInset * 2 }
    static var libraryHeight: CGFloat { block * CGFloat(libraryRows) + blockGap * CGFloat(libraryRows - 1) + libraryInset * 2 }
    /// 详情独立留白，不把说明与换色入口挤在旧色板宽度里。
    static let editorWidth: CGFloat = 198
    static let padding: CGFloat = 24
    /// Between the wheel and the right column.
    static let columnGap: CGFloat = 28
    static let windowRadius: CGFloat = 18
    /// Shallow relief throughout (R149): the tray, its pads, an empty socket, the slot under a drag,
    /// the hub and the keys.
    static let trayDepth: CGFloat = 2.4
    static let padDepth: CGFloat = 1.5
    static let socketDepth: CGFloat = 0.8
    static let targetDepth: CGFloat = 1.8
    static let hubDepth: CGFloat = 1.2
    static let blockDepth: CGFloat = 2.2
    /// Icons of slots that hold another function while one function's page is open.
    static let dimmed: Double = 0.28
    /// Pointer travel below this is a click, at or above it a drag.
    static let clickTolerance: CGFloat = 3
}

@MainActor final class POSettingsModel: ObservableObject {
    enum Page: Equatable { case functions, edit(PointOutAction) }
    enum SaveState: Equatable { case idle, saving, saved, failed }
    /// What is being dragged: a block from the right (a copy; the block stays) or a slot's content.
    enum Source: Equatable { case block(PointOutAction), slot(Int) }
    enum Drop: Equatable { case slot(Int), hub, outside }

    struct Drag: Equatable {
        let source: Source
        let action: PointOutAction
        let start: CGPoint
        var location: CGPoint
        var moved = false
    }

    /// What the wheel shows: the settings, or during a drag the result the drop would give.
    struct WheelState: Equatable {
        var slots: [PointOutAction?]
        /// Slot under the pointer, pressed in.
        var target: Int?
        /// The dragged slot when dropping here changes nothing; its icon is shown faded.
        var lifted: Int?
    }

    @Published private(set) var settings = WheelSettings.defaults
    @Published var page: Page = .functions {
        didSet { if page != oldValue { closeColorEditor() } }
    }
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var drag: Drag?
    /// Preview entry: edits apply in this process only and are never saved.
    @Published var isSample = false
    @Published private(set) var colorEditorAction: PointOutAction?
    var presentsColorEditorOnScreen = true
    var colorEditorAnchor: () -> NSRect? = { nil }
    private var colorWindow: POFloatingWindow?
    private var colorPicker: POSettingsColorPickerModel?
    private var colorSession: UUID?
    private var colorNeedsSave = false

    #if PINPIN_UI_TESTING
    /// Repeated real actions exercise multi-row layout; production always uses allCases.
    @Published var testLibraryActions: [PointOutAction]?
    #endif
    var libraryActions: [PointOutAction] {
        #if PINPIN_UI_TESTING
        if let testLibraryActions { return testLibraryActions }
        #endif
        return PointOutAction.allCases
    }

    /// Wheel center in the body row's coordinate space (y down); the wheel is the row's top-leading item.
    let wheelCenter = CGPoint(x: POSettingsMetrics.side / 2, y: POSettingsMetrics.side / 2)

    /// Applies an edit to the wheel, balls and cards at once.
    var onPreview: (WheelSettings) -> Void = { _ in }
    /// Saves an edit; false means it was not written.
    var onPersist: ((WheelSettings) async -> Bool)?
    var onClose: () -> Void = {}
    var onToggleAppearance: () -> Void = {}
    var onShowAssets: () -> Void = {}
    var onShowSubscription: () -> Void = {}
    private var revision = 0
    /// An edit is previewed but not yet handed to the host. Settings arriving from outside in this gap
    /// (a late launch load) are older than it and must not replace it.
    private(set) var hasUnsentEdit = false

    // MARK: Edits

    func setTriggerEnabled(_ enabled: Bool) {
        var s = settings
        s.triggerEnabled = enabled
        commit(s)
    }

    func setSlotCount(_ count: Int) {
        let n = min(max(count, 1), POWheelLayout.maxSlots)
        var s = settings
        if n < s.slots.count { s.slots.removeLast(s.slots.count - n) }
        else { s.slots += Array(repeating: nil, count: n - s.slots.count) }
        commit(s)
    }

    func assign(_ action: PointOutAction?, to index: Int) {
        guard settings.slots.indices.contains(index) else { return }
        var s = settings
        s.slots[index] = action
        commit(s)
    }

    /// Picking the design default removes the entry, so the file only holds real choices.
    func setColor(_ swatch: POSwatch, for action: PointOutAction) {
        var s = settings
        s.colors[action] = swatch == POSwatches.defaultSwatch(for: action) ? nil : swatch.wheelColor
        commit(s)
    }

    func resetColor(_ action: PointOutAction) {
        var s = settings
        s.colors[action] = nil
        commit(s)
    }

    /// Settings from outside (the saved file at launch, or the host echoing an edit). Not an edit.
    func receive(_ new: WheelSettings) {
        guard new != settings else { return }
        settings = new
        if let action = colorEditorAction {
            colorPicker?.receive(new.colors[action] ?? POSwatches.defaultSwatch(for: action).wheelColor)
        }
        drag = nil
    }

    /// Each time the panel opens: the function list, nothing held.
    func prepare() {
        closeColorEditor()
        page = .functions
        drag = nil
    }

    func retry() { save() }

    private func commit(_ new: WheelSettings) {
        guard new != settings, new.isValid else { return }
        settings = new
        onPreview(new)
        colorNeedsSave = false
        save()
    }

    /// 选色拖动只更新当前显示；松手、关闭或切页时交出最终值。
    func toggleColorEditor(for action: PointOutAction) {
        if colorEditorAction == action { closeColorEditor(); return }
        closeColorEditor()
        guard page == .edit(action) else { return }
        let session = UUID()
        let picker = POSettingsColorPickerModel(color: settings.colors[action] ?? POSwatches.defaultSwatch(for: action).wheelColor)
        let window = POFloatingWindow(level: .normal, radius: POSettingsMetrics.windowRadius,
                                      allSpaces: false, presentsOnScreen: presentsColorEditorOnScreen)
        colorSession = session
        colorEditorAction = action
        colorPicker = picker
        colorWindow = window
        picker.onPreview = { [weak self] color in
            guard let self, self.colorSession == session else { return }
            var value = self.settings
            value.colors[action] = POSwatches.defaultSwatch(for: action).matches(color) ? nil : color
            guard value != self.settings, value.isValid else { return }
            self.revision += 1
            self.hasUnsentEdit = true
            self.colorNeedsSave = true
            self.settings = value
            self.onPreview(value)
        }
        picker.onFinish = { [weak self] in
            guard let self, self.colorSession == session else { return }
            self.saveColorDraft()
        }
        picker.onReset = { [weak self, weak picker] in
            guard let self, self.colorSession == session else { return }
            picker?.receive(POSwatches.defaultSwatch(for: action).wheelColor)
            self.resetColor(action)
            self.saveColorDraft()
        }
        picker.onClose = { [weak self] in
            guard let self, self.colorSession == session else { return }
            self.closeColorEditor()
        }
        window.panel.isFloatingPanel = false
        window.panel.isMovable = true
        window.panel.isMovableByWindowBackground = false
        let anchor = colorEditorAnchor() ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 0, height: 0)
        window.placement = { [weak window] size in
            if let window, window.isVisible {
                let frame = window.panel.frame
                return NSPoint(x: frame.minX, y: frame.maxY - size.height)
            }
            let screen = POFloatingWindow.screen(containing: NSPoint(x: anchor.midX, y: anchor.midY))?.visibleFrame
            let x = anchor.maxX + 12
            guard let screen else { return NSPoint(x: x, y: anchor.maxY - size.height) }
            return NSPoint(x: min(max(screen.minX, x), screen.maxX - size.width),
                           y: min(max(screen.minY, anchor.maxY - size.height), screen.maxY - size.height))
        }
        window.setContent(POSettingsColorPickerView(model: picker, title: action.title))
        window.onHidden = picker.onClose
        window.show()
        if presentsColorEditorOnScreen { window.panel.makeKey() }
    }

    private func saveColorDraft() {
        guard colorNeedsSave else { return }
        colorNeedsSave = false
        save()
    }

    func closeColorEditor() {
        guard colorSession != nil else { return }
        colorSession = nil
        colorPicker?.onPreview = { _ in }
        colorPicker?.onFinish = {}
        colorPicker?.onReset = {}
        colorPicker?.onClose = {}
        colorPicker = nil
        colorEditorAction = nil
        let window = colorWindow
        colorWindow = nil
        window?.onHidden = nil
        window?.dispose()
        saveColorDraft()
    }

    func finishEditing() {
        cancelDrag()
        closeColorEditor()
    }

    #if PINPIN_UI_TESTING
    var testColorWindow: POFloatingWindow? { colorWindow }
    var testColorPicker: POSettingsColorPickerModel? { colorPicker }
    #endif

    /// Only the newest edit's result is shown; each save carries the whole settings.
    /// An edit replaced before its task starts is never sent: the host echoes what it is given,
    /// so sending it would briefly bring the older settings back.
    private func save() {
        revision += 1
        guard !isSample, let persist = onPersist else { hasUnsentEdit = false; saveState = .idle; return }
        let rev = revision, value = settings
        saveState = .saving
        hasUnsentEdit = true
        Task { @MainActor [weak self] in
            guard let self, self.revision == rev else { return }
            self.hasUnsentEdit = false
            let ok = await persist(value)
            guard self.revision == rev else { return }
            self.saveState = ok ? .saved : .failed
        }
    }

    // MARK: Pointer (one gesture per block or slot: a click opens, a drag moves)

    func pointerMoved(_ source: Source, start: CGPoint, location: CGPoint) {
        if drag?.source != source {
            guard let action = action(of: source) else { return }
            drag = Drag(source: source, action: action, start: start, location: start)
        }
        guard var d = drag else { return }
        d.location = location
        if !d.moved, hypot(location.x - d.start.x, location.y - d.start.y) >= POSettingsMetrics.clickTolerance {
            d.moved = true
        }
        if d != drag { drag = d }
    }

    func pointerEnded(_ source: Source, start: CGPoint, location: CGPoint) {
        pointerMoved(source, start: start, location: location)
        guard let d = drag, d.source == source else { return }
        drag = nil
        guard d.moved else { page = .edit(d.action); return }
        guard let slots = result(of: d) else { return }
        var s = settings
        s.slots = slots
        commit(s)
    }

    func cancelDrag() { drag = nil }

    private func action(of source: Source) -> PointOutAction? {
        switch source {
        case .block(let a): return a
        case .slot(let i): return settings.slots.indices.contains(i) ? settings.slots[i] : nil
        }
    }

    /// The same angular partition as the gesture wheel, limited to the tray: off the tray is outside.
    func drop(at p: CGPoint) -> Drop {
        let dx = p.x - wheelCenter.x, dy = wheelCenter.y - p.y
        guard hypot(dx, dy) <= POSettingsMetrics.trayRadius else { return .outside }
        guard let i = POWheelLayout.slot(dx: dx, dy: dy, slots: POWheelLayout.standard(settings.slots.count),
                                         cancelRadius: POSettingsMetrics.inner) else { return .hub }
        return .slot(i)
    }

    /// The slots a drop would leave; nil when it changes nothing.
    func result(of d: Drag) -> [PointOutAction?]? {
        var slots = settings.slots
        switch (d.source, drop(at: d.location)) {
        case let (.block(a), .slot(i)):
            slots[i] = a
        case let (.slot(from), .slot(to)) where slots.indices.contains(from):
            slots.swapAt(from, to)
        case let (.slot(from), .outside) where slots.indices.contains(from):
            slots[from] = nil
        default:
            return nil
        }
        return slots == settings.slots ? nil : slots
    }

    var wheelState: WheelState {
        guard let d = drag, d.moved else { return WheelState(slots: settings.slots) }
        let preview = result(of: d)
        var target: Int?
        if case .slot(let i) = drop(at: d.location) { target = i }
        var lifted: Int?
        if case .slot(let from) = d.source {
            if target == from { target = nil }
            if preview == nil { lifted = from }
        }
        return WheelState(slots: preview ?? settings.slots, target: target, lifted: lifted)
    }

    /// The only status the panel shows: a save that did not go through. Saving and saved stay silent,
    /// because the edit is already in effect; nothing ever claims a save that failed.
    var showsSaveFailure: Bool { saveState == .failed && !isSample && drag == nil }

    /// While one function's page is open, the wheel keeps that function's slots and dims the rest.
    var focus: PointOutAction? {
        if case .edit(let action) = page { return action }
        return nil
    }

    /// 1-based slot numbers that hold `action`.
    func places(of action: PointOutAction) -> [Int] {
        settings.slots.indices.filter { settings.slots[$0] == action }.map { $0 + 1 }
    }

    func tint(_ action: PointOutAction) -> Color {
        POSwatches.token(for: action, in: settings.colors).color
    }
}

// MARK: - 原生窗口移动

/// 顶部留白拖动窗口；控件继续使用各自的 SwiftUI 手势。
struct POSettingsWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> POSettingsWindowDragView { POSettingsWindowDragView() }
    func updateNSView(_ view: POSettingsWindowDragView, context: Context) {}
}

final class POSettingsWindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Views

struct POSettingsView: View {
    static let space = "po.settings"
    @ObservedObject var model: POSettingsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let m = POSettingsMetrics.self
        // Drags are measured in this row's space. The wheel sits at its top-leading corner,
        // so the wheel center is a constant and needs no layout report.
        HStack(alignment: .top, spacing: m.columnGap) {
            VStack(spacing: 12) {
                POSettingsWheel(model: model, state: model.wheelState, focus: model.focus)
                HStack(spacing: 8) {
                    POSlotStepper(model: model)
                    POTriggerSwitch(model: model)
                }
            }
            .frame(width: m.side)
            rightColumn
                .frame(width: m.column, height: m.side)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { dragChip }
        .padding(m.padding)
        .overlay(alignment: .topLeading) {
            POSettingsWindowDragArea()
                .frame(height: m.padding)
                // 为关闭、保存失败与重试、示例标识预留空间。
                .padding(.leading, 70)
                .padding(.trailing, 180)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                POIconButton(symbol: colorScheme == .dark ? "sun.max" : "moon",
                             label: colorScheme == .dark ? "切换到浅色" : "切换到深色",
                             action: model.onToggleAppearance)
                    .accessibilityValue(colorScheme == .dark ? "当前深色" : "当前浅色")
                POIconButton(symbol: "tray.full", label: "资产看板", action: model.onShowAssets)
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) { corner.padding(10) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("轮盘设置")
        .onExitCommand {
            if model.drag != nil { model.cancelDrag() } else { model.onClose() }
        }
    }

    /// Corner status stays silent unless this is a sample or persistence failed.
    private var corner: some View {
        HStack(spacing: 6) {
            if model.isSample { POSampleBadge() }
            if model.showsSaveFailure {
                Text("没能保存")
                    .font(.system(size: 11))
                    .foregroundStyle(POPalette.inkSecondary)
                POIconButton(symbol: "arrow.clockwise", label: "重试保存", action: model.retry)
            }
            POIconButton(symbol: "creditcard", label: "订阅与用量", action: model.onShowSubscription)
                .disabled(model.isSample)
                .opacity(model.isSample ? 0.45 : 1)
            POIconButton(symbol: "xmark", label: "关闭", action: model.onClose)
        }
        .frame(height: 22)
    }

    @ViewBuilder private var rightColumn: some View {
        ZStack {
            switch model.page {
            case .functions:
                POFunctionList(model: model).transition(.opacity)
            case .edit(let action):
                POFunctionEditor(model: model, action: action).transition(.opacity)
            }
        }
        .animation(POMotion.swap, value: model.page)
    }

    @ViewBuilder private var dragChip: some View {
        if let d = model.drag, d.moved {
            POGlyph(symbol: d.action.symbol, size: POSettingsMetrics.blockIcon, color: model.tint(d.action))
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(POPalette.surface)
                        .shadow(color: POPalette.lightEdge, radius: 1.5, x: -1, y: -1)
                        .shadow(color: POPalette.darkEdge, radius: 4, x: 2, y: 3)
                }
                .position(d.location)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 与格数并排的轮盘触发开关；固定宽度避免切换文案时移动控件。
private struct POTriggerSwitch: View {
    @ObservedObject var model: POSettingsModel

    var body: some View {
        let enabled = model.settings.triggerEnabled
        Button { model.setTriggerEnabled(!enabled) } label: {
            HStack(spacing: 5) {
                Image(systemName: enabled ? "checkmark" : "minus")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
                Text(enabled ? "触发" : "不触发")
                    .font(.system(size: 11, weight: enabled ? .semibold : .medium))
                    .frame(width: 34)
            }
        }
        .buttonStyle(POTriggerButtonStyle(enabled: enabled))
        .help("\(enabled ? "关闭" : "开启")轮盘触发；Option + 右键仍可打开设置")
        .accessibilityIdentifier("wheel-trigger")
        .accessibilityLabel("轮盘触发")
        .accessibilityValue(enabled ? "触发" : "不触发")
        .accessibilityHint("仅控制轮盘触发，设置快捷键始终可用")
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }
}

private struct POTriggerButtonStyle: ButtonStyle {
    let enabled: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? POPalette.ink : POPalette.inkSecondary)
            .frame(width: 74, height: 22)
            .background {
                if enabled || configuration.isPressed { Capsule().poWellFill(depth: 1.3) }
                else { Capsule().poRaisedFill(depth: 1.3) }
            }
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(POPalette.hairline, lineWidth: 0.5) }
            }
            .contentShape(Capsule())
    }
}

/// − n 格 + in one shallow pressed capsule, under the wheel.
private struct POSlotStepper: View {
    @ObservedObject var model: POSettingsModel

    var body: some View {
        let n = model.settings.slots.count
        HStack(spacing: 0) {
            Button { model.setSlotCount(n - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(POStepStyle())
                .disabled(n <= 1)
                .accessibilityLabel("减少一格")
            Text("\(n) 格")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(POPalette.inkSecondary)
                .frame(width: 38)
                .accessibilityLabel("轮盘格数")
                .accessibilityValue("\(n) 格")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.setSlotCount(n + 1)
                    case .decrement: model.setSlotCount(n - 1)
                    @unknown default: break
                    }
                }
            Button { model.setSlotCount(n + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(POStepStyle())
                .disabled(n >= POWheelLayout.maxSlots)
                .accessibilityLabel("增加一格")
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .poWellCapsule()
    }
}

/// A bare glyph key inside the stepper: ink while held, faint at a limit.
private struct POStepStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        POStepBody(configuration: configuration)
    }
}

private struct POStepBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? POPalette.ink : POPalette.inkSecondary)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }
}

/// The settings wheel: a raised tray, one raised pad per filled slot, a shallow empty socket per empty
/// slot (nothing drawn in it, as on the gesture wheel), a pressed hub. The slot under a drag presses in
/// and its icon glows, as on the gesture wheel. On a function's page, other slots' icons dim.
private struct POSettingsWheel: View {
    @ObservedObject var model: POSettingsModel
    let state: POSettingsModel.WheelState
    let focus: PointOutAction?

    var body: some View {
        let m = POSettingsMetrics.self
        let c = m.side / 2
        ZStack {
            Circle().poRaisedFill(depth: m.trayDepth)
            ForEach(POWheelLayout.standard(state.slots.count), id: \.index) { slot in
                sector(slot, center: c)
            }
            Circle().poWellFill(depth: m.hubDepth)
                .frame(width: m.hub * 2, height: m.hub * 2)
                .accessibilityHidden(true)
            Circle().fill(POPalette.inkTertiary)
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
        }
        .frame(width: m.side, height: m.side)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("轮盘")
    }

    private func sector(_ slot: POWheelLayout.Slot, center c: CGFloat) -> some View {
        let m = POSettingsMetrics.self
        let i = slot.index
        let shown = state.slots[i]
        let committed = model.settings.slots.indices.contains(i) ? model.settings.slots[i] : nil
        let isTarget = state.target == i
        let shape = POSectorShape(slot: slot)
        let place = POWheelLayout.iconPlacement(slot, inner: m.inner, outer: m.outer, gap: m.gap, iconSize: m.icon)
        let position = CGPoint(x: c + cos(slot.mid) * place.radius, y: c - sin(slot.mid) * place.radius)
        let space = POSettingsView.space
        let opacity = state.lifted == i ? 0.35 : (focus != nil && shown != focus && !isTarget ? m.dimmed : 1)
        return ZStack {
            if shown == nil || isTarget {
                shape.poWellFill(depth: isTarget ? m.targetDepth : m.socketDepth)
            } else {
                shape.poRaisedFill(depth: m.padDepth)
            }
            if let shown {
                let tint = model.tint(shown)
                POGlyph(symbol: shown.symbol, size: m.icon * place.scale, color: tint)
                    .modifier(POGlyphDepth(glow: isTarget ? tint : nil))
                    .opacity(opacity)
                    .position(position)
            }
        }
        .contentShape(shape)
        // One gesture for click and drag, on every slot, so a slot changing during a drag keeps it.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in model.pointerMoved(.slot(i), start: v.startLocation, location: v.location) }
            .onEnded { v in model.pointerEnded(.slot(i), start: v.startLocation, location: v.location) })
        .contextMenu { slotActions(i, filled: committed != nil) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(i + 1) 格")
        .accessibilityValue(committed?.title ?? "空")
        .accessibilityAction { if let committed { model.page = .edit(committed) } }
        .accessibilityActions { slotActions(i, filled: committed != nil) }
    }

    /// The same edits without dragging: right click, or VoiceOver actions.
    @ViewBuilder private func slotActions(_ i: Int, filled: Bool) -> some View {
        ForEach(PointOutAction.allCases, id: \.self) { a in
            Button("放入\(a.title)") { model.assign(a, to: i) }
        }
        if filled { Button("移出这一格") { model.assign(nil, to: i) } }
    }
}

/// A slot of the settings wheel. The geometry is the gesture wheel's (y up), mirrored into SwiftUI (y down).
private struct POSectorShape: Shape {
    let slot: POWheelLayout.Slot

    func path(in rect: CGRect) -> Path {
        let m = POSettingsMetrics.self
        let path = POWheelLayout.sectorPath(slot, center: CGPoint(x: rect.midX, y: rect.midY),
                                            inner: m.inner, outer: m.outer, gap: m.gap)
        var flip = CGAffineTransform(translationX: 0, y: rect.midY * 2).scaledBy(x: 1, y: -1)
        return Path(path.copy(using: &flip) ?? path)
    }
}

/// A four-column library. Only available actions appear; longer libraries scroll inside this region.
private struct POFunctionList: View {
    @ObservedObject var model: POSettingsModel

    var body: some View {
        let m = POSettingsMetrics.self
        let space = POSettingsView.space
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.block), spacing: m.blockGap), count: m.libraryColumns),
                      alignment: .leading, spacing: m.blockGap) {
                ForEach(Array(model.libraryActions.enumerated()), id: \.offset) { _, action in
                    POFunctionBlock(action: action, tint: model.tint(action),
                                    pressed: model.drag?.source == .block(action))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                            .onChanged { v in model.pointerMoved(.block(action), start: v.startLocation, location: v.location) }
                            .onEnded { v in model.pointerEnded(.block(action), start: v.startLocation, location: v.location) })
                        .help("\(action.settingsDescription)\(action.settingsUsesAI ? "（AI）" : "")\n拖进轮盘，或点按查看设置")
                        .accessibilityAction { model.page = .edit(action) }
                }
            }
            .padding(m.libraryInset)
        }
        .scrollIndicators(.hidden)
        .frame(width: m.column, height: m.libraryHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能")
    }
}

/// A function key: a small raised square, the icon embossed in its color over a small name;
/// pressed in while held or dragged from.
private struct POFunctionBlock: View {
    let action: PointOutAction
    let tint: Color
    let pressed: Bool

    var body: some View {
        let m = POSettingsMetrics.self
        let shape = RoundedRectangle(cornerRadius: m.blockRadius, style: .continuous)
        VStack(spacing: 3) {
            POGlyph(symbol: action.symbol, size: m.blockIcon, color: tint)
                .modifier(POGlyphDepth(glow: nil))
            Text(action.title)
                .font(.system(size: m.blockLabel, weight: .medium))
                .foregroundStyle(pressed ? POPalette.ink : POPalette.inkSecondary)
        }
        .frame(width: m.block, height: m.block)
        .background {
            if pressed { shape.poWellFill(depth: m.blockDepth) } else { shape.poRaisedFill(depth: m.blockDepth) }
        }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityHint("\(action.settingsDescription)\(action.settingsUsesAI ? "使用 AI。" : "")拖进轮盘的格子，或打开功能设置")
        .accessibilityAddTraits(.isButton)
    }
}

/// 功能详情保留独立层次；连续选色只在点击入口后打开。
private struct POFunctionEditor: View {
    @ObservedObject var model: POSettingsModel
    let action: PointOutAction

    var body: some View {
        let m = POSettingsMetrics.self
        let places = model.places(of: action)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 7) {
                POIconButton(symbol: "chevron.left", label: "返回") { model.page = .functions }
                POFeatureToken(symbol: action.symbol, feature: action)
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(POPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(places.isEmpty ? "不在轮盘上"
                                        : "在第 \(places.map(String.init).joined(separator: "、")) 格")
                if action.settingsUsesAI {
                    Text("AI")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(POPalette.inkSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().poWellFill(depth: 0.7))
                        .accessibilityLabel("AI 功能")
                }
            }
            .frame(height: 22)
            Text(action.settingsDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(POPalette.inkSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.toggleColorEditor(for: action) } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.tint(action)).frame(width: 14, height: 14)
                    Text("换颜色").font(.system(size: 11.5, weight: .medium))
                    Spacer(minLength: 8)
                    Image(systemName: model.colorEditorAction == action ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(POPalette.inkSecondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().poRaisedFill(depth: 1.2))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(model.colorEditorAction == action ? "收起颜色选择" : "展开颜色选择")
            .accessibilityLabel("\(action.title)的颜色")
            .accessibilityValue(model.colorEditorAction == action ? "已展开" : "已收起")
        }
        .frame(width: m.editorWidth, alignment: .leading)
    }
}

extension PointOutAction {
    var settingsDescription: String {
        switch self {
        case .explain: return "把当前内容讲清楚。"
        case .translate: return "翻译当前内容，保留原意。"
        case .rewrite: return "保留原意，让表达更顺畅。"
        case .save: return "把当前内容保存到资产看板。"
        case .pickColor: return "取出屏幕上的颜色。"
        case .replyCoach: return "分析对方意图，给出合适的回复。"
        }
    }

    var settingsUsesAI: Bool {
        switch self {
        case .explain, .translate, .rewrite, .replyCoach: return true
        case .pickColor: return false
        case .save:
            #if PINPIN_APP_STORE
            return false
            #else
            return true
            #endif
        }
    }
}

/// Shared symbol image for settings, wheel, markers and cards; the brain is an original line path.
struct POGlyph: View {
    let symbol: String
    let size: CGFloat
    var weight: NSFont.Weight = .medium
    let color: Color

    var body: some View {
        Image(nsImage: Self.image(symbol, size: size, weight: weight))
            .renderingMode(.template)
            .foregroundStyle(color)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ symbol: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        let key = "\(symbol)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let image: NSImage
        if symbol == "pinpin.brain" {
            image = brain(size: size)
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// R181: two soft hemispheres and three interior strokes, shared with the Windows 16-unit path.
    private static func brain(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size / 16, y: size / 16)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 8, y: 3))
            path.addCurve(to: CGPoint(x: 4, y: 3), control1: CGPoint(x: 7, y: 1), control2: CGPoint(x: 4.5, y: 1))
            path.addCurve(to: CGPoint(x: 2.5, y: 6.5), control1: CGPoint(x: 2, y: 3), control2: CGPoint(x: 1.5, y: 5))
            path.addCurve(to: CGPoint(x: 3.5, y: 11), control1: CGPoint(x: 1, y: 8), control2: CGPoint(x: 1.5, y: 10.5))
            path.addCurve(to: CGPoint(x: 7, y: 13), control1: CGPoint(x: 3, y: 13), control2: CGPoint(x: 5.5, y: 14.5))
            path.addCurve(to: CGPoint(x: 8, y: 12), control1: CGPoint(x: 7.5, y: 13.8), control2: CGPoint(x: 8, y: 13.5))
            path.addCurve(to: CGPoint(x: 9, y: 13), control1: CGPoint(x: 8, y: 13.5), control2: CGPoint(x: 8.5, y: 13.8))
            path.addCurve(to: CGPoint(x: 12.5, y: 11), control1: CGPoint(x: 10.5, y: 14.5), control2: CGPoint(x: 13, y: 13))
            path.addCurve(to: CGPoint(x: 13.5, y: 6.5), control1: CGPoint(x: 14.5, y: 10.5), control2: CGPoint(x: 15, y: 8))
            path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 14.5, y: 5), control2: CGPoint(x: 14, y: 3))
            path.addCurve(to: CGPoint(x: 8, y: 3), control1: CGPoint(x: 11.5, y: 1), control2: CGPoint(x: 9, y: 1))
            path.addLine(to: CGPoint(x: 8, y: 12))
            path.move(to: CGPoint(x: 4, y: 5))
            path.addQuadCurve(to: CGPoint(x: 6, y: 7), control: CGPoint(x: 6, y: 5))
            path.move(to: CGPoint(x: 12, y: 9))
            path.addQuadCurve(to: CGPoint(x: 10, y: 11), control: CGPoint(x: 10, y: 9))
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.35)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
            return true
        }
    }
}

/// Embossed at rest (lit top-left edge, soft shade down-right); a soft glow in its own color when pointed.
private struct POGlyphDepth: ViewModifier {
    let glow: Color?

    func body(content: Content) -> some View {
        if let glow {
            content.shadow(color: glow.opacity(0.7), radius: 4)
        } else {
            content
                .shadow(color: POPalette.lightEdge, radius: 0, x: -0.6, y: -0.6)
                .shadow(color: POPalette.darkEdge, radius: 0.8, x: 0.7, y: 0.7)
        }
    }
}
