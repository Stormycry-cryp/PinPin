import XCTest
import ImageIO
@testable import PointOut

final class VisualEvidenceTests: XCTestCase {
    private func fixture() throws -> CGImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "model-visual-text-block-fixture", withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    func testPixelMappingHandlesNegativeDisplaysAndRetinaScale() {
        let frame = CGRect(x: -1200, y: -100, width: 1200, height: 650)
        let crop = CGRect(x: -1100, y: -50, width: 600, height: 400)
        XCTAssertEqual(VisualEvidence.pixelCrop(crop, in: frame, imageSize: CGSize(width: 2400, height: 1300)),
                       CGRect(x: 200, y: 100, width: 1200, height: 800))
        XCTAssertNil(VisualEvidence.pixelCrop(crop.offsetBy(dx: -1000, dy: 0), in: frame, imageSize: CGSize(width: 1200, height: 650)))
    }
    func testPublicImageCropPreservesPointAndKeepsSavedBytesUnmarked() throws {
        let image = try fixture()
        let frame = CGRect(x: -1200, y: -100, width: image.width, height: image.height)
        let crop = CGRect(x: -1200, y: -50, width: 600, height: 400)
        let encoded = try XCTUnwrap(VisualEvidence.encode(image, crop: crop, frame: frame, pointer: CGPoint(x: -1050, y: 120)))
        XCTAssertEqual(encoded.point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(encoded.point.y, 0.425, accuracy: 0.0001)
        XCTAssertEqual(encoded.pixelSize, CGSize(width: 600, height: 400))
        XCTAssertNotEqual(encoded.marked, encoded.original)
        XCTAssertEqual(try decoded(encoded.marked).width, 600)
        XCTAssertEqual(try decoded(encoded.original).height, 400)
        // Saving gets the pre-annotation encoding. Drawing a model pointer cannot mutate the source frame.
        let second = try XCTUnwrap(VisualEvidence.encode(image, crop: crop, frame: frame, pointer: CGPoint(x: -1000, y: 120)))
        XCTAssertEqual(second.original, encoded.original)
        XCTAssertNotEqual(second.marked, encoded.marked)
    }
    func testSmallWindowPadsInsteadOfDistortingAndLargeWindowHasBoundedDimensions() throws {
        let image = try fixture(), frame = CGRect(x: 0, y: 0, width: 1200, height: 650)
        let small = try XCTUnwrap(VisualEvidence.encode(image, crop: CGRect(x: 0, y: 0, width: 100, height: 100), frame: frame, pointer: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(small.pixelSize, CGSize(width: 280, height: 280))
        XCTAssertEqual(small.point, CGPoint(x: 0.5, y: 0.5))
        let large = try XCTUnwrap(VisualEvidence.encode(image, crop: frame, frame: frame, pointer: CGPoint(x: 150, y: 220), maxSide: 560))
        XCTAssertEqual(large.pixelSize.width, 560)
        XCTAssertGreaterThanOrEqual(large.pixelSize.height, 280)
        XCTAssertEqual(large.point.x, 0.125, accuracy: 0.0001)
    }
    func testInvalidInputsNeverAllocateOrReturnUnanchoredImage() throws {
        let image = try fixture(), frame = CGRect(x: 0, y: 0, width: 1200, height: 650)
        XCTAssertNil(VisualEvidence.encode(image, crop: frame, frame: frame, pointer: .zero, maxSide: .infinity))
        XCTAssertNil(VisualEvidence.encode(image, crop: frame, frame: frame, pointer: .zero, maxSide: 10))
        XCTAssertNil(VisualEvidence.encode(image, crop: frame, frame: frame, pointer: CGPoint(x: -1, y: 10)))
        XCTAssertNil(VisualEvidence.encode(image, crop: frame, frame: frame, pointer: CGPoint(x: CGFloat.nan, y: 0)))
    }
}
