import AppKit
import Foundation
import Combine

/// 编译真实 UI 源码并执行实际展示状态和回调；所有 POPanel 禁止上屏。
@main
struct MultipleCardsTests {
    @MainActor static var checks = 0
    @MainActor static var scenarios = 0
    static let point = CGPoint(x: 240, y: 260)

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                                 file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)", file: file, line: line) }
    }

    @MainActor static func passed(_ name: String) {
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "测试中不得有原生窗口上屏")
        scenarios += 1
        print("PASS \(name)")
    }

    @MainActor static func begin(_ ui: OverlayPresentation, owner: pid_t = 101, action: PointOutAction = .explain,
                                text: String? = nil) -> UUID {
        let id = UUID()
        ui.beginResult(id, action: action, at: point, processID: owner)
        if let text { ui.updateResult(id, text: text, subtitle: nil); ui.finishResult(id) }
        return id
    }

    @MainActor static func answer(_ ui: OverlayPresentation, _ id: UUID) -> String? {
        guard case .answer(_, let text, _) = ui.testModel(id)?.content else { return nil }
        return text
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        interleavedAnswers()
        replyCoachAnswer()
        backgroundFailure()
        activeFailure()
        independentRemoval()
        menuAndOrdering()
        gestureAndOutside()
        appVisibility()
        capacityAndClear()
        failuresAndPending()
        focusState()
        savedActions()
        previewAndLifecycle()
        streamVisibilityRaces()
        print("PASS \(scenarios) scenarios, \(checks) checks; no windows ordered on screen")
    }

    @MainActor static func interleavedAnswers() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui), b = begin(ui, action: .translate)
        check(ui.testVisibleIDs == [a, b], "两个初答窗口同时存在")
        check(ui.testModel(a) !== ui.testModel(b), "A/B 使用独立模型")
        check(ui.testWindow(a) !== ui.testWindow(b), "A/B 使用独立原生窗口")
        ui.updateResult(b, text: "B first", subtitle: "英 → 中")
        ui.updateResult(a, text: "A first", subtitle: nil)
        ui.finishResult(b)
        ui.updateResult(a, text: "A full", subtitle: nil)
        ui.finishResult(a)
        check(answer(ui, a) == "A full", "A 收到自己的完整答案")
        check(answer(ui, b) == "B first", "B 不被 A 更新")
        check(ui.testOrder.last == b, "后台流式更新不改变前后顺序")
        ui.testOpen(a, dialog: true)
        ui.testModel(a)!.draft = "A draft"
        ui.testOpen(b, dialog: true)
        ui.testModel(b)!.draft = "B draft"
        ui.updateResult(a, text: "A final", subtitle: nil)
        check(ui.testModel(a)?.draft == "A draft" && ui.testModel(b)?.draft == "B draft", "流式更新保留各自草稿")
        ui.clearAllMarkers()
        passed("A/B 交错流式更新、独立窗口与模型")
    }

    @MainActor static func replyCoachAnswer() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var sent: [(UUID, String)] = []
        ui.onFollowUp = { sent.append(($0, $1)) }
        let id = begin(ui, action: .replyCoach)
        ui.updateResult(id, text: "对方想确认进度。", subtitle: nil)
        check(answer(ui, id) == "对方想确认进度。", "嘴替使用已有流式文本结果")
        ui.updateResult(id, text: POSamples.replyCoach, subtitle: nil)
        ui.finishResult(id)
        ui.testOpen(id, dialog: true)
        let model = ui.testModel(id)!
        check(model.supportsFollowUp && model.plainText == POSamples.replyCoach, "嘴替完整回答支持追问与复制")
        var copied: String?
        model.onCopy = { copied = $0 }
        model.copy()
        check(copied == POSamples.replyCoach && sent.isEmpty, "复制完整建议只触发复制回调")
        if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), CommandLine.arguments.count > index + 1 {
            renderMultiple(ui, into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true), file: "reply-coach-card")
        }
        model.draft = "语气更自然一点"
        check(sent.isEmpty, "输入草稿不会自动发送")
        model.submitFollowUp()
        check(sent.count == 1 && sent[0].0 == id && sent[0].1 == "语气更自然一点", "明确提交才将嘴替追问交给宿主")
        ui.failResult(id, message: "请稍后重试", kind: .temporaryService)
        check(answer(ui, id) == POSamples.replyCoach && model.draft == "语气更自然一点", "嘴替追问失败保留完整建议与问题")
        ui.clearAllMarkers()
        passed("嘴替流式回答、复制、主动追问与失败恢复")
    }

    @MainActor static func backgroundFailure() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A stable"), b = begin(ui, text: "B stable")
        var sent: [(UUID, String)] = []
        ui.onFollowUp = { sent.append(($0, $1)) }
        ui.testOpen(a, dialog: true)
        ui.testModel(a)!.draft = "A question"
        ui.testModel(a)!.submitFollowUp()
        check(sent.count == 1 && sent[0].0 == a && sent[0].1 == "A question", "追问闭包绑定 A")
        ui.updateResult(a, text: "A partial", subtitle: nil)
        ui.testModel(a)!.onClose()
        ui.testOpen(b, dialog: true)
        ui.testModel(b)!.draft = "B unsent"
        ui.failResult(a, message: "请稍后再试", kind: .temporaryService)
        check(ui.testVisibleIDs == [b], "后台失败不让 A 自行出现")
        check(answer(ui, a) == "A partial", "收起期间不向隐藏模型发布回退答案")
        check(ui.testModel(a)?.draft == "", "收起期间不发布失败草稿到视图")
        check(ui.testModel(a)?.notice == nil, "收起时不提前消耗错误提示")
        check(answer(ui, b) == "B stable" && ui.testModel(b)?.draft == "B unsent", "B 内容和草稿不变")
        ui.testOpen(a, dialog: true)
        check(answer(ui, a) == "A stable" && ui.testModel(a)?.draft == "A question", "重开恢复完整答案和失败草稿")
        check(ui.testModel(a)?.notice == "请稍后再试", "下次打开提示失败原因")
        ui.testModel(a)!.onClose()
        ui.testOpen(a, dialog: true)
        check(ui.testModel(a)?.notice == nil, "同一失败提示只出现一次")
        check(ui.testModel(a)?.draft == "A question", "再次打开仍保留失败草稿")
        ui.clearAllMarkers()
        passed("后台 A 追问失败恢复答案、草稿与一次提示")
    }

    @MainActor static func activeFailure() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A stable"), b = begin(ui, text: "B stable")
        ui.onFollowUp = { _, _ in }
        ui.testOpen(a, dialog: true)
        ui.testOpen(b, dialog: true)
        ui.testModel(b)!.draft = "B typing"
        ui.testModel(b)!.inputFocused = true
        ui.testModel(a)!.draft = "A ask"
        ui.testModel(a)!.submitFollowUp()
        ui.failResult(a, message: "A failed", kind: .temporaryService)
        check(ui.testVisibleIDs == [a, b], "失败只更新 A，不替换 B")
        check(ui.testModel(a)?.notice == "A failed" && ui.testModel(b)?.notice == nil, "失败提示只属于 A")
        check(ui.testModel(b)?.inputFocused == true && ui.testModel(b)?.draft == "B typing", "A 失败不重置 B 输入状态")
        ui.clearAllMarkers()
        passed("可见 A 追问失败与 B 输入隔离")
    }

    @MainActor static func independentRemoval() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui), b = begin(ui, text: "B")
        var forgotten: [UUID] = []
        ui.onForget = { forgotten.append($0) }
        ui.testRemove(a)
        ui.updateResult(a, text: "late", subtitle: nil)
        ui.finishResult(a)
        ui.failResult(a, message: "late failure", kind: nil)
        ui.showSaved(a, item: POSamples.savedItem, suggestions: [])
        ui.testRemove(a)
        check(forgotten == [a], "单独关闭 A 只释放 A 一次")
        check(ui.testResultIDs == [b] && ui.testCardIDs == [b], "迟到回调不能复活 A")
        check(ui.testVisibleIDs == [b] && answer(ui, b) == "B", "B 仍可见且内容不变")
        ui.clearAllMarkers()
        passed("独立关闭、重复关闭及迟到回调")
    }

    @MainActor static func menuAndOrdering() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A stable"), b = begin(ui, text: "B stable")
        var cancelled: [UUID] = [], forgotten: [UUID] = []
        ui.onCancel = { cancelled.append($0) }
        ui.onForget = { forgotten.append($0) }
        ui.onFollowUp = { _, _ in }
        ui.testOpen(a, dialog: true)
        ui.testModel(a)!.draft = "A question"
        ui.testModel(a)!.submitFollowUp()
        ui.testClick(b)
        ui.updateResult(a, text: "A streaming", subtitle: nil)
        check(ui.testOrder.last == b, "更新 A 不挤到 B 前面")
        ui.testHover(a, inside: true)
        check(ui.testOrder.last == b, "悬停不改变前后顺序")
        ui.testClick(a)
        check(ui.testOrder.last == a, "点击 A 将 A 移到最前")
        ui.closeCard()
        check(cancelled == [a] && forgotten.isEmpty, "菜单取消 A 追问，保留完成结果")
        check(ui.testResultIDs.contains(a) && ui.testVisibleIDs == [b], "关闭 A 不影响 B")
        ui.testOpen(a, dialog: true)
        check(answer(ui, a) == "A stable", "取消追问后重开恢复完整答案")
        let c = begin(ui)
        ui.closeCard()
        check(forgotten == [c] && !ui.testResultIDs.contains(c), "菜单关闭未完成初答只遗忘 C")
        ui.clearAllMarkers()
        passed("菜单关闭、点击层级与收起/取消区别")
    }

    @MainActor static func gestureAndOutside() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A"), b = begin(ui, text: "B"), c = begin(ui, text: "C")
        ui.testOpen(a, dialog: true)
        ui.testModel(c)!.onClose()
        ui.testOpen(c, peek: true)
        ui.testHover(c, inside: false)
        check(ui.testHasLeaveTask(c), "悬停短卡片有独立离开任务")
        ui.showWheel(at: point)
        check(ui.testVisibleIDs == [a, b], "新手势只收起悬停打开的 C")
        check(!ui.testHasLeaveTask(c), "收起取消 C 的离开任务")
        ui.hideWheel()
        ui.testOutside(optionHeld: true)
        check(ui.testVisibleIDs == [a, b], "Option 按下不当作外部关闭")
        ui.testOutside()
        check(ui.testVisibleIDs == [a], "普通外部点击收起 B 短卡，保留 A 对话框")
        ui.testOpen(b)
        ui.testModel(b)!.draft = "unsent"
        ui.testOutside()
        check(ui.testVisibleIDs == [a, b], "有草稿的卡片保留")
        ui.clearAllMarkers()
        passed("新手势、外部点击、悬停延时隔离")
    }

    @MainActor static func appVisibility() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, owner: 101, text: "A"), b = begin(ui, owner: 202, text: "B")
        let c = begin(ui, owner: 101, text: "C")
        for id in [a, b, c] { ui.testOpen(id, dialog: true) }
        ui.testModel(a)!.draft = "A draft"
        ui.testModel(b)!.draft = "B draft"
        ui.updateResultSource(a, at: point, visible: true)
        ui.updateResultSource(b, at: point, visible: true)
        check(ui.testVisibleIDs == [a, b, c], "不同应用和同应用多窗口同时可见")
        ui.updateResultSource(a, at: point, visible: false)
        check(ui.testVisibleIDs == [b, c], "只隐藏不可见源窗口的卡片")
        var published = 0
        let subscription = ui.testModel(a)!.objectWillChange.sink { published += 1 }
        ui.updateResult(a, text: "A while hidden", subtitle: nil)
        ui.finishResult(a)
        check(published == 0, "隐藏流式和完成不发布视图模型")
        check(ui.testVisibleIDs == [b, c], "隐藏流式不使卡片出现")
        ui.updateResultSource(a, at: point, visible: true)
        check(ui.testVisibleIDs == [a, b, c], "恢复源窗口保留全部可见卡片")
        check(answer(ui, a) == "A while hidden" && ui.testModel(a)?.draft == "A draft", "恢复最新正文和草稿")
        ui.onFollowUp = { _, _ in }
        ui.testModel(a)!.draft = "A hidden question"
        ui.testModel(a)!.submitFollowUp()
        ui.updateResultSource(a, at: point, visible: false)
        ui.failResult(a, message: "source hidden failure", kind: nil)
        check(ui.testModel(a)?.notice == nil && !ui.testVisibleIDs.contains(a), "隐藏源窗口的失败不弹出")
        ui.updateResultSource(a, at: point, visible: true)
        check(ui.testModel(a)?.draft == "A hidden question" && ui.testModel(a)?.notice == "source hidden failure", "恢复失败草稿和一次提示")
        ui.testModel(a)!.onClose()
        ui.testOpen(a, peek: true)
        ui.updateResultSource(a, at: point, visible: false)
        ui.updateResultSource(a, at: point, visible: true)
        check(!ui.testVisibleIDs.contains(a), "源窗口隐藏时悬停短卡收起")
        withExtendedLifetime(subscription) {}
        ui.clearAllMarkers()
        passed("源窗口可见性、隐藏流式与草稿")
        sourcePosition()
    }

    @MainActor static func sourcePosition() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let id = begin(ui, text: "position")
        let window = ui.testWindow(id)!
        let original = window.panel.frame
        window.panel.setFrameOrigin(CGPoint(x: original.minX + 17, y: original.minY + 11))
        let target = CGPoint(x: point.x + 80, y: point.y + 30)
        ui.updateResultSource(id, at: target, visible: true)
        let followed = window.panel.frame
        check(ui.testSourcePoint(id) == target && ui.testMarkerPoint(id) == target, "球与卡采用绝对源位置")
        check(abs(followed.minX - original.minX - 97) < 0.5 && abs(followed.minY - original.minY - 41) < 0.5, "移动源窗口保留用户移动的卡片偏移")
        ui.updateResultSource(id, at: target, visible: true)
        check(window.panel.frame == followed, "重复绝对位置不累加漂移")
        ui.updateResultSource(id, at: target, visible: false)
        let hiddenTarget = CGPoint(x: target.x + 10, y: target.y + 20)
        ui.updateResultSource(id, at: hiddenTarget, visible: false)
        ui.updateResultSource(id, at: hiddenTarget, visible: true)
        check(ui.testMarkerPoint(id) == hiddenTarget && window.isVisible, "隐藏期间移动后原位恢复")
        var forgotten = 0
        ui.onForget = { _ in forgotten += 1 }
        ui.removeResult(id)
        ui.removeResult(id)
        ui.updateResultSource(id, at: point, visible: true)
        check(forgotten == 1 && ui.testResultIDs.isEmpty && ui.testCardIDs.isEmpty, "源销毁移除幂等，迟到位置不复活")
        passed("源位置跟随、用户偏移与单项销毁")
    }

    @MainActor static func capacityAndClear() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var forgotten: [UUID] = []
        ui.onForget = { forgotten.append($0) }
        let ids = (0..<128).map { begin(ui, text: "answer \($0)") }
        check(forgotten.isEmpty, "连续128个结果不静默淘汰")
        check(ui.testResultIDs.count == 128 && ui.testCardIDs.count == 128, "128个结果和独立卡片全部保留")
        ui.testOpen(ids[0], dialog: true)
        check(answer(ui, ids[0]) == "answer 0", "最早结果仍可打开")
        ui.clearAllMarkers()
        check(ui.testResultIDs.isEmpty && ui.testCardIDs.isEmpty && ui.testMarkerIDs.isEmpty, "全清释放所有结果、卡片、小球")
        check(Set(forgotten) == Set(ids) && forgotten.count == 128, "每个 ID 仅遗忘一次")
        for id in ids { ui.updateResult(id, text: "late", subtitle: nil); ui.finishResult(id) }
        check(ui.testCardIDs.isEmpty, "全清后迟到回调不恢复卡片")
        passed("128个结果保留与全清")
    }

    @MainActor static func failuresAndPending() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A"), f = begin(ui)
        ui.failResult(f, message: "failed", kind: .noReadableTarget)
        check(ui.testVisibleIDs == [a, f], "初答失败卡独立显示，A 不动")
        check(!ui.testMarkerIDs.contains(f) && !ui.testResultIDs.contains(f), "失败卡没有小球或业务结果")
        ui.testModel(a)!.onOpen()
        ui.testOutside()
        check(ui.testVisibleIDs == [a] && !ui.testCardIDs.contains(f), "外部点击丢弃失败卡，保留对话框 A")
        ui.showWheel(at: point)
        let b = begin(ui), c = begin(ui)
        ui.failResult(c, message: "queued failure", kind: nil)
        check(ui.testVisibleIDs == [a], "轮盘出现期间新结果与失败都暂缓显示")
        ui.hideWheel()
        check(ui.testVisibleIDs == [a, b, c], "轮盘隐藏后分别显示新卡与失败卡")
        ui.closeCard()
        check(!ui.testCardIDs.contains(c) && ui.testVisibleIDs == [a, b], "菜单只关闭最上面的失败卡")
        ui.showWheel(at: point)
        let d = begin(ui)
        ui.failResult(d, message: "discard pending", kind: nil)
        ui.clearAllMarkers()
        ui.hideWheel()
        check(ui.testCardIDs.isEmpty, "全清包括尚未展示的失败卡")
        let onlyFailure = begin(ui)
        ui.failResult(onlyFailure, message: "only failure", kind: nil)
        check(ui.testMarkerIDs.isEmpty && ui.testCardIDs == [onlyFailure], "只剩失败卡时没有小球")
        ui.clearAllMarkers()
        check(ui.testCardIDs.isEmpty, "没有小球时全清仍关闭失败卡")
        passed("独立失败卡、轮盘暂缓与全清")
    }

    @MainActor static func focusState() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, text: "A"), b = begin(ui, text: "B")
        ui.testOpen(a, dialog: true)
        ui.testModel(a)!.inputFocused = true
        ui.testModel(a)!.draft = "editing A"
        ui.testOpen(b, dialog: true)
        ui.updateResult(b, text: "B update", subtitle: nil)
        check(ui.testModel(a)?.inputFocused == true, "打开/更新 B 不重置 A 焦点状态")
        ui.testModel(b)!.onClose()
        check(ui.testVisibleIDs == [a] && ui.testModel(a)?.inputFocused == true, "B 的 Esc/收起回调只影响 B")
        check(ui.testWindow(a)!.panel.styleMask.contains(.nonactivatingPanel), "结果使用不激活应用的原生面板")
        check(ui.testWindow(a)!.panel.becomesKeyOnlyIfNeeded, "只在输入需要时获取键盘焦点")
        check(!ui.testWindow(a)!.panel.collectionBehavior.contains(.canJoinAllSpaces), "结果卡片只在创建时的桌面空间")
        check(!ui.testWindow(a)!.panel.canBecomeMain && !ui.testWindow(a)!.panel.isKeyWindow, "离屏执行无主窗口或键盘窗口")
        ui.testModel(a)!.onClose()
        check(ui.testModel(a)?.inputFocused == false, "收起 A 清除 A 的焦点状态")
        ui.testOpen(a, dialog: true)
        check(ui.testModel(a)?.inputFocused == false && ui.testModel(a)?.draft == "editing A", "重开保留草稿，不自动聚焦")
        ui.clearAllMarkers()
        passed("焦点状态归属与原生窗口配置（非键盘实机验收）")
    }

    @MainActor static func savedActions() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = begin(ui, action: .save), b = begin(ui, action: .save)
        var itemA = POSamples.savedItem, itemB = POSamples.savedItem
        itemA.id = UUID(); itemB.id = UUID()
        itemA.tags = []; itemB.tags = []
        ui.showSaved(a, item: itemA, suggestions: [])
        ui.showSaved(b, item: itemB, suggestions: [])
        var edits: [LibraryEdit] = []
        ui.onLibraryEdit = { edits.append($0) }
        ui.testModel(a)!.addTag("A tag")
        guard case .addTag(let changedID, let tag) = edits.first else { fatalError("missing tag edit") }
        check(changedID == itemA.id && tag == "A tag", "A 标签操作绑定 A 收藏 ID")
        ui.testModel(a)!.onUnsave()
        guard case .delete(let deletedID) = edits.last else { fatalError("missing delete") }
        check(deletedID == itemA.id && ui.testVisibleIDs == [b], "取消收藏 A 不移除 B")
        ui.clearAllMarkers()
        passed("收藏标签与删除操作按 ID 隔离")
    }

    @MainActor static func previewAndLifecycle() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        ui.previewComponent("multiple", at: point)
        check(ui.testResultIDs.count == 3 && ui.testMarkerIDs.count == 3, "multiple 含三个独立示例结果")
        check(ui.testVisibleIDs.count == 2, "multiple 显示两张卡片，第三个保留生成中小球")
        check(ui.testVisibleIDs.compactMap { ui.testModel($0) }.filter(\.expanded).count == 1, "multiple 一张对话框、一张短卡片")
        let frames = ui.testVisibleIDs.compactMap { ui.testWindow($0)?.panel.frame }
        check(!frames[0].intersects(frames[1]), "multiple 两张真实窗口 frame 不重叠")
        if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), CommandLine.arguments.count > index + 1 {
            renderMultiple(ui, into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        let id = ui.testVisibleIDs.first!
        ui.testOpen(id, dialog: true)
        ui.testModel(id)!.draft = "preview question"
        ui.testModel(id)!.submitFollowUp()
        check(ui.testPreviewTaskCount == 1, "示例追问任务属于自己的 ID")
        ui.testModel(id)!.onClose()
        ui.testOpen(id, dialog: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        check(ui.testModel(id)?.isShown == true && ui.testVisibleIDs.contains(id), "旧淡出回调不把已重开的卡片标为隐藏")
        weak var discardedWindow = ui.testWindow(id)
        ui.clearAllMarkers()
        check(ui.testPreviewTaskCount == 0, "全清取消所有示例任务")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.75))
        check(ui.testCardIDs.isEmpty && ui.testResultIDs.isEmpty, "取消后的延时示例任务不复活窗口")
        check(discardedWindow == nil, "淡出完成后已遗忘的浮窗对象释放")
        discardedWindow = nil
        passed("multiple 预览、淡出竞争与延时任务清理")
    }

    @MainActor static func streamVisibilityRaces() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let id = begin(ui, text: "first")
        let window = ui.testWindow(id)!
        for round in 0..<12 {
            ui.testModel(id)!.onClose()
            check(!window.isVisible, "hide 立即更新逻辑可见性，淡出尚未结束")
            ui.testOpen(id, dialog: true)
            ui.updateResult(id, text: "updated \(round)", subtitle: nil)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        check(window.isVisible && ui.testModel(id)?.isShown == true, "连续反转后旧淡出不能隐藏重开卡片")
        check(window.panel.alphaValue == 1 && ui.testWindow(id) === window, "重开保持原窗口且完成淡入")
        check(answer(ui, id) == "updated 11", "反转期间正文不丢失")
        ui.testModel(id)!.draft = "保留草稿"
        ui.updateResultSource(id, at: point, visible: false)
        ui.updateResult(id, text: "hidden update", subtitle: nil)
        check(!window.isVisible, "隐藏期间 stream 不把卡片打开")
        ui.updateResultSource(id, at: point, visible: true)
        // 在上一次淡出结束前再次隐藏/恢复。
        ui.updateResultSource(id, at: point, visible: false)
        ui.updateResultSource(id, at: point, visible: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        check(window.isVisible && ui.testModel(id)?.isShown == true && window.panel.alphaValue == 1,
              "来源可见性连续反转后窗口仍显示")
        check(answer(ui, id) == "hidden update" && ui.testModel(id)?.draft == "保留草稿", "恢复最新正文和草稿")
        ui.clearAllMarkers()
        passed("流式时连续收起/重开与应用隐藏/恢复反转")
    }

    /// 对真实 NSHostingView / CALayer 做离屏绘制，以实际窗口 frame 组合。
    /// 没有把窗口交给 WindowServer 显示；系统外投影、焦点与跨应用行为需另验。
    @MainActor static func renderMultiple(_ ui: OverlayPresentation, into directory: URL, file: String = "multiple") {
        let panels = ui.testOrder.compactMap { ui.testVisibleIDs.contains($0) ? ui.testWindow($0)?.panel : nil }
            + ui.testRestingMarkerPanels
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for panel in panels {
                panel.appearance = NSAppearance(named: appearanceName)
                panel.contentView?.wantsLayer = true
                panel.contentView?.needsLayout = true
                panel.contentView?.layoutSubtreeIfNeeded()
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
            let union = panels.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -32, dy: -32)
            let width = Int(ceil(union.width)), height = Int(ceil(union.height + 44))
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
                let origin = CGPoint(x: panel.frame.minX - union.minX, y: panel.frame.minY - union.minY)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: origin.x, y: origin.y)
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
            let title = "PinPin \(file) · \(name == "light" ? "浅色" : "深色") · 真实组件离屏检查"
            (title as NSString).draw(at: NSPoint(x: 20, y: height - 25), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: name == "light" ? 0.2 : 0.9, alpha: 1)
            ])
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG export") }
            do { try png.write(to: directory.appendingPathComponent("\(file)-\(name).png")) }
            catch { fatalError("PNG write: \(error)") }
            check(NSApp.windows.allSatisfy { !$0.isVisible }, "渲染全程窗口不上屏")
        }
    }
}
