import Foundation

/// 轮盘设置只保存在本机；文件读写由 actor 串行执行。
actor WheelSettingsStore {
    enum StoreError: Error { case invalidSettings }

    private let fileURL: URL
    private var latestRevision: UInt64?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PinPin", isDirectory: true)
            .appendingPathComponent("wheel-settings.json")
    }

    func load() throws -> WheelSettings {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .defaults }
        let settings = try JSONDecoder().decode(WheelSettings.self, from: data)
        guard settings.isValid else { throw StoreError.invalidSettings }
        return settings
    }

    func save(_ settings: WheelSettings, revision: UInt64) throws {
        if let latestRevision, revision <= latestRevision { return }
        // 较新编辑即使保存失败，也不能让稍后到达的旧编辑覆盖文件。
        latestRevision = revision
        guard settings.isValid else { throw StoreError.invalidSettings }
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
