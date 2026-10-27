import AppKit

// MARK: - PinPin brand glyph (brand/README.md)
//
// Two pins leaning head to head: a big pin with a hole and a small solid pin (0.62x).
// The numbers below are the master geometry shared with brand/*.svg (base units, y down).

/// Brand images for the host. The type keeps the name the host asked for; the product is PinPin.
@MainActor enum PingBrand {
    /// 18 x 18 pt monochrome template for the menu bar status item (same drawing as brand/menubar.svg).
    /// Drawn in code: no asset, no network. AppKit tints it for light, dark and highlighted menu bars.
    static func menuBarImage() -> NSImage {
        PinPinGlyph.menuBarImage()
    }
}

/// Pure drawing with no actor, because NSImage may run its drawing handler for any representation.
private enum PinPinGlyph {
    /// One pin, head center at the origin: head radius 100, tip circle radius 16 centered 180 below,
    /// straight common tangents between the two circles.
    static let headRadius: CGFloat = 100
    static let tipRadius: CGFloat = 16
    static let tipCenter: CGFloat = 180
    static var tipBottom: CGFloat { tipCenter + tipRadius }

    struct Placement {
        let tip: CGPoint
        let degrees: CGFloat
        let scale: CGFloat
    }

    static let big = Placement(tip: CGPoint(x: 190, y: 395), degrees: 10, scale: 1)
    static let small = Placement(tip: CGPoint(x: 380, y: 395), degrees: -14, scale: 0.62)
    /// Bounding box of the whole mark.
    static let markCenter = CGPoint(x: 268.32, y: 248.64)
    static let markHeight: CGFloat = 293.31

    static let menuBarSide: CGFloat = 18
    static let menuBarMarkHeight: CGFloat = 15
    static let menuBarGap: CGFloat = 1
    /// Slightly smaller than the color mark's 40, so the ring stays solid at 18 pt.
    static let menuBarHoleRadius: CGFloat = 36

    static func menuBarImage() -> NSImage {
        let side = menuBarSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect,
                 markHeight: rect.height * menuBarMarkHeight / side,
                 gap: rect.height * menuBarGap / side,
                 holeRadius: menuBarHoleRadius)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PinPin"
        return image
    }

    /// Pin outline grown by `grow` local units. Growing both circles equally keeps the tangent angle.
    static func outline(grow: CGFloat = 0) -> CGPath {
        let a = asin((headRadius - tipRadius) / tipCenter)
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: headRadius + grow,
                    startAngle: .pi - a, endAngle: 2 * .pi + a, clockwise: false)
        path.addArc(center: CGPoint(x: 0, y: tipCenter), radius: tipRadius + grow,
                    startAngle: a, endAngle: .pi - a, clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Same order as the SVG transform: translate(tip) rotate(degrees) scale(scale) translate(0, -tipBottom).
    static func transform(_ p: Placement) -> CGAffineTransform {
        CGAffineTransform(translationX: p.tip.x, y: p.tip.y)
            .rotated(by: p.degrees * .pi / 180)
            .scaledBy(x: p.scale, y: p.scale)
            .translatedBy(x: 0, y: -tipBottom)
    }

    /// Draws the mark centered in `rect` (flipped context). `gap` is in points.
    static func draw(in ctx: CGContext, rect: CGRect, markHeight: CGFloat, gap: CGFloat, holeRadius: CGFloat) {
        let k = markHeight / Self.markHeight
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -markCenter.x, y: -markCenter.y)
        ctx.setFillColor(NSColor.black.cgColor)

        // Big pin and its hole, minus a gap around the small pin (even-odd clip, so nothing
        // outside this image is ever cleared).
        let gapClip = CGMutablePath()
        gapClip.addRect(CGRect(x: -1000, y: -1000, width: 3000, height: 3000))
        gapClip.addPath(outline(grow: gap / k / small.scale), transform: transform(small))
        ctx.saveGState()
        ctx.addPath(gapClip)
        ctx.clip(using: .evenOdd)
        let bigPin = CGMutablePath()
        bigPin.addPath(outline(), transform: transform(big))
        bigPin.addEllipse(in: CGRect(x: -holeRadius, y: -holeRadius, width: holeRadius * 2, height: holeRadius * 2),
                          transform: transform(big))
        ctx.addPath(bigPin)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        let smallPin = CGMutablePath()
        smallPin.addPath(outline(), transform: transform(small))
        ctx.addPath(smallPin)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
