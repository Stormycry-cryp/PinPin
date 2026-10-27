import AppKit
import QuartzCore

// MARK: - Result balls (design-system.md §8)
//
// Every result rests as a small ball where its action happened (R103). The ball shows the marker's
// attributes (R104): what the action was, and whether it is still working or done. Resting
// on it for 1s opens the short card; a click opens the dialog. Hover also shows a close badge for
// that ball. Option + double-click (host gesture) clears every ball. Balls follow their source
// window through host updates and are removed when that source closes.
// Nothing is persisted.

/// What a ball shows besides its action glyph.
enum POBallState: Equatable { case working, done }

enum POMarkerStyle {
    static let windowSide: CGFloat = 32
    static let discCenter = CGPoint(x: 14, y: 14)
    static let discRadius: CGFloat = 10
    static let badgeCenter = CGPoint(x: 25, y: 25)
    static let badgeRadius: CGFloat = 6
    /// The ball sits up and right of the press point, above the pointed line, so neither the ball
    /// nor the card that grows up out of it covers the pointed word.
    static let offset = CGVector(dx: 10, dy: 19)
    /// The card's corner sits this far below-left of the ball center, so its rounded corner covers
    /// the whole ball and the pointer resting on the ball is already on the card.
    static let cardCornerInset: CGFloat = 10
    /// Working indicator: a short arc in a groove on the ball's face, around the glyph.
    static let ringRadius: CGFloat = 7.3


    @MainActor static func symbolMask(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> CALayer {
        let mask = CALayer()
        let image = POGlyph.image(name, size: pointSize, weight: weight)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        mask.contents = image.layerContents(forContentsScale: scale)
        mask.contentsScale = scale
        mask.contentsGravity = .resizeAspect
        mask.frame = CGRect(origin: .zero, size: image.size)
        return mask
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }
}

/// One ball: a raised matte pebble of the panel surface with the function's colored glyph (R128);
/// a raised close badge on hover.
/// Only the visible pixels take clicks; the rest of the small window passes clicks through.
final class POMarkerView: NSView {
    var onOpen: () -> Void = {}
    var onPeek: () -> Void = {}
    var onClose: () -> Void = {}
    let feature: POFeature
    private(set) var ballState: POBallState = .working

    private let content = CALayer()
    private let disc = CAShapeLayer()
    /// Convex face: lighter toward the top left, deeper toward the bottom right.
    private let dome = CAGradientLayer()
    private let domeMask = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let glyph = CALayer()
    private let ring = CAShapeLayer()
    private var peekTask: Task<Void, Never>?
    private var animationVisible = false
    private let badge = CALayer()
    private let badgeDisc = CAShapeLayer()
    private let badgeGlyph = CALayer()
    private var area: NSTrackingArea?
    private var hovering = false
    private enum Part { case disc, badge }
    private var pressed: Part?

