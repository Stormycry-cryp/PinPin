// Derived from Pika centerPixelColor(of:), d28d2ecc4f85ca78077a48a2f669797de65dfab8.
// Copyright (c) 2021 Charlie Gleason. MIT: ../../ThirdPartyNotices/Pika-MIT.txt.
import CoreGraphics
import Foundation

enum PikaPixelReader {
    /// nil delegates unsupported layouts/profiles to the existing Core Graphics conversion.
    /// x/y are local raster pixels; no capture, global-coordinate transform or centre fallback.
    static func sample(in image: CGImage, x: Int, y: Int) throws -> CGImage? {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else {
            throw PixelSamplingError.invalidImage
        }
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil,
              let cgColorSpace = image.colorSpace, cgColorSpace.model == .rgb,
              let name = cgColorSpace.name,
              [CGColorSpace.sRGB, CGColorSpace.displayP3].contains(where: { CFEqual(name, $0) }),
              let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        // Pika's standard SCK BGRA layout check; other layouts use the original converter.
        let alphaFirst = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first
            || image.alphaInfo == .noneSkipFirst
        guard image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little, alphaFirst else { return nil }
        let (row, rowOverflow) = y.multipliedReportingOverflow(by: image.bytesPerRow)
        let (column, columnOverflow) = x.multipliedReportingOverflow(by: 4)
        let (offset, offsetOverflow) = row.addingReportingOverflow(column)
        guard !rowOverflow, !columnOverflow, !offsetOverflow,
              image.bytesPerRow >= 4, column <= image.bytesPerRow - 4,
              CFDataGetLength(data) >= 4, offset <= CFDataGetLength(data) - 4 else {
            throw PixelSamplingError.invalidImage
        }
        // Skip-alpha is opaque by definition; premultiplied/straight alpha must be 255.
        guard image.alphaInfo == .noneSkipFirst || ptr[offset + 3] == 255 else {
            throw PixelSamplingError.transparentPixel
        }
        let blue = ptr[offset]
        let green = ptr[offset + 1]
        let red = ptr[offset + 2]
        // Keep the exact source profile and defer conversion/rounding to the existing CGContext.
        let rgba = Data([red, green, blue, 255]) as CFData
        guard let provider = CGDataProvider(data: rgba),
              let sample = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: cgColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: image.renderingIntent) else {
            throw PixelSamplingError.invalidImage
        }
        return sample
    }
}
