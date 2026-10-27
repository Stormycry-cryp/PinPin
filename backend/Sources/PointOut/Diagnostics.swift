import Foundation

enum Diagnostics {
    private static let queue = DispatchQueue(label: "PointOut.metrics", qos: .utility)
    static func record(_ event: String, values: [String: Double] = [:], labels: [String: String] = [:]) {
        queue.async {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PinPin", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = folder.appendingPathComponent("performance.jsonl")
            let entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": event, "milliseconds": values, "labels": labels]
            guard let bytes = try? JSONSerialization.data(withJSONObject: entry) else { return }
            if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let file = try? FileHandle(forWritingTo: path) else { return }
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: bytes + Data([10]))
        }
    }
}
