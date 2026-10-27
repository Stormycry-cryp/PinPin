import XCTest
@testable import PointOut

@MainActor final class SavedLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pinpin-library-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private var file: URL { folder.appendingPathComponent("library.json") }
    private var images: URL { folder.appendingPathComponent("Images", isDirectory: true) }

    private func permissions(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func envelope() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testAddAndTagsAreDurableWhenAcknowledged() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "  会议改到周四  ", appName: "Mail", windowTitle: "Inbox", now: Date(timeIntervalSince1970: 1))
        let item = try XCTUnwrap(added)
        XCTAssertEqual(item.text, "会议改到周四")
        XCTAssertEqual(library.items.map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let tagged = try await library.setTags(item.id, ["工作", " 待办 ", "工作"])
        XCTAssertEqual(tagged?.tags, ["工作", "待办"])

        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
        XCTAssertEqual(try envelope()["version"] as? Int, 2)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(folder), 0o700)
    }

    func testTagIntentsUseCurrentTagsAndNormalizeEachAcknowledgement() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "标签编辑", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 1))
        let id = try XCTUnwrap(added?.id)
        try await library.setTags(id, ["Old"])
        let first = try await library.addTag(id, " A ")
        XCTAssertEqual(first?.tags, ["Old", "A"])
        let second = try await library.addTag(id, "B")
        XCTAssertEqual(second?.tags, ["Old", "A", "B"])
        let removed = try await library.removeTag(id, " old ")
        XCTAssertEqual(removed?.tags, ["A", "B"])
        try await library.addTag(id, "a")
        try await library.addTag(id, " \n ")
        try await library.removeTag(id, String(repeating: "x", count: 17))
        XCTAssertEqual(library.item(id)?.tags, ["A", "B"])
        try await library.removeTag(id, "a")
        try await library.addTag(id, "A")
        XCTAssertEqual(library.item(id)?.tags, ["B", "A"], "Sequential remove/add keeps actor invocation order")
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
    }

    func testConcurrentTagIntentsKeepEveryIndependentChange() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "并发标签", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 1))
        let id = try XCTUnwrap(added?.id)
        try await library.setTags(id, ["Old"])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask { try await library.addTag(id, "Tag-\(index)") }
            }
            group.addTask { try await library.removeTag(id, "OLD") }
            try await group.waitForAll()
        }
        XCTAssertEqual(Set(try XCTUnwrap(library.item(id)).tags), Set((0..<6).map { "Tag-\($0)" }))
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
    }

    func testFailedTagIntentsPreserveBytesAndRecoverFromAcknowledgedTags() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "失败恢复", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 1))
        let id = try XCTUnwrap(added?.id)
        try await library.setTags(id, ["Old"])
        let original = try Data(contentsOf: file), acknowledged = library.items
        let backup = folder.appendingPathComponent("acknowledged.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: backup)
        do { try await library.addTag(id, "A"); XCTFail("A refused file type must not acknowledge an add") } catch {}
        do { try await library.removeTag(id, "Old"); XCTFail("A refused file type must not acknowledge a removal") } catch {}
        XCTAssertEqual(library.items, acknowledged)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try await library.addTag(id, "B")
        XCTAssertEqual(library.item(id)?.tags, ["Old", "B"])
        try await library.removeTag(id, "Old")
        XCTAssertEqual(library.item(id)?.tags, ["B"])
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
    }

    func testImageKeepsOriginalBytesAndPointerAfterEnrichmentAndReload() async throws {
        let library = SavedLibrary(url: file)
        // 用固定字节检查存储是否添加标记、转换格式或重新编码。
        let original = Data([0xFF, 0xD8, 0x00, 0x42, 0x7F, 0xFF, 0xD9])
        let point = CGPoint(x: 0.237, y: 0.864)
        let added = try await library.add(text: "", image: original, point: point,
                                          appName: "Preview", windowTitle: "Picture", now: Date(timeIntervalSince1970: 2))
        let item = try XCTUnwrap(added)
        let imageURL = try XCTUnwrap(item.imageURL)
        XCTAssertEqual(imageURL.deletingLastPathComponent(), images)
        XCTAssertEqual(imageURL.lastPathComponent, item.id.uuidString + ".jpg")
        XCTAssertEqual(try Data(contentsOf: imageURL), original)
        XCTAssertEqual(item.pointInImage, point)
        XCTAssertEqual(try permissions(imageURL), 0o600)
        XCTAssertEqual(try permissions(images), 0o700)

        try await library.enrich(item.id, SavedDescription(text: "一张图片", tags: ["设计"]))
        try await library.setTags(item.id, ["自选"])
        try await library.enrich(item.id, SavedDescription(text: "补充说明", tags: ["模型标签"]))
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        let restored = try XCTUnwrap(reloaded.item(item.id))
        XCTAssertEqual(restored.text, "补充说明")
        XCTAssertEqual(restored.tags, ["自选"])
        XCTAssertEqual(restored.pointInImage, point)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.imageURL)), original)
    }

    func testDuplicateTextMovesToTopWithoutDuplicatingOrChangingSelection() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "A", appName: "Notes", windowTitle: "First",
                                          now: Date(timeIntervalSince1970: 1))
        let first = try XCTUnwrap(added)
        try await library.setTags(first.id, ["学习"])
        try await library.add(text: "B", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 2))
        let again = try await library.add(text: " A ", appName: "Notes", windowTitle: "First",
                                         now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(again?.id, first.id)
        XCTAssertEqual(again?.tags, ["学习"])
        XCTAssertEqual(again?.createdAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(library.items.map(\.text), ["A", "B"])
        let empty = try await library.add(text: " \n ", appName: "", windowTitle: "")
        XCTAssertNil(empty)
        try await library.enrich(first.id, SavedDescription(text: "模型不应改写选中文字", tags: ["模型标签"]))
        XCTAssertEqual(library.item(first.id)?.text, "A")
        XCTAssertEqual(library.item(first.id)?.tags, ["学习"])

        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
    }

    func testDeleteRemovesImageAndPersistsRemainingItems() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "", image: Data([1, 2, 3]), point: CGPoint(x: 0.5, y: 0.5),
                                          appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 3))
        let imageItem = try XCTUnwrap(added)
        let imageURL = try XCTUnwrap(imageItem.imageURL)
        let other = try await library.add(text: "保留", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 4))
        let remaining = try XCTUnwrap(other)
        try await library.setTags(imageItem.id, ["学习"])
        try await library.setTags(remaining.id, ["工作", "学习"])
        XCTAssertEqual(library.topTags(), ["学习", "工作"])

        try await library.delete(imageItem.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(library.items.map(\.id), [remaining.id])
        try await library.delete(imageItem.id)
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
    }

    func testCorruptLibraryThrowsAndPreservesOriginalFile() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        let library = SavedLibrary(url: file)
        do {
            try await library.reload()
            XCTFail("损坏文件必须报告读取失败")
        } catch {}
        do {
            try await library.add(text: "新收藏", appName: "", windowTitle: "")
            XCTFail("读取失败后不能用新收藏覆盖原文件")
        } catch {}
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testBlockedParentPathThrowsWithoutAcknowledgingAnItem() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blockedParent = folder.appendingPathComponent("regular-file")
        let blocker = Data("keep".utf8)
        try blocker.write(to: blockedParent)
        let library = SavedLibrary(url: blockedParent.appendingPathComponent("library.json"))
        do {
            try await library.add(text: "不能写入", appName: "", windowTitle: "")
            XCTFail("父路径不是目录时必须报告写入失败")
        } catch {}
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: blockedParent), blocker)
    }

    func testFailedMutationKeepsAcknowledgedStateAndCleansUncommittedImage() async throws {
        let library = SavedLibrary(url: file)
        let added = try await library.add(text: "原收藏", appName: "", windowTitle: "")
        let item = try XCTUnwrap(added)
        let acknowledged = library.items
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        do {
            try await library.add(text: "", image: Data([4, 5, 6]), appName: "", windowTitle: "")
            XCTFail("图片收藏必须在元数据写入成功后才返回成功")
        } catch {}
        XCTAssertEqual(library.items, acknowledged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: images.path), [])
        do {
            try await library.setTags(item.id, ["新标签"])
            XCTFail("标签写入失败时必须抛出错误")
        } catch {}
        XCTAssertEqual(library.items, acknowledged)
        do {
            try await library.delete(item.id)
            XCTFail("删除写入失败时必须抛出错误")
        } catch {}
        XCTAssertEqual(library.items, acknowledged)
    }

    func testConcurrentAddsEditsAndDeletesMatchPersistedState() async throws {
        let library = SavedLibrary(url: file)
        let ids = try await withThrowingTaskGroup(of: UUID.self, returning: [UUID].self) { group in
            for index in 0..<40 {
                group.addTask {
                    guard let item = try await library.add(text: "收藏-\(index)", appName: "", windowTitle: "",
                                                          now: Date(timeIntervalSince1970: Double(index))) else {
                        throw ModelClientError.persistence
                    }
                    return item.id
                }
            }
            var ids: [UUID] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        XCTAssertEqual(Set(library.items.map(\.id)), Set(ids))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    if index.isMultiple(of: 2) { try await library.delete(id) }
                    else { try await library.setTags(id, ["保留"]) }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(library.items.count, 20)
        XCTAssertTrue(library.items.allSatisfy { $0.tags == ["保留"] })
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(Set(reloaded.items.map(\.id)), Set(library.items.map(\.id)))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, $0) }))
    }

    func testLegacyVersionOneLoadsWithoutImageFieldsAndNextMutationWritesVersionTwo() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let legacy: [String: Any] = ["version": 1, "items": [
            ["id": id.uuidString, "text": "旧收藏", "appName": "Notes", "windowTitle": "旧窗口",
             "tags": ["工作"], "createdAt": "2026-10-20T12:00:00Z"]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let library = SavedLibrary(url: file)
        try await library.reload()
        let item = try XCTUnwrap(library.item(id))
        XCTAssertEqual(item.text, "旧收藏")
        XCTAssertEqual(item.tags, ["工作"])
        XCTAssertNil(item.imageURL)
        XCTAssertNil(item.pointInImage)
        try await library.setTags(id, ["工作", "迁移"])
        XCTAssertEqual(try envelope()["version"] as? Int, 2)
        let reloaded = SavedLibrary(url: file)
        try await reloaded.reload()
        XCTAssertEqual(reloaded.items, library.items)
        XCTAssertEqual(try permissions(file), 0o600)
    }
    func testLargeExistingLibraryAndItsPicturesSurviveAddingAnotherCollection() async throws {
        struct Stored: Encodable { let version: Int; let items: [SavedItem] }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let oldID = UUID(), oldImage = images.appendingPathComponent(oldID.uuidString + ".jpg")
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9]); try bytes.write(to: oldImage)
        let records = (0..<5001).map { index in
            SavedItem(id: index == 0 ? oldID : UUID(), text: "record-\(index)", appName: "", windowTitle: "", tags: [],
                createdAt: Date(timeIntervalSince1970: Double(index)), imageURL: index == 0 ? oldImage : nil)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Stored(version: 2, items: records)).write(to: file)
        let library = SavedLibrary(url: file); try await library.reload()
        XCTAssertEqual(library.items.count, 5001)
        XCTAssertNotNil(library.item(oldID))
        try await library.add(text: "new collection", appName: "", windowTitle: "", now: Date(timeIntervalSince1970: 9000))
        let restored = SavedLibrary(url: file); try await restored.reload()
        XCTAssertEqual(restored.items.count, 5002)
        XCTAssertNotNil(restored.item(oldID))
        XCTAssertEqual(try Data(contentsOf: oldImage), bytes)
    }

}
