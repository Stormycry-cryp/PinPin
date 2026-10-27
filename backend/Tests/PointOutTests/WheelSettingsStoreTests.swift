import XCTest
@testable import PointOut

final class WheelSettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("nested/wheel-settings.json") }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pinpin-wheel-settings-\(UUID())", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testMissingFileReturnsDefaultsWithoutWriting() async throws {
        let settings = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertEqual(settings, .defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLegacyFileKeepsExistingLayoutAndDefaultsToEnabled() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            WheelSettings(slots: [.pickColor, nil, .replyCoach], colors: [:]))) as! [String: Any]
        legacy.removeValue(forKey: "triggerEnabled")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: file)
        let loaded = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertTrue(loaded.triggerEnabled)
        XCTAssertEqual(loaded.slots, [.pickColor, nil, .replyCoach])
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDisabledTriggerSurvivesRestartAndLaterLayoutChanges() async throws {
        let store = WheelSettingsStore(fileURL: file)
        var settings = WheelSettings(slots: [.save, .explain], colors: [:], triggerEnabled: false)
        try await store.save(settings, revision: 1)
        let restored = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertEqual(restored, settings)
        settings.slots.append(.pickColor)
        try await store.save(settings, revision: 2)
        let edited = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertFalse(edited.triggerEnabled)
        XCTAssertEqual(edited.slots, [.save, .explain, .pickColor])
    }

    func testOneAndEightSlotsRoundTrip() async throws {
        let store = WheelSettingsStore(fileURL: file)
        let one = WheelSettings(slots: [.explain], colors: [:])
        try await store.save(one, revision: 0)
        let loadedOne = try await store.load()
        XCTAssertEqual(loadedOne, one)

        let eight = WheelSettings(slots: [.save, nil, .translate, .rewrite, .explain, .save, nil, .rewrite], colors: [:])
        try await store.save(eight, revision: 1)
        let loadedEight = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertEqual(loadedEight, eight)
    }

    func testEmptySlotsAndRepeatedActionsAreValid() async throws {
        let settings = WheelSettings(slots: [nil, .rewrite, .rewrite, nil], colors: [:])
        try await WheelSettingsStore(fileURL: file).save(settings, revision: 1)
        let reloaded = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertEqual(reloaded, settings)
    }

    func testColorsPersistAcrossStoreRestart() async throws {
        let settings = WheelSettings(slots: [.translate, .explain], colors: [
            .translate: WheelColor(red: 0, green: 0.125, blue: 1),
            .explain: WheelColor(red: 0.8, green: 0.4, blue: 0.2)
        ])
        try await WheelSettingsStore(fileURL: file).save(settings, revision: 1)
        let restored = try await WheelSettingsStore(fileURL: file).load()
        XCTAssertEqual(restored, settings)
    }

    func testInvalidSettingsNeverOverwriteExistingFile() async throws {
        let store = WheelSettingsStore(fileURL: file)
        try await store.save(.defaults, revision: 1)
        let original = try Data(contentsOf: file)
        let invalid = [
            WheelSettings(slots: [], colors: [:]),
            WheelSettings(slots: Array(repeating: .save, count: 9), colors: [:]),
            WheelSettings(slots: [.save], colors: [.save: WheelColor(red: -0.01, green: 0, blue: 0)]),
            WheelSettings(slots: [.save], colors: [.save: WheelColor(red: 0, green: 1.01, blue: 0)]),
            WheelSettings(slots: [.save], colors: [.save: WheelColor(red: 0, green: 0, blue: .nan)]),
            WheelSettings(slots: [.save], colors: [.save: WheelColor(red: .infinity, green: 0, blue: 0)])
        ]
        for (index, settings) in invalid.enumerated() {
            do {
                try await store.save(settings, revision: UInt64(index + 2))
                XCTFail("无效设置必须保存失败")
            } catch {
                XCTAssertTrue(error is WheelSettingsStore.StoreError)
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testCorruptLoadPreservesOriginalBytes() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken settings".utf8)
        try corrupt.write(to: file)
        do {
            _ = try await WheelSettingsStore(fileURL: file).load()
            XCTFail("损坏文件必须读取失败")
        } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testDecodedInvalidSettingsThrowWithoutRewriting() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = try JSONEncoder().encode(WheelSettings(slots: [], colors: [:]))
        try invalid.write(to: file)
        do {
            _ = try await WheelSettingsStore(fileURL: file).load()
            XCTFail("无效设置必须读取失败")
        } catch { XCTAssertTrue(error is WheelSettingsStore.StoreError) }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testOlderAndEqualRevisionsCannotOverwriteNewerEdit() async throws {
        let store = WheelSettingsStore(fileURL: file)
        let newer = WheelSettings(slots: [.rewrite, nil], colors: [:])
        try await store.save(newer, revision: 2)
        let original = try Data(contentsOf: file)
        try await store.save(.defaults, revision: 1)
        try await store.save(.defaults, revision: 2)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let restored = try await store.load()
        XCTAssertEqual(restored, newer)
        try await store.save(.defaults, revision: 3)
        let latest = try await store.load()
        XCTAssertEqual(latest, .defaults)
    }

    func testFailedNewerEditStillPreventsLateOlderWrite() async throws {
        let store = WheelSettingsStore(fileURL: file)
        try await store.save(.defaults, revision: 1)
        let original = try Data(contentsOf: file)
        do {
            try await store.save(WheelSettings(slots: [], colors: [:]), revision: 3)
            XCTFail("无效设置必须保存失败")
        } catch { XCTAssertTrue(error is WheelSettingsStore.StoreError) }
        try await store.save(WheelSettings(slots: [.translate], colors: [:]), revision: 2)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testActualWriteFailurePreservesLastSavedSettings() async throws {
        let store = WheelSettingsStore(fileURL: file)
        try await store.save(.defaults, revision: 1)
        let original = try Data(contentsOf: file)
        let parent = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        guard !FileManager.default.isWritableFile(atPath: parent.path) else {
            throw XCTSkip("当前执行身份仍可写入只读目录，无法验证真实写入失败")
        }
        let next = WheelSettings(slots: [.rewrite], colors: [:])
        do {
            try await store.save(next, revision: 2)
            XCTFail("真实文件写入失败必须返回错误")
        } catch { XCTAssertFalse(error is WheelSettingsStore.StoreError) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try await store.save(next, revision: 3)
        let restored = try await store.load()
        XCTAssertEqual(restored, next)
    }
}
