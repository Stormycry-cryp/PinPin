import AppKit
import Foundation

/// R145 设置面板与 1–8 格轮盘：编译真实 UI 源码，执行真实模型、窗口与轮盘控制器；所有 POPanel 禁止上屏。
@main
struct SettingsTests {
    @MainActor static var checks = 0
    @MainActor static var scenarios = 0
    static let point = CGPoint(x: 400, y: 400)

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

    static func settle(_ seconds: Double = 0.25) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// 动态色在四种外观之一下与 token 一致。
    @MainActor static func isColor(_ color: CGColor?, _ token: POToken) -> Bool {
        guard let color else { return false }
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                          .accessibilityHighContrastDarkAqua]
        return names.contains { token.cg(NSAppearance(named: $0)!) == color }
    }

    /// 轮盘中心沿某格中线 `r` 处的屏幕点（y 向上）。
    static func pointer(_ slot: POWheelLayout.Slot, _ r: CGFloat = 60) -> CGPoint {
        CGPoint(x: point.x + cos(slot.mid) * r, y: point.y + sin(slot.mid) * r)
    }

    /// 设置面板坐标（y 向下）中某格中线上的点。
    @MainActor static func panelPoint(_ model: POSettingsModel, slot i: Int, r: CGFloat = 80) -> CGPoint {
        let s = POWheelLayout.standard(model.settings.slots.count)[i]
        return CGPoint(x: model.wheelCenter.x + cos(s.mid) * r, y: model.wheelCenter.y - sin(s.mid) * r)
    }

    @MainActor static func drag(_ model: POSettingsModel, _ source: POSettingsModel.Source, to end: CGPoint,
                                from start: CGPoint = CGPoint(x: 600, y: 120)) {
        model.pointerMoved(source, start: start, location: start)
        model.pointerMoved(source, start: start, location: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        model.pointerEnded(source, start: start, location: end)
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if let index = CommandLine.arguments.firstIndex(of: "--render-picker-only"), CommandLine.arguments.count > index + 1 {
            let originalAppearance = app.appearance
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                app.appearance = NSAppearance(named: appearance)
                let ui = OverlayPresentation(presentsOnScreen: false)
                let model = open(ui)
                model.page = .edit(.explain)
                model.toggleColorEditor(for: .explain)
                settle()
                renderPanels([ui.testSettingsWindow!.panel, model.testColorWindow!.panel],
                             into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                             file: "detail-color-expanded", title: "解释详情 · 连续选色展开",
                             appearances: [(name, appearance)])
                model.onClose(); settle()
            }
            app.appearance = originalAppearance
            print("PASS fresh color picker light/dark rendering; no windows ordered on screen")
            return
        }
        if CommandLine.arguments.contains("--color-picker-only") {
            colorDetails()
            if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), CommandLine.arguments.count > index + 1 {
                let ui = OverlayPresentation(presentsOnScreen: false)
                let model = open(ui)
                model.page = .edit(.save)
                renderPanels([ui.testSettingsWindow!.panel],
                             into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true),
                             file: "detail-save-direct", title: "普通包收藏详情 · AI路径")
                model.onClose(); settle()
            }
            print("PASS \(scenarios) scenarios, \(checks) checks; color picker only; no windows ordered on screen")
            return
        }
        if CommandLine.arguments.contains("--color-details-only") {
            wheelBoundaries()
            frozenWhileVisible()
            recolorInPlace()
            windowMovement()
            dragAndClick()
            saving()
            hostOrdering()
            samplePreview()
            colorDetails()
            if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), CommandLine.arguments.count > index + 1 {
                renderColorDetails(into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            }
            print("PASS \(scenarios) scenarios, \(checks) checks; R215 settings only; no windows ordered on screen")
            return
        }
        wheelBoundaries()
        frozenWhileVisible()
        recolorInPlace()
        replyCoachSettings()
        panelEdits()
        triggerSwitch()
        windowMovement()
        appearanceSwitch()
        dragAndClick()
        saving()
        hostOrdering()
        samplePreview()
        if let index = CommandLine.arguments.firstIndex(of: "--render-dir"), CommandLine.arguments.count > index + 1 {
            render(into: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        print("PASS \(scenarios) scenarios, \(checks) checks; no windows ordered on screen")
    }

    // MARK: Gesture wheel

    @MainActor static func wheelBoundaries() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let wheel = ui.testWheel
        check(wheel.testConfigured == .defaults, "未收到设置时使用默认四格")

        ui.updateWheelSettings(WheelSettings(slots: [.explain], colors: [:]))
        ui.showWheel(at: point)
        check(wheel.testSlots.count == 1, "1 格：一个整环")
        check((1..<POWheelLayout.maxSlots).allSatisfy { wheel.testSectorState($0).hidden }, "1 格：其余 7 个格子隐藏")
        for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
            let a = angle * .pi / 180
            let p = CGPoint(x: point.x + cos(a) * 60, y: point.y + sin(a) * 60)
            check(ui.updateWheel(pointer: p) == .explain, "1 格：环外任意方向都是这一格（\(angle)°）")
        }
        check(ui.updateWheel(pointer: point) == nil, "1 格：中心仍是取消区")
        ui.hideWheel()
        settle()

        let eight: [PointOutAction?] = [.explain, .translate, nil, .save, .rewrite, nil, .explain, .translate]
        ui.updateWheelSettings(WheelSettings(slots: eight, colors: [:]))
        ui.showWheel(at: point)
        check(wheel.testSlots.count == 8, "8 格")
        check(wheel.testSlots.allSatisfy { abs($0.half - .pi / 8) < 0.001 }, "8 格等分 45°")
        for slot in wheel.testSlots {
            check(ui.updateWheel(pointer: pointer(slot)) == eight[slot.index], "8 格：第 \(slot.index + 1) 格命中对应功能")
            check(ui.updateWheel(pointer: pointer(slot, 400)) == eight[slot.index], "8 格：环外远处同一方向仍命中")
        }
        for i in [2, 5] {
            let s = wheel.testSectorState(i)
            check(!s.hidden && s.empty && s.floor == 1 && s.shade == 0, "空格是浅凹槽，不凸起")
        }
        check(wheel.testSectorState(0).shade == 1 || ui.updateWheel(pointer: pointer(wheel.testSlots[0])) != nil,
              "非空格保持凸起或被指向")
        check(ui.updateWheel(pointer: pointer(wheel.testSlots[2])) == nil, "指向空格松开不执行")
        check(ui.updateWheel(pointer: pointer(wheel.testSlots[6])) == .explain, "同一功能可以放进多格")
        ui.hideWheel()
        settle()

        let before = wheel.testConfigured
        ui.updateWheelSettings(WheelSettings(slots: [], colors: [:]))
        ui.updateWheelSettings(WheelSettings(slots: Array(repeating: .save, count: 9), colors: [:]))
        ui.updateWheelSettings(WheelSettings(slots: [.save], colors: [.save: WheelColor(red: .nan, green: 0, blue: 0)]))
        check(wheel.testConfigured == before && ui.testWheelSettings == before, "0 格、9 格和非法颜色都被忽略")
        passed("1 格与 8 格边界、空格、重复功能、非法设置")
    }

    @MainActor static func frozenWhileVisible() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let wheel = ui.testWheel
        ui.showWheel(at: point)
        let slots = wheel.testSlots
        let top = slots[0]
        check(ui.updateWheel(pointer: pointer(top)) == .save, "默认顶部是收藏")
        let tintBefore = wheel.testSectorState(0).tint
        let changed = WheelSettings(slots: [.rewrite, .explain], colors: [.save: POSwatches.green.wheelColor,
                                                                          .rewrite: POSwatches.violet.wheelColor])
        ui.updateWheelSettings(changed)
        check(wheel.testSlots == slots && wheel.testConfigured == .defaults, "打开中的轮盘保留本次格子")
        check(ui.updateWheel(pointer: pointer(top)) == .save, "打开中的轮盘保留本次命中")
        check(wheel.testSectorState(0).tint == tintBefore, "打开中的轮盘保留本次颜色")
        ui.hideWheel()
        check(wheel.testConfigured == .defaults, "淡出期间仍不换")
        settle()
        check(wheel.testConfigured == changed, "淡出结束后应用")
        ui.showWheel(at: point)
        check(wheel.testSlots.count == 2, "下次打开是 2 格")
        check(ui.updateWheel(pointer: pointer(wheel.testSlots[0])) == .rewrite, "下次打开命中新布局")
        check(isColor(wheel.testSectorState(0).tint, POSwatches.violet.token), "下次打开用新颜色")
        ui.hideWheel()

        // 关闭后立刻再开（淡出回调前）：show 先应用待定设置。
        ui.showWheel(at: point)
        ui.updateWheelSettings(WheelSettings(slots: [.translate, nil, .save], colors: [:]))
        ui.hideWheel()
        ui.showWheel(at: point)
        check(wheel.testSlots.count == 3 && ui.updateWheel(pointer: pointer(wheel.testSlots[0])) == .translate,
              "淡出前再次打开也使用新设置")
        ui.hideWheel()
        settle()
        passed("打开中的轮盘冻结格子、命中与颜色，关闭后或下次打开生效")
    }

    @MainActor static func recolorInPlace() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let a = UUID(), b = UUID()
        ui.beginResult(a, action: .translate, at: point, processID: 101)
        ui.updateResult(a, text: "A", subtitle: nil)
        ui.finishResult(a)
        ui.beginResult(b, action: .explain, at: CGPoint(x: 700, y: 300), processID: 101)
        settle(0.3)
        check(isColor(ui.testMarkerTint(a), POSwatches.teal.token), "翻译小球默认青绿")
        let explainBefore = ui.testMarkerTint(b)

        POUIPerformance.reset()
        let s = WheelSettings(slots: WheelSettings.defaults.slots, colors: [.translate: POSwatches.violet.wheelColor])
        ui.updateWheelSettings(s)
        check(isColor(ui.testMarkerTint(a), POSwatches.violet.token), "小球立即换成新颜色")
        check(ui.testMarkerTint(b) == explainBefore, "其他功能的小球不变")
        check(isColor(POFeatureColors.shared.tint(.translate).cg(NSAppearance(named: .aqua)!), POSwatches.violet.token),
              "卡片图标读取同一颜色")
        let counters = POUIPerformance.counters
        for name in ["forcedLayout", "frameChange", "show", "showFade", "orderFront", "markerApplyState", "markerSpinStart"] {
            check((counters[name] ?? 0) == 0, "换色不触发 \(name)")
        }

        POUIPerformance.reset()
        ui.updateWheelSettings(s)
        check(!POFeatureColors.shared.apply(s.colors), "同一颜色再次应用不发布")
        check(POUIPerformance.counters.isEmpty, "同一设置再次应用不做任何事")

        ui.updateWheelSettings(WheelSettings(slots: [.save], colors: [:]))
        check(isColor(ui.testMarkerTint(a), POSwatches.teal.token), "移出颜色后恢复默认")
        check(isColor(ui.testMarkerTint(a), POSwatches.teal.token), "格子变化不影响已有小球的功能")
        ui.clearAllMarkers()
        ui.updateWheelSettings(.defaults)
        passed("小球与卡片原地换色，无重排、无重显、幂等")
    }

    @MainActor static func replyCoachSettings() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = open(ui)
        check(model.libraryActions.count == 6 && model.libraryActions.last == .replyCoach, "功能库包含六个真实功能，嘴替在末尾")
        check(model.settings == .defaults && !model.settings.slots.contains(.replyCoach), "新增功能不改变默认四格")
        for count in 1...8 {
            model.setSlotCount(count)
            let before = model.settings.slots
            drag(model, .block(.replyCoach), to: panelPoint(model, slot: count - 1))
            check(model.settings.slots.last! == .replyCoach && Array(model.settings.slots.dropLast()) == Array(before.dropLast()),
                  "嘴替可拖入 \(count) 格轮盘且仅替换目标格")
            ui.showWheel(at: point)
            let slot = ui.testWheel.testSlots[count - 1]
            check(ui.updateWheel(pointer: pointer(slot)) == .replyCoach, "嘴替轮盘命中返回真实动作")
            ui.hideWheel()
        }
        let id = UUID()
        ui.beginResult(id, action: .replyCoach, at: point, processID: 101)
        ui.updateResult(id, text: "合成回复建议", subtitle: nil)
        ui.finishResult(id)
        check(isColor(ui.testMarkerTint(id), POSwatches.green.token), "嘴替默认绿色")
        model.setColor(POSwatches.brick, for: .replyCoach)
        check(isColor(ui.testMarkerTint(id), POSwatches.brick.token), "嘴替标注随编辑换色")
        check(isColor(POFeatureColors.shared.tint(.replyCoach).cg(NSAppearance(named: .aqua)!), POSwatches.brick.token),
              "嘴替卡片与轮盘共用颜色")
        model.setColor(POSwatches.green, for: .replyCoach)
        check(model.settings.colors[.replyCoach] == nil, "嘴替选回默认绿色不存冗余覆盖")
        let glyph = POGlyph.image(PointOutAction.replyCoach.symbol, size: 18, weight: .medium)
        check(glyph.size == NSSize(width: 18, height: 18) && glyph.isTemplate, "嘴替使用可着色线条大脑图标")
        model.onClose(); ui.clearAllMarkers(); ui.updateWheelSettings(.defaults)
        settle()
        passed("嘴替六功能库、1–8格拖入、命中和共用颜色")
    }

    // MARK: Settings panel

    @MainActor static func open(_ ui: OverlayPresentation) -> POSettingsModel {
        ui.showSettings()
        settle(0.1)
        return ui.testSettingsModel
    }

    /// 窗口不上屏，检查真实原生视图命中区域与移动后的布局。
    @MainActor static func windowMovement() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = open(ui)
        let window = ui.testSettingsWindow!
        let panel = window.panel
        check(panel.level == .normal && !panel.isFloatingPanel, "设置使用普通窗口层级")
        check(panel.isMovable && !panel.isMovableByWindowBackground, "允许原生移动，仅专用留白区启动窗口拖动")
        func dragView(in view: NSView) -> POSettingsWindowDragView? {
            if let view = view as? POSettingsWindowDragView { return view }
            return view.subviews.compactMap { dragView(in: $0) }.first
        }
        guard let handle = dragView(in: window.container) else { fatalError("缺少原生窗口拖动区") }
        let area = handle.convert(handle.bounds, to: window.container)
        check(abs(area.height - POSettingsMetrics.padding) < 1
              && abs(area.width - (panel.frame.width - 180 - 70)) < 1,
              "顶部拖动区使用现有留白并避开左右角控件")
        check(abs(area.maxY - window.container.bounds.maxY) < 1, "拖动区固定在窗口顶部")
        let hit = window.container.hitTest(NSPoint(x: area.midX, y: area.midY))
        check(hit === handle && handle.acceptsFirstMouse(for: nil), "顶部留白命中原生拖动区且接受首次点击")
        let m = POSettingsMetrics.self
        let protectedPoints = [
            NSPoint(x: 21, y: panel.frame.height - 21), // 外观
            NSPoint(x: 49, y: panel.frame.height - 21), // 资产看板
            NSPoint(x: panel.frame.width - 21, y: panel.frame.height - 21), // 关闭
            NSPoint(x: m.padding + m.side / 2, y: panel.frame.height - m.padding - 30), // 轮盘
            NSPoint(x: m.padding + m.side + m.columnGap + m.libraryInset + m.block / 2,
                    y: panel.frame.height - m.padding - (m.side - m.libraryHeight) / 2 - m.libraryInset - m.block / 2),
            NSPoint(x: m.padding + m.side / 2, y: m.padding + 11) // 格数
        ]
        check(protectedPoints.allSatisfy { window.container.hitTest($0) !== handle },
              "外观、关闭、轮盘、功能块、格数控件不命中窗口拖动区")
        let moved = panel.frame.origin.applying(CGAffineTransform(translationX: 68, y: -43))
        panel.setFrameOrigin(moved)
        model.page = .edit(.explain)
        settle(0.2)
        window.relayout()
        check(panel.frame.origin == moved, "移动后切页和重新布局保留窗口位置")
        model.setColor(POSwatches.violet, for: .explain)
        settle(0.1)
        check(panel.frame.origin == moved, "移动后换色不跳回原位置")
        check(window.container.hitTest(NSPoint(x: area.midX, y: area.midY)) === handle,
              "颜色页仍保留同一原生拖动区")
        ui.showSettings()
        settle(0.1)
        check(panel.frame.origin == moved && model.page == .functions, "可见时再次打开复用位置并回到功能库")
        model.onClose()
        passed("设置原生拖动区域、普通层级和移动后布局")
    }

    @MainActor static func appearanceSwitch() {
        let suite = "PinPinSettingsTests.Appearance." + UUID().uuidString
        print("Isolated appearance suite: \(suite)")
        fflush(stdout)
        let defaults = UserDefaults(suiteName: suite)!
        let previous = NSApp.appearance
        // 从未创建原生设备的 deferred 窗口不接收 AppKit 应用外观更新。
        POPanel.testDefersWindowCreation = false
        defer {
            POPanel.testDefersWindowCreation = true
            NSApp.appearance = previous
            defaults.removePersistentDomain(forName: suite)
        }
        NSApp.appearance = nil
        let startedDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ui = OverlayPresentation(presentsOnScreen: false, appearanceDefaults: defaults)
        let model = open(ui)
        check(NSApp.appearance == nil && defaults.string(forKey: POAppearancePreference.storageKey) == nil,
              "未选择外观时沿用系统，不提前写入偏好")
        model.onToggleAppearance()
        check(NSApp.appearance?.name == (startedDark ? .aqua : .darkAqua), "首次点击切到系统当前外观的相反模式")
        check(defaults.string(forKey: POAppearancePreference.storageKey) == (startedDark ? "light" : "dark"),
              "首次切换写入隔离偏好域")

        let id = UUID()
        ui.beginResult(id, action: .translate, at: point, processID: 101)
        ui.updateResult(id, text: "外观切换保留内容", subtitle: nil)
        ui.finishResult(id)
        ui.testOpen(id, dialog: true)
        ui.showWheel(at: point)
        let wheel = ui.testWheel
        let slots = wheel.testSlots
        _ = ui.updateWheel(pointer: pointer(slots[0]))
        settle(0.3)
        let frame = ui.testSettingsWindow!.panel.frame
        let cardFrame = ui.testWindow(id)!.panel.frame
        for (name, stored) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: name == .aqua ? .darkAqua : .aqua)
            settle(0.1)
            model.onToggleAppearance()
            settle(0.2)
            let appearance = NSAppearance(named: name)!
            check(NSApp.appearance?.name == name && defaults.string(forKey: POAppearancePreference.storageKey) == stored,
                  "连续点击能切换并保存 \(stored)")
            let panels = [ui.testSettingsWindow!.panel, ui.testWindow(id)!.panel, wheel.testPanel]
            check(panels.allSatisfy { $0.appearance == nil && $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name },
                  "设置、已有卡片、轮盘继承应用 \(stored) 外观：\(panels.map { ($0.appearance?.name.rawValue ?? "nil") + "/" + ($0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "nil") })")
            check(ui.testMarkerView(id)?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name
                  && ui.testMarkerTint(id) == POSwatches.teal.token.cg(appearance),
                  "已有小球立即重绘 \(stored) 色值")
            check(wheel.testSectorState(0).tint == POSwatches.rose.token.cg(appearance),
                  "已打开手势轮盘立即重绘 \(stored) 色值")
            check(wheel.testSlots == slots && wheel.hit == .save, "切换外观保留轮盘布局与命中")
            check(ui.testSettingsWindow!.panel.frame == frame && ui.testWindow(id)!.panel.frame == cardFrame,
                  "切换外观保留设置与已有卡片位置尺寸：设置 \(frame) -> \(ui.testSettingsWindow!.panel.frame)，卡片 \(cardFrame) -> \(ui.testWindow(id)!.panel.frame)")
            check(ui.testModel(id)?.plainText == "外观切换保留内容", "切换外观保留已有答案")
        }
        NSApp.appearance = nil
        _ = POAppearancePreference(defaults: UserDefaults(suiteName: suite)!)
        check(NSApp.appearance?.name == .darkAqua, "重新创建偏好对象恢复上次选择")
        let newID = UUID()
        ui.beginResult(newID, action: .explain, at: CGPoint(x: 600, y: 450), processID: 101)
        ui.updateResult(newID, text: "新内容", subtitle: nil)
        ui.finishResult(newID)
        ui.testOpen(newID, dialog: true)
        check(ui.testWindow(newID)!.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
              "后续创建的卡片继承手动选择")
        NSApp.appearance = nil
        defaults.set("invalid", forKey: POAppearancePreference.storageKey)
        _ = POAppearancePreference(defaults: defaults)
        check(NSApp.appearance == nil, "未知偏好值保留系统外观")
        ui.hideWheel()
        ui.clearAllMarkers()
        model.onClose()
        settle()
        passed("明暗切换、原生应用外观传播与隔离偏好恢复")
    }

    @MainActor static func panelEdits() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = open(ui)
        let window = ui.testSettingsWindow!
        check(window.isVisible && window.panel.alphaValue <= 1, "设置面板打开（离屏）")
        check(model.page == .functions && model.settings == .defaults, "打开时显示功能列表和当前设置")
        let m = POSettingsMetrics.self
        let size = window.panel.frame.size
        // 拖放坐标以轮盘为这一行左上角为前提：面板正好是边距 + 轮盘 + 间距 + 右栏。
        check(abs(size.width - (m.padding * 2 + m.side + m.columnGap + m.column)) < 1
              && abs(size.height - (m.padding * 2 + m.side + 12 + 22)) < 1,
              "面板尺寸等于轮盘列加功能列，拖放坐标以轮盘中心为准")
        check(model.libraryActions == PointOutAction.allCases, "正式功能库只显示真实可用动作")

        model.setSlotCount(3)
        check(model.settings.slots == [.save, .translate, .rewrite], "减少一格去掉最后一格")
        check(ui.testWheel.testConfigured?.slots.count == 3, "轮盘关闭时立即生效")
        model.setSlotCount(5)
        check(model.settings.slots == [.save, .translate, .rewrite, nil, nil], "增加的格子是空的")
        for _ in 0..<12 { model.setSlotCount(model.settings.slots.count + 1) }
        check(model.settings.slots.count == 8, "最多 8 格")
        for _ in 0..<12 { model.setSlotCount(model.settings.slots.count - 1) }
        check(model.settings.slots == [.save], "最少 1 格，保留第一格")
        model.setSlotCount(0)
        check(model.settings.slots.count == 1, "不能少于 1 格")
        settle(0.1)
        check(window.panel.frame.size == size, "格数变化不改变面板尺寸")

        model.page = .edit(.explain)
        settle(0.1)
        check(window.panel.frame.size == size, "切换到编辑页不改变面板尺寸")
        model.setColor(POSwatches.violet, for: .explain)
        check(model.settings.colors[.explain] == POSwatches.violet.wheelColor, "选择色板写入颜色")
        check(POSwatches.selection(for: .explain, in: model.settings.colors) == POSwatches.violet, "回读为同一色板")
        check(isColor(POFeatureColors.shared.tint(.explain).cg(NSAppearance(named: .darkAqua)!), POSwatches.violet.token),
              "立即生效到全局颜色")
        model.setColor(POSwatches.blue, for: .explain)
        check(model.settings.colors[.explain] == nil, "选回默认色不写入文件")
        model.setColor(POSwatches.graphite, for: .save)
        model.resetColor(.save)
        check(model.settings.colors.isEmpty, "恢复默认移除颜色")
        let custom = WheelColor(red: 0.2, green: 0.4, blue: 0.3)
        ui.updateWheelSettings(WheelSettings(slots: [.save], colors: [.save: custom]))
        check(POSwatches.selection(for: .save, in: model.settings.colors) == nil, "手改文件的颜色显示为自定义")
        check(POFeatureColors.shared.tint(.save).cg(NSAppearance(named: .aqua)!).components?.prefix(3)
                .map { Double($0) } == [0.2, 0.4, 0.3], "自定义颜色浅色下按原值使用")

        model.onClose()
        check(!window.isVisible, "关闭按钮收起面板")
        ui.updateWheelSettings(.defaults)
        let reopened = open(ui)
        check(reopened === model && reopened.page == .functions && reopened.settings == .defaults,
              "再次打开复用同一面板，回到功能列表并显示最新设置")
        model.onClose()
        settle()
        passed("格数 1–8、颜色选择、默认与自定义、尺寸稳定")
    }

    @MainActor static func triggerSwitch() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var sent: [WheelSettings] = []
        var success = true
        ui.onWheelSettingsChange = { [weak ui] value in
            sent.append(value)
            ui?.updateWheelSettings(value)
            return success
        }
        let model = open(ui)
        let frame = ui.testSettingsWindow!.panel.frame
        check(model.settings.triggerEnabled, "旧配置和默认配置保持触发开启")
        let original = model.settings
        model.setTriggerEnabled(false)
        check(!model.settings.triggerEnabled && !ui.testWheelSettings.triggerEnabled,
              "关闭触发立即随整份设置预览到宿主接口")
        check(model.settings.slots == original.slots && model.settings.colors == original.colors,
              "触发开关保留轮盘槽位与配色")
        ui.updateWheelSettings(.defaults)
        check(!model.settings.triggerEnabled, "保存发出前的迟到启动配置不重新开启触发")
        settle(0.1)
        check(sent.count == 1 && sent[0].triggerEnabled == false && model.saveState == .saved,
              "关闭触发通过现有保存回调交付完整false设置")
        let count = sent.count
        model.setTriggerEnabled(false)
        settle(0.05)
        check(sent.count == count, "重复选择同一触发状态不重复保存")
        model.setSlotCount(5)
        model.setColor(POSwatches.violet, for: .translate)
        drag(model, .block(.replyCoach), to: panelPoint(model, slot: 4))
        settle(0.1)
        check(!model.settings.triggerEnabled && sent.last?.triggerEnabled == false && model.settings.slots[4] == .replyCoach,
              "关闭后仍可改格数、颜色和拖放且不意外重新开启")
        model.onClose(); settle(0.15)
        ui.showSettings(); settle(0.1)
        check(ui.testSettingsWindow!.isVisible && ui.testSettingsModel === model && !model.settings.triggerEnabled,
              "关闭触发后设置仍可被宿主唤起并保留状态")
        check(ui.testSettingsWindow!.panel.frame == frame, "两种触发文案及重开不改变面板尺寸位置")
        let restored = OverlayPresentation(presentsOnScreen: false)
        restored.updateWheelSettings(sent.last!)
        check(!open(restored).settings.triggerEnabled, "新面板接收已保存false快照后恢复不触发")
        restored.testSettingsModel.onClose()
        success = false
        model.setTriggerEnabled(true); settle(0.1)
        check(model.settings.triggerEnabled && model.showsSaveFailure, "保存失败保留本次触发状态并如实显示失败")
        success = true
        model.retry(); settle(0.1)
        check(sent.last?.triggerEnabled == true && model.saveState == .saved && !model.showsSaveFailure,
              "重试交付当前触发状态且成功后清除错误")
        model.setTriggerEnabled(false); model.setTriggerEnabled(true); settle(0.1)
        check(sent.last?.triggerEnabled == true && model.settings.triggerEnabled, "连续切换最终保存最新状态")
        model.onClose(); settle()
        ui.updateWheelSettings(.defaults)
        passed("轮盘触发开关、保存失败重试、配置恢复及设置面板独立唤起")
    }

    @MainActor static func dragAndClick() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        ui.updateWheelSettings(WheelSettings(slots: [.save, .translate, .rewrite, nil], colors: [:]))
        let model = open(ui)

        // 点按功能块：进入该功能的编辑页，不改设置。
        let blockStart = CGPoint(x: 600, y: 120)
        model.pointerMoved(.block(.rewrite), start: blockStart, location: blockStart)
        model.pointerEnded(.block(.rewrite), start: blockStart, location: CGPoint(x: 601, y: 121))
        check(model.page == .edit(.rewrite) && model.settings.slots[3] == nil, "点按进入改写编辑页")
        model.page = .functions

        // 拖动中：预览放下后的结果并按下目标格，但不写入。
        let target = panelPoint(model, slot: 3)
        model.pointerMoved(.block(.explain), start: blockStart, location: blockStart)
        model.pointerMoved(.block(.explain), start: blockStart, location: target)
        let preview = model.wheelState
        check(preview.target == 3 && preview.slots[3] == .explain, "拖到第 4 格时预览并按下该格")
        check(model.settings.slots[3] == nil, "拖动中不写入")
        model.pointerEnded(.block(.explain), start: blockStart, location: target)
        check(model.settings.slots == [.save, .translate, .rewrite, .explain], "松开放进第 4 格")
        check(model.drag == nil && model.page == .functions, "拖动后不切页")
        check(ui.testWheel.testConfigured?.slots[3] == .explain, "轮盘同步")

        drag(model, .block(.explain), to: panelPoint(model, slot: 0))
        check(model.settings.slots == [.explain, .translate, .rewrite, .explain], "同一功能可以放进多格")

        drag(model, .slot(1), to: panelPoint(model, slot: 2), from: panelPoint(model, slot: 1))
        check(model.settings.slots == [.explain, .rewrite, .translate, .explain], "格子拖到另一格互换")

        drag(model, .slot(0), to: CGPoint(x: model.wheelCenter.x, y: -40), from: panelPoint(model, slot: 0))
        check(model.settings.slots == [nil, .rewrite, .translate, .explain], "格子拖出轮盘清空")

        let unchanged = model.settings
        drag(model, .slot(1), to: model.wheelCenter, from: panelPoint(model, slot: 1))
        drag(model, .block(.save), to: model.wheelCenter)
        drag(model, .block(.save), to: CGPoint(x: 900, y: 900))
        drag(model, .slot(3), to: panelPoint(model, slot: 3, r: 50), from: panelPoint(model, slot: 3))
        check(model.settings == unchanged, "拖回中心、拖到轮盘外或放回原处都不变")

        // 拖动格子到自己：图标变淡表示松开放回原处。
        let own = panelPoint(model, slot: 1)
        model.pointerMoved(.slot(1), start: own, location: own)
        model.pointerMoved(.slot(1), start: own, location: model.wheelCenter)
        check(model.wheelState.lifted == 1 && model.wheelState.target == nil, "拖起的格子变淡")
        model.cancelDrag()

        // 点按格子：有功能时进入它的编辑页；空格不响应。
        let empty = panelPoint(model, slot: 0)
        model.pointerMoved(.slot(0), start: empty, location: empty)
        model.pointerEnded(.slot(0), start: empty, location: empty)
        check(model.page == .functions && model.drag == nil, "点空格不切页")
        let filled = panelPoint(model, slot: 2)
        model.pointerMoved(.slot(2), start: filled, location: filled)
        model.pointerEnded(.slot(2), start: filled, location: filled)
        check(model.page == .edit(.translate), "点有功能的格子进入其编辑页")
        check(model.places(of: .translate) == [3] && model.focus == .translate, "编辑页在轮盘上标出所在格（其他格变淡）")

        // 8 格边界：每一格都能被拖入。
        model.setSlotCount(8)
        for i in 0..<8 { drag(model, .block(PointOutAction.allCases[i % PointOutAction.allCases.count]), to: panelPoint(model, slot: i)) }
        check(model.settings.slots == (0..<8).map { PointOutAction.allCases[$0 % PointOutAction.allCases.count] }, "8 格每格都能拖入")
        model.setSlotCount(1)
        drag(model, .block(.rewrite), to: panelPoint(model, slot: 0, r: 100))
        check(model.settings.slots == [.rewrite], "1 格整环可拖入")
        model.onClose()
        settle()
        ui.updateWheelSettings(.defaults)
        passed("拖入、互换、移出、点按切页、1 格与 8 格拖放")
    }

    @MainActor static func saving() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var saved: [WheelSettings] = []
        var answer = true
        var delay: UInt64 = 0
        ui.onWheelSettingsChange = { [weak ui] s in
            // 与宿主相同：保存前先回传同一份设置。
            ui?.updateWheelSettings(s)
            saved.append(s)
            let ok = answer, wait = delay
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            return ok
        }
        let model = open(ui)
        check(model.saveState == .idle && !model.showsSaveFailure, "接入保存时不显示任何状态文字")
        model.setSlotCount(3)
        check(model.saveState == .saving && !model.showsSaveFailure, "等待保存结果，不提前说已保存")
        settle(0.1)
        check(saved == [model.settings] && model.saveState == .saved && !model.showsSaveFailure, "保存成功后安静生效")

        answer = false
        model.setSlotCount(2)
        settle(0.1)
        check(model.saveState == .failed && model.showsSaveFailure, "保存失败如实说明")
        check(ui.testWheel.testConfigured?.slots.count == 2, "失败时本次运行仍生效")
        answer = true
        model.retry()
        settle(0.1)
        check(saved.count == 3 && saved.last == model.settings && model.saveState == .saved, "重试保存当前设置")

        // 旧保存已发出、晚到的结果不覆盖新结果。
        answer = false
        delay = 200_000_000
        model.setSlotCount(4)
        settle(0.05)
        check(saved.last?.slots.count == 4, "第一次保存已经发出，正在等待")
        answer = true
        delay = 0
        model.setSlotCount(5)
        settle(0.4)
        check(model.saveState == .saved && saved.last?.slots.count == 5, "只显示最新一次保存的结果")

        let count = saved.count
        model.setSlotCount(5)
        model.setColor(POSwatches.defaultSwatch(for: .save), for: .save)
        check(saved.count == count, "没有变化的操作不保存")
        model.onClose()
        settle()
        ui.updateWheelSettings(.defaults)
        passed("保存中、已保存、失败、重试与过期结果")
    }

    /// 与 PointOutApp.connectWheelSettings 相同的宿主接线：保存开始时代次 +1 并同步回传同一份设置；
    /// 启动读取在代次仍为 0 时才应用。只在内存里模拟，不读写磁盘。
    @MainActor final class Host {
        var revision: UInt64 = 0
        var answer = true
        var sent: [Int] = []
        /// 每次回传后轮盘与面板实际持有的格数。
        var seen: [Int] = []

        func connect(_ ui: OverlayPresentation) {
            ui.onWheelSettingsChange = { [weak self, weak ui] s in
                guard let self, let ui, s.isValid else { return false }
                self.revision += 1
                self.sent.append(s.slots.count)
                ui.updateWheelSettings(s)
                self.seen.append(ui.testWheelSettings.slots.count)
                self.seen.append(ui.testSettingsModel.settings.slots.count)
                await Task.yield()
                return self.answer
            }
        }

        func load(_ s: WheelSettings, into ui: OverlayPresentation) {
            guard revision == 0 else { return }
            ui.updateWheelSettings(s)
        }
    }

    @MainActor static func hostOrdering() {
        // 连续两次改格数（同一轮主线程）：被替代、尚未发出的保存不交给宿主，回传不把格数带回去。
        var ui = OverlayPresentation(presentsOnScreen: false)
        var host = Host()
        host.connect(ui)
        var model = open(ui)
        model.setSlotCount(5)
        model.setSlotCount(6)
        check(model.settings.slots.count == 6 && ui.testWheelSettings.slots.count == 6, "两次改动都立即预览")
        settle(0.1)
        check(host.sent == [6], "已被后续改动替代的保存不发给宿主")
        check(host.seen.allSatisfy { $0 == 6 }, "宿主回传期间轮盘和面板一直是 6 格，不回退到 5")
        check(model.saveState == .saved && ui.testWheel.testConfigured?.slots.count == 6, "最终保存 6 格并显示已保存")
        model.onClose()
        settle()

        // 启动读取晚到：落在本地预览之后、保存发出之前。
        ui = OverlayPresentation(presentsOnScreen: false)
        host = Host()
        host.connect(ui)
        model = open(ui)
        let disk = WheelSettings(slots: [.explain, .save, .translate, .rewrite],
                                 colors: [.explain: POSwatches.graphite.wheelColor])
        model.setSlotCount(5)
        check(model.hasUnsentEdit, "预览后、保存发出前有待发改动")
        host.load(disk, into: ui)
        check(model.settings.slots.count == 5 && ui.testWheelSettings.slots.count == 5
              && ui.testWheel.testConfigured?.slots.count == 5, "晚到的启动读取不覆盖待发的本地改动")
        check(isColor(POFeatureColors.shared.tint(.explain).cg(NSAppearance(named: .aqua)!), POSwatches.blue.token),
              "晚到的启动读取也不改颜色")
        settle(0.1)
        check(host.sent == [5] && host.revision == 1 && !model.hasUnsentEdit, "随后整份保存本地改动")
        check(host.seen.allSatisfy { $0 == 5 } && model.saveState == .saved, "保存与回传期间保持 5 格")
        host.load(disk, into: ui)
        check(ui.testWheelSettings.slots.count == 5, "保存发出后宿主代次挡住更晚的读取")
        model.onClose()
        settle()

        // 没有待发改动时，启动读取照常应用。
        ui = OverlayPresentation(presentsOnScreen: false)
        host = Host()
        host.connect(ui)
        model = open(ui)
        host.load(disk, into: ui)
        check(model.settings == disk && ui.testWheelSettings == disk, "没有待发改动时启动读取照常应用")
        check(isColor(POFeatureColors.shared.tint(.explain).cg(NSAppearance(named: .aqua)!), POSwatches.graphite.token),
              "启动读取的颜色立即生效")

        // 失败与示例都不会把待发标记留下。
        host.answer = false
        model.setSlotCount(2)
        settle(0.1)
        check(model.saveState == .failed && !model.hasUnsentEdit, "保存失败后没有遗留待发标记")
        model.setSlotCount(3)
        ui.previewComponent("settings", at: point)
        model.setSlotCount(1)
        check(!model.hasUnsentEdit, "切到示例后的改动不发给宿主，也不留待发标记")
        settle(0.1)
        check(host.sent == [2], "被示例改动替代的那次保存没有发出")
        ui.updateWheelSettings(.defaults)
        check(model.settings == .defaults && ui.testWheelSettings == .defaults, "之后外来设置照常应用")
        model.onClose()
        settle()
        passed("真实宿主接线：连续改动的回传顺序与晚到的启动读取")
    }

    @MainActor static func samplePreview() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var saved = 0
        ui.onWheelSettingsChange = { _ in saved += 1; return true }
        ui.previewComponent("settings", at: point)
        settle(0.1)
        let model = ui.testSettingsModel
        check(model.isSample && model.onPersist == nil, "预览入口标为示例")
        model.setSlotCount(6)
        settle(0.1)
        check(saved == 0 && model.saveState == .idle && !model.showsSaveFailure, "示例改动不保存")
        ui.showSettings()
        check(!model.isSample && model.onPersist != nil, "正式打开恢复保存")
        model.onClose()
        settle()
        ui.updateWheelSettings(.defaults)
        passed("预览入口不保存")
    }

    // MARK: Offscreen renders

    @MainActor static func colorDetails() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var writes: [WheelSettings] = []
        var failDelayed = false
        ui.onWheelSettingsChange = { [weak ui] settings in
            writes.append(settings)
            ui?.updateWheelSettings(settings)
            let fails = failDelayed
            if fails { try? await Task.sleep(nanoseconds: 180_000_000) }
            return !fails
        }
        let model = open(ui)
        check(model.testColorWindow == nil, "打开设置不创建选色面板")
        model.page = .edit(.explain)
        check(model.testColorWindow == nil, "功能详情默认收起颜色选择")
        check([PointOutAction.explain, .translate, .rewrite, .replyCoach].allSatisfy(\.settingsUsesAI), "四个模型功能标注AI")
        check(!PointOutAction.pickColor.settingsUsesAI, "原生取色不标注AI")
        #if PINPIN_APP_STORE
        check(!PointOutAction.save.settingsUsesAI, "MAS本地收藏不标注AI")
        #else
        check(PointOutAction.save.settingsUsesAI, "普通包云端收藏标注AI")
        #endif
        model.toggleColorEditor(for: .explain)
        settle()
        let window = model.testColorWindow!
        let picker = model.testColorPicker!
        check(window.panel.level == .normal && !window.panel.isFloatingPanel && window.panel.isMovable,
              "选色面板可移动且是普通层级")
        check(!window.panel.isMovableByWindowBackground, "选色拖动区域不移动窗口")
        check(ui.testSettingsWindow!.panel.frame.size == NSSize(width: 514, height: 294), "展开选色不挤大详情设置页")
        let frame = window.panel.frame
        window.panel.setFrameOrigin(NSPoint(x: frame.minX + 27, y: frame.minY - 19))
        let moved = window.panel.frame
        POUIPerformance.reset()
        for n in 0..<64 {
            picker.select(at: CGPoint(x: 32 + n, y: 35), size: CGSize(width: 208, height: 140))
        }
        settle(0.1)
        check(writes.isEmpty && model.hasUnsentEdit, "连续拖动只预览，未创建配置写入")
        check(POFeatureColors.shared.colors == model.settings.colors, "拖动颜色即时共享给轮盘与结果")
        check(window.panel.frame == moved, "预览更新保留选色窗口移动位置")
        check((POUIPerformance.counters["show"] ?? 0) == 0 && (POUIPerformance.counters["orderFront"] ?? 0) == 0,
              "拖动过程中不重新显示或置前窗口")
        let draft = model.settings
        ui.updateWheelSettings(.defaults)
        check(model.settings == draft, "松手前晚到的设置不能覆盖选色预览")
        picker.onFinish(); settle(0.1)
        check(writes == [draft] && !model.hasUnsentEdit && model.saveState == .saved, "松手只保存最终颜色一次")
        picker.onFinish(); settle(0.05)
        check(writes.count == 1, "重复结束不重复保存")
        picker.onReset(); settle(0.1)
        check(model.settings.colors[.explain] == nil && writes.count == 2, "恢复默认删除颜色覆盖并保存一次")

        failDelayed = true
        picker.selectHue(at: 150, width: 208); picker.onFinish(); settle(0.04)
        failDelayed = false
        picker.selectHue(at: 78, width: 208); picker.onFinish(); settle(0.25)
        check(model.saveState == .saved && model.settings == writes.last, "旧选色保存失败不覆盖新保存成功与新颜色")

        let oldPreview = picker.onPreview, oldFinish = picker.onFinish
        picker.select(at: CGPoint(x: 120, y: 70), size: CGSize(width: 208, height: 140))
        let beforeSwitch = writes.count
        model.page = .edit(.translate)
        settle(0.12)
        check(model.testColorWindow == nil && !window.isVisible && writes.count == beforeSwitch + 1,
              "切换功能关闭旧面板并保存尚未松手的最终颜色")
        model.toggleColorEditor(for: .translate)
        let newPicker = model.testColorPicker!
        newPicker.select(at: CGPoint(x: 150, y: 50), size: CGSize(width: 208, height: 140))
        let current = model.settings, count = writes.count
        oldPreview(WheelColor(red: 1, green: 0, blue: 0)); oldFinish(); settle(0.05)
        check(model.settings == current && writes.count == count, "旧功能迟到事件不能修改新功能或提交新草稿")
        let finalWindow = model.testColorWindow!
        let afterClosePreview = newPicker.onPreview, afterCloseFinish = newPicker.onFinish
        model.onClose(); settle(0.15)
        check(model.testColorWindow == nil && !finalWindow.isVisible && writes.count == count + 1,
              "关闭设置收起选色面板并保存当前最终值")
        afterClosePreview(WheelColor(red: 0, green: 1, blue: 0)); afterCloseFinish(); settle(0.05)
        check(model.settings == current && writes.count == count + 1, "关闭后旧回调不再改色或保存")
        model.prepare()
        check(model.page == .functions && model.testColorWindow == nil, "重新打开回到收起状态")
        for color in [WheelColor(red: 1, green: 0, blue: 0), WheelColor(red: 0, green: 1, blue: 0),
                      WheelColor(red: 0, green: 0, blue: 1), WheelColor(red: 0.31, green: 0.57, blue: 0.12),
                      WheelColor(red: 0, green: 0, blue: 0), WheelColor(red: 1, green: 1, blue: 1)] {
            let result = POSettingsHSV(color).color
            check(abs(result.red - color.red) < 0.00001 && abs(result.green - color.green) < 0.00001
                  && abs(result.blue - color.blue) < 0.00001, "HSV与sRGB往返保留实际颜色")
        }
        ui.updateWheelSettings(.defaults)
        passed("R215详情与AI标记、连续选色预览、保存代次及关闭事件隔离")
    }

    @MainActor static func renderColorDetails(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let model = open(ui)
        let settings = ui.testSettingsWindow!.panel
        renderPanels([settings], into: directory, file: "settings-library", title: "四列功能库")
        for action in PointOutAction.allCases {
            model.page = .edit(action)
            renderPanels([settings], into: directory, file: "detail-\(action.rawValue)", title: "\(action.title)详情 · 换色收起")
        }
        model.page = .edit(.explain)
        model.toggleColorEditor(for: .explain)
        settle()
        renderPanels([settings, model.testColorWindow!.panel], into: directory, file: "detail-color-expanded", title: "解释详情 · 连续选色展开")
        model.onClose()
        ui.updateWheelSettings(.defaults)
        settle()
    }

    @MainActor static func render(into directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        ui.updateWheelSettings(.defaults)
        let model = open(ui)
        let window = ui.testSettingsWindow!

        renderPanels([window.panel], into: directory, file: "settings-functions", title: "设置 · 功能列表 · 默认四格")
        model.setTriggerEnabled(false)
        renderPanels([window.panel], into: directory, file: "settings-trigger-off", title: "设置 · 不触发 · 设置入口保留")
        model.setTriggerEnabled(true)
        ui.updateWheelSettings(WheelSettings(slots: PointOutAction.allCases.map { Optional($0) }, colors: [:]))
        renderPanels([window.panel], into: directory, file: "settings-six-functions", title: "设置 · 六功能 · 嘴替")
        model.page = .edit(.replyCoach)
        renderPanels([window.panel], into: directory, file: "settings-reply-coach-edit", title: "设置 · 嘴替颜色编辑")
        model.page = .functions
        ui.updateWheelSettings(.defaults)


        let start = CGPoint(x: model.wheelCenter.x + 300, y: 120)
        model.setSlotCount(5)
        model.pointerMoved(.block(.translate), start: start, location: start)
        model.pointerMoved(.block(.translate), start: start, location: panelPoint(model, slot: 4))
        renderPanels([window.panel], into: directory, file: "settings-drag", title: "设置 · 拖入第 5 格（松开前）")
        model.cancelDrag()

        ui.updateWheelSettings(WheelSettings(slots: [.explain, .translate, nil, .save, .rewrite, nil, .explain, .translate],
                                             colors: [.translate: POSwatches.violet.wheelColor]))
        model.page = .edit(.translate)
        renderPanels([window.panel], into: directory, file: "settings-edit", title: "设置 · 翻译编辑页 · 8 格含空格 · 紫")

        ui.updateWheelSettings(WheelSettings(slots: [.explain], colors: [:]))
        model.page = .functions
        renderPanels([window.panel], into: directory, file: "settings-one", title: "设置 · 1 格")
        // Test-only repeated real actions: exercise three full rows and overflow without adding actions.
        model.setSlotCount(8)
        model.testLibraryActions = Array(Array(repeating: PointOutAction.allCases, count: 3).flatMap { $0 }.prefix(12))
        renderPanels([window.panel], into: directory, file: "settings-library-rows", title: "设置 · 12 项布局夹具（重复真实功能）")
        model.testLibraryActions = Array(Array(repeating: PointOutAction.allCases, count: 4).flatMap { $0 }.prefix(16))
        renderPanels([window.panel], into: directory, file: "settings-library-overflow", title: "设置 · 16 项滚动夹具（重复真实功能）")
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        guard let content = window.panel.contentView, let scroll = scrollView(in: content),
              let document = scroll.documentView else { fatalError("功能库缺少原生滚动区域") }
        check(document.bounds.height > scroll.contentView.bounds.height, "超出三排的功能在真实滚动文档中保留")
        let originalOffset = scroll.contentView.bounds.origin
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.1)
        check(scroll.contentView.bounds.origin != originalOffset, "多排功能可通过原生滚动容器到达底部")
        renderPanels([window.panel], into: directory, file: "settings-library-scrolled", title: "设置 · 16 项夹具滚至末排")
        let beforeDrop = model.settings.slots
        let libraryPoint = CGPoint(x: POSettingsMetrics.side + POSettingsMetrics.columnGap + POSettingsMetrics.libraryInset + POSettingsMetrics.block / 2,
                                   y: (POSettingsMetrics.side - POSettingsMetrics.libraryHeight) / 2 + POSettingsMetrics.libraryInset + POSettingsMetrics.block / 2)
        drag(model, .block(.rewrite), to: panelPoint(model, slot: 7), from: libraryPoint)
        check(model.settings.slots[7] == .rewrite && Array(model.settings.slots.prefix(7)) == Array(beforeDrop.prefix(7)),
              "功能库滚动后拖入只修改目标格")
        check(window.panel.frame.size == NSSize(width: POSettingsMetrics.padding * 2 + POSettingsMetrics.side + POSettingsMetrics.columnGap + POSettingsMetrics.column,
                                                height: POSettingsMetrics.padding * 2 + POSettingsMetrics.side + 34),
              "多排与滚动不撑大设置窗口")
        model.testLibraryActions = nil
        check(model.libraryActions == PointOutAction.allCases, "离开多排夹具后恢复六项真实功能")
        model.onClose()
        settle()

        // 真实手势轮盘（CALayer）：8 格含空格并指向一格；1 格。轮盘在显示时按外观取色，所以每种外观重新打开一次。
        ui.updateWheelSettings(WheelSettings(slots: [.explain, .translate, nil, .save, .rewrite, nil, .explain, .translate],
                                             colors: [.translate: POSwatches.violet.wheelColor]))
        let reopen = { (pointAt: Int?) in
            ui.hideWheel()
            ui.showWheel(at: point)
            if let pointAt { _ = ui.updateWheel(pointer: pointer(ui.testWheel.testSlots[pointAt])) }
        }
        ui.showWheel(at: point)
        renderPanels([ui.testWheel.testPanel], into: directory, file: "wheel-eight", title: "手势轮盘 · 8 格 · 指向翻译",
                     prepare: { reopen(1) })
        check(ui.updateWheel(pointer: pointer(ui.testWheel.testSlots[1])) == .translate, "渲染时指向的是翻译")
        ui.hideWheel()
        settle()
        ui.updateWheelSettings(WheelSettings(slots: PointOutAction.allCases.map { Optional($0) }, colors: [:]))
        ui.showWheel(at: point)
        renderPanels([ui.testWheel.testPanel], into: directory, file: "wheel-six-functions", title: "手势轮盘 · 六功能 · 指向嘴替",
                     prepare: { reopen(5) })
        check(ui.updateWheel(pointer: pointer(ui.testWheel.testSlots[5])) == .replyCoach, "六功能轮盘真实命中嘴替")
        ui.hideWheel(); settle()
        ui.updateWheelSettings(WheelSettings(slots: [.rewrite], colors: [:]))
        ui.showWheel(at: point)
        renderPanels([ui.testWheel.testPanel], into: directory, file: "wheel-one", title: "手势轮盘 · 1 格",
                     prepare: { reopen(nil) })
        ui.hideWheel()
        settle()
        ui.updateWheelSettings(.defaults)
        passed("离屏渲染浅色与深色")
    }

    /// 对真实 NSHostingView / CALayer 做离屏绘制；没有交给 WindowServer 显示。
    @MainActor static func renderPanels(_ panels: [POPanel], into directory: URL, file: String, title: String,
                                        appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)],
                                        prepare: () -> Void = {}) {
        for (name, appearanceName) in appearances {
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
