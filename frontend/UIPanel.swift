import AppKit
import SwiftUI

// MARK: - Non-activating floating panel (design-system.md §12)

/// Borderless panel that never activates PointOut. It becomes key only when a text field
/// actually needs keyboard input (`becomesKeyOnlyIfNeeded`).
final class POPanel: NSPanel {
    #if PINPIN_UI_TESTING
    /// 外观传播检查需创建隐藏的原生窗口设备；仍由 presentsOnScreen 禁止上屏。
    static var testDefersWindowCreation = true
    #endif
    var allowsKey = false
    /// 离屏验证禁止任何窗口上屏或获得键盘焦点。
    var presentsOnScreen = true
    override var canBecomeKey: Bool { allowsKey && presentsOnScreen }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        #if PINPIN_UI_TESTING
        POUIPerformance.count("orderFront")
        #endif
        if presentsOnScreen { super.orderFrontRegardless() }
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if presentsOnScreen || place == .out { super.order(place, relativeTo: otherWin) }
    }

    /// - Parameters:
    ///   - interactive: false for the wheel (the host forwards the pointer). When true,
    ///     `ignoresMouseEvents` is left at its default, so fully transparent pixels pass clicks
    ///     through to the app below (markers rely on this).
    ///   - allSpaces: true for transient surfaces; false for markers, which stay on their Space.
    static func make(level: NSWindow.Level, interactive: Bool, allSpaces: Bool = true,
                     presentsOnScreen: Bool = true) -> POPanel {
        #if PINPIN_UI_TESTING
        let defersWindowCreation = testDefersWindowCreation
        #else
        let defersWindowCreation = true
        #endif
        let panel = POPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: defersWindowCreation)
        #if PINPIN_UI_TESTING
        POUIPerformance.count("panelCreated")
        #endif
        panel.level = level
        panel.presentsOnScreen = presentsOnScreen
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The window server draws the same soft shadow as system menus and popovers,
        // following the visible (masked) shape.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            : [.fullScreenAuxiliary, .ignoresCycle]
        if !interactive { panel.ignoresMouseEvents = true }
        panel.allowsKey = interactive
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

// MARK: - Neumorphic slab (design-system.md §3)

/// The opaque matte surface every floating window is made of. Its rounded alpha shape also gives
/// the window server's soft drop shadow, so the slab lifts off whatever page is behind it.
final class POSurfaceView: NSView {
    let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = POColor.surface.cg(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension CAGradientLayer {
    /// Diagonal bevel: light at the start fading out by the middle, shade fading in toward the end.
    /// Each fade goes to the same color at zero alpha, never to `clear` (black at zero alpha),
    /// so the middle stays the surface itself instead of a gray band.
    func setBevel(light: CGColor, dark: CGColor) {
        colors = [light, light.copy(alpha: 0) ?? light, dark.copy(alpha: 0) ?? dark, dark]
        locations = [0, 0.48, 0.52, 1]
    }
}

/// The slab's bevel: light along the top-left edge, shade along the bottom-right, inside a hairline.
final class POBorderView: NSView {
    let radius: CGFloat
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.5
        rim.mask = rimMask
        // Layer y points up: top left to bottom right.
        rim.startPoint = CGPoint(x: 0, y: 1)
        rim.endPoint = CGPoint(x: 1, y: 0)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rim.superlayer == nil { layer?.addSublayer(rim) }
        rim.frame = bounds
        rimMask.frame = bounds
        let r = max(radius - 1.25, 0)
        rimMask.path = CGPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
    }

    override func updateLayer() {
        let a = effectiveAppearance
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = POColor.hairline.cg(a)
        rim.setBevel(light: POColor.lightEdge.cg(a), dark: POColor.darkEdge.cg(a))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Accepts the first click, so buttons work without activating PointOut.
final class POHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Hover tracking

final class POTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var inside = false

    /// A card can open under a pointer that does not move (it grows out of the ball the pointer
    /// rests on). AppKit sends no mouseEntered then, so the real position is checked here.
    override func updateTrackingAreas() {
        #if PINPIN_UI_TESTING
        POUIPerformance.count("cardTracking")
        #endif
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let now = window.map { $0.isVisible && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if now { options.insert(.assumeInside) }
        let newArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newArea)
        area = newArea
        if now != inside { report(now) }
    }

    func resetHover() { inside = false }

    private func report(_ value: Bool) {
        inside = value
        onHover?(value)
    }

    override func mouseEntered(with event: NSEvent) { if !inside { report(true) } }
    override func mouseExited(with event: NSEvent) { if inside { report(false) } }
}

// MARK: - Content size reporting (design-system.md §12, 窗口尺寸)

struct POSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Receives the content size from SwiftUI and hands it to the window outside the SwiftUI update
/// and layout pass: one coalesced main-actor hop per burst of changes (a streaming chunk, an
/// expand, a tag added). The window never resizes itself from inside SwiftUI.
@MainActor final class POSizeSink {
    private(set) var latest: CGSize = .zero
    var onChange: () -> Void = {}
    private var scheduled = false

    var hasMeasurement: Bool { latest.width > 1 && latest.height > 1 }
    #if PINPIN_UI_TESTING
    var testScheduled: Bool { scheduled }
    #endif

    func report(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != latest else { return }
        latest = size
        guard !scheduled else { return }
        scheduled = true
        #if PINPIN_UI_TESTING
        POUIPerformance.count("sizeTask")
        #endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.onChange()
        }
    }
}

/// Root of every floating window.
/// - The content is measured from its own ideal size, never from the window's current size, so the
///   measurement cannot be held at whatever height the window happens to have.
/// - The content is pinned to the top-leading corner. While the window is still catching up with a
///   new size, overflow can only fall off the bottom, never off the header and close button.
/// - Two independent signals feed the same sink: the layout pass and a geometry preference. Both
///   carry the same value; the sink drops duplicates.
struct POFloatingRoot<Content: View>: View {
    let sink: POSizeSink
    let content: Content

