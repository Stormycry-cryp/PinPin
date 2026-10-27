import AppKit
import SwiftUI

// MARK: - 统一资产看板（design-system.md §12，R171）

@MainActor final class POLibraryModel: ObservableObject {
    enum Scope: String, CaseIterable { case all = "全部", saved = "收藏", color = "取色" }
    @Published private(set) var assets: [AssetRecord] = []
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published var tag: String? { didSet { if tag != oldValue { refresh() } } }
    @Published var scope: Scope = .all {
        didSet {
            guard scope != oldValue else { return }
            if scope == .color { tag = nil }
            refresh()
        }
    }
    @Published var openRow: AssetRecord.ID?
    @Published var isSample = false
    @Published var notice: String?
    /// 全部匹配项可连续滚动；视图由 LazyVStack 按需创建。
    @Published private(set) var results: [AssetRecord] = []
    @Published private(set) var tags: [String] = []
    var announces = true
    var onDelete: (AssetRecord.ID) -> Void = { _ in }
    var onAddTag: (UUID, String) -> Void = { _, _ in }
    var onRemoveTag: (UUID, String) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    var onCopyText: (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    private var noticeTask: Task<Void, Never>?
    #if PINPIN_UI_TESTING
    var testMountedIDs: Set<AssetRecord.ID> = []
    #endif

    /// 旧收藏回传和既有示例入口仍可使用；不覆盖独立的取色记录。
    var items: [SavedItem] {
        get { assets.compactMap { if case .saved(let item) = $0 { return item }; return nil } }
        set { receive(assets.filter { if case .color = $0 { return true }; return false } + newValue.map(AssetRecord.saved)) }
    }

    private static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private struct Entry { let asset: AssetRecord; let fields: [String] }
    private var entries: [AssetRecord.ID: Entry] = [:]
    static func fold(_ text: String) -> String { text.folding(options: foldOptions, locale: nil) }

    deinit { noticeTask?.cancel() }

    func receive(_ records: [AssetRecord]) {
        let ordered = records.sorted {
            $0.createdAt == $1.createdAt ? Self.sortKey($0) < Self.sortKey($1) : $0.createdAt > $1.createdAt
        }
        guard ordered != assets else { return }
        assets = ordered
        reindex()
        if let openRow, entries[openRow] == nil { self.openRow = nil }
        if let tag, !tags.contains(tag) { self.tag = nil }
        refresh()
    }

    private static func sortKey(_ asset: AssetRecord) -> String {
        switch asset {
        case .saved(let item): return "saved:\(item.id.uuidString)"
        case .color(let item): return "color:\(item.id.uuidString)"
        }
    }

    private func reindex() {
        var next: [AssetRecord.ID: Entry] = [:]
        next.reserveCapacity(assets.count)
        var counts: [String: Int] = [:]
        var order: [String] = []
        for asset in assets {
            if let entry = entries[asset.id], entry.asset == asset { next[asset.id] = entry }
            else {
                let fields: [String]
                switch asset {
                case .saved(let item): fields = [item.text, item.appName, item.windowTitle] + item.tags
                case .color(let item): fields = [item.color.hex, item.color.rgb, item.appName, item.windowTitle]
                }
                next[asset.id] = Entry(asset: asset, fields: fields.map(Self.fold))
                #if PINPIN_UI_TESTING
                POUIPerformance.count("assetIndex")
                #endif
            }
            if case .saved(let item) = asset {
                for t in item.tags {
                    if counts[t] == nil { order.append(t) }
                    counts[t, default: 0] += 1
                }
            }
        }
        entries = next
        let nextTags = order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map(\.element)
        if tags != nextTags { tags = nextTags }
    }

    private func refresh() {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let found = assets.filter { asset in
            switch (scope, asset) {
            case (.saved, .color), (.color, .saved): return false
            default: break
            }
            if let tag {
                guard case .saved(let item) = asset, item.tags.contains(tag) else { return false }
            }
            return q.isEmpty || entries[asset.id]?.fields.contains(where: { $0.range(of: q, options: .literal) != nil }) == true
        }
        if results != found { results = found }
    }

    func toggle(_ id: AssetRecord.ID) { openRow = openRow == id ? nil : id }

    func copy(_ asset: AssetRecord, format: POCardModel.ColorFormat = .hex) {
        let text: String
        switch asset {
        case .saved(let item): text = item.text
        case .color(let item): text = format == .hex ? item.color.hex : item.color.rgb
        }
        guard !text.isEmpty else { return }
        flash(onCopyText(text) ? "已复制" : "没能复制")
    }

    func delete(_ id: AssetRecord.ID) {
        guard entries[id] != nil else { return }
        if isSample { receive(assets.filter { $0.id != id }) }
        else { onDelete(id) }
        // 宿主成功回传后才移除；没有成功回传时保留原记录。
    }

    func addTag(_ raw: String, to id: UUID) { editTag(raw, for: id, adding: true) }
    func removeTag(_ raw: String, from id: UUID) { editTag(raw, for: id, adding: false) }

    private func editTag(_ raw: String, for id: UUID, adding: Bool) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, tag.count <= 16,
              case .saved(var item)? = entries[.saved(id)]?.asset else { return }
        if isSample {
            if adding {
                if !item.tags.contains(tag) { item.tags.append(tag) }
            } else { item.tags.removeAll { $0 == tag } }
            receive(assets.map { $0.id == .saved(id) ? .saved(item) : $0 })
        } else {
            // 旧快照可能尚未包含前一笔操作；只发送意图，由宿主按当前持久化状态处理。
            if adding { onAddTag(id, tag) } else { onRemoveTag(id, tag) }
        }
    }

