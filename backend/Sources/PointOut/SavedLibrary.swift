import Foundation

private struct LibrarySnapshot: Sendable { let revision: Int; let items: [SavedItem] }
private struct LibraryMutation: Sendable { let item: SavedItem?; let snapshot: LibrarySnapshot }

/// All disk work and mutations are serialized off the main actor. UI sees only acknowledged writes.
private actor LibraryDiskStore {
    private let url: URL
    private var items: [SavedItem] = []
    private var loaded = false
    private var revision = 0
    private var images: URL { url.deletingLastPathComponent().appendingPathComponent("Images", isDirectory: true) }
    private struct Envelope: Codable { let version: Int; let items: [SavedItem] }
    init(url: URL) { self.url = url }

    func snapshot() throws -> LibrarySnapshot { try load(); return current() }
    private func current() -> LibrarySnapshot { LibrarySnapshot(revision: revision, items: items) }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1 || envelope.version == 2 else { throw ModelClientError.persistence }
            items = envelope.items.sorted { $0.createdAt > $1.createdAt }.map { item in
                var item = item
                // Stored URLs are rebased into the owned image directory, never opened as arbitrary URLs.
                if let name = item.imageURL?.lastPathComponent,
                   name.hasSuffix(".jpg"), UUID(uuidString: String(name.dropLast(4))) != nil {
                    item.imageURL = images.appendingPathComponent(name)
                } else { item.imageURL = nil; item.pointInImage = nil }
                return item
            }
        }
        loaded = true
    }

    private func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ModelClientError.persistence }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func atomic(_ data: Data, to destination: URL) throws {
        try prepareDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ModelClientError.persistence }
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func persist(_ next: [SavedItem]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try atomic(encoder.encode(Envelope(version: 2, items: next)), to: url)
        items = next; revision += 1
    }

    func add(text raw: String, image: Data?, point: CGPoint?, app: String, window: String, now: Date) throws -> LibraryMutation {
        try load()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 4000, image.map({ !$0.isEmpty && $0.count <= 8_000_000 }) ?? true else { throw ModelClientError.outputLimit }
        guard !text.isEmpty || image != nil else { return LibraryMutation(item: nil, snapshot: current()) }
        var next = items
        if image == nil, let index = next.firstIndex(where: { $0.imageURL == nil && $0.text == text }) {
            var item = next.remove(at: index); item.createdAt = now
            next.insert(item, at: 0); try persist(next)
            return LibraryMutation(item: item, snapshot: current())
        }
        let id = UUID()
        let imageURL = image.map { _ in images.appendingPathComponent(id.uuidString + ".jpg") }
        if let image, let imageURL { try atomic(image, to: imageURL) }
        let item = SavedItem(id: id, text: text, appName: String(app.prefix(200)), windowTitle: String(window.prefix(300)),
                             tags: [], createdAt: now, imageURL: imageURL, pointInImage: image == nil ? nil : point)
        next.insert(item, at: 0)
        do { try persist(next) }
        catch { if let imageURL { try? FileManager.default.removeItem(at: imageURL) }; throw error }
        return LibraryMutation(item: item, snapshot: current())
    }

    func edit(_ id: UUID, tags: [String]?, description: SavedDescription?) throws -> LibraryMutation {
        try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return LibraryMutation(item: nil, snapshot: current()) }
        var next = items
        if let tags { next[index].tags = ActionRules.normalizedTags(tags) }
        if let description {
            if next[index].imageURL != nil { next[index].text = String(description.text.prefix(4000)) }
            if next[index].tags.isEmpty { next[index].tags = description.tags }
        }
        try persist(next)
        return LibraryMutation(item: next[index], snapshot: current())
    }

    /// Apply a single user intent to the latest acknowledged tags inside the disk actor.
    func editTag(_ id: UUID, tag raw: String, adding: Bool) throws -> LibraryMutation {
        try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return LibraryMutation(item: nil, snapshot: current())
        }
        guard let tag = ActionRules.normalizedTag(raw) else {
            return LibraryMutation(item: items[index], snapshot: current())
        }
        var next = items
        let tags = ActionRules.normalizedTags(items[index].tags)
        next[index].tags = adding ? ActionRules.normalizedTags(tags + [tag]) : tags.filter { $0.lowercased() != tag.lowercased() }
        guard next[index].tags != items[index].tags else {
            return LibraryMutation(item: items[index], snapshot: current())
        }
        try persist(next)
        return LibraryMutation(item: next[index], snapshot: current())
    }

    func delete(_ id: UUID) throws -> LibrarySnapshot {
        try load()
        guard let old = items.first(where: { $0.id == id }) else { return current() }
        let original = items
        try persist(items.filter { $0.id != id })
        if let image = old.imageURL, FileManager.default.fileExists(atPath: image.path) {
            do { try FileManager.default.removeItem(at: image) }
            catch { try? persist(original); throw ModelClientError.persistence }
        }
        return current()
    }
}

@MainActor final class SavedLibrary {
    private(set) var items: [SavedItem] = []
    private let store: LibraryDiskStore
    private var revision = -1
    nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PinPin/library.json")
    }
    init(url: URL = SavedLibrary.defaultURL) { store = LibraryDiskStore(url: url) }
    private func apply(_ state: LibrarySnapshot) { if state.revision >= revision { items = state.items; revision = state.revision } }
    func reload() async throws { apply(try await store.snapshot()) }

    @discardableResult func add(text: String, image: Data? = nil, point: CGPoint? = nil,
                               appName: String, windowTitle: String, now: Date = Date()) async throws -> SavedItem? {
        let result = try await store.add(text: text, image: image, point: point, app: appName, window: windowTitle, now: now)
        apply(result.snapshot); return result.item
    }
    func item(_ id: UUID) -> SavedItem? { items.first { $0.id == id } }
    @discardableResult func setTags(_ id: UUID, _ tags: [String]) async throws -> SavedItem? {
        let result = try await store.edit(id, tags: tags, description: nil); apply(result.snapshot); return result.item
    }
    @discardableResult func addTag(_ id: UUID, _ tag: String) async throws -> SavedItem? {
        let result = try await store.editTag(id, tag: tag, adding: true); apply(result.snapshot); return result.item
    }
    @discardableResult func removeTag(_ id: UUID, _ tag: String) async throws -> SavedItem? {
        let result = try await store.editTag(id, tag: tag, adding: false); apply(result.snapshot); return result.item
    }
    @discardableResult func enrich(_ id: UUID, _ description: SavedDescription) async throws -> SavedItem? {
        let result = try await store.edit(id, tags: nil, description: description); apply(result.snapshot); return result.item
    }
    func delete(_ id: UUID) async throws { apply(try await store.delete(id)) }
    func topTags(limit: Int = 40) -> [String] {
        var counts: [String: Int] = [:]
        for tag in items.flatMap(\.tags) { counts[tag, default: 0] += 1 }
        return Array(counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0]! > counts[$1]! }.prefix(limit))
    }
}
