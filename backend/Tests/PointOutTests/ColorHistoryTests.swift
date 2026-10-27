import XCTest
@testable import PointOut

@MainActor final class ColorHistoryTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("color-history.json") }
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pinpin-color-history-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func record(_ time: Double = 1, id: UUID = UUID()) -> ColorRecord {
        ColorRecord(id: id, color: PickedColor(red: 17, green: 34, blue: 51), createdAt: Date(timeIntervalSince1970: time),
                    appName: String(repeating: "a", count: 201), windowTitle: String(repeating: "w", count: 301))
    }
    func testRecordsSurviveRestartWithoutChangingOldLibraryOrImages() async throws {
        let library = SavedLibrary(url: directory.appendingPathComponent("library.json"))
        let image = Data([0xFF, 0xD8, 0x00, 0x42, 0xFF, 0xD9])
        let added = try await library.add(text: "原有收藏", image: image,
            appName: "Preview", windowTitle: "Image", now: Date(timeIntervalSince1970: 3))
        let saved = try XCTUnwrap(added)
        _ = try await library.setTags(saved.id, ["保留标签"])
        let oldBytes = try Data(contentsOf: directory.appendingPathComponent("library.json"))
        let imageURL = try XCTUnwrap(saved.imageURL)
        let history = ColorHistory(url: file)
        let first = record(1.25), second = record(2.75)
        try await history.add(first); try await history.add(second); try await history.add(second)
        XCTAssertEqual(history.items.map(\.id), [second.id, first.id])
        let restarted = ColorHistory(url: file); try await restarted.reload()
        XCTAssertEqual(restarted.items, history.items)
        XCTAssertEqual(restarted.items.first?.color.hex, "#112233")
        XCTAssertEqual(restarted.items.first?.appName.count, 200)
        XCTAssertEqual(restarted.items.first?.windowTitle.count, 300)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.json")), oldBytes)
        XCTAssertEqual(try Data(contentsOf: imageURL), image)
        let oldLibrary = SavedLibrary(url: directory.appendingPathComponent("library.json")); try await oldLibrary.reload()
        XCTAssertEqual(oldLibrary.items, library.items)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }
    func testFailedWriteAndDeleteKeepAcknowledgedState() async throws {
        let history = ColorHistory(url: file)
        let kept = record()
        try await history.add(kept)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await history.add(record(2)); XCTFail("write must fail") } catch {}
        XCTAssertEqual(history.items.map(\.id), [kept.id])
        do { try await history.delete(kept.id); XCTFail("delete must fail") } catch {}
        XCTAssertEqual(history.items.map(\.id), [kept.id])
    }
    func testMalformedHistoryIsPreservedInsteadOfReplaced() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("broken history".utf8); try original.write(to: file)
        let history = ColorHistory(url: file)
        do { try await history.add(record()); XCTFail("corrupt history must fail") } catch {}
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testMergeOrderingAndDeletingColorsKeepSavedRecords() async throws {
        let sharedID = UUID(), color = record(3, id: sharedID)
        let saved = SavedItem(id: sharedID, text: "kept", appName: "", windowTitle: "", tags: ["tag"], createdAt: Date(timeIntervalSince1970: 2))
        let history = ColorHistory(url: file); try await history.add(color)
        let merged = AssetRecord.merged(saved: [saved], colors: history.items)
        XCTAssertEqual(merged.map(\.id), [.color(sharedID), .saved(sharedID)])
        XCTAssertNotEqual(merged[0].id, merged[1].id)
        try await history.delete(sharedID)
        XCTAssertEqual(AssetRecord.merged(saved: [saved], colors: history.items), [.saved(saved)])
        let restored = ColorHistory(url: file); try await restored.reload(); XCTAssertTrue(restored.items.isEmpty)
        let tied = ColorRecord(id: sharedID, color: color.color, createdAt: saved.createdAt, appName: "", windowTitle: "")
        XCTAssertEqual(AssetRecord.merged(saved: [saved], colors: [tied]).map(\.id), [.color(sharedID), .saved(sharedID)])
    }
}
