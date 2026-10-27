import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image geometry is deterministic; no text recognition or semantic classification runs locally.
enum VisualEvidence {
    struct Encoded: Sendable {
        let original: Data
        let marked: Data
        let point: CGPoint
        let pixelSize: CGSize
    }

    static func pixelCrop(_ crop: CGRect, in frame: CGRect, imageSize: CGSize) -> CGRect? {
        guard CaptureRules.finite(frame), CaptureRules.finite(crop), imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              !crop.isEmpty, frame.contains(crop) else { return nil }
        let sx = imageSize.width / frame.width, sy = imageSize.height / frame.height
        let rect = CGRect(x: (crop.minX - frame.minX) * sx, y: (crop.minY - frame.minY) * sy,
                          width: crop.width * sx, height: crop.height * sy).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        return rect.isEmpty ? nil : rect
    }

    static func encode(_ image: CGImage, crop: CGRect, frame: CGRect, pointer: CGPoint,
                       maxSide: CGFloat = 1568) -> Encoded? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard maxSide.isFinite, (280...1568).contains(maxSide), pointer.x.isFinite, pointer.y.isFinite,
              let rect = pixelCrop(crop, in: frame, imageSize: imageSize),
              let source = image.cropping(to: rect), crop.contains(pointer) else { return nil }
        // Pixel rounding is included in the point transform, so window-edge crops stay anchored.
        let sourcePoint = CGPoint(x: (pointer.x - frame.minX) * imageSize.width / frame.width - rect.minX,
                                  y: (pointer.y - frame.minY) * imageSize.height / frame.height - rect.minY)
        let scale = min(1, maxSide / CGFloat(max(source.width, source.height)))
        let width = max(280, Int(ceil(CGFloat(source.width) * scale)))
        let height = max(280, Int(ceil(CGFloat(source.height) * scale)))
        let drawn = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        let offset = CGPoint(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2)
        let point = CGPoint(x: offset.x + sourcePoint.x * scale, y: offset.y + sourcePoint.y * scale)
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(width), point.y < CGFloat(height),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: offset.x, y: CGFloat(height) - offset.y - drawn.height,
                                   width: drawn.width, height: drawn.height))
        guard let originalImage = ctx.makeImage(), let original = jpeg(originalImage) else { return nil }
        // A model-input pointer only. This is never shown as the app's marker or stored in collections.
        let tip = CGPoint(x: point.x, y: CGFloat(height) - point.y)
        let dx: CGFloat = point.x + 26 < CGFloat(width) - 4 ? 22 : -22
        let dy: CGFloat = point.y > 50 ? 44 : -44
        let start = CGPoint(x: tip.x + dx, y: tip.y + dy)
        ctx.setStrokeColor(CGColor(red: 0.95, green: 0.12, blue: 0.12, alpha: 1))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.12, blue: 0.12, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: start); ctx.addLine(to: tip); ctx.strokePath()
        let length = hypot(dx, dy), ux = dx / length, uy = dy / length
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x + ux * 12 - uy * 4, y: tip.y + uy * 12 + ux * 4))
        ctx.addLine(to: CGPoint(x: tip.x + ux * 12 + uy * 4, y: tip.y + uy * 12 - ux * 4))
        ctx.closePath(); ctx.fillPath()
        guard let markedImage = ctx.makeImage(), let marked = jpeg(markedImage) else { return nil }
        return Encoded(original: original, marked: marked,
                       point: CGPoint(x: point.x / CGFloat(width), y: point.y / CGFloat(height)),
                       pixelSize: CGSize(width: width, height: height))
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }
}