    init(feature: POFeature) {
        self.feature = feature
        let side = POMarkerStyle.windowSide
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        guard let root = layer else { return }
        let side = POMarkerStyle.windowSide
        let c = POMarkerStyle.discCenter, r = POMarkerStyle.discRadius
        // Scale animations pivot on the disc center, where the action happened.
        content.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        content.anchorPoint = CGPoint(x: c.x / side, y: c.y / side)
        content.position = c
        root.addSublayer(content)

        // Only the dark shade falls outside the disc, so clicks a few points away still reach the app.
        let discPath = POMarkerStyle.circle(c, r)
        disc.frame = content.bounds
        disc.path = discPath
        disc.lineWidth = 0.5
        disc.shadowPath = discPath
        disc.shadowOpacity = 1
        disc.shadowRadius = 2.2
        disc.shadowOffset = CGSize(width: 1.2, height: -1.6)
        content.addSublayer(disc)

        dome.frame = content.bounds
        domeMask.frame = content.bounds
        domeMask.path = discPath
        dome.mask = domeMask
        // Layer y points up: from the disc's top-left to its bottom-right.
        dome.startPoint = CGPoint(x: (c.x - r * 0.75) / side, y: (c.y + r * 0.75) / side)
        dome.endPoint = CGPoint(x: (c.x + r * 0.75) / side, y: (c.y - r * 0.75) / side)
        content.addSublayer(dome)

        outline.frame = content.bounds
        outline.path = discPath
        outline.fillColor = nil
        outline.lineWidth = 0.8
        content.addSublayer(outline)

        glyph.position = c
        content.addSublayer(glyph)

        // Rotates about the ball center.
        ring.bounds = content.bounds
        ring.anchorPoint = CGPoint(x: c.x / side, y: c.y / side)
        ring.position = c
        ring.path = POMarkerStyle.circle(c, POMarkerStyle.ringRadius)
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        ring.strokeEnd = 0.28
        content.addSublayer(ring)

        let b = POMarkerStyle.badgeCenter, br = POMarkerStyle.badgeRadius
        let badgePath = POMarkerStyle.circle(b, br)
        badge.frame = content.bounds
        badge.opacity = 0
        badgeDisc.frame = content.bounds
        badgeDisc.path = badgePath
        badgeDisc.lineWidth = 0.5
        badgeDisc.shadowPath = badgePath
        badgeDisc.shadowOpacity = 1
        badgeDisc.shadowRadius = 1.4
        badgeDisc.shadowOffset = CGSize(width: 0.8, height: -1)
        badge.addSublayer(badgeDisc)
        let xMask = POMarkerStyle.symbolMask("xmark", pointSize: 6.5, weight: .bold)
        badgeGlyph.bounds = xMask.bounds
        badgeGlyph.position = b
        badgeGlyph.mask = xMask
        badge.addSublayer(badgeGlyph)
        content.addSublayer(badge)
        applyColors()
        applyState()
    }

    func setState(_ state: POBallState) {
        guard state != ballState else { return }
        ballState = state
        applyState()
    }

    /// Glyph and working ring for the current state. Also restarts the spin after the ball was ordered out.
    func applyState() {
        #if PINPIN_UI_TESTING
        POUIPerformance.count("markerApplyState")
        #endif
        let mask = POMarkerStyle.symbolMask(feature.symbol, pointSize: 8, weight: .bold)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = mask.bounds
        glyph.mask = mask
        ring.isHidden = ballState != .working
        CATransaction.commit()
        ring.removeAnimation(forKey: "spin")
        guard animationVisible, ballState == .working, !POMotion.reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        #if PINPIN_UI_TESTING
        POUIPerformance.count("markerSpinStart")
        #endif
        ring.add(spin, forKey: "spin")
    }

    func setAnimationVisible(_ visible: Bool) {
        animationVisible = visible
        if visible { applyState() }
        else { ring.removeAnimation(forKey: "spin"); resetHover() }
    }

    /// Also called when the function colors change in settings (R145): layer colors only, no re-show.
    func applyColors() {
        let a = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.fillColor = POColor.surface.cg(a)
        disc.strokeColor = POColor.hairline.cg(a)
        disc.shadowColor = POColor.darkEdge.cg(a)
        // Matte, not glossy: the shade side is half the panel bevel's strength.
        let shade = POColor.darkEdge.cg(a)
        dome.setBevel(light: POColor.lightEdge.cg(a), dark: shade.copy(alpha: shade.alpha * 0.5) ?? shade)
        // The function's own color (R128), the same as on the wheel and the card.
        glyph.backgroundColor = feature.tint.cg(a)
        outline.strokeColor = feature.tint.cg(a)
        ring.strokeColor = feature.tint.cg(a)
        badgeDisc.fillColor = POColor.surface.cg(a)
        badgeDisc.strokeColor = POColor.hairline.cg(a)
        badgeDisc.shadowColor = POColor.darkEdge.cg(a)
        badgeGlyph.backgroundColor = POColor.inkSecondary.cg(a)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    #if PINPIN_UI_TESTING
    var testGlyphColor: CGColor? { glyph.backgroundColor }
    #endif

    /// Pops in from the press point (scale 0.6 to 1); the window fade covers reduce motion.
    func animateIn() {
        guard !POMotion.reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 1
        scale.duration = 0.18
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        content.add(scale, forKey: "in")
    }

    // MARK: Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                     owner: self, userInfo: nil)
        addTrackingArea(newArea)
        area = newArea
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    /// Resting on the ball for 1s opens its short card (R103).
    private func setHover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        badge.opacity = inside ? 1 : 0
        CATransaction.commit()
        peekTask?.cancel()
        peekTask = nil
        guard inside else { return }
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(POMotion.peekDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.hovering else { return }
            self.onPeek()
        }
    }