    func suspendNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    func flash(_ text: String) {
        noticeTask?.cancel()
        notice = text
        if announces {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
            self.noticeTask = nil
        }
    }
}

enum POAssetBoardMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 500
    static let padding: CGFloat = 16
    static let rowRadius: CGFloat = 10
}

struct POAssetBoardView: View {
    @ObservedObject var model: POLibraryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            search
            filters
            if !model.tags.isEmpty, model.scope != .color {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        POTagChip(title: "所有标签", selected: model.tag == nil) { model.tag = nil }
                        ForEach(model.tags, id: \.self) { t in
                            POTagChip(title: t, selected: model.tag == t) { model.tag = model.tag == t ? nil : t }
                        }
                    }
                    .padding(3)
                }
                .frame(height: 27)
            }
            if model.results.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "tray")
                        .font(.system(size: 23, weight: .light))
                        .accessibilityHidden(true)
                    Text(model.assets.isEmpty ? "还没有资产" : "没有找到相关资产")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(POPalette.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.results) { asset in
                            POAssetRow(asset: asset, open: model.openRow == asset.id,
                                       onToggle: { model.toggle(asset.id) },
                                       onCopy: { model.copy(asset, format: $0) },
                                       onDelete: { model.delete(asset.id) },
                                       onAddTag: { if case .saved(let item) = asset { model.addTag($0, to: item.id) } },
                                       onRemoveTag: { if case .saved(let item) = asset { model.removeTag($0, from: item.id) } })
                                .onAppear {
                                    #if PINPIN_UI_TESTING
                                    POUIPerformance.count("assetRowMounted")
                                    model.testMountedIDs.insert(asset.id)
                                    #endif
                                }
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(POAssetBoardMetrics.padding)
        .frame(width: POAssetBoardMetrics.width, height: POAssetBoardMetrics.height)
        .onExitCommand { model.onClose() }
        .onAppear { focused = true }
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            POSettingsWindowDragArea().padding(.trailing, 34).accessibilityHidden(true)
            HStack(spacing: 8) {
                Text("资产看板")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(POPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
                Text("\(model.assets.count) 项")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(POPalette.inkTertiary)
                    .allowsHitTesting(false)
                if model.isSample { POSampleBadge().allowsHitTesting(false) }
                Spacer()
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(POPalette.inkSecondary)
                        .allowsHitTesting(false)
                }
                POIconButton(symbol: "xmark", label: "关闭资产看板", action: model.onClose)
            }
        }
        .frame(height: 24)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(POPalette.inkTertiary).accessibilityHidden(true)
            TextField("", text: $model.query,
                      prompt: Text("搜索内容、标签或色值").foregroundStyle(POPalette.inkTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(POPalette.ink)
                .focused($focused)
                .accessibilityLabel("搜索资产")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(POPalette.inkTertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .poWell()
    }

    private var filters: some View {
        HStack(spacing: 7) {
            ForEach(POLibraryModel.Scope.allCases, id: \.self) { scope in
                POTagChip(title: scope.rawValue, selected: model.scope == scope) { model.scope = scope }
            }
            Spacer()
            if model.results.count != model.assets.count {
                Text("\(model.results.count) 项")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(POPalette.inkTertiary)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 25)
    }
}

struct POAssetRow: View {
    let asset: AssetRecord
    let open: Bool
    let onToggle: () -> Void
    let onCopy: (POCardModel.ColorFormat) -> Void
    let onDelete: () -> Void
    let onAddTag: (String) -> Void
    let onRemoveTag: (String) -> Void
    @State private var hover = false

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var source: String {
        switch asset {
        case .saved(let item): return [item.appName, item.windowTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        case .color(let item): return [item.appName, item.windowTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
    private var kind: String { if case .saved = asset { return "收藏" }; return "取色" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onToggle) { summary }
                    .buttonStyle(.plain)
                    .accessibilityHint(open ? "收起详情" : "展开详情")
                HStack(spacing: 3) {
                    POIconButton(symbol: "doc.on.doc", label: copyLabel) { onCopy(.hex) }
                        .disabled(!canCopy)
                    POIconButton(symbol: "trash", label: "删除\(kind)", action: onDelete)
                }
                .opacity(hover || open ? 1 : 0)
                .allowsHitTesting(hover || open)
            }
            if open { detail }
        }
        .padding(10)
        .background {
            let shape = RoundedRectangle(cornerRadius: POAssetBoardMetrics.rowRadius, style: .continuous)
            if open { shape.poWellFill(depth: 1.2) }
            else if hover { shape.poRaisedFill(depth: 1.2) }
        }
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: copyLabel) { if canCopy { onCopy(.hex) } }
        .accessibilityAction(named: "删除\(kind)", onDelete)
        .contextMenu {
            Button(copyLabel) { onCopy(.hex) }.disabled(!canCopy)
            if case .color = asset { Button("复制 RGB") { onCopy(.rgb) } }
            Divider()
            Button("删除\(kind)", action: onDelete)
        }
    }

    private var canCopy: Bool { if case .saved(let item) = asset { return !item.text.isEmpty }; return true }
    private var copyLabel: String { if case .color = asset { return "复制 HEX" }; return "复制文字" }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            switch asset {
            case .saved(let item):
                if let url = item.imageURL { POThumbnail(url: url, side: 38) }
                else {
                    Image(systemName: "bookmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(POPalette.inkSecondary)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 7).poWellFill(depth: 1))
                }
            case .color(let item):
                POAssetSwatch(color: item.color).frame(width: 38, height: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                switch asset {
                case .saved(let item):
                    Text(item.text.isEmpty ? "图片收藏" : item.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(POPalette.ink)
                        .lineLimit(2)
                case .color(let item):
                    HStack(spacing: 9) {
                        Text(item.color.hex).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(item.color.rgb).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(POPalette.inkSecondary)
                    }
                    .foregroundStyle(POPalette.ink)
                    .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(kind)
                    Text("·")
                    Text(Self.formatter.localizedString(for: asset.createdAt, relativeTo: Date()))
                    if case .saved(let item) = asset, !item.tags.isEmpty {
                        Text("·")
                        Text(item.tags.joined(separator: " · "))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(POPalette.inkTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        switch asset {
        case .saved(let item):
            if let url = item.imageURL {
                POSavedImage(url: url, point: item.pointInImage, expanded: true,
                             width: POAssetBoardMetrics.width - 2 * POAssetBoardMetrics.padding - 26,
                             label: item.text)
                    .frame(maxWidth: .infinity)
            }
            if !item.text.isEmpty {
                Text(item.text).font(.system(size: 12.5)).lineSpacing(2)
                    .foregroundStyle(POPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            POAssetTagEditor(tags: item.tags, onAdd: onAddTag, onRemove: onRemoveTag)
        case .color(let item):
            HStack(spacing: 12) {
                POAssetSwatch(color: item.color).frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    colorValue("HEX", item.color.hex, format: .hex)
                    colorValue("RGB", item.color.rgb, format: .rgb)
                }
            }
        }
        if !source.isEmpty {
            Text(source).font(.system(size: 10.5)).foregroundStyle(POPalette.inkTertiary)
                .lineLimit(2).textSelection(.enabled)
        }
    }

    private func colorValue(_ title: String, _ value: String, format: POCardModel.ColorFormat) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(POPalette.inkTertiary)
                .frame(width: 28, alignment: .leading)
            Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(POPalette.ink)
                .textSelection(.enabled)
            POIconButton(symbol: "doc.on.doc", label: "复制 \(title)") { onCopy(format) }
        }
    }
}

struct POAssetSwatch: View {
    let color: PickedColor
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(.sRGB, red: Double(color.red) / 255,
                        green: Double(color.green) / 255, blue: Double(color.blue) / 255, opacity: 1))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(POPalette.hairline, lineWidth: 0.5))
            .accessibilityLabel("颜色 \(color.hex)，sRGB")
    }
}

private struct POAssetTagEditor: View {
    let tags: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    @State private var adding = false
    @State private var newTag = ""
    @FocusState private var focused: Bool

    var body: some View {
        POFlowLayout(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                POTagChip(title: tag, selected: true) { onRemove(tag) }
                    .help("移除标签 \(tag)")
            }
            if adding {
                TextField("", text: $newTag, prompt: Text("新标签"))
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(POPalette.ink)
                    .frame(width: 80, height: 21).padding(.horizontal, 8).poWellCapsule()
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { adding = false; newTag = "" }
                    .accessibilityLabel("添加收藏标签")
            } else {
                POIconButton(symbol: "plus", label: "添加标签") { adding = true; focused = true }
            }
        }
        .onChange(of: focused) { _, focused in if !focused { commit() } }
    }

    private func commit() {
        guard adding else { return }
        onAdd(newTag)
        newTag = ""
        adding = false
    }
}

/// Small square preview for an image save in the library list.
struct POThumbnail: View {
    let url: URL
    var side: CGFloat = 32
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.poWellFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(POPalette.hairline, lineWidth: 0.5))
        .task(id: url) { image = await POImageLoader.load(url, maxPixel: Int(side * 3)) }
        .accessibilityHidden(true)
    }
}

// MARK: - Permission help (§10)

@MainActor final class POPermissionModel: ObservableObject {
    @Published var accessibility = false
    @Published var screenCapture = false
}

struct POPermissionView: View {
    @ObservedObject var model: POPermissionModel
    var onClose: () -> Void = {}

    var body: some View {
        let ready = model.accessibility && model.screenCapture
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ready ? "权限已就绪" : "PinPin 需要两项权限")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(POPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                POIconButton(symbol: "xmark", label: "关闭", action: onClose)
            }
            VStack(spacing: 8) {
                #if PINPIN_APP_STORE
                row(symbol: "hand.point.up.left", title: "辅助功能", detail: "响应全局快捷手势",
                    granted: model.accessibility, url: POSystemSettings.accessibility)
                row(symbol: "rectangle.dashed", title: "屏幕录制", detail: "获取你指向的窗口图像",
                    granted: model.screenCapture, url: POSystemSettings.screenCapture)
                #else
                row(symbol: "hand.point.up.left", title: "辅助功能", detail: "响应手势，读取选中的文字",
                    granted: model.accessibility, url: POSystemSettings.accessibility)
                row(symbol: "rectangle.dashed", title: "屏幕录制", detail: "识别你指向的内容",
                    granted: model.screenCapture, url: POSystemSettings.screenCapture)
                #endif
            }
        }
        .padding(14)
        .frame(width: POMetrics.permissionWidth, alignment: .leading)
        .onExitCommand(perform: onClose)
    }

    private func row(symbol: String, title: String, detail: String, granted: Bool, url: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(POPalette.ink)
                .frame(width: 30, height: 30)
                .background(Circle().poRaisedFill(depth: 1.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(POPalette.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(POPalette.inkSecondary)
            }
            Spacer(minLength: 8)
            if granted {
                // Done: the key stays pressed in, with a check.
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(POPalette.ink)
                    .frame(width: 24, height: 24)
                    .background(Circle().poWellFill(depth: 1.3))
                    .accessibilityLabel("\(title)已开启")
            } else {
                POPillButton(title: "去开启") { POSystemSettings.open(url) }
                    .accessibilityLabel("开启\(title)")
            }
        }
    }
}
