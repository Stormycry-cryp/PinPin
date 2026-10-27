import AppKit
import ApplicationServices
import Combine
import Foundation

/// App host: menu bar item, permissions and the global gesture tap. Every action, follow-up,
/// and saved-library change is coordinated by ActionCoordinator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let presentation = OverlayPresentation()
    // Settings can open immediately; the wheel waits for its saved activation preference.
    private let monitor = GlobalGestureMonitor(wheelTriggerEnabled: false)
    private var coordinator: ActionCoordinator?
    private var item: NSStatusItem?
    private var permissionTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var listening = false
    private let wheelSettingsStore = WheelSettingsStore()
    private var wheelSettingsRevision: UInt64 = 0
    private var subscriptionAPI: SubscriptionAPIClient?
    private var subscriptionStore: SubscriptionStore?
    private var subscriptionObservers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        if let index = CommandLine.arguments.firstIndex(of: "--ui-preview") {
            let name = CommandLine.arguments.dropFirst(index + 1).first ?? "explanation"
            let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            presentation.previewComponent(name, at: CGPoint(x: frame.midX, y: frame.midY))
            return
        }
        let engine: ExplanationEngine
        let prepareAI: @Sendable () async throws -> Void
        let cancelAIAction: @Sendable (UUID) async -> Void
        #if PINPIN_APP_STORE
        do {
            let api = try SubscriptionAPIClient()
            subscriptionAPI = api
            connectSubscription(api)
            engine = ExplanationEngine(credentials: { try api.currentGatewayCredentials() })
            prepareAI = { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireCloudConsent()
                _ = try await api.ensureSession()
            }
            cancelAIAction = { id in
                // Cleanup must survive the cancelled model task, and never retries model execution.
                let cleanup = Task.detached { try? await api.cancelAction(id) }
                _ = await cleanup.value
            }
        } catch {
            let message = error.localizedDescription
            presentation.updateSubscription(SubscriptionPanelState(message: message, canRestore: false))
            engine = ExplanationEngine(credentials: { throw SubscriptionError.invalidConfiguration })
            prepareAI = { throw SubscriptionError.invalidConfiguration }
            cancelAIAction = { _ in }
        }
        #else
        engine = ExplanationEngine()
        prepareAI = {}
        cancelAIAction = { _ in }
        presentation.updateSubscription(SubscriptionPanelState(message: "订阅将在商店版本提供。", canRestore: false))
        #endif
        let coordinator = ActionCoordinator(presentation: presentation, capture: ContextCapture(),
                                            engine: engine, library: SavedLibrary(),
                                            sourceObserver: WindowResultObserver(), prepareAIAction: prepareAI,
                                            cancelAIAction: cancelAIAction)
        coordinator.record = { event, values, labels in Diagnostics.record(event, values: values, labels: labels) }
        self.coordinator = coordinator
        connectWheelSettings()
        let clearGesture = NativeClearGestureAdapter(interval: NSEvent.doubleClickInterval)
        monitor.recognizeNativeGesture = { sample in clearGesture.consume(sample) }
        monitor.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        monitor.onSettingsRequested = { [weak self] in
            DispatchQueue.main.async { self?.showSettings() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.refreshScreenGeometry()
        }
        startListeningIfAllowed()
        // A temporary authorization watch, stopped as soon as the tap is running.
        if !listening {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startListeningIfAllowed() }
            }
            presentation.showPermissionHelp(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
        }
    }

    private func installMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = PingBrand.menuBarImage()
        item?.button?.setAccessibilityLabel("PinPin")
        let menu = NSMenu()
        let status = NSMenuItem(title: "PinPin", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        for (title, action) in [("设置…", #selector(showSettings)), ("订阅…", #selector(showSubscription)),
                                ("资产看板…", #selector(showLibrary)), ("权限", #selector(showPermissions)),
                                ("关闭卡片", #selector(dismissCard))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 PinPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item?.menu = menu
    }

    private func connectWheelSettings() {
        presentation.onWheelSettingsChange = { [weak self] settings in
            guard let self, settings.isValid else { return false }
            self.wheelSettingsRevision += 1
            let revision = self.wheelSettingsRevision
            self.monitor.setWheelTriggerEnabled(settings.triggerEnabled)
            self.presentation.updateWheelSettings(settings)
            do {
                try await self.wheelSettingsStore.save(settings, revision: revision)
                return true
            } catch {
                Diagnostics.record("wheel_settings_save_failed")
                return false
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let settings = try await self.wheelSettingsStore.load()
                // A late initial load must not replace a change already made in the settings panel.
                guard self.wheelSettingsRevision == 0 else { return }
                self.monitor.setWheelTriggerEnabled(settings.triggerEnabled)
                self.presentation.updateWheelSettings(settings)
            } catch {
                if self.wheelSettingsRevision == 0 { self.monitor.setWheelTriggerEnabled(WheelSettings.defaults.triggerEnabled) }
                Diagnostics.record("wheel_settings_load_failed")
            }
        }
    }

    @objc private func showSettings() { presentation.showSettings() }

    @objc private func showSubscription() {
        presentation.showSubscription()
    }

    private func connectSubscription(_ api: SubscriptionAPIClient) {
        let store = SubscriptionStore(api: api)
        subscriptionStore = store
        Publishers.CombineLatest4(store.$product, store.$phase, store.$entitlement, store.$isBusy)
            .combineLatest(store.$purchaseAwaitingResolution)
            .sink { [weak self] values, awaitingResolution in
                guard let self else { return }
                let (product, phase, entitlement, isBusy) = values
                let snapshot: SubscriptionSnapshot?
                if case .available(let value) = entitlement, value.periodEnd > Date() { snapshot = value }
                else { snapshot = nil }
                var message: String?
                switch phase {
                case .loading: message = "正在同步订阅…"
                case .purchasing: message = "请在 App Store 中确认购买。"
                case .pending: message = "购买正在等待批准，批准后会自动同步。"
                case .confirming: message = "正在确认订阅…"
                case .cancelled: message = "已取消购买。"
                case .failed(let detail): message = detail
                default: break
                }
                let isPro = snapshot?.plan == .pro
                self.presentation.updateSubscription(SubscriptionPanelState(
                    isPro: isPro, periodEnd: snapshot?.periodEnd, limit: snapshot?.limit ?? 20,
                    remaining: snapshot?.remaining, displayPrice: product?.displayPrice,
                    message: message, isBusy: isBusy,
                    canPurchase: snapshot?.plan == .free && product?.id == SubscriptionStore.productID && !isBusy && !awaitingResolution,
                    canRestore: !isBusy, entitlementKnown: snapshot != nil))
            }
            .store(in: &subscriptionObservers)
        presentation.onSubscriptionAction = { [weak self, weak store] action in
            guard let self, let store else { return }
            switch action {
            case .purchase: Task { await store.purchase() }
            case .restore: Task { await store.restore() }
            case .refresh: Task { await store.refresh() }
            case .manage:
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") { NSWorkspace.shared.open(url) }
            case .privacy, .terms:
                let page = action == .privacy ? "privacy" : "terms"
                if let url = URL(string: "https://gateway.example.com/pinpin/" + page) { NSWorkspace.shared.open(url) }
            }
        }
        store.start()
    }

    private func requireCloudConsent() throws {
        let preference = "PinPin.cloud-processing-consent.v1"
        guard !UserDefaults.standard.bool(forKey: preference) else { return }
        let alert = NSAlert()
        alert.messageText = "允许使用云端 AI？"
        alert.informativeText = "确认功能后，相关窗口图像或文字会发送至 PinPin 服务，并由 BeatAPI Jev 和火山方舟 DeepSeek 处理。取色和本地收藏不会上传。"
        alert.addButton(withTitle: "允许并继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { throw CloudProcessingConsentError.declined }
        UserDefaults.standard.set(true, forKey: preference)
    }

    /// Finder or Spotlight can reopen settings when the menu bar has no room for the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentation.showSettings()
        return false
    }

    /// Opens the saved library just below the menu bar item.
    @objc private func showLibrary() {
        var point: CGPoint?
        if let button = item?.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            point = CGPoint(x: frame.midX, y: frame.minY)
        }
        if let coordinator { coordinator.showLibrary(near: point) } else { presentation.showLibrary(near: point) }
    }

    @objc private func showPermissions() {
        presentation.showPermissionHelp(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
    }

    @objc private func dismissCard() {
        presentation.closeCard()
    }

    private func startListeningIfAllowed() {
        guard !listening, AXIsProcessTrusted() else { return }
        listening = monitor.start()
        if listening {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private func receive(_ event: GestureEvent) {
        let resolved: GestureEvent
        if case .began(let candidate) = event { resolved = .began(TargetSourceResolver.anchor(from: candidate)) }
        else { resolved = event }
        coordinator?.receive(resolved)
        if case .permissionLost = event {
            listening = false
            presentation.showPermissionHelp(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        subscriptionStore?.stop()
        subscriptionObservers.removeAll()
        permissionTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        monitor.stop()
        coordinator?.stopSourceObservation()
    }
}

/// Constructed on main, then exclusively consumed by the event-tap thread.
/// All gesture timing, movement and neutral-zone decisions are the UI-owned value rule.
private final class NativeClearGestureAdapter: @unchecked Sendable {
    private var rule: POClearGesture
    init(interval: TimeInterval) { rule = POClearGesture(interval: interval) }
    func consume(_ sample: NativeGestureSample) -> Bool {
        switch sample {
        case let .down(point, time, startsSession):
            rule.down(at: point, time: time, startsSession: startsSession)
        case .dragged(let point): rule.dragged(to: point)
        case let .up(point, time): return rule.up(at: point, time: time)
        case .reset: rule.reset()
        }
        return false
    }
}


@main
struct PointOutMain {
    @MainActor static func main() async {
        if let request = ActionProbe.parse(CommandLine.arguments) {
            do {
                let record = try await ActionProbe.run(request)
                let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("PinPin: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--explain-text"),
           let text = CommandLine.arguments.dropFirst(index + 1).first {
            let context = CapturedContext(sessionID: UUID(), targetText: text,
                surroundingText: "", appName: "PinPin CLI", windowTitle: "", source: "ax_text")
            do {
                let output = try await ExplanationEngine().explain(context: context, supplement: { _ in context }, onText: { _ in })
                let record: [String: Any] = ["text": output.text, "route": output.route,
                    "metrics": output.metrics, "jevModel": output.jevModel ?? "none", "answerModel": output.answerModel ?? "unknown"]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("PinPin: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--permissions") {
            print("accessibility=\(AXIsProcessTrusted()) screenCapture=\(CGPreflightScreenCaptureAccess())")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