    /// Called when the ball shows again after its card closed: no stale badge or pending peek.
    func resetHover() {
        peekTask?.cancel()
        peekTask = nil
        hovering = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.opacity = 0
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func part(at event: NSEvent) -> Part? {
        let p = convert(event.locationInWindow, from: nil)
        let b = POMarkerStyle.badgeCenter, c = POMarkerStyle.discCenter
        if hovering, hypot(p.x - b.x, p.y - b.y) <= POMarkerStyle.badgeRadius + 2 { return .badge }
        if hypot(p.x - c.x, p.y - c.y) <= POMarkerStyle.discRadius + 3 { return .disc }
        return nil
    }

    private func setPressed(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.opacity = on ? 0.7 : 1
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        peekTask?.cancel()
        peekTask = nil
        pressed = part(at: event)
        if pressed == .disc { setPressed(true) }
    }

    /// Acts on release inside the same part, like system buttons.
    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        defer { pressed = nil }
        guard let pressed, part(at: event) == pressed else { return }
        switch pressed {
        case .disc: onOpen()
        case .badge: onClose()
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(feature.title)标注" }
    override func accessibilityValue() -> Any? {
        switch ballState {
        case .working: return "正在生成"
        case .done: return "已完成"
        }
    }
    override func accessibilityHelp() -> String? { "按下打开对话框" }
    override func accessibilityPerformPress() -> Bool { onOpen(); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "预览") { [weak self] in
            MainActor.assumeIsolated { self?.onPeek() }
            return true
        },
         NSAccessibilityCustomAction(name: "关闭标注") { [weak self] in
            MainActor.assumeIsolated { self?.onClose() }
            return true
        }]
    }
}

/// Owns every retained result ball until explicit removal or source destruction.
@MainActor final class POMarkerController {
    struct Marker {
        let id: UUID
        let feature: POFeature
        var point: CGPoint
        /// App the marker was made in; 0 when unknown (then it is always shown).
        let owner: pid_t
        let sample: Bool
        let panel: POPanel
        let view: POMarkerView
    }

    var onOpen: (UUID) -> Void = { _ in }
    var onPeek: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    /// A marker removed because its source app quit. `remove`/`removeAll` never report.
    var onRemoved: (UUID) -> Void = { _ in }
    private(set) var markers: [Marker] = []
    private let presentsOnScreen: Bool
    private var observers: [NSObjectProtocol] = []
    /// Balls hidden because their card is open.
    private var suppressed = Set<UUID>()
    /// Balls hidden by the source window state supplied by the host.
    private var hiddenBySource = Set<UUID>()

