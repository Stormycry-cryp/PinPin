import AppKit
import Foundation

/// 真实协议、模型和原生隐藏窗口；不接触用户资产、偏好或系统剪贴板。
@main struct AssetBoardTests {
    @MainActor static var checks = 0
    @MainActor static var scenarios = 0
    static let point = CGPoint(x: 450, y: 480)
    static let sharedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let color = PickedColor(red: 46, green: 94, blue: 158)
    static var saved: SavedItem {
        SavedItem(id: sharedID, text: "Café ＡＢ：把算过的结果先存下来，下次直接复用。",
                  appName: "备忘录", windowTitle: "产品讨论", tags: ["工作", "学习"],
                  createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    static var sampled: ColorRecord {
        ColorRecord(id: sharedID, color: color, createdAt: saved.createdAt,
                    appName: "Safari", windowTitle: "配色参考")
    }
    static var records: [AssetRecord] { [.saved(saved), .color(sampled), .saved(POSamples.imageItem)] }

    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func passed(_ name: String) {
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "所有窗口禁止上屏")
        scenarios += 1
        print("PASS \(name)")
        fflush(stdout)
    }
    static func settle(_ seconds: Double = 0.25) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    @MainActor static func layout(_ window: POFloatingWindow) {
        window.container.needsLayout = true
        window.container.layoutSubtreeIfNeeded()
        window.container.displayIfNeeded()
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        POPanel.testDefersWindowCreation = false
        POSamples.registerImages()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        routingAndSearch()
        editsAndCopies()
        delayedTagEdits()
        savedCardTagEdits()
        persistence(into: directory)
        windowLifecycle(into: directory)
        longText(into: directory)
        largeList(into: directory)
        render(into: directory)
        print("PASS \(scenarios) scenarios, \(checks) checks; no windows ordered on screen")
    }

    @MainActor static func routingAndSearch() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let presentation: PointOutPresentation = ui
        presentation.updateAssets(records)
        let model = ui.testAssetModel
        check(model.assets.count == 3 && model.results.count == 3, "真实updateAssets接入两种资产")
        check(model.assets.last?.id == .saved(sharedID) && model.assets[1].id == .color(sharedID),
              "统一时间倒序，相同时按类型和ID稳定排序")
        check(Set(model.assets.map(\.id)).count == 3, "相同UUID的收藏和颜色不冲突")
        model.query = "CAFE AB"
        check(model.results.map(\.id) == [.saved(sharedID)], "收藏搜索忽略大小写、重音和全半角")
        model.query = "#2e5e9e"
        check(model.results.map(\.id) == [.color(sharedID)], "按HEX搜索真实取色记录")
        model.query = "46, 94, 158"
        check(model.results.map(\.id) == [.color(sharedID)], "按RGB搜索真实取色记录")
        model.query = "配色参考"
        check(model.results.map(\.id) == [.color(sharedID)], "颜色来源窗口可搜索")
        model.query = "备忘录"
        check(model.results.map(\.id) == [.saved(sharedID)], "收藏来源应用可搜索")
        model.query = "学习"
        check(model.results.count == 2, "标签可搜索")
        model.query = ""
        model.tag = "工作"
        check(model.results.map(\.id) == [.saved(sharedID)], "标签筛选只返回拥有标签的收藏")
        model.scope = .color
        check(model.tag == nil && model.results.map(\.id) == [.color(sharedID)], "选择取色清除不适用的标签筛选")
        model.scope = .saved
        check(model.results.count == 2, "收藏类型筛选不混入颜色")
        model.scope = .all
        model.openRow = .color(sharedID)
        var edited = saved
        edited.tags = ["更新标签"]
        presentation.updateLibrary([edited, POSamples.imageItem])
        check(model.assets.contains { $0.id == .color(sharedID) }, "兼容updateLibrary不覆盖颜色历史")
        check(model.items.first(where: { $0.id == sharedID })?.tags == ["更新标签"], "兼容接口更新收藏标签")
        check(model.openRow == .color(sharedID), "同UUID收藏更新不改变颜色展开状态")
        presentation.updateAssets([.saved(edited)])
        check(model.openRow == nil && model.assets == [.saved(edited)], "完整资产快照删除旧项并清理对应展开状态")
        passed("协议接入、排序、类型隔离、搜索和兼容更新")
    }