    var body: some View {
        POTopAnchoredLayout(sink: sink) {
            content
                .background(GeometryReader { g in
                    Color.clear.preference(key: POSizeKey.self, value: g.size)
                })
                .onPreferenceChange(POSizeKey.self) { size in
                    MainActor.assumeIsolated { sink.report(size) }
                }
        }
    }
}

/// Fills the hosting view and places its single child from the top edge at the child's own size.
///
/// The ideal size (open proposal) is the natural size. The child is then placed with that size as
/// a concrete proposal, so flexible frames inside get a definite size. Height-capped content
/// (POCappedScroll) takes its height from its own content, so the open-height pass is already
/// exact; nothing inside may depend on how tall the window currently is.
struct POTopAnchoredLayout: Layout {
    let sink: POSizeSink

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let ideal = content.sizeThatFits(.unspecified)
        let concrete = ProposedViewSize(ideal)
        let fitted = content.sizeThatFits(concrete)
        content.place(at: bounds.origin, anchor: .topLeading, proposal: concrete)
        let sink = self.sink
        MainActor.assumeIsolated { sink.report(fitted) }
    }
}

// MARK: - Floating material window: top-anchored; size follows content like a popover

@MainActor final class POFloatingWindow {
    let panel: POPanel
    let container: POTrackingView
    /// Returns the window origin for a given window size.
    var placement: (CGSize) -> NSPoint = { _ in .zero }
    /// Called after the panel is fully ordered out, so content can stop running animations.
    var onHidden: (() -> Void)?
    private(set) var isVisible = false

    private let radius: CGFloat
    private let sink = POSizeSink()
    private var hosting: NSView?
    private var visibilityGeneration = 0
    private var discarded = false

    /// The frame the window must end at: the last one asked for, animated or not.
    private var targetFrame = NSRect.zero
    private var frameGeneration = 0
    /// Generation of the frame animation still running, if any.
    private var animatingFrame: Int?
    /// True when the window appeared before SwiftUI reported any size; the first report is then
    /// applied at once instead of animating from a guess.
    private var awaitingFirstFit = false

    /// Used only until the content reports its first size.
    private static let provisionalSize = CGSize(width: POMetrics.cardWidth, height: 80)

    init(level: NSWindow.Level, radius: CGFloat = POMetrics.cardRadius, allSpaces: Bool = true,
         presentsOnScreen: Bool = true) {
        self.radius = radius
        panel = POPanel.make(level: level, interactive: true, allSpaces: allSpaces, presentsOnScreen: presentsOnScreen)
        container = POTrackingView(frame: NSRect(origin: .zero, size: Self.provisionalSize))
        container.autoresizingMask = [.width, .height]

        let backdrop = POSurfaceView(radius: radius)
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        panel.contentView = container

        sink.onChange = { [weak self] in self?.contentSizeChanged() }
    }

    func setContent<V: View>(_ view: V) {
        let host = POHostingView(rootView: POFloatingRoot(sink: sink, content: view))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        hosting = host

        let border = POBorderView(radius: radius)
        border.frame = container.bounds
        border.autoresizingMask = [.width, .height]
        container.addSubview(border)
    }

    /// A position changed outside layout (e.g. native dragging) remains relative to its source.
    /// An in-flight size animation is not a user offset.
    var externalPositionOffset: CGVector {
        guard animatingFrame == nil, !targetFrame.isEmpty else { return .zero }
        return CGVector(dx: panel.frame.minX - targetFrame.minX, dy: panel.frame.minY - targetFrame.minY)
    }

    /// Re-applies placement at the current content size, without animation.
    func relayout() {
        applyFrame(animated: false)
    }

