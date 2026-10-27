import Darwin
import Foundation

private struct ColorHistorySnapshot: Sendable { let revision: Int; let items: [ColorRecord] }

/// Independent from library.json and Images. Only acknowledged writes enter the visible history.
private actor ColorHistoryDiskStore {
    private let url: URL
    private var items: [ColorRecord] = []
    private var loaded = false
    private var revision = 0
    private struct Envelope: Codable { let version: Int; let items: [ColorRecord] }
    init(url: URL) { self.url = url }

    private func current() -> ColorHistorySnapshot { ColorHistorySnapshot(revision: revision, items: items) }
    func snapshot() throws -> ColorHistorySnapshot { try load(); return current() }
    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1 else { throw ModelClientError.persistence }
            items = Self.sorted(envelope.items)
        }
        loaded = true
    }
    private static func sorted(_ values: [ColorRecord]) -> [ColorRecord] {
        values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    private func persist(_ next: [ColorRecord]) throws {
        let manager = FileManager.default, directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ModelClientError.persistence
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: url.path) {
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw ModelClientError.persistence
            }
        }
        let temporary = directory.appendingPathComponent(".color-history-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(Envelope(version: 1, items: next))
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ModelClientError.persistence
        }
        guard rename(temporary.path, url.path) == 0 else { throw ModelClientError.persistence }
        items = next; revision += 1
    }
    func add(_ record: ColorRecord) throws -> ColorHistorySnapshot {
        try load()
        // The record id is the completed gesture's id, so a repeated acknowledgement cannot duplicate it.
        guard !items.contains(where: { $0.id == record.id }) else { return current() }
        let record = ColorRecord(id: record.id, color: record.color, createdAt: record.createdAt,
                                 appName: String(record.appName.prefix(200)), windowTitle: String(record.windowTitle.prefix(300)))
        try persist(Self.sorted(items + [record])); return current()
    }
    func delete(_ id: UUID) throws -> ColorHistorySnapshot {
        try load()
        guard items.contains(where: { $0.id == id }) else { return current() }
        try persist(items.filter { $0.id != id }); return current()
    }
}

@MainActor final class ColorHistory {
    private(set) var items: [ColorRecord] = []
    private let store: ColorHistoryDiskStore
    private var revision = -1
    nonisolated static var defaultURL: URL {
        SavedLibrary.defaultURL.deletingLastPathComponent().appendingPathComponent("color-history.json")
    }
    init(url: URL = ColorHistory.defaultURL) { store = ColorHistoryDiskStore(url: url) }
    private func apply(_ state: ColorHistorySnapshot) {
        if state.revision >= revision { items = state.items; revision = state.revision }
    }
    func reload() async throws { apply(try await store.snapshot()) }
    func add(_ record: ColorRecord) async throws { apply(try await store.add(record)) }
    func delete(_ id: UUID) async throws { apply(try await store.delete(id)) }
}
