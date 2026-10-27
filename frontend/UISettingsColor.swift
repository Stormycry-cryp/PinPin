import AppKit
import SwiftUI

/// 一个色相值与二维饱和度/明度，颜色以既有 sRGB 契约交给设置模型。
struct POSettingsHSV: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(_ color: WheelColor) {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let delta = high - low
        brightness = high
        saturation = high == 0 ? 0 : delta / high
        if delta == 0 { hue = 0 }
        else if high == color.red { hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6) / 6 }
        else if high == color.green { hue = ((color.blue - color.red) / delta + 2) / 6 }
        else { hue = ((color.red - color.green) / delta + 4) / 6 }
        if hue < 0 { hue += 1 }
    }

    var color: WheelColor {
        let h = hue.truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return WheelColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }
}

@MainActor final class POSettingsColorPickerModel: ObservableObject {
    @Published private(set) var value: POSettingsHSV
    var onPreview: (WheelColor) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var onReset: () -> Void = {}
    var onClose: () -> Void = {}

    init(color: WheelColor) { value = POSettingsHSV(color) }

    func receive(_ color: WheelColor) {
        let next = POSettingsHSV(color)
        if next != value { value = next }
    }

    private func update(_ next: POSettingsHSV) {
        guard next != value else { return }
        value = next
        onPreview(next.color)
    }

    func select(at point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var next = value
        next.saturation = min(max(Double(point.x / size.width), 0), 1)
        next.brightness = 1 - min(max(Double(point.y / size.height), 0), 1)
        update(next)
    }

    func selectHue(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        var next = value
        next.hue = min(max(Double(x / width), 0), 1)
        update(next)
    }

    func adjust(hue: Double = 0, saturation: Double = 0, brightness: Double = 0) {
        var next = value
        next.hue = min(max(next.hue + hue, 0), 1)
        next.saturation = min(max(next.saturation + saturation, 0), 1)
        next.brightness = min(max(next.brightness + brightness, 0), 1)
        update(next)
        onFinish()
    }

    var hex: String {
        let c = value.color
        return String(format: "#%02X%02X%02X", Int((c.red * 255).rounded()),
                      Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
    }
}

/// 按需展示的小型原生视图，无鼠标监听、轮询或持续动画。
struct POSettingsColorPickerView: View {
    @ObservedObject var model: POSettingsColorPickerModel
    let title: String
    private let width: CGFloat = 208

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(title)颜色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(POPalette.ink)
                Spacer()
                POIconButton(symbol: "xmark", label: "关闭颜色选择", action: model.onClose)
            }
            .frame(height: 22)
            .overlay(alignment: .leading) {
                POSettingsWindowDragArea().padding(.trailing, 30).accessibilityHidden(true)
            }
            saturationBrightness
            hue
            HStack {
                Text(model.hex)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(POPalette.inkSecondary)
                    .accessibilityLabel("颜色 \(model.hex)")
                Spacer()
                Button("恢复默认", action: model.onReset)
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(POPalette.inkSecondary)
            }
            .frame(height: 22)
        }
        .frame(width: width)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)颜色选择")
        .onExitCommand(perform: model.onClose)
    }

    private var saturationBrightness: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(Color(hue: model.value.hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle().stroke(.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: 10, height: 10)
                    .position(x: min(max(model.value.saturation * geometry.size.width, 6), geometry.size.width - 6),
                              y: min(max((1 - model.value.brightness) * geometry.size.height, 6), geometry.size.height - 6))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { model.select(at: $0.location, size: geometry.size) }
                .onEnded { model.select(at: $0.location, size: geometry.size); model.onFinish() })
        }
        .frame(height: 140)
        .focusable()
        .onKeyPress(.leftArrow) { model.adjust(saturation: -0.02); return .handled }
        .onKeyPress(.rightArrow) { model.adjust(saturation: 0.02); return .handled }
        .onKeyPress(.upArrow) { model.adjust(brightness: 0.02); return .handled }
        .onKeyPress(.downArrow) { model.adjust(brightness: -0.02); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("饱和度与明度")
        .accessibilityValue("饱和度 \(Int(model.value.saturation * 100))%，明度 \(Int(model.value.brightness * 100))%")
        .accessibilityHint("左右调节饱和度，上下调节明度")
        .accessibilityAdjustableAction { direction in model.adjust(brightness: direction == .increment ? 0.02 : -0.02) }
        .accessibilityAction(named: "增加饱和度") { model.adjust(saturation: 0.02) }
        .accessibilityAction(named: "减少饱和度") { model.adjust(saturation: -0.02) }
    }

    private var hue: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 12).clipShape(Capsule())
                Capsule().stroke(.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: 7, height: 18)
                    .offset(x: min(max(model.value.hue * (geometry.size.width - 7), 0), geometry.size.width - 7))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { model.selectHue(at: $0.location.x, width: geometry.size.width) }
                .onEnded { model.selectHue(at: $0.location.x, width: geometry.size.width); model.onFinish() })
        }
        .frame(height: 22)
        .focusable()
        .onKeyPress(.leftArrow) { model.adjust(hue: -1 / 36); return .handled }
        .onKeyPress(.rightArrow) { model.adjust(hue: 1 / 36); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("色相")
        .accessibilityValue("\(Int(model.value.hue * 360))度")
        .accessibilityAdjustableAction { direction in model.adjust(hue: direction == .increment ? 1 / 36 : -1 / 36) }
    }
}