    /// Opacity-only, like a system popover. While visible, a call at the same place animates any
    /// size change (streaming); a call whose placement moved (a new anchor) moves the window at once.
    func show() {
        #if PINPIN_UI_TESTING
        POUIPerformance.count("show")
        #endif
        guard !discarded else { return }
        visibilityGeneration += 1
        measureNow()
        if isVisible {
            applyFrame(animated: !placementMoved)
        } else {
            awaitingFirstFit = !sink.hasMeasurement
            applyFrame(animated: false)
            isVisible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        let panel = self.panel
        #if PINPIN_UI_TESTING
        POUIPerformance.count("showFade")
        #endif
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = POMotion.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        container.resetHover()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let panel = self.panel
        if panel.isKeyWindow { panel.resignKey() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = POMotion.hideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                guard self.visibilityGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.onHidden?()
                if self.discarded { self.panel.close() }
            }
        })
    }

    /// 结果已遗忘时，淡出后释放原生窗口；普通收起保留窗口以便再次打开。
    func dispose() {
        discarded = true
        if isVisible { hide() }
        else if !panel.isVisible { panel.close() }
    }

    // MARK: Sizing

    /// Lets SwiftUI lay out pending model changes now, so the root reports the current size
    /// before the window is placed.
    private func measureNow() {
        guard let hosting else { return }
        #if PINPIN_UI_TESTING
        POUIPerformance.count("forcedLayout")
        #endif
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
    }

    /// Content size rounded up to whole points, so no fractional row of text is ever cut.
    private var fittedSize: CGSize {
        guard sink.hasMeasurement else {
            return targetFrame.isEmpty ? Self.provisionalSize : targetFrame.size
        }
        return CGSize(width: ceil(sink.latest.width), height: ceil(sink.latest.height))
    }

    /// True when placement now puts the current size somewhere else (the anchor changed).
    private var placementMoved: Bool {
        guard !targetFrame.isEmpty else { return true }
        let size = targetFrame.size
        return !Self.same(NSRect(origin: placement(size), size: size), targetFrame)
    }

    private func contentSizeChanged() {
        let animated = !awaitingFirstFit
        awaitingFirstFit = false
        applyFrame(animated: animated)
    }

    /// Moves the window to placement(content size). Always compares with the window's real frame,
    /// so a change that was dropped is applied again instead of being treated as done.
    private func applyFrame(animated: Bool) {
        let size = fittedSize
        let frame = NSRect(origin: placement(size), size: size)
        if Self.same(frame, targetFrame), animatingFrame != nil || Self.same(panel.frame, frame) { return }

        #if PINPIN_UI_TESTING
        POUIPerformance.count("frameChange")
        #endif
        targetFrame = frame
        frameGeneration += 1
        let generation = frameGeneration
        let panel = self.panel

        if animated, isVisible, !POMotion.reduceMotion {
            animatingFrame = generation
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = POMotion.resizeDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.frameAnimationEnded(generation) }
            })
        } else {
            if animatingFrame != nil {
                // Replace the running frame animation instead of racing it.
                animatingFrame = nil
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    panel.animator().setFrame(frame, display: true)
                }
            }
            panel.setFrame(frame, display: true)
            frameSettled()
        }
    }

    private func frameAnimationEnded(_ generation: Int) {
        if animatingFrame == generation { animatingFrame = nil }
        guard animatingFrame == nil else { return }
        // If the animator dropped or overrode the change, land on the target directly.
        if !Self.same(panel.frame, targetFrame) { panel.setFrame(targetFrame, display: true) }
        frameSettled()
    }

    private func frameSettled() {
        panel.invalidateShadow()
        container.updateTrackingAreas()
    }

    private static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    #if PINPIN_UI_TESTING
    var testHasFrameAnimation: Bool { animatingFrame != nil }
    var testHasPendingSizeWork: Bool { sink.testScheduled }
    #endif

    // MARK: Placement helpers

    /// Screen that contains a global AppKit point, falling back to the main screen.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A result card grows up out of its ball (R103): the bottom edge stays where the ball is, so
    /// streaming, expanding into the dialog and follow-ups all grow upward. Leading edge at the ball,
    /// flipped to end at the ball near the right edge; moved down only if the top would leave the screen.
    static func growingUp(from ball: CGRect, windowSize: CGSize) -> NSPoint {
        let w = windowSize.width, h = windowSize.height
        guard let screen = screen(containing: CGPoint(x: ball.midX, y: ball.midY)) else { return ball.origin }
        let visible = screen.visibleFrame.insetBy(dx: POMetrics.screenInset, dy: POMetrics.screenInset)
        var x = ball.minX
        if x + w > visible.maxX { x = ball.maxX - w }
        x = min(max(x, visible.minX), visible.maxX - w)
        var y = max(ball.minY, visible.minY)
        if y + h > visible.maxY { y = visible.maxY - h }
        return NSPoint(x: x, y: max(y, visible.minY))
    }

    /// Places a surface beside the wheel: right of the press point, else left; clamped to the screen.
    static func besideAnchor(_ anchor: CGPoint, windowSize: CGSize) -> NSPoint {
        let w = windowSize.width, h = windowSize.height
        guard let screen = screen(containing: anchor) else { return anchor }
        let visible = screen.visibleFrame.insetBy(dx: POMetrics.screenInset, dy: POMetrics.screenInset)

        var x = anchor.x + POMetrics.cardOffsetX
        if x + w > visible.maxX { x = anchor.x - POMetrics.cardOffsetX - w }
        x = min(max(x, visible.minX), visible.maxX - w)

        var top = min(anchor.y + POMetrics.cardOffsetY, visible.maxY)
        if top - h < visible.minY { top = visible.minY + h }
        return NSPoint(x: x, y: top - h)
    }
}
