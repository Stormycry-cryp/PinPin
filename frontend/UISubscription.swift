import AppKit
import SwiftUI

// MARK: - Subscription panel (display-only host contract)

enum POSubscriptionMetrics {
    static let width: CGFloat = 344
    static let padding: CGFloat = 18
    static let radius: CGFloat = 18
    static let buttonHeight: CGFloat = 32
}

@MainActor final class POSubscriptionModel: ObservableObject {
    @Published private(set) var state = SubscriptionPanelState()
    var onAction: ((SubscriptionControlAction) -> Void)?
    var onClose: () -> Void = {}

    func receive(_ state: SubscriptionPanelState) {
        guard self.state != state else { return }
        self.state = state
    }

    var price: String? {
        guard let value = state.displayPrice?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var canPurchase: Bool { state.entitlementKnown && !state.isPro && !state.isBusy && state.canPurchase && price != nil }
    var canRestore: Bool { !state.isBusy && state.canRestore }
    var planTitle: String { state.entitlementKnown ? (state.isPro ? "Pro" : "Free") : "待同步" }
    var remaining: Int? { state.entitlementKnown ? state.remaining : nil }
    var primaryEnabled: Bool { canPurchase }
    var primaryTitle: String {
        if state.isBusy { return price == nil ? "正在加载订阅…" : "正在处理…" }
        guard let price else { return "价格暂不可用" }
        return "订阅 Pro · \(price) / 月"
    }
    var message: String? {
        if let value = state.message?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        return state.remaining == nil ? "订阅与额度待同步" : nil
    }

    func perform(_ action: SubscriptionControlAction) {
        switch action {
        case .purchase: guard canPurchase else { return }
        case .restore: guard canRestore else { return }
        case .manage, .refresh: guard !state.isBusy else { return }
        case .privacy, .terms: break
        }
        onAction?(action)
    }

    func primaryAction() { perform(.purchase) }
}

struct POSubscriptionView: View {
    @ObservedObject var model: POSubscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            quota
            VStack(spacing: 9) {
                allowance("Free", amount: "20 次 AI / 月")
                allowance("Pro", amount: "1,000 次 AI / 月")
                allowance("本地功能", amount: "免费")
            }
            if let message = model.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(POPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("订阅状态：\(message)")
            }
            if !model.state.entitlementKnown || !model.state.isPro {
                Button(action: model.primaryAction) {
                    Text(model.primaryTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(POSubscriptionButtonStyle())
                .disabled(!model.primaryEnabled)
                .accessibilityHint("由 App Store 显示价格并确认月度订阅")
            }
        }
        .padding(POSubscriptionMetrics.padding)
        .frame(width: POSubscriptionMetrics.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("订阅与用量")
        .onExitCommand(perform: model.onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("订阅")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(POPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            optionsMenu
            POIconButton(symbol: "xmark", label: "关闭订阅面板", action: model.onClose)
        }
        .frame(height: 22)
        .overlay(alignment: .leading) {
            POSettingsWindowDragArea()
                .padding(.trailing, 62)
                .accessibilityHidden(true)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button("恢复购买") { model.perform(.restore) }.disabled(!model.canRestore)
            Button("管理订阅") { model.perform(.manage) }.disabled(model.state.isBusy)
            Button("刷新状态") { model.perform(.refresh) }.disabled(model.state.isBusy)
            Divider()
            Button("隐私政策") { model.perform(.privacy) }
            Button("使用条款") { model.perform(.terms) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(POPalette.inkSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().poRaisedFill(depth: 1.2))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("订阅选项")
        .accessibilityLabel("订阅选项")
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.planTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(POPalette.ink)
                Text("当前方案")
                    .font(.system(size: 10.5))
                    .foregroundStyle(POPalette.inkTertiary)
                Spacer()
                Text("本周期剩余")
                    .font(.system(size: 10.5))
                    .foregroundStyle(POPalette.inkSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(model.remaining.map { $0.formatted(.number.locale(Locale(identifier: "zh_CN"))) } ?? "—")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(POPalette.ink)
                Text(!model.state.entitlementKnown ? "次" :
                     "/ \(model.state.limit.formatted(.number.locale(Locale(identifier: "zh_CN")))) 次")
                    .font(.system(size: 11))
                    .foregroundStyle(POPalette.inkSecondary)
                Spacer(minLength: 0)
            }
            Text(periodDescription)
                .font(.system(size: 10.5))
                .foregroundStyle(POPalette.inkTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .poWell(radius: 10)
        .accessibilityElement(children: .combine)
    }

    private var periodDescription: String {
        guard model.state.entitlementKnown, let end = model.state.periodEnd else { return "周期日期待同步" }
        return "本周期至 " + end.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day())
    }

    private func allowance(_ title: String, amount: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11.5, weight: title == "Pro" ? .semibold : .medium))
            Spacer()
            Text(amount).font(.system(size: 11.5)).monospacedDigit()
        }
        .foregroundStyle(POPalette.inkSecondary)
    }

}

private struct POSubscriptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isEnabled ? POPalette.ink : POPalette.inkTertiary)
            .frame(height: POSubscriptionMetrics.buttonHeight)
            .background {
                if configuration.isPressed || !isEnabled { Capsule().poWellFill(depth: 1.2) }
                else { Capsule().poRaisedFill(depth: 1.5) }
            }
            .contentShape(Capsule())
    }
}
