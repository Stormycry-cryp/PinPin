import AppKit
import Foundation

/// R159：真实组件离屏检查；复制写入注入闭包，不接触系统剪贴板。
@main
struct EyedropperTests {
    @MainActor static var checks = 0
    static let point = CGPoint(x: 460, y: 500)
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: \(message)") }
    }
    static func settle(_ seconds: Double = 0.25) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    @MainActor static func begin(_ ui: OverlayPresentation, _ action: PointOutAction = .pickColor) -> UUID {
        let id = UUID()
        ui.beginResult(id, action: action, at: point, processID: 101)
        return id
    }
    @MainActor static func color(_ ui: OverlayPresentation, _ id: UUID) -> PickedColor? {
        guard case .pickedColor(let color) = ui.testModel(id)?.content else { return nil }
        return color
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ui = OverlayPresentation(presentsOnScreen: false)
        let sample = PickedColor(red: 46, green: 94, blue: 158)
        let a = begin(ui), b = begin(ui, .explain)
        check(ui.testModel(a)?.content == .pickingColor, "等待采样只显示静态状态")
        check(ui.testMarkerView(a)?.ballState == .done, "取色小球没有生成旋转")
        check(ui.testModel(a)?.content.isLoading == false, "无模型生成骨架")
        ui.updateResult(b, text: "另一个独立答案", subtitle: nil); ui.finishResult(b)
        ui.showPickedColor(a, color: sample)
        check(color(ui, a) == sample, "显示 typed 采样结果")
        check(ui.testModel(b)?.plainText == "另一个独立答案", "颜色不影响另一张卡")
        check(!ui.testModel(a)!.supportsFollowUp && ui.testModel(a)!.plainText == nil, "颜色没有追问或整段文本复制")
        var copies: [String] = [], questions = 0
        ui.testModel(a)!.onCopy = { copies.append($0) }
        ui.onFollowUp = { _, _ in questions += 1 }
        check(copies.isEmpty, "呈现不自动复制")
        ui.testModel(a)!.copyColor(.hex)
        ui.testModel(a)!.copyColor(.rgb)
        check(copies == ["#2E5E9E", "46, 94, 158"], "用户点击的两种复制值精确传入注入闭包")
        ui.testModel(a)!.draft = "不应发送"
        ui.testModel(a)!.submitFollowUp()
        check(questions == 0, "即使直接调用提交也不会发送颜色追问")
        ui.testModel(a)!.draft = ""
        ui.testModel(a)!.suspendNotice()
        ui.testOpen(a, dialog: true)
        check(ui.testModel(a)!.expanded && !ui.testModel(a)!.supportsFollowUp, "点开保留卡片且不加入追问栏")
        renderPanels([ui.testWindow(a)!.panel], into: directory, file: "picked-color", title: "取色结果 · sRGB #2E5E9E")
        ui.testModel(a)!.onClose()
        check(ui.testVisibleIDs == [b], "颜色卡收起只影响自己")
        let marker = ui.testMarkerView(a)!
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        marker.mouseEntered(with: entered)
        settle(0.6)
        check(!ui.testVisibleIDs.contains(a), "悬停不足一秒不展开")
        settle(0.55)
        check(ui.testVisibleIDs.contains(a) && !ui.testModel(a)!.expanded, "一秒悬停打开自己的短卡片")
        ui.testHover(a, inside: false); settle(0.45)
        check(!ui.testVisibleIDs.contains(a), "离开悬停卡后独立收起")
        ui.testOpen(a, dialog: true)
        ui.testOutside()
        check(ui.testVisibleIDs == [a], "显式打开的颜色卡保留，普通短卡收起")
        ui.updateResultSource(a, at: point, visible: false)
        check(!ui.testVisibleIDs.contains(a), "随所属应用隐藏")
        ui.showPickedColor(a, color: sample)
        check(!ui.testVisibleIDs.contains(a), "隐藏时更新颜色不弹出")
        ui.updateResultSource(a, at: point, visible: true)
        check(ui.testVisibleIDs.contains(a) && color(ui, a) == sample, "切回恢复准确颜色")
        ui.updateResult(a, text: "#FFFFFF", subtitle: "猜测")
        ui.finishResult(a)
        ui.showPickedColor(b, color: sample)
        check(color(ui, a) == sample && ui.testModel(b)?.plainText == "另一个独立答案", "忽略类型不匹配的迟到结果")
        ui.closeCard()
        check(!ui.testVisibleIDs.contains(a) && ui.testResultIDs.contains(a), "菜单关闭保留颜色结果供重开")
        ui.testOpen(a, dialog: true)
        ui.updateWheelSettings(WheelSettings(slots: [.pickColor], colors: [.pickColor: POSwatches.rose.wheelColor]))
        check(color(ui, a) == sample, "修改取色器图标颜色不会改样本")
        renderPanels([ui.testWindow(a)!.panel], into: directory, file: "picked-custom-icon", title: "取色结果 · 玫红图标与原始样本")
        for (name, c) in [("black", PickedColor(red: 0, green: 0, blue: 0)),
                          ("white", PickedColor(red: 255, green: 255, blue: 255))] {
            ui.showPickedColor(a, color: c)
            renderPanels([ui.testWindow(a)!.panel], into: directory, file: "picked-\(name)", title: "取色结果 · \(c.hex)")
        }
        var forgotten: [UUID] = []
        ui.onForget = { forgotten.append($0) }
        ui.testRemove(a)
        ui.showPickedColor(a, color: sample)
        check(!ui.testCardIDs.contains(a) && forgotten == [a] && ui.testResultIDs == [b], "单独删除和迟到回调不复活、不影响其他结果")
        let c = begin(ui); ui.showPickedColor(c, color: sample)
        ui.clearAllMarkers(); ui.showPickedColor(c, color: sample)
        check(ui.testCardIDs.isEmpty && ui.testMarkerIDs.isEmpty && ui.testResultIDs.isEmpty, "全清释放所有颜色和普通卡片")
        check(ui.testMouseMonitorCount == 0, "离屏测试未安装鼠标监听")
        settings(directory)
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "全程窗口不上屏")
        print("PASS \(checks) checks; typed sRGB, injected copies, 1s hover, independent cards, five-action settings; no windows on screen")
    }

    @MainActor static func settings(_ directory: URL) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        check(WheelSettings.defaults.slots == [.save, .translate, .rewrite, .explain], "默认四格顺序保持")
        var persisted: [WheelSettings] = []
        ui.onWheelSettingsChange = { persisted.append($0); return true }
        ui.showSettings()
        let model = ui.testSettingsModel
        check(Array(model.libraryActions.prefix(5)) == [.explain, .translate, .rewrite, .save, .pickColor], "第五个真实功能为取色器")
        renderPanels([ui.testSettingsWindow!.panel], into: directory, file: "settings-six", title: "设置 · 六个真实功能 · 默认四格")
        let start = CGPoint(x: 380, y: 150)
        for count in 1...8 {
            model.setSlotCount(count)
            let slot = POWheelLayout.standard(count)[count - 1]
            let end = CGPoint(x: model.wheelCenter.x + cos(slot.mid) * 80, y: model.wheelCenter.y - sin(slot.mid) * 80)
            model.pointerMoved(.block(.pickColor), start: start, location: start)
            model.pointerMoved(.block(.pickColor), start: start, location: end)
            model.pointerEnded(.block(.pickColor), start: start, location: end)
            check(model.settings.slots[count - 1] == .pickColor, "取色器拖入 \(count) 格配置的末格")
        }
        settle()
        check(persisted.last == model.settings, "取色器槽位交给宿主保存")
        model.pointerEnded(.block(.pickColor), start: start, location: start)
        check(model.page == .edit(.pickColor), "点击功能块打开取色器配色")
        model.setColor(POSwatches.green, for: .pickColor); settle()
        check(persisted.last?.colors[.pickColor] == POSwatches.green.wheelColor, "配色随完整设置保存")
        renderPanels([ui.testSettingsWindow!.panel], into: directory, file: "settings-picker-edit", title: "设置 · 取色器颜色页 · 八格")
        model.resetColor(.pickColor); settle()
        check(model.settings.colors[.pickColor] == nil, "恢复紫色默认值清除覆盖")
        ui.showWheel(at: point)
        for slot in ui.testWheel.testSlots {
            let pointer = CGPoint(x: point.x + cos(slot.mid) * 1000, y: point.y + sin(slot.mid) * 1000)
            check(ui.updateWheel(pointer: pointer) == .pickColor, "圈外角度仍命中取色器")
        }
        renderPanels([ui.testWheel.testPanel], into: directory, file: "wheel-picker", title: "取色器轮盘 · 八格", prepare: {
            ui.hideWheel(); settle(0.15)
            ui.showWheel(at: point)
        })
        ui.hideWheel(); model.onClose()
    }

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
