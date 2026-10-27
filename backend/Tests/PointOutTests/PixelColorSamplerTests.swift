import AppKit
import XCTest
@testable import PointOut

final class PixelColorSamplerTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func image(_ bytes: [UInt8], width: Int = 1, height: Int = 1, rowBytes: Int? = nil,
                       space: CGColorSpace? = nil, bgra: Bool = false) throws -> CGImage {
        let info = bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: rowBytes ?? width * 4, space: space ?? sRGB,
                                    bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testKnownRGBAAndBGRAPixelsAndHexFormatting() throws {
        let grid = try NativePixelGrid(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1)
        for source in [try image([17, 34, 51, 255]), try image([51, 34, 17, 255], bgra: true)] {
            let color = try PixelColorSampler.color(in: source, grid: grid, at: .zero)
            XCTAssertEqual(color, PickedColor(red: 17, green: 34, blue: 51))
            XCTAssertEqual(color.hex, "#112233")
            XCTAssertEqual(color.rgb, "17, 34, 51")
            XCTAssertEqual(color.colorSpace, "sRGB")
        }
    }

    func testPaddedRowsUseTopLeftOriginWithNoVerticalFlip() throws {
        let source = try image([255, 0, 0, 255, 0, 255, 0, 255, 22, 23, 24, 25,
                                0, 0, 255, 255, 17, 34, 51, 255, 26, 27, 28, 29],
                               width: 2, height: 2, rowBytes: 12)
        let grid = try NativePixelGrid(bounds: CGRect(x: -1, y: -2, width: 2, height: 2), scale: 1)
        XCTAssertEqual(try PixelColorSampler.color(in: source, grid: grid, at: CGPoint(x: -1, y: -2)), PickedColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(try PixelColorSampler.color(in: source, grid: grid, at: CGPoint(x: 0, y: -2)), PickedColor(red: 0, green: 255, blue: 0))
        XCTAssertEqual(try PixelColorSampler.color(in: source, grid: grid, at: CGPoint(x: -1, y: -1)), PickedColor(red: 0, green: 0, blue: 255))
        XCTAssertEqual(try PixelColorSampler.color(in: source, grid: grid, at: CGPoint(x: 0, y: -1)), PickedColor(red: 17, green: 34, blue: 51))
    }

    func testOneTwoAndNonIntegerScaleWithNegativeDisplayOrigin() throws {
        for scale: CGFloat in [1, 2, 1.5] {
            let grid = try NativePixelGrid(bounds: CGRect(x: -100, y: -50, width: 80, height: 60), scale: scale)
            XCTAssertEqual(grid.width, Int(80 * scale))
            let first = try grid.pixel(at: CGPoint(x: -100, y: -50))
            XCTAssertEqual(first.x, 0); XCTAssertEqual(first.y, 0)
            let mid = try grid.pixel(at: CGPoint(x: -89.6, y: -29.4))
            XCTAssertEqual(mid.x, Int(floor(10.4 * scale)))
            XCTAssertEqual(mid.y, Int(floor(20.6 * scale)))
            let last = try grid.pixel(at: CGPoint(x: -20.00001, y: 9.99999))
            XCTAssertEqual(last.x, grid.width - 1); XCTAssertEqual(last.y, grid.height - 1)
            for point in [CGPoint(x: -20, y: 0), CGPoint(x: -30, y: 10), CGPoint(x: -100.001, y: 0),
                          CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
                XCTAssertThrowsError(try grid.pixel(at: point))
            }
        }
    }

    func testInvalidGeometryAndResizedImagesAreRejected() throws {
        for scale: CGFloat in [0, -1, .nan, .infinity, 1.333] {
            XCTAssertThrowsError(try NativePixelGrid(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), scale: scale))
        }
        let grid = try NativePixelGrid(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 2)
        XCTAssertThrowsError(try PixelColorSampler.color(in: image([1, 2, 3, 255]), grid: grid, at: .zero)) {
            XCTAssertEqual($0 as? PixelSamplingError, .invalidImage)
        }
    }

    func testDisplayP3ConvertsToSRGBInsteadOfReinterpretingComponents() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let source = try image([128, 64, 192, 255], space: p3)
        let grid = try NativePixelGrid(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1)
        let sampled = try PixelColorSampler.color(in: source, grid: grid, at: .zero)
        let reference = try XCTUnwrap(NSColor(displayP3Red: 128.0 / 255, green: 64.0 / 255, blue: 192.0 / 255, alpha: 1).usingColorSpace(.sRGB))
        XCTAssertEqual(Int(sampled.red), Int((reference.redComponent * 255).rounded()), accuracy: 1)
        XCTAssertEqual(Int(sampled.green), Int((reference.greenComponent * 255).rounded()), accuracy: 1)
        XCTAssertEqual(Int(sampled.blue), Int((reference.blueComponent * 255).rounded()), accuracy: 1)
        XCTAssertNotEqual(sampled, PickedColor(red: 128, green: 64, blue: 192))
    }

    func testTransparentPixelsAreRejectedWithoutInventedBackground() throws {
        let grid = try NativePixelGrid(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1)
        for bytes: [UInt8] in [[0, 0, 0, 0], [17, 34, 51, 128]] {
            XCTAssertThrowsError(try PixelColorSampler.color(in: image(bytes), grid: grid, at: .zero)) {
                XCTAssertEqual($0 as? PixelSamplingError, .transparentPixel)
            }
        }
    }

    func testContextColorSamplingIsIndependentFromForgetAndUsesFrozenPoint() async throws {
        let a = TargetAnchor(id: UUID(), screenPoint: CGPoint(x: -20.5, y: 77.25), presentationPoint: .zero,
                             processID: 0, startedAt: 0)
        let started = expectation(description: "sampler started")
        let completion = CaptureCompletion<PickedColor>()
        let capture = ContextCapture(screenCaptureAllowed: { true }, colorSampler: { point in
            XCTAssertEqual(point, a.screenPoint)
            return await withCheckedContinuation { continuation in completion.install(continuation); started.fulfill() }
        })
        let sample = Task { try await capture.sampleColor(a) }
        await fulfillment(of: [started], timeout: 1)
        capture.forget(a.id)
        completion.finish(PickedColor(red: 1, green: 2, blue: 3))
        let color = try await sample.value
        XCTAssertEqual(color.hex, "#010203")
    }

    func testContextColorSamplingChecksPermissionAndCancellationWithoutCapture() async throws {
        let a = TargetAnchor(id: UUID(), screenPoint: .zero, presentationPoint: .zero, processID: 0, startedAt: 0)
        let denied = ContextCapture(screenCaptureAllowed: { false }, colorSampler: { _ in
            XCTFail("must not capture or request permission")
            return PickedColor(red: 0, green: 0, blue: 0)
        })
        do { _ = try await denied.sampleColor(a); XCTFail("expected permission error") }
        catch { XCTAssertEqual(error as? PixelSamplingError, .permissionDenied) }
        let started = expectation(description: "sampler started")
        let completion = CaptureCompletion<PickedColor>()
        let capture = ContextCapture(screenCaptureAllowed: { true }, colorSampler: { _ in
            await withCheckedContinuation { continuation in completion.install(continuation); started.fulfill() }
        })
        let sample = Task { try await capture.sampleColor(a) }
        await fulfillment(of: [started], timeout: 1)
        sample.cancel()
        completion.finish(PickedColor(red: 1, green: 2, blue: 3))
        do { _ = try await sample.value; XCTFail("late sample must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
