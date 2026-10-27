import Foundation

extension AssetRecord {
    private var sortKey: String {
        switch self {
        case .saved(let item): return "saved:\(item.id.uuidString)"
        case .color(let item): return "color:\(item.id.uuidString)"
        }
    }
    static func merged(saved: [SavedItem], colors: [ColorRecord]) -> [AssetRecord] {
        (saved.map(AssetRecord.saved) + colors.map(AssetRecord.color)).sorted {
            $0.createdAt == $1.createdAt ? $0.sortKey < $1.sortKey : $0.createdAt > $1.createdAt
        }
    }
}
