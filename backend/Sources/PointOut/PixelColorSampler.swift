import AppKit
import CoreVideo
import ScreenCaptureKit

/// A screen-composited pixel, not the source application's CSS/document color.
/// SCK produces sRGB before its 8-bit output; Core Graphics then reads one native pixel.
enum PixelSamplingError: Error, LocalizedError, Equatable {
    case permissionDenied, unavailable, invalidGeometry, invalidImage, transparentPixel, timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要屏幕录制权限才能取色，请在系统设置中允许 PinPin。"
        case .unavailable: return "暂时无法读取这个位置的屏幕颜色，请重试。"
        case .invalidGeometry, .invalidImage: return "屏幕显示状态已变化，请重新取色。"
        case .transparentPixel: return "这个位置没有完整的屏幕颜色，请重新取色。"
        case .timedOut: return "读取屏幕颜色超时，请重试。"
        }
    }
}

/// The full display raster is used because SCK's sourceRect contract is in logical points;
/// it does not promise exact rounding of a sub-point, one-pixel crop.
struct NativePixelGrid: Equatable {
    let bounds: CGRect
    let width: Int
    let height: Int

    init(bounds: CGRect, scale: CGFloat) throws {
        let width = bounds.width * scale, height = bounds.height * scale
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, scale, width, height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, scale > 0,
              width >= 1, height >= 1, width < CGFloat(Int.max), height < CGFloat(Int.max),
              abs(width - width.rounded()) < 0.001, abs(height - height.rounded()) < 0.001 else {
            throw PixelSamplingError.invalidGeometry
        }
        self.bounds = bounds; self.width = Int(width.rounded()); self.height = Int(height.rounded())
    }

    /// CG global coordinates and CGImage rows both start at the top left. Display edges
    /// are half-open: a point at maxX/maxY belongs to the neighbouring display, if any.
    func pixel(at point: CGPoint) throws -> (x: Int, y: Int) {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= bounds.minX, point.x < bounds.maxX,
              point.y >= bounds.minY, point.y < bounds.maxY else { throw PixelSamplingError.invalidGeometry }
        let x = Int(floor((point.x - bounds.minX) * CGFloat(width) / bounds.width))
        let y = Int(floor((point.y - bounds.minY) * CGFloat(height) / bounds.height))
        guard (0..<width).contains(x), (0..<height).contains(y) else { throw PixelSamplingError.invalidGeometry }
        return (x, y)
    }
}

final class PixelColorSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PinPin.pixel", qos: .userInitiated)

    func sample(at point: CGPoint) async throws -> PickedColor {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw PixelSamplingError.permissionDenied }
        let result: Result<PickedColor, Error> = await boundedCapture(
            timeout: 2, fallback: .failure(PixelSamplingError.timedOut), cancelled: .failure(CancellationError())
        ) { completion in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                self.queue.async {
                    guard !completion.isFinished else { return }
                    guard let content, let display = content.displays.first(where: { $0.frame.contains(point) }) else {
                        completion.finish(.failure(PixelSamplingError.unavailable)); return
                    }
                    // Exclude every window from this process, including wheel, markers and result cards.
                    let ownApplications = content.applications.filter { $0.processID == getpid() }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                    let grid: NativePixelGrid
                    do {
                        guard filter.contentRect.size == display.frame.size else { throw PixelSamplingError.invalidGeometry }
                        grid = try NativePixelGrid(bounds: display.frame, scale: CGFloat(filter.pointPixelScale))
                        _ = try grid.pixel(at: point)
                    } catch { completion.finish(.failure(error)); return }
                    let config = SCStreamConfiguration()
                    config.width = grid.width; config.height = grid.height
                    config.captureResolution = .best
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.showsCursor = false
                    config.scalesToFit = false
                    // Convert before 8-bit output to avoid an extra display-profile round trip.
                    config.colorSpaceName = CGColorSpace.sRGB
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                        self.queue.async {
                            guard !completion.isFinished else { return }
                            guard CGDisplayIsActive(display.displayID) != 0,
                                  CGDisplayBounds(display.displayID) == grid.bounds,
                                  let image else {
                                completion.finish(.failure(PixelSamplingError.unavailable)); return
                            }
                            completion.finish(Result { try Self.color(in: image, grid: grid, at: point) })
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return try result.get()
    }

    static func color(in image: CGImage, grid: NativePixelGrid, at point: CGPoint) throws -> PickedColor {
        guard image.width == grid.width, image.height == grid.height, image.colorSpace != nil else {
            throw PixelSamplingError.invalidImage
        }
        let pixel = try grid.pixel(at: point)
        guard let sample = try PikaPixelReader.sample(in: image, x: pixel.x, y: pixel.y)
                ?? image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw PixelSamplingError.invalidImage }
        // Core Graphics decodes the source layout, row stride, alpha and profile. An explicit
        // big-endian RGBA destination makes the four resulting bytes unambiguous on any CPU.
        var rgba = [UInt8](repeating: 0, count: 4)
        let converted = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard converted else { throw PixelSamplingError.invalidImage }
        // A display composition should be opaque. Never invent a backing color for a transparent
        // sample, or return premultiplied components as if they were an opaque screen color.
        guard rgba[3] == 255 else { throw PixelSamplingError.transparentPixel }
        return PickedColor(red: rgba[0], green: rgba[1], blue: rgba[2])
    }
}