    @MainActor static func editsAndCopies() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        ui.updateAssets(records)
        let model = ui.testAssetModel
        var copied: [String] = []
        model.onCopyText = { copied.append($0); return true }
        check(copied.isEmpty, "加载资产不会自动复制")
        model.copy(.saved(saved))
        model.copy(.color(sampled), format: .hex)
        model.copy(.color(sampled), format: .rgb)
        check(copied == [saved.text, color.hex, color.rgb], "复制文字、HEX、RGB只发送用户所选格式")
        check(model.assets.count == 3, "复制不修改资产")
        model.onCopyText = { _ in false }
        model.copy(.color(sampled))
        check(model.notice == "没能复制", "复制失败不声称成功")
        var deleted: [AssetRecord.ID] = []
        ui.onAssetEdit = { edit in if case .delete(let id) = edit { deleted.append(id) } }
        model.delete(.color(sharedID))
        check(deleted == [.color(sharedID)] && model.assets.count == 3, "按类型发送删除，不提前移除或声称成功")
        check(model.assets.contains(.color(sampled)), "无成功回传时颜色继续保留")
        ui.updateAssets(records.filter { $0.id != .color(sharedID) })
        check(!model.assets.contains { $0.id == .color(sharedID) }
              && model.assets.contains { $0.id == .saved(sharedID) }, "成功回传只移除该类型，不误删同UUID收藏")
        model.delete(.saved(sharedID))
        check(deleted.last == .saved(sharedID), "收藏删除走typed AssetEdit")
        var tagEdits: [LibraryEdit] = []
        ui.onLibraryEdit = { tagEdits.append($0) }
        model.addTag("  新标签  ", to: sharedID)
        if case .addTag(let id, let tag)? = tagEdits.last {
            check(id == sharedID && tag == "新标签", "新增只发送规范化后的标签意图")
        } else { check(false, "新增应发送addTag") }
        check(model.items.first { $0.id == sharedID }?.tags == saved.tags, "标签等成功回传后更新")
        model.addTag("", to: sharedID)
        model.addTag(String(repeating: "长", count: 17), to: sharedID)
        check(tagEdits.count == 1, "空或超长标签不发送")
        model.removeTag("工作", from: sharedID)
        if case .removeTag(let id, let tag)? = tagEdits.last {
            check(id == sharedID && tag == "工作", "移除只发送目标标签意图")
        } else { check(false, "移除应发送removeTag") }
        check(model.items.contains { $0.imageURL == POSamples.imageURL && $0.pointInImage == POSamples.imageItem.pointInImage },
              "标签和删除请求保留其他图片资产及原点")
        model.suspendNotice()
        passed("复制意图、删除确认边界与旧标签编辑")
    }

    @MainActor static func delayedTagEdits() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = ui.testAssetModel
        var submitted: [LibraryEdit] = []
        ui.onLibraryEdit = { submitted.append($0) }
        var persisted = saved
        func reset() {
            persisted = saved
            submitted = []
            ui.updateAssets([.saved(saved), .color(sampled)])
        }
        // 只模拟宿主的原子增删与成功快照，不读写真实资产磁盘。
        func apply(_ edit: LibraryEdit, success: Bool = true) {
            guard success else { return }
            switch edit {
            case .addTag(let id, let tag):
                check(id == sharedID, "新增关联正确收藏ID")
                if !persisted.tags.contains(tag) { persisted.tags.append(tag) }
            case .removeTag(let id, let tag):
                check(id == sharedID, "移除关联正确收藏ID")
                persisted.tags.removeAll { $0 == tag }
            default: check(false, "看板标签必须逐次发送增删意图，不能发送整组覆盖")
            }
        }
        func publish() { ui.updateAssets([.saved(persisted), .color(sampled)]) }
        func checkConfirmed(_ expected: [String], _ message: String) {
            check(model.items.first { $0.id == sharedID }?.tags == expected, message)
            check(model.assets.contains(.color(sampled)), "标签编辑保留同UUID取色资产")
        }
        reset()
        model.addTag("新标签", to: sharedID)
        model.removeTag("工作", from: sharedID)
        check(submitted.count == 2, "未回传时连续操作均发出")
        checkConfirmed(saved.tags, "等待成功快照期间保持已确认标签")
        for edit in submitted { apply(edit) }
        check(persisted.tags == ["学习", "新标签"], "延迟回传连续新增再移除必须保留累计意图")
        publish()
        checkConfirmed(["学习", "新标签"], "成功快照展示累计结果")

        reset()
        model.addTag("新增A", to: sharedID)
        model.addTag("新增B", to: sharedID)
        for edit in submitted { apply(edit) }
        publish()
        checkConfirmed(saved.tags + ["新增A", "新增B"], "连续新增不丢第一笔")

        reset()
        model.removeTag("工作", from: sharedID)
        model.removeTag("学习", from: sharedID)
        for edit in submitted { apply(edit) }
        publish()
        checkConfirmed([], "连续移除不恢复前一笔删除")

        reset()
        model.removeTag("工作", from: sharedID)
        model.addTag("工作", to: sharedID)
        model.addTag("临时", to: sharedID)
        model.removeTag("临时", from: sharedID)
        check(submitted.count == 4, "旧快照不拦截撤销未确认的增删")
        for edit in submitted { apply(edit) }
        publish()
        checkConfirmed(["学习", "工作"], "交替增删按意图顺序应用")

        reset()
        model.addTag("保存失败的标签", to: sharedID)
        model.removeTag("工作", from: sharedID)
        apply(submitted[0], success: false)
        checkConfirmed(saved.tags, "第一笔失败且没有回传时不显示成功或锁住编辑")
        apply(submitted[1]); publish()
        checkConfirmed(["学习"], "后续移除独立成功，不重试或夹带失败新增")
        model.addTag("后续标签", to: sharedID)
        apply(submitted.last!); publish()
        checkConfirmed(["学习", "后续标签"], "失败后仍可继续新增")

        reset()
        model.removeTag("工作", from: sharedID)
        model.removeTag("学习", from: sharedID)
        apply(submitted[0], success: false)
        apply(submitted[1]); publish()
        checkConfirmed(["工作"], "失败移除不影响下一次独立移除")

        reset()
        model.addTag("新增A", to: sharedID)
        model.addTag("新增B", to: sharedID)
        apply(submitted[0]); publish()
        checkConfirmed(saved.tags + ["新增A"], "第二笔已发出时仍接受第一笔成功快照")
        model.removeTag("新增B", from: sharedID)
        check(submitted.count == 3, "较早快照不阻止对未确认新增的移除意图")
        apply(submitted[1]); apply(submitted[2]); publish()
        checkConfirmed(saved.tags + ["新增A"], "中间快照不丢后续意图")

        reset()
        model.addTag("重复", to: sharedID)
        model.addTag("重复", to: sharedID)
        model.removeTag("不存在", from: sharedID)
        for edit in submitted { apply(edit) }
        publish()
        checkConfirmed(saved.tags + ["重复"], "重复增删由宿主幂等处理")
        let count = submitted.count
        model.addTag("未知记录", to: UUID())
        model.removeTag("未知记录", from: UUID())
        check(submitted.count == count, "不存在的收藏不产生编辑")
        passed("延迟回传、连续增删与失败后继续编辑")
    }

    @MainActor static func savedCardTagEdits() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let resultID = UUID()
        ui.beginResult(resultID, action: .save, at: point, processID: 101)
        ui.showSaved(resultID, item: saved, suggestions: ["建议"])
        ui.updateAssets([.saved(saved), .color(sampled)])
        let card = ui.testModel(resultID)!
        let board = ui.testAssetModel
        var submitted: [LibraryEdit] = []
        ui.onLibraryEdit = { submitted.append($0) }
        card.addTag("卡片新增")
        board.removeTag("工作", from: sharedID)
        card.toggleTag("学习")
        card.toggleTag("建议")
        check(submitted.count == 4, "收藏卡与看板交错发出四次原子意图")
        if case .saved(let current, _) = card.content {
            check(current.tags == saved.tags, "收藏卡未确认编辑不提前显示保存成功")
        } else { check(false, "收藏卡保持原内容类型") }
        var persisted = saved
        for edit in submitted {
            switch edit {
            case .addTag(let id, let tag):
                check(id == sharedID, "卡片新增使用收藏ID而非结果ID")
                if !persisted.tags.contains(tag) { persisted.tags.append(tag) }
            case .removeTag(let id, let tag):
                check(id == sharedID, "卡片移除使用收藏ID而非结果ID")
                persisted.tags.removeAll { $0 == tag }
            default: check(false, "卡片与看板不发完整标签覆盖")
            }
        }
        ui.updateLibrary([persisted])
        check(persisted.tags == ["卡片新增", "建议"], "交错操作累计保留全部意图")
        if case .saved(let current, _) = card.content {
            check(current.tags == persisted.tags, "成功回传同步收藏卡")
        } else { check(false, "收藏卡仍存在") }
        check(board.items.first?.tags == persisted.tags && board.assets.contains(.color(sampled)),
              "兼容回传同时更新看板并保留颜色")
        card.addTag("失败新增")
        ui.testOpen(resultID, dialog: true)
        if case .saved(let current, _) = card.content {
            check(current.tags == persisted.tags, "失败无回传时重开卡片仍显示已确认内容")
        }
        ui.clearAllMarkers()
        ui.previewComponent("saved", at: point)
        guard let sampleID = ui.testResultIDs.first, let sample = ui.testModel(sampleID) else { fatalError("缺少收藏示例") }
        sample.addTag("示例标签")
        if case .saved(let current, _) = sample.content {
            check(current.tags.contains("示例标签"), "示例新增本地立即展示")
        } else { check(false, "示例保持收藏内容") }
        sample.toggleTag("示例标签")
        if case .saved(let current, _) = sample.content {
            check(!current.tags.contains("示例标签"), "示例移除本地立即展示")
        }
        check(submitted.count == 5, "示例编辑不发送真实宿主请求")
        ui.clearAllMarkers()
        passed("收藏卡与看板交错增删及示例隔离")
    }

    @MainActor static func persistence(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let id = UUID()
        ui.beginResult(id, action: .pickColor, at: point, processID: 101)
        ui.showPickedColor(id, color: color)
        let card = ui.testModel(id)!
        var copied: [String] = []
        card.onCopy = { copied.append($0) }
        for state in [AssetPersistenceState.saving, .failed, .saved] {
            ui.updateColorPersistence(id, state: state)
            check(card.colorPersistence == state && card.content == .pickedColor(color), "保存状态\(state)不覆盖采样颜色")
            card.copyColor(.hex)
            check(copied.last == color.hex, "保存状态\(state)仍可复制")
            check(ui.testAssetModel.assets.isEmpty, "仅保存状态不会凭空向看板添加记录")
        }
        ui.updateColorPersistence(id, state: .failed)
        card.suspendNotice()
        renderPanels([ui.testWindow(id)!.panel], into: directory, file: "color-save-failed", title: "取色卡 · 保存失败仍可复制")
        ui.closeCard()
        ui.testOpen(id, dialog: true)
        check(ui.testModel(id)?.colorPersistence == .failed, "收起再开仍保留保存失败状态")
        ui.updateAssets([.color(ColorRecord(id: id, color: color, createdAt: Date(), appName: "Safari", windowTitle: "样本"))])
        ui.updateColorPersistence(id, state: .saved)
        card.onShowLibrary()
        check(ui.testAssetWindow?.isVisible == true && ui.testAssetModel.assets.count == 1, "取色结果按钮打开真实资产看板")
        ui.testRemove(id)
        ui.updateColorPersistence(id, state: .failed)
        check(!ui.testResultIDs.contains(id) && ui.testAssetModel.assets.count == 1, "关闭结果后迟到状态不复活卡片或删除历史")
        ui.clearAllMarkers()
        check(ui.testAssetModel.assets.count == 1, "清除全部标注保留资产历史")
        ui.testAssetModel.onClose()
        settle()
        passed("取色保存状态、失败复制和关闭结果保留历史")
    }

    @MainActor static func windowLifecycle(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        ui.updateAssets(records)
        ui.showSettings()
        settle()
        let settings = ui.testSettingsWindow!
        let drag = descendants(settings.container).compactMap { $0 as? POSettingsWindowDragView }.first!
        check(settings.container.hitTest(NSPoint(x: 49, y: settings.panel.frame.height - 21)) !== drag,
              "设置的资产入口不被窗口拖动区拦截")
        ui.testSettingsModel.onShowAssets()
        settle()
        let window = ui.testAssetWindow!
        let model = ui.testAssetModel
        check(window.isVisible && window.panel.level == .normal && !window.panel.isFloatingPanel,
              "设置入口创建普通层级资产看板")
        check(window.panel.isMovable && !window.panel.isMovableByWindowBackground, "窗口仅专用标题区移动")
        check(window.panel.frame.size == NSSize(width: 560, height: 500), "看板保持固定轻量视口")
        let handle = descendants(window.container).compactMap { $0 as? POSettingsWindowDragView }.first!
        let area = handle.convert(handle.bounds, to: window.container)
        check(area.height == 24 && window.container.hitTest(NSPoint(x: area.midX, y: area.midY)) === handle,
              "看板标题留白命中原生窗口拖动区")
        check(window.container.hitTest(NSPoint(x: window.panel.frame.width - 27, y: window.panel.frame.height - 28)) !== handle,
              "关闭按钮避开原生拖动区")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window.panel)
        check(window.isVisible, "失去焦点保持看板打开")
        ui.showWheel(at: point)
        check(window.isVisible, "试用轮盘不关闭看板")
        ui.hideWheel()
        let moved = NSPoint(x: window.panel.frame.minX + 40, y: window.panel.frame.minY - 30)
        window.panel.setFrameOrigin(moved)
        model.query = "Safari"
        model.scope = .color
        window.relayout()
        check(window.panel.frame.origin == moved, "搜索筛选和布局保留拖动后位置")
        model.onClose()
        settle()
        check(!window.isVisible, "关闭看板收起窗口")
        ui.showLibrary(near: nil)
        settle()
        check(ui.testAssetWindow === window && model.query == "Safari" && model.scope == .color,
              "重新打开复用窗口并保留查询筛选")
        renderPanels([settings.panel], into: directory, file: "settings-assets-entry", title: "设置 · 左上资产入口")
        model.onClose()
        ui.testSettingsModel.onClose()
        settle()
        passed("设置入口、普通窗口、原生拖动与关闭重开")
    }

    @MainActor static func longText(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var item = saved
        item.text = (1...40).map { "第\($0)段：收藏长文应在看板中完整阅读，滚动可继续查看后续内容。" }.joined(separator: "\n") + "\n正文末尾：完整内容到这里结束。"
        ui.updateAssets([.saved(item)])
        ui.showLibrary(near: nil)
        ui.testAssetModel.openRow = .saved(item.id)
        let window = ui.testAssetWindow!
        layout(window); settle(0.4)
        guard let scroll = descendants(window.container).compactMap({ $0 as? NSScrollView })
                .first(where: { ($0.documentView?.bounds.height ?? 0) > 800 }),
              let document = scroll.documentView else { fatalError("长文展开没有完整滚动高度") }
        check(document.bounds.height > 800, "展开长文布局超过六行并产生完整滚动高度")
        renderPanels([window.panel], into: directory, file: "assets-long-text-top", title: "资产看板 · 长文开头")
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        layout(window); settle(0.4)
        check(abs(scroll.contentView.bounds.origin.y - bottom) < 2, "原生列表可滚动到完整长文底部")
        renderPanels([window.panel], into: directory, file: "assets-long-text-bottom", title: "资产看板 · 长文末尾")
        ui.testAssetModel.onClose(); settle()
        passed("长文完整布局与原生滚动到末尾渲染")
    }

    @MainActor static func largeList(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = ui.testAssetModel
        let date = Date()
        let records: [AssetRecord] = (0..<10_000).map { i in
            let id = UUID()
            let created = date.addingTimeInterval(-Double(i))
            if i % 2 == 0 {
                return .saved(SavedItem(id: id, text: "记录 \(i)：可连续滚动访问。", appName: "测试",
                                        windowTitle: "entry-\(i)", tags: ["分类"], createdAt: created))
            }
            return .color(ColorRecord(id: id, color: PickedColor(red: UInt8(i % 256), green: 80, blue: 160),
                                      createdAt: created, appName: "测试", windowTitle: "entry-\(i)"))
        }
        POUIPerformance.reset()
        let start = ProcessInfo.processInfo.systemUptime
        ui.updateAssets(records)
        let indexedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        check(model.assets.count == 10_000 && model.results.count == 10_000, "一万条资产和搜索结果不截断")
        check(POUIPerformance.counters["assetIndex"] == 10_000, "每条新记录只建一次搜索索引")
        POUIPerformance.reset()
        ui.updateAssets(records)
        check(POUIPerformance.counters["assetIndex"] == nil, "相同快照复用索引")
        let searchStart = ProcessInfo.processInfo.systemUptime
        model.query = "entry-9999"
        let searchedMS = (ProcessInfo.processInfo.systemUptime - searchStart) * 1000
        check(model.results.map(\.id) == [records.last!.id], "最末记录可通过搜索访问")
        model.query = ""
        ui.showLibrary(near: nil)
        let window = ui.testAssetWindow!
        layout(window)
        settle(0.4)
        let mounted = model.testMountedIDs.count
        check(mounted > 0 && mounted < 100, "一万条初次仅挂载少量可见行：\(mounted)")
        let scrollers = descendants(window.container).compactMap { $0 as? NSScrollView }
        guard let scroll = scrollers.first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 10 }),
              let document = scroll.documentView else { fatalError("缺少资产列表滚动视图") }
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        layout(window)
        settle(0.4)
        check(model.testMountedIDs.contains(records.last!.id), "一万条末项可通过同一原生列表滚动到达")
        check(model.testMountedIDs.count < 200, "滚到末尾没有创建全部一万行")
        let report: [String: Any] = ["records": records.count, "indexedMilliseconds": indexedMS,
                                    "searchMilliseconds": searchedMS, "initialMountedRows": mounted,
                                    "mountedAfterBottomScroll": model.testMountedIDs.count]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: directory.appendingPathComponent("large-list.json"))
        print(String(decoding: data, as: UTF8.self))
        model.onClose()
        settle()
        passed("一万条连续列表、索引复用与可见行资源")
    }

    @MainActor static func render(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let extra = ColorRecord(id: UUID(), color: PickedColor(red: 237, green: 198, blue: 137),
                                createdAt: Date(timeIntervalSinceNow: -600), appName: "预览", windowTitle: "色彩笔记")
        ui.updateAssets(records + [.color(extra)] + POSamples.savedList.filter { $0.id != POSamples.imageItem.id }.map(AssetRecord.saved))
        ui.showLibrary(near: nil)
        let model = ui.testAssetModel
        let window = ui.testAssetWindow!
        renderPanels([window.panel], into: directory, file: "assets-all", title: "资产看板 · 收藏与取色")
        model.scope = .color
        model.openRow = .color(extra.id)
        renderPanels([window.panel], into: directory, file: "assets-colors", title: "资产看板 · 取色详情")
        model.scope = .saved
        model.openRow = .saved(POSamples.imageItem.id)
        renderPanels([window.panel], into: directory, file: "assets-image", title: "资产看板 · 图片与标签")
        model.query = "不存在的内容"
        renderPanels([window.panel], into: directory, file: "assets-no-match", title: "资产看板 · 搜索为空")
        model.query = ""
        ui.updateAssets([])
        renderPanels([window.panel], into: directory, file: "assets-empty", title: "资产看板 · 空库")
        model.onClose()
        settle()
        passed("真实组件浅深色与各状态渲染")
    }

    /// 对真实 NSHostingView / CALayer 做离屏绘制；没有交给 WindowServer 显示。
    @MainActor static func renderPanels(_ panels: [POPanel], into directory: URL, file: String, title: String,
                                        prepare: () -> Void = {}) {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for panel in panels {
                panel.appearance = NSAppearance(named: appearanceName)
            }
            prepare()
            for panel in panels {
                panel.contentView?.wantsLayer = true
                panel.contentView?.needsLayout = true
                panel.contentView?.layoutSubtreeIfNeeded()
            }
            settle(0.35)
            let caption = "PinPin \(title) · \(name == "light" ? "浅色" : "深色") · 真实组件离屏检查"
            let captionAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: name == "light" ? 0.2 : 0.9, alpha: 1)
            ]
            let captionWidth = (caption as NSString).size(withAttributes: captionAttributes).width
            let union = panels.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -32, dy: -32)
            let width = Int(ceil(max(union.width, captionWidth + 40))), height = Int(ceil(union.height + 44))
            let inset = (CGFloat(width) - union.width) / 2
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("render context") }
            bitmap.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            NSColor(white: name == "light" ? 0.83 : 0.13, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for panel in panels {
                guard let view = panel.contentView, let layer = view.layer else { fatalError("render view") }
                view.displayIfNeeded()
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: panel.frame.minX - union.minX + inset, y: panel.frame.minY - union.minY)
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
            (caption as NSString).draw(at: NSPoint(x: 20, y: height - 25), withAttributes: captionAttributes)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG export") }
            do { try png.write(to: directory.appendingPathComponent("\(file)-\(name).png")) }
            catch { fatalError("PNG write: \(error)") }
            check(NSApp.windows.allSatisfy { !$0.isVisible }, "渲染全程窗口不上屏")
        }
    }
}