    init(presentsOnScreen: Bool = true) {
        self.presentsOnScreen = presentsOnScreen
        guard presentsOnScreen else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.appTerminated(pid) }
        })

    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isEmpty: Bool { markers.isEmpty }

    func marker(_ id: UUID) -> Marker? { markers.first { $0.id == id } }

    func isHiddenBySource(_ id: UUID) -> Bool { hiddenBySource.contains(id) }

    /// `id` is the result id; `point` the frozen press point (AppKit global); `owner` the target app's process.
    func add(_ id: UUID, feature: POFeature, at point: CGPoint, owner: pid_t, sample: Bool = false) {
        remove(id)
        let view = POMarkerView(feature: feature)
        view.onOpen = { [weak self] in self?.onOpen(id) }
        view.onPeek = { [weak self] in self?.onPeek(id) }
        view.onClose = { [weak self] in self?.onClose(id) }

        // Markers stay on their own Space, below cards and the wheel, and never take key status.
        let panel = POPanel.make(level: .floating, interactive: true, allSpaces: false,
                                presentsOnScreen: presentsOnScreen)
        panel.allowsKey = false
        panel.hasShadow = false
        panel.contentView = view
        let side = POMarkerStyle.windowSide
        panel.setFrame(NSRect(origin: Self.origin(for: point), size: CGSize(width: side, height: side)), display: false)
        markers.append(Marker(id: id, feature: feature, point: point, owner: owner, sample: sample,
                              panel: panel, view: view))
        // A new marker is always shown, even when its app is in the background (Option + click
        // does not activate the target app).
        fadeIn(panel)
        view.animateIn()
    }

    private func drop(_ id: UUID) {
        guard marker(id) != nil else { return }
        remove(id)
        onRemoved(id)
    }

    /// Idempotent.
    func remove(_ id: UUID) {
        suppressed.remove(id)
        hiddenBySource.remove(id)
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let m = markers.remove(at: i)
        fadeOut([m.panel], discard: true)
    }

    func removeAll() {
        let panels = markers.map(\.panel)
        markers.removeAll()
        suppressed.removeAll()
        hiddenBySource.removeAll()
        fadeOut(panels, discard: true)
    }

    func setState(_ id: UUID, _ state: POBallState) {
        marker(id)?.view.setState(state)
    }

    /// The function colors changed (R145): every ball takes its new color in place.
    func recolor() {
        for m in markers { m.view.applyColors() }
    }

    /// The ball hides while its card is open: the card is the ball, grown up (R103).
    func setSuppressed(_ id: UUID, _ hidden: Bool) {
        guard let m = marker(id) else { return }
        if hidden {
            guard suppressed.insert(id).inserted else { return }
            fadeOut([m.panel])
        } else {
            guard suppressed.remove(id) != nil else { return }
            m.view.resetHover()
            if !hiddenBySource.contains(id) { fadeIn(m.panel); m.view.applyState() }
        }
    }

    /// Center of the ball for a press point (AppKit global).
    static func ballCenter(for point: CGPoint) -> CGPoint {
        let o = origin(for: point)
        return CGPoint(x: o.x + POMarkerStyle.discCenter.x, y: o.y + POMarkerStyle.discCenter.y)
    }

    /// The square the card grows out of: its corner covers the ball.
    static func ballRect(for point: CGPoint) -> CGRect {
        let c = ballCenter(for: point), r = POMarkerStyle.cardCornerInset
        return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    // MARK: Lifecycle

    /// Absolute source coordinates prevent drift when repeated events describe the same position.
    func updateSource(_ id: UUID, at point: CGPoint, visible: Bool) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        let wasHidden = hiddenBySource.contains(id)
        if markers[index].point != point {
            markers[index].point = point
            markers[index].panel.setFrameOrigin(Self.origin(for: point))
        }
        let marker = markers[index]
        if visible {
            hiddenBySource.remove(id)
            if wasHidden, !suppressed.contains(id) { fadeIn(marker.panel) }
        } else {
            hiddenBySource.insert(id)
            if !wasHidden { fadeOut([marker.panel]) }
        }
    }

    private func appTerminated(_ pid: pid_t?) {
        guard let pid else { return }
        for m in markers where m.owner == pid { drop(m.id) }
    }

    // MARK: Motion

    private func fadeIn(_ panel: POPanel) {
        (panel.contentView as? POMarkerView)?.setAnimationVisible(true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = POMotion.reduceMotion ? 0.1 : 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fades panels out, then orders them out. A panel faded back in meanwhile (its app was
    /// activated again) keeps its target alpha of 1 and stays.
    private func fadeOut(_ panels: [POPanel], discard: Bool = false) {
        guard !panels.isEmpty else { return }
        for panel in panels { (panel.contentView as? POMarkerView)?.setAnimationVisible(false) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = POMotion.reduceMotion ? 0.08 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for p in panels { p.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                for p in panels where p.alphaValue == 0 {
                    p.orderOut(nil)
                    if discard { p.close() }
                }
            }
        })
    }

    /// Window origin: pin up-right of the point, flipped inward at screen edges.
    static func origin(for point: CGPoint) -> NSPoint {
        let side = POMarkerStyle.windowSide
        let c = POMarkerStyle.discCenter
        var center = CGPoint(x: point.x + POMarkerStyle.offset.dx, y: point.y + POMarkerStyle.offset.dy)
        if let f = POFloatingWindow.screen(containing: point)?.frame {
            if center.x - c.x + side > f.maxX { center.x = point.x - POMarkerStyle.offset.dx }
            if center.y - c.y + side > f.maxY { center.y = point.y - POMarkerStyle.offset.dy }
            center.x = min(max(center.x, f.minX + c.x), f.maxX - side + c.x)
            center.y = min(max(center.y, f.minY + c.y), f.maxY - side + c.y)
        }
        return NSPoint(x: center.x - c.x, y: center.y - c.y)
    }
}
