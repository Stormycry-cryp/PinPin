import AppKit
import QuartzCore

/// Wheel content view; exposes the wheel to assistive technologies.
/// Children are informational only: no press actions, because the wheel is driven by the
/// host gesture and unavailable features must not offer executable actions.
final class POWheelView: NSView {
    var sectorElements: [NSAccessibilityElement] = []
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { "功能轮盘" }
    override func accessibilityLabel() -> String? { "PinPin 功能轮盘" }
    override func accessibilityChildren() -> [Any]? { sectorElements }
    override func accessibilitySelectedChildren() -> [Any]? {
        sectorElements.filter { $0.isAccessibilitySelected() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Layout shared by the on-screen wheel and the settings wheel (design-system.md §8, §21)

/// Pure geometry. Angles in radians, counter-clockwise from +x, y up.
enum POWheelLayout {
    static let maxSlots = 8

    /// One sector placement for `WheelSettings.slots[index]`.
    struct Slot: Equatable {
        let index: Int
        let mid: CGFloat
        let half: CGFloat
    }

    /// The first slot is centered on top, the rest follow clockwise at equal widths.
    /// Four slots give the original layout: top, right, bottom, left.
    static func standard(_ count: Int) -> [Slot] {
        let n = min(max(count, 1), maxSlots)
        let width = 2 * CGFloat.pi / CGFloat(n)
        return (0..<n).map { Slot(index: $0, mid: .pi / 2 - CGFloat($0) * width, half: width / 2) }
    }

    /// The wheel always stays centered on the press point (press-and-release in place stays in the
    /// cancel zone; the frozen origin is untouched). If part of the ring would fall outside every
    /// screen, the slots are fanned evenly across the longest on-screen arc instead, keeping
    /// clockwise order and the rotation closest to the standard layout.
    static func slots(count: Int, around p: CGPoint, screens: [CGRect], ringRadius r: CGFloat,
                      minSpan: CGFloat) -> [Slot] {
        let n = min(max(count, 1), maxSlots)
        let stepDeg = 2
        let samples = 360 / stepDeg
        var ok = [Bool](repeating: false, count: samples)
        for i in 0..<samples {
            let a = CGFloat(i * stepDeg) * .pi / 180
            let q = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            ok[i] = screens.contains { $0.contains(q) }
        }
        guard let firstOff = ok.firstIndex(of: false), ok.contains(true) else { return standard(n) }

        // Longest circular run of on-screen samples, scanning from just after an off-screen one.
        var bestStart = 0, bestLen = 0, runStart = 0, runLen = 0
        for k in 1...samples {
            let idx = (firstOff + k) % samples
            if ok[idx] {
                if runLen == 0 { runStart = idx }
                runLen += 1
                if runLen > bestLen { bestLen = runLen; bestStart = runStart }
            } else {
                runLen = 0
            }
        }
        var start = CGFloat(bestStart * stepDeg) * .pi / 180
        var span = CGFloat(max(bestLen - 1, 1) * stepDeg) * .pi / 180
        if span < minSpan {
            // Only possible with unusual screen arrangements: widen symmetrically.
            start -= (minSpan - span) / 2
            span = minSpan
        }
        let width = span / CGFloat(n)
        // Clockwise = decreasing angle from the run's counter-clockwise end.
        let mids = (0..<n).map { start + span - (CGFloat($0) + 0.5) * width }
        let standardMids = standard(n).map(\.mid)
        func cost(_ rot: Int) -> CGFloat {
            (0..<n).reduce(0) { $0 + distance(mids[$1], standardMids[($1 + rot) % n]) }
        }
        let rotation = (0..<n).min { cost($0) < cost($1) } ?? 0
        return (0..<n).map { Slot(index: ($0 + rotation) % n, mid: mids[$0], half: width / 2) }
    }

    /// Screen partition (R126). Each slot owns `mid ± half`; the drawn gaps split exactly on these
    /// boundaries, so there is no dead angle. When the slots are fanned along a screen edge, angles they
    /// do not cover go to the angularly nearest slot edge. Only the cancel zone returns nil.
    static func slot(dx: CGFloat, dy: CGFloat, slots: [Slot], cancelRadius: CGFloat) -> Int? {
        guard hypot(dx, dy) >= cancelRadius, !slots.isEmpty else { return nil }
        let angle = atan2(dy, dx)
        func offset(_ slot: Slot) -> CGFloat {
            // Signed angular distance from the slot's middle, in -π...π.
            var d = (angle - slot.mid).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            return max(abs(d) - slot.half, 0)
        }
        return slots.min { offset($0) < offset($1) }?.index
    }

    /// One sector pad with constant-width gaps; a single slot is a whole ring with no gap
    /// (outer circle and reversed inner circle, so either fill rule leaves the hole open).
    static func sectorPath(_ slot: Slot, center c: CGPoint, inner: CGFloat, outer: CGFloat, gap: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if slot.half >= .pi - 0.0001 {
            path.addArc(center: c, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            path.move(to: CGPoint(x: c.x + inner, y: c.y))
            path.addArc(center: c, radius: inner, startAngle: 2 * .pi, endAngle: 0, clockwise: true)
            path.closeSubpath()
            return path
        }
        // Constant-width gap: the angular offset depends on the radius.
        let ao = asin((gap / 2) / outer)
        let ai = asin((gap / 2) / inner)
        path.addArc(center: c, radius: outer, startAngle: slot.mid - slot.half + ao,
                    endAngle: slot.mid + slot.half - ao, clockwise: false)
        path.addArc(center: c, radius: inner, startAngle: slot.mid + slot.half - ai,
                    endAngle: slot.mid - slot.half + ai, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Where the icon sits in a slot: mid-ring. Narrow slots (screen corners, many slots on an edge)
    /// move it outward, where the slot is wider, and draw it smaller: 0.82 down to a four-slot corner,
    /// never below 0.5 (eight slots in a corner, about 11° each).
    static func iconPlacement(_ slot: Slot, inner: CGFloat, outer: CGFloat, gap: CGFloat,
                              iconSize: CGFloat) -> (radius: CGFloat, scale: CGFloat) {
        let mid = (inner + outer) / 2
        let width = slot.half * 2
        guard width < 40 * .pi / 180 else { return (mid, 1) }
        let r = width < 15 * .pi / 180 ? outer - 10 : mid + 6
        let room = r * width - gap
        return (r, min(0.82, max(0.5, room / (iconSize * 1.15))))
    }

    private static func distance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d < 0 { d += 2 * .pi }
        return min(d, 2 * .pi - d)
    }
}

/// Radial wheel (design-system.md §8), neumorphic: an opaque round tray lifted by the window-server
/// shadow, one to eight sector pads raised out of it, a pressed hub. Each pad carries only its colored
/// icon; an empty slot is a shallow socket with nothing in it. The sector the pointer points into
/// presses in and its icon glows; an empty socket never highlights and never runs anything.
/// Built once (eight pads, unused ones hidden). Settings re-configure the pads only while the wheel is
/// hidden; a visible wheel keeps its slots, colors and hit geometry until it closes.
/// Per show the shapes are re-laid out only near screen edges; per move only layer state changes.
/// The panel ignores mouse events; the host forwards pointer positions.
/// Drawing, material mask and accessibility frames come from the same CGPaths. Hit testing (R126) uses
/// the same slots' angle ranges over the whole screen, so it always agrees with the drawn sector.
@MainActor final class POWheelController {
    static let innerRadius = POWheelGeometry.cancelRadius
    static let outerRadius = POWheelGeometry.outerRadius
    static let gap: CGFloat = 4
    static let hubRadius: CGFloat = 20
    /// Tray rim around the sectors; room for the pads' shadows inside the tray.
    static let margin: CGFloat = 10
    static var side: CGFloat { (outerRadius + margin) * 2 }
    /// Icon size; there are no words on the wheel (R127).
    static let iconPointSize: CGFloat = 17
    /// Smallest arc the slots may share when fanned along an edge.
    static let minSpan: CGFloat = 80 * .pi / 180

    private final class Sector {
        let index: Int
        /// nil: an empty slot.
        var action: PointOutAction?
        /// The color frozen with the current configuration.
        var tint: POToken?
        var path: CGPath = CGMutablePath()
        /// Raised: the same surface with a shade cast down-right and light cast up-left.
        let shade = CAShapeLayer()
        let light = CAShapeLayer()
        /// Pressed: a deeper floor with shade inside the top-left edge and light inside the bottom-right.
        /// An empty socket uses the same floor, shallower.
        let floor = CAShapeLayer()
        let inner = CALayer()
        let innerMask = CAShapeLayer()
        let innerShade = CAShapeLayer()
        let innerLight = CAShapeLayer()
        /// The icon (R128): its own color, embossed at rest, glowing when hit. Positioned and scaled as one.
        let iconGroup = CALayer()
        /// The glyph's lit top-left edge: a copy just behind it, offset up-left.
        let iconLight = CALayer()
        let iconLightMask = CALayer()
        /// Casts the glyph's shade at rest and its glow when hit (a masked layer would clip its own shadow).
        let iconBody = CALayer()
        let icon = CALayer()
        let iconMask = CALayer()
        let element = NSAccessibilityElement()
        init(index: Int) { self.index = index }

        var layers: [CALayer] { [shade, light, floor, inner, iconGroup] }
    }

    private let panel: POPanel
    private let view: POWheelView
    /// Layer-hosting root; everything inside the tray is clipped to it.
    private let root = CALayer()
    private let tray = CAShapeLayer()
    private let content = CALayer()
    private let contentMask = CAShapeLayer()
    private let trayRim = CAGradientLayer()
    private let trayRimMask = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let hubFloor = CAShapeLayer()
    private let hubInner = CALayer()
    private let hubInnerMask = CAShapeLayer()
    private let hubInnerShade = CAShapeLayer()
    private let hubInnerLight = CAShapeLayer()
    private let hubDot = CAShapeLayer()
    private var sectors: [Sector] = []
    private var slots: [POWheelLayout.Slot] = []
    private var center: CGPoint = .zero
    private var generation = 0

    /// The latest settings received.
    private var settings = WheelSettings.defaults
    /// What the pads currently show; differs from `settings` only while a change waits for the wheel to close.
    private var configured: WheelSettings?

    private(set) var isVisible = false
    /// Index of the pointed slot; only slots with an action can be pointed.
    private(set) var hitIndex: Int?
    var hit: PointOutAction? { hitIndex.flatMap { sectors[$0].action } }
    var slotCount: Int { configured?.slots.count ?? settings.slots.count }

    init(presentsOnScreen: Bool = true) {
        panel = POPanel.make(level: .popUpMenu, interactive: false, presentsOnScreen: presentsOnScreen)
        let side = Self.side
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        view = POWheelView(frame: bounds)
        root.frame = bounds
        view.layer = root
        view.wantsLayer = true

        panel.contentView = view
        panel.setContentSize(bounds.size)
        panel.setAccessibilityLabel("PinPin 功能轮盘")
        build()
        applySettings()
        apply(slots: POWheelLayout.standard(settings.slots.count))
        view.onAppearanceChange = { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.applyAppearance()
            CATransaction.commit()
        }
    }

    // MARK: Settings (R145)

    /// Takes effect now if the wheel is closed, else once it has faded out: one gesture keeps one geometry.
    func update(settings newSettings: WheelSettings) {
        settings = newSettings
        guard !isVisible, !panel.isVisible else { return }
        applySettings()
    }

    private func applySettings() {
        guard configured != settings else { return }
        configured = settings
        let n = min(settings.slots.count, sectors.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in sectors {
            let used = s.index < n
            for layer in s.layers { layer.isHidden = !used }
            let action = used ? settings.slots[s.index] : nil
            s.action = action
            s.tint = action?.tint
            s.iconGroup.isHidden = action == nil
            if let action { Self.setIcon(s, symbol: action.symbol) }
            s.element.setAccessibilityLabel(action?.title ?? "空")
        }
        CATransaction.commit()
        view.sectorElements = sectors.prefix(n).map(\.element)
        // Paths are laid out again by the next apply(slots:).
        slots = []
        hitIndex = nil
    }

    // MARK: Layout (§8 edge rule)

    /// Re-lays out material mask, drawn shapes, hit shapes and accessibility frames from one set of paths.
    private func apply(slots newSlots: [POWheelLayout.Slot]) {
        guard newSlots != slots else { return }
        slots = newSlots
        let c = CGPoint(x: Self.side / 2, y: Self.side / 2)
        let outside = CGRect(x: -40, y: -40, width: Self.side + 80, height: Self.side + 80)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in newSlots where slot.index < sectors.count {
            let s = sectors[slot.index]
            let path = POWheelLayout.sectorPath(slot, center: c, inner: Self.innerRadius,
                                                outer: Self.outerRadius, gap: Self.gap)
            s.path = path
            for layer in [s.shade, s.light, s.floor, s.innerMask] { layer.path = path }
            s.shade.shadowPath = path
            s.light.shadowPath = path
            let ring = CGMutablePath()
            ring.addRect(outside)
            ring.addPath(path)
            s.innerShade.path = ring
            s.innerLight.path = ring

            let place = POWheelLayout.iconPlacement(slot, inner: Self.innerRadius, outer: Self.outerRadius,
                                                    gap: Self.gap, iconSize: Self.iconPointSize)
            s.iconGroup.position = CGPoint(x: c.x + cos(slot.mid) * place.radius, y: c.y + sin(slot.mid) * place.radius)
            s.iconGroup.setAffineTransform(CGAffineTransform(scaleX: place.scale, y: place.scale))
            s.element.setAccessibilityFrameInParentSpace(path.boundingBoxOfPath)
        }
        CATransaction.commit()
    }

    // MARK: Build

    private static var symbolCache: [String: (contents: Any, size: CGSize, scale: CGFloat)] = [:]

    /// Symbol contents are made once per symbol and shared by every pad that shows it.
    private static func setIcon(_ s: Sector, symbol name: String) {
        let entry: (contents: Any, size: CGSize, scale: CGFloat)
        if let cached = symbolCache[name] {
            entry = cached
        } else {
            let image = POGlyph.image(name, size: iconPointSize, weight: .medium)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            entry = (image.layerContents(forContentsScale: scale), image.size, scale)
            symbolCache[name] = entry
        }
        let bounds = CGRect(origin: .zero, size: entry.size)
        s.iconGroup.bounds = bounds
        s.iconLight.frame = bounds.offsetBy(dx: -0.6, dy: 0.6)
        s.iconBody.frame = bounds
        s.icon.frame = bounds
        for mask in [s.iconMask, s.iconLightMask] {
            mask.contents = entry.contents
            mask.contentsScale = entry.scale
            mask.contentsGravity = .resizeAspect
            mask.frame = bounds
        }
    }

    /// Inner shadow: the region outside `shape`, filled and offset, seen only through `shape`.
    private static func setupInner(_ container: CALayer, mask: CAShapeLayer, shade: CAShapeLayer,
                                   light: CAShapeLayer, bounds: CGRect, offset: CGFloat, radius: CGFloat) {
        container.frame = bounds
        mask.frame = bounds
        mask.fillColor = NSColor.black.cgColor
        container.mask = mask
        for layer in [shade, light] {
            layer.frame = bounds
            layer.fillRule = .evenOdd
            layer.fillColor = NSColor.black.cgColor
            layer.shadowOpacity = 1
            container.addSublayer(layer)
        }
        setDepth(shade: shade, light: light, offset: offset, radius: radius)
    }

    private static func setDepth(shade: CAShapeLayer, light: CAShapeLayer, offset: CGFloat, radius: CGFloat) {
        for (layer, sign) in [(shade, CGFloat(1)), (light, CGFloat(-1))] {
            layer.shadowRadius = radius
            // Layer y points up: shade comes from the top left, light from the bottom right.
            layer.shadowOffset = CGSize(width: offset * sign, height: -offset * sign)
        }
    }

    private func build() {
        let bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let c = Self.side / 2
        let trayPath = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)

        tray.frame = bounds
        tray.path = trayPath
        root.addSublayer(tray)
        content.frame = bounds
        contentMask.frame = bounds
        contentMask.path = trayPath
        contentMask.fillColor = NSColor.black.cgColor
        content.mask = contentMask
        root.addSublayer(content)

        for index in 0..<POWheelLayout.maxSlots {
            let s = Sector(index: index)
            for (layer, sign) in [(s.shade, CGFloat(1)), (s.light, CGFloat(-1))] {
                layer.frame = bounds
                layer.shadowOpacity = 1
                layer.shadowRadius = 3.5
                layer.shadowOffset = CGSize(width: 2.5 * sign, height: -2.5 * sign)
                content.addSublayer(layer)
            }
            s.floor.frame = bounds
            s.floor.opacity = 0
            content.addSublayer(s.floor)
            Self.setupInner(s.inner, mask: s.innerMask, shade: s.innerShade, light: s.innerLight,
                            bounds: bounds, offset: 3, radius: 3.5)
            s.inner.opacity = 0
            content.addSublayer(s.inner)

            // Icon only, no words (R127). Two copies of the glyph mask: a lit edge offset up-left,
            // and the colored glyph on top inside a body that casts its shade or glow.
            s.iconLight.mask = s.iconLightMask
            s.iconGroup.addSublayer(s.iconLight)
            s.iconBody.shadowOpacity = 1
            s.iconGroup.addSublayer(s.iconBody)
            s.icon.mask = s.iconMask
            s.iconBody.addSublayer(s.icon)
            content.addSublayer(s.iconGroup)

            s.element.setAccessibilityParent(view)
            s.element.setAccessibilityRole(.staticText)
            s.element.setAccessibilityRoleDescription("功能")
            sectors.append(s)
        }

        // The hub is a pressed dimple: pressing in place lands here and cancels.
        let hubPath = CGPath(ellipseIn: CGRect(x: c - Self.hubRadius, y: c - Self.hubRadius,
                                               width: Self.hubRadius * 2, height: Self.hubRadius * 2), transform: nil)
        hubFloor.frame = bounds
        hubFloor.path = hubPath
        content.addSublayer(hubFloor)
        Self.setupInner(hubInner, mask: hubInnerMask, shade: hubInnerShade, light: hubInnerLight,
                        bounds: bounds, offset: 2, radius: 2.5)
        hubInnerMask.path = hubPath
        let hubRing = CGMutablePath()
        hubRing.addRect(bounds.insetBy(dx: -40, dy: -40))
        hubRing.addPath(hubPath)
        hubInnerShade.path = hubRing
        hubInnerLight.path = hubRing
        content.addSublayer(hubInner)
        hubDot.frame = bounds
        hubDot.path = CGPath(ellipseIn: CGRect(x: c - 2, y: c - 2, width: 4, height: 4), transform: nil)
        content.addSublayer(hubDot)

        // Bevel of the tray: light on the top-left edge, shade on the bottom-right.
        trayRim.frame = bounds
        trayRimMask.frame = bounds
        trayRimMask.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.75, dy: 1.75), transform: nil)
        trayRimMask.fillColor = nil
        trayRimMask.strokeColor = NSColor.black.cgColor
        trayRimMask.lineWidth = 1.5
        trayRim.mask = trayRimMask
        trayRim.startPoint = CGPoint(x: 0, y: 1)
        trayRim.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(trayRim)

        outline.frame = bounds
        outline.path = trayPath
        outline.fillColor = nil
        outline.lineWidth = 0.5
        root.addSublayer(outline)
    }

    // MARK: Appearance

    private func applyAppearance() {
        let a = view.effectiveAppearance
        let surface = POColor.surface.cg(a), deep = POColor.surfaceDeep.cg(a)
        let light = POColor.lightEdge.cg(a), dark = POColor.darkEdge.cg(a)
        tray.fillColor = surface
        trayRim.setBevel(light: light, dark: dark)
        outline.strokeColor = POColor.hairline.cg(a)
        hubFloor.fillColor = deep
        hubInnerShade.shadowColor = dark
        hubInnerLight.shadowColor = light
        hubDot.fillColor = POColor.inkTertiary.cg(a)
        for s in sectors {
            s.shade.fillColor = surface
            s.shade.shadowColor = dark
            s.light.fillColor = surface
            s.light.shadowColor = light
            s.floor.fillColor = deep
            s.innerShade.shadowColor = dark
            s.innerLight.shadowColor = light
        }
        applyHighlight()
    }

    /// The sector pointed into presses in like a physical key going down, and its icon lights up: the
    /// embossed edge gives way to a soft glow in the icon's own color (R128). Instant, like a menu.
    /// Each icon keeps its color in both states, so the pressed pad and the glow tell the state.
    /// An empty slot is a shallow socket in every state, like a disabled menu item that never highlights.
    private func applyHighlight() {
        let a = view.effectiveAppearance
        let match = a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                       .accessibilityHighContrastDarkAqua])
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let light = POColor.lightEdge.cg(a), dark = POColor.darkEdge.cg(a)
        for s in sectors.prefix(slotCount) {
            guard let tint = s.tint?.cg(a) else {
                s.shade.opacity = 0
                s.light.opacity = 0
                s.floor.opacity = 1
                s.inner.opacity = 1
                Self.setDepth(shade: s.innerShade, light: s.innerLight, offset: 1.5, radius: 2)
                s.element.setAccessibilityValue("空")
                s.element.setAccessibilityEnabled(false)
                s.element.setAccessibilitySelected(false)
                continue
            }
            let isHit = s.index == hitIndex
            s.shade.opacity = isHit ? 0 : 1
            s.light.opacity = isHit ? 0 : 1
            s.floor.opacity = isHit ? 1 : 0
            s.inner.opacity = isHit ? 1 : 0
            Self.setDepth(shade: s.innerShade, light: s.innerLight, offset: 3, radius: 3.5)
            s.icon.backgroundColor = tint
            s.iconLight.backgroundColor = light
            s.iconLight.opacity = isHit ? 0 : 1
            if isHit {
                s.iconBody.shadowColor = tint
                s.iconBody.shadowOffset = .zero
                s.iconBody.shadowRadius = 4
                // A colored glow reads weaker on the light surface, so it is a little stronger there.
                s.iconBody.shadowOpacity = isDark ? 0.75 : 0.7
            } else {
                s.iconBody.shadowColor = dark
                s.iconBody.shadowOffset = CGSize(width: 0.7, height: -0.7)
                s.iconBody.shadowRadius = 0.8
                s.iconBody.shadowOpacity = 1
            }

            s.element.setAccessibilityValue(isHit ? "已指向" : "可用")
            s.element.setAccessibilityEnabled(true)
            s.element.setAccessibilitySelected(isHit)
        }
    }

    // MARK: Public

    /// `point` is the frozen press point (AppKit global). It is never changed here.
    func show(at point: CGPoint) {
        generation += 1
        hitIndex = nil
        center = point
        let side = Self.side

        applySettings()
        apply(slots: POWheelLayout.slots(count: slotCount, around: point, screens: NSScreen.screens.map(\.frame),
                                         ringRadius: Self.outerRadius + 3, minSpan: Self.minSpan))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyAppearance()
        CATransaction.commit()

        panel.setFrameOrigin(CGPoint(x: point.x - side / 2, y: point.y - side / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        isVisible = true
        if panel.presentsOnScreen { NSAccessibility.post(element: view, notification: .created) }

        // A quick fade, like a contextual menu. Opacity only, so reduce motion needs no change.
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = POMotion.wheelShow
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The slot index the pointer (AppKit global) points into, empty or not. R126: the screen is divided
    /// by angle, so a pointer anywhere outside the center cancel zone selects the slot whose direction it
    /// lies in, however far beyond the drawn ring. Only the cancel zone returns nil.
    func slotIndex(at pointer: CGPoint) -> Int? {
        POWheelLayout.slot(dx: pointer.x - center.x, dy: pointer.y - center.y, slots: slots,
                           cancelRadius: Self.innerRadius)
    }

    /// Updates the highlight; returns the action under the pointer. An empty slot returns nil.
    /// Returns nil whenever the wheel is hidden (including right after a clear gesture).
    @discardableResult func update(pointer: CGPoint) -> PointOutAction? {
        guard isVisible else { return nil }
        let newHit = slotIndex(at: pointer).flatMap { sectors[$0].action == nil ? nil : $0 }
        if newHit != hitIndex {
            hitIndex = newHit
            // Selection changes instantly, like menu items.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyHighlight()
            CATransaction.commit()
            NSAccessibility.post(element: view, notification: .selectedChildrenChanged)
        }
        return hit
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        hitIndex = nil
        generation += 1
        let current = generation
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = POMotion.wheelHide
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel.orderOut(nil)
                NSAccessibility.post(element: self.view, notification: .uiElementDestroyed)
                // A settings change that arrived during the gesture applies now, off the next show's path.
                self.applySettings()
            }
        })
    }

    #if PINPIN_UI_TESTING
    var testSlots: [POWheelLayout.Slot] { slots }
    var testConfigured: WheelSettings? { configured }
    var testPanel: POPanel { panel }
    func testSectorState(_ index: Int) -> (hidden: Bool, empty: Bool, floor: Float, shade: Float, tint: CGColor?) {
        let s = sectors[index]
        return (s.shade.isHidden, s.action == nil, s.floor.opacity, s.shade.opacity, s.icon.backgroundColor)
    }
    #endif
}
