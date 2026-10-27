#if PINPIN_UI_TESTING
/// 仅离屏性能实验启用；所有调用来自主线程，不进入产品构建。
enum POUIPerformance {
    static var counters: [String: Int] = [:]
    static func count(_ name: String) { counters[name, default: 0] += 1 }
    static func reset() { counters.removeAll(keepingCapacity: true) }
}
#endif
