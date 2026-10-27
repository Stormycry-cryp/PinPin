import AppKit
import Combine
import Foundation

/// 同一主线程负载驱动真实离屏卡片；不等同于 WindowServer 上屏帧率。
@main struct AnnotationPerformanceTests {
    @MainActor static var verified = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        verified += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func pump(_ seconds: TimeInterval = 0.01) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { _ = RunLoop.current.run(mode: .default, before: until) }
    }
    @MainActor static func frame(_ ui: OverlayPresentation, _ ids: [UUID]) {
        for id in ids {
            guard let window = ui.testWindow(id) else { continue }
            // 离屏窗口没有屏幕刷新驱动；每批明确运行真实 hosting 布局，前后版本相同。
            for view in window.container.subviews {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
            }
        }
    }
    @MainActor static func measure(_ name: String, _ operation: () -> Void) {
        POUIPerformance.reset()
        let start = ProcessInfo.processInfo.systemUptime
        operation()
        var output: [String: Any] = POUIPerformance.counters
        output["scenario"] = name
        output["milliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    @MainActor static func begin(_ ui: OverlayPresentation, _ i: Int) -> UUID {
        let id = UUID()
        ui.beginResult(id, action: .explain, at: CGPoint(x: 150 + (i % 4) * 180, y: 250 + (i % 2) * 180), processID: 101)
        return id
    }
    @MainActor static func text(_ round: Int, _ index: Int) -> String {
        "卡片 \(index)：**缓存**保存已经算过的结果。" + String(repeating: "读取已有内容，减少重复计算。", count: round + 1)
    }
    @MainActor static func stream(_ name: String, paced: Bool, optimized: Bool) {
        let ui = OverlayPresentation(presentsOnScreen: false)
        let ids = (0..<8).map { begin(ui, $0) }
        for id in ids { ui.testOpen(id, dialog: true) }
        // 先过首字与展开，测稳定流式阶段，避免把一次性加载混入每包成本。
        for (i, id) in ids.enumerated() { ui.updateResult(id, text: text(0, i), subtitle: nil) }
        frame(ui, ids)
        pump(0.3)
        let initialFrames = ids.map { ui.testWindow($0)!.panel.frame }
        var subscriptions: [AnyCancellable] = []
        for id in ids {
            subscriptions.append(ui.testModel(id)!.objectWillChange.sink { POUIPerformance.count("modelPublish") })
        }
        let order = ui.testOrder
        let windows = ids.map { ObjectIdentifier(ui.testWindow($0)!) }
        measure(name) {
            for round in 1...80 {
                for (i, id) in ids.enumerated() { ui.updateResult(id, text: text(round, i), subtitle: nil) }
                if paced && round % 4 == 0 {
                    // 每批允许真实 SwiftUI/AppKit 处理布局；绝不上屏。
                    frame(ui, ids)
                    pump(0.002)
                }
            }
        }
        if optimized {
            check(POUIPerformance.counters["showFade", default: 0] == 0, "已有卡片流式更新不得重启淡入")
            check(POUIPerformance.counters["forcedLayout", default: 0] == 0, "流式包不得强制同步布局")
            check(POUIPerformance.counters["modelPublish", default: 0] == 640, "只发布实际变化的正文")
        }
        check(POUIPerformance.counters["orderFront", default: 0] == 0, "流式不能重新排序窗口")
        check(POUIPerformance.counters["panelCreated", default: 0] == 0, "流式不创建新窗口")
        frame(ui, ids)
        pump(0.35)
        for (i, id) in ids.enumerated() {
            let finalFrame = ui.testWindow(id)!.panel.frame
            if finalFrame.height <= initialFrames[i].height { fputs("FRAME initial=\(initialFrames[i]) final=\(finalFrame)\n", stderr) }
            check(finalFrame.height > initialFrames[i].height, "正文增多后真实窗口增高")
            check(abs(finalFrame.minY - initialFrames[i].minY) < 0.5, "卡片底边保持固定")
        }
        check(ui.testOrder == order, "保留前后顺序")
        check(ids.map { ObjectIdentifier(ui.testWindow($0)!) } == windows, "保留 8 个原窗口")
        for (i, id) in ids.enumerated() {
            guard case .answer(_, let value, _) = ui.testModel(id)!.content else { preconditionFailure("answer") }
            check(value == text(80, i), "不丢失任何完整正文")
            ui.finishResult(id)
        }
        check(ui.testLeaveTaskCount == 0 && ui.testPreviewTaskCount == 0, "正常 stream 不创建 hover/preview 任务")
        check(ui.testMouseMonitorCount == 0, "离屏不安装全局/本地监听")
        withExtendedLifetime(subscriptions) {}
        ui.clearAllMarkers()
        pump(0.1)
        check(ui.testCardIDs.isEmpty && ui.testResultIDs.isEmpty, "清理后无卡片/结果")
    }
    @MainActor final class WeakWindow {
        weak var value: POFloatingWindow?
        init(_ value: POFloatingWindow?) { self.value = value }
    }
    @MainActor static func lifecycleSnapshot(_ ui: OverlayPresentation, _ windows: [WeakWindow], after seconds: Double) {
        let alive = windows.compactMap(\.value)
        let output: [String: Any] = ["scenario": "rapid_release", "secondsAfterClear": seconds,
            "liveFloatingWindows": alive.count, "logicalVisible": alive.filter(\.isVisible).count,
            "frameAnimations": alive.filter(\.testHasFrameAnimation).count,
            "pendingSizeTasks": alive.filter(\.testHasPendingSizeWork).count,
            "visibleNativeWindows": NSApp.windows.filter(\.isVisible).count,
            "leaveTasks": ui.testLeaveTaskCount, "previewTasks": ui.testPreviewTaskCount,
            "mouseMonitors": ui.testMouseMonitorCount]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    @MainActor static func rapid() {
        let ui = OverlayPresentation(presentsOnScreen: false)
        var forgotten = 0
        var windows: [WeakWindow] = []
        ui.onForget = { _ in forgotten += 1 }
        measure("rapid_64_annotations_12_chunks") {
            for i in 0..<64 {
                let id = begin(ui, i)
                windows.append(WeakWindow(ui.testWindow(id)))
                for chunk in 0..<12 { ui.updateResult(id, text: text(chunk, i), subtitle: nil) }
                ui.finishResult(id)
                if i % 3 == 0 { ui.testRemove(id) }
                if i % 8 == 7 { pump(0.002) }
            }
            ui.clearAllMarkers()
        }
        pump(0.2)
        let releasedAtPointTwo = windows.allSatisfy { $0.value == nil }
        lifecycleSnapshot(ui, windows, after: 0.2)
        pump(0.3)
        lifecycleSnapshot(ui, windows, after: 0.5)
        pump(0.5)
        lifecycleSnapshot(ui, windows, after: 1.0)
        check(releasedAtPointTwo, "64 张卡片的浮窗对象在淡出后释放")
        check(forgotten == 64, "每个快速标注仅遗忘一次")
        check(ui.testCardIDs.isEmpty && ui.testMarkerIDs.isEmpty && ui.testResultIDs.isEmpty, "清理状态无残留")
        check(ui.testLeaveTaskCount == 0 && ui.testPreviewTaskCount == 0 && ui.testMouseMonitorCount == 0, "清理后没有状态任务或监听")
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--lifecycle-only") {
            rapid()
            print("PASS \(verified) lifecycle checks; offscreen only")
            return
        }
        let optimized = CommandLine.arguments.contains("--verify-optimized")
        for trial in 1...3 {
            stream("dense_8x80_trial_\(trial)", paced: false, optimized: optimized)
            stream("paced_8x80_trial_\(trial)", paced: true, optimized: optimized)
        }
        rapid()
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "无原生窗口上屏")
        print("PASS \(verified) checks; offscreen only")
    }
}
