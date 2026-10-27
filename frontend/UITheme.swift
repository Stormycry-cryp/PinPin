import AppKit
import SwiftUI

// MARK: - Color tokens (design-system.md §2)
// Black-and-white neumorphism: no large areas of pure #000 or #FFF. One opaque matte gray surface;
// depth comes from a light top-left edge and a soft bottom-right shade. Graphite is the single dark
// accent. The only hue is on the function icons (R128). Light, dark and Increase Contrast each
// have their own values.

struct POToken {
    let ns: NSColor

    var color: Color { Color(nsColor: ns) }

    /// Resolves the dynamic color for Core Animation layers in a given appearance.
    func cg(_ appearance: NSAppearance) -> CGColor {
        var resolved = ns.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = ns.cgColor }
        return resolved
    }

    static func dynamic(light: NSColor, dark: NSColor) -> POToken {
        POToken(ns: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Light, dark and their Increase Contrast variants.
    static func dynamic(light: NSColor, dark: NSColor, lightHigh: NSColor, darkHigh: NSColor) -> POToken {
        POToken(ns: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return dark
            case .accessibilityHighContrastAqua?: return lightHigh
            case .accessibilityHighContrastDarkAqua?: return darkHigh
            default: return light
            }
        })
    }
}

enum POBrand {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Porcelain: the off-white used on graphite (the send arrow). L 0.914.
    static let porcelain = rgb(0xF5F5F7)

    /// Graphite: the send key and the point in a saved picture. Porcelain on it (sRGB relative luminance, WCAG formula):
    /// light #2C2C2E 12.8:1, dark #6E6E73 4.66:1, Increase Contrast light #1C1C1E 15.6:1,
    /// dark #636366 5.50:1. All at least 4.5:1, none pure black.
    static let graphite = POToken.dynamic(light: rgb(0x2C2C2E), dark: rgb(0x6E6E73),
                                          lightHigh: rgb(0x1C1C1E), darkHigh: rgb(0x636366))
}

enum POColor {
    // Neumorphism (design-system.md §1–3): one opaque matte surface. Every control is made of the
    // same material, raised out of it or pressed into it, lit from the top left. Ink is a near-black
    // or near-white gray, never pure; hue is reserved for the function icons below.
    static let surface = POToken.dynamic(light: POBrand.rgb(0xE5E5E8), dark: POBrand.rgb(0x2C2C2F),
                                         lightHigh: POBrand.rgb(0xE5E5E8), darkHigh: POBrand.rgb(0x2C2C2F))
    /// The floor of a pressed area, a touch deeper than the surface.
    static let surfaceDeep = POToken.dynamic(light: POBrand.rgb(0xDCDCE0), dark: POBrand.rgb(0x252528),
                                             lightHigh: POBrand.rgb(0xD5D5DA), darkHigh: POBrand.rgb(0x222225))
    /// Light falling on the top-left edges.
    static let lightEdge = POToken.dynamic(light: NSColor(white: 1, alpha: 0.92), dark: NSColor(white: 1, alpha: 0.075),
                                           lightHigh: NSColor(white: 1, alpha: 1), darkHigh: NSColor(white: 1, alpha: 0.14))
    /// Shade toward the bottom right.
    static let darkEdge = POToken.dynamic(light: NSColor(white: 0, alpha: 0.17), dark: NSColor(white: 0, alpha: 0.55),
                                          lightHigh: NSColor(white: 0, alpha: 0.30), darkHigh: NSColor(white: 0, alpha: 0.75))

    /// Ink on the surface (WCAG, against #E5E5E8 / #2C2C2F): 13.4:1 / 11.8:1.
    static let ink = POToken.dynamic(light: POBrand.rgb(0x1D1D1F), dark: POBrand.rgb(0xECECEF),
                                     lightHigh: POBrand.rgb(0x111113), darkHigh: POBrand.rgb(0xF5F5F7))
    /// Titles, icons, idle labels: 7.2:1 / 6.9:1 on the surface, at least 6.6:1 on a pressed floor.
    static let inkSecondary = POToken.dynamic(light: POBrand.rgb(0x48484D), dark: POBrand.rgb(0xB6B6BB),
                                              lightHigh: POBrand.rgb(0x2E2E31), darkHigh: POBrand.rgb(0xD1D1D6))
    /// Dates, sources, placeholders: still at least 4.5:1 on both the surface and a pressed floor.
    static let inkTertiary = POToken.dynamic(light: POBrand.rgb(0x606065), dark: POBrand.rgb(0x949499),
                                             lightHigh: POBrand.rgb(0x48484D), darkHigh: POBrand.rgb(0xB0B0B5))
    /// The one dark accent: the send key, the point in a saved picture.
    static let accent = POBrand.graphite
    /// Foreground on `accent`: porcelain, not pure white.
    static let onAccent = POToken(ns: POBrand.porcelain)
    static let emphasis = ink
    /// Errors are told by glyph and words, not by a hue.
    static let danger = inkSecondary
    static let success = ink

    // Older names, now the neumorphic pair, so every component reads the same material.
    static let well = surfaceDeep
    static let hover = surface
    static let wellShade = darkEdge
    static let wellLight = lightEdge
    static let raisedFill = surface
    static let raisedLight = lightEdge
    static let raisedShade = darkEdge
    /// Top edge light on the graphite key.
    static let edgeLight = POToken.dynamic(light: NSColor(white: 1, alpha: 0.16),
                                           dark: NSColor(white: 1, alpha: 0.22))
    /// Outermost line of each slab; Increase Contrast makes it a real outline.
    static let hairline = POToken.dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.07),
                                          lightHigh: NSColor(white: 0, alpha: 0.45), darkHigh: NSColor(white: 1, alpha: 0.45))

    // Function icon colors (R128) are swatches (POSwatches below). Each function has a design default;
    // the user may pick another in settings (R145). Everything that draws one reads `PointOutAction.tint`.
}

// MARK: - Function color swatches (design-system.md §3, §21)

/// One function color. Muted hue, glyphs only (wheel icon, ball glyph, ring and outline, card token);
/// in settings it is also shown as a small sample dot. Each appearance has a fixed value.
/// The stored `WheelColor` is the light-appearance value, so a saved choice maps back to all four.
struct POSwatch: Identifiable, Equatable {
    let id: String
    /// Accessibility name.
    let name: String
    let light: UInt32
    let token: POToken

    init(_ id: String, _ name: String, light: UInt32, dark: UInt32, lightHigh: UInt32, darkHigh: UInt32) {
        self.id = id
        self.name = name
        self.light = light
        token = .dynamic(light: POBrand.rgb(light), dark: POBrand.rgb(dark),
                         lightHigh: POBrand.rgb(lightHigh), darkHigh: POBrand.rgb(darkHigh))
    }

    var wheelColor: WheelColor {
        WheelColor(red: Double((light >> 16) & 0xFF) / 255, green: Double((light >> 8) & 0xFF) / 255,
                   blue: Double(light & 0xFF) / 255)
    }

    func matches(_ color: WheelColor) -> Bool {
        let own = wheelColor
        return abs(own.red - color.red) < 0.6 / 255 && abs(own.green - color.green) < 0.6 / 255
            && abs(own.blue - color.blue) < 0.6 / 255
    }

    static func == (a: POSwatch, b: POSwatch) -> Bool { a.id == b.id }
}

/// WCAG against surface / surfaceDeep, the lower of the pair (light, dark, light high, dark high):
/// blue 4.78 / 6.39 / 6.08 / 8.37, violet 4.98 / 6.07 / 6.37 / 7.85, rose 4.77 / 5.79 / 6.04 / 7.71,
/// brick 4.64 / 6.10 / 5.88 / 7.86, amber 4.58 / 6.42 / 5.87 / 8.22, green 4.79 / 7.20 / 5.65 / 8.88,
/// teal 4.89 / 6.63 / 5.51 / 8.42, graphite 6.44 / 7.68 / 8.99 / 9.99.
enum POSwatches {
    static let blue = POSwatch("blue", "蓝", light: 0x2E5E9E, dark: 0x8DB2E6, lightHigh: 0x1F4A82, darkHigh: 0xAECBF2)
    static let violet = POSwatch("violet", "紫", light: 0x6A4A9E, dark: 0xB6A0E6, lightHigh: 0x553782, darkHigh: 0xCBBAF2)
    static let rose = POSwatch("rose", "玫红", light: 0xA2365C, dark: 0xE98BAA, lightHigh: 0x852746, darkHigh: 0xF2AEC5)
    static let brick = POSwatch("brick", "砖红", light: 0xA53D2E, dark: 0xEE9484, lightHigh: 0x872E22, darkHigh: 0xF4B3A8)
    static let amber = POSwatch("amber", "琥珀", light: 0x8A5410, dark: 0xDDA65A, lightHigh: 0x6E420A, darkHigh: 0xEBC083)
    static let green = POSwatch("green", "绿", light: 0x4A6619, dark: 0xA8C56C, lightHigh: 0x3D5615, darkHigh: 0xC1D791)
    static let teal = POSwatch("teal", "青绿", light: 0x1B675C, dark: 0x6CC2B3, lightHigh: 0x135A50, darkHigh: 0x92D6CA)
    /// No hue: for a wheel that stays black and white (R058).
    static let graphite = POSwatch("graphite", "石墨", light: 0x4A4A4F, dark: 0xC0C0C5, lightHigh: 0x303034, darkHigh: 0xDADADF)

    /// Settings order: around the hue circle, graphite last.
    static let all: [POSwatch] = [blue, violet, rose, brick, amber, green, teal, graphite]

    static func defaultSwatch(for action: PointOutAction) -> POSwatch {
        switch action {
        case .explain: return blue
        case .translate: return teal
        case .rewrite: return amber
        case .save: return rose
        case .pickColor: return violet
        case .replyCoach: return green
        }
    }

    static func matching(_ color: WheelColor) -> POSwatch? { all.first { $0.matches(color) } }

    /// A custom color from continuous selection or a saved configuration:
    /// used as given in light, lifted toward white in dark, deepened or lifted further for Increase Contrast.
    static func custom(_ c: WheelColor) -> POToken {
        func mix(_ t: Double, toward v: Double) -> NSColor {
            NSColor(srgbRed: CGFloat(c.red + (v - c.red) * t), green: CGFloat(c.green + (v - c.green) * t),
                    blue: CGFloat(c.blue + (v - c.blue) * t), alpha: 1)
        }
        return .dynamic(light: mix(0, toward: 0), dark: mix(0.45, toward: 1),
                        lightHigh: mix(0.2, toward: 0), darkHigh: mix(0.6, toward: 1))
    }

    /// The token for `action` under a settings color map.
    static func token(for action: PointOutAction, in colors: [PointOutAction: WheelColor]) -> POToken {
        guard let color = colors[action] else { return defaultSwatch(for: action).token }
        return matching(color)?.token ?? custom(color)
    }

    /// The selected swatch for `action`; nil for a custom color.
    static func selection(for action: PointOutAction, in colors: [PointOutAction: WheelColor]) -> POSwatch? {
        guard let color = colors[action] else { return defaultSwatch(for: action) }
        return matching(color)
    }
}

/// The function colors in effect (R145). Wheel, balls and card tokens all read it, so a change shows
/// everywhere at once; a wheel that is open keeps the colors it opened with until it closes.
@MainActor final class POFeatureColors: ObservableObject {
    static let shared = POFeatureColors()

    @Published private(set) var colors: [PointOutAction: WheelColor] = [:]
    private var tokens: [PointOutAction: POToken] = [:]

    /// Returns false when nothing changed.
    @discardableResult func apply(_ newColors: [PointOutAction: WheelColor]) -> Bool {
        guard newColors != colors else { return false }
        tokens = Dictionary(uniqueKeysWithValues: newColors.keys.map { ($0, POSwatches.token(for: $0, in: newColors)) })
        colors = newColors
        return true
    }

    func tint(_ action: PointOutAction) -> POToken {
        tokens[action] ?? POSwatches.defaultSwatch(for: action).token
    }
}

/// SwiftUI shorthands. `accent` is the emphasized glyph ink; `accentFill` is the graphite fill
/// that always pairs with `onAccent`.
enum POPalette {
    static var surface: Color { POColor.surface.color }
    static var surfaceDeep: Color { POColor.surfaceDeep.color }
    static var lightEdge: Color { POColor.lightEdge.color }
    static var darkEdge: Color { POColor.darkEdge.color }
    static var ink: Color { POColor.ink.color }
    static var inkSecondary: Color { POColor.inkSecondary.color }
    static var inkTertiary: Color { POColor.inkTertiary.color }
    static var accent: Color { POColor.emphasis.color }
    static var accentFill: Color { POColor.accent.color }
    static var onAccent: Color { POColor.onAccent.color }
    static var edgeLight: Color { POColor.edgeLight.color }
    static var danger: Color { POColor.danger.color }
    static var success: Color { POColor.success.color }
    static var well: Color { POColor.well.color }
    static var hover: Color { POColor.hover.color }
    static var wellShade: Color { POColor.wellShade.color }
    static var wellLight: Color { POColor.wellLight.color }
    static var raisedFill: Color { POColor.raisedFill.color }
    static var raisedLight: Color { POColor.raisedLight.color }
    static var raisedShade: Color { POColor.raisedShade.color }
    static var hairline: Color { POColor.hairline.color }
}

// MARK: - Metrics (§4)

enum POMetrics {
    static let pickedColorSide: CGFloat = 48
    static let pickedColorRadius: CGFloat = 8
    static let cardWidth: CGFloat = 320
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static var cardTextWidth: CGFloat { cardWidth - cardPadding * 2 }
    static let expandedTextMax: CGFloat = 260
    static let searchWidth: CGFloat = 340
    static let libraryListMax: CGFloat = 300
    static let permissionWidth: CGFloat = 340
    /// Distance from the press point to the card's leading edge (wheel radius + 12).
    static let cardOffsetX: CGFloat = 92
    static let cardOffsetY: CGFloat = 28
    static let screenInset: CGFloat = 8
}

// MARK: - Motion (§10, §11). Short, quiet, opacity-first, like system menus and popovers.

enum POMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var showDuration: Double { reduceMotion ? 0.1 : 0.15 }
    static var hideDuration: Double { reduceMotion ? 0.08 : 0.12 }
    static let wheelShow: Double = 0.08
    static let wheelHide: Double = 0.1
    static var resizeDuration: Double { 0.2 }
    /// Resting on a ball this long opens its short card (R103: 悬停1s).
    static let peekDelay: Double = 1.0
    /// A peeked card closes this long after the pointer leaves it.
    static let leaveDelay: Double = 0.35

    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }
    static var expand: Animation { reduceMotion ? .easeOut(duration: 0.12) : ease(0.2) }
    /// Content cross-fade; nil under reduce motion.
    static var swap: Animation? { reduceMotion ? nil : .easeOut(duration: 0.14) }
}

// MARK: - Features

/// The wheel actions are the shared contract's `PointOutAction`; this layer adds their presentation.
typealias POFeature = PointOutAction

extension PointOutAction {
    var title: String {
        switch self {
        case .explain: return "解释"
        case .translate: return "翻译"
        case .rewrite: return "改写"
        case .save: return "收藏"
        case .pickColor: return "取色器"
        case .replyCoach: return "嘴替"
        }
    }

    var symbol: String {
        switch self {
        case .explain: return "questionmark"
        case .translate: return "character.bubble"
        case .rewrite: return "pencil.line"
        case .save: return "bookmark"
        case .pickColor: return "eyedropper"
        case .replyCoach: return "pinpin.brain"
        }
    }

    /// R128: each function's icon has its own color, the same on the wheel, the ball and the card.
    /// Only these glyphs carry hue; every surface and text stays black and white. R145: the user's
    /// choice from settings, else the design default.
    @MainActor var tint: POToken { POFeatureColors.shared.tint(self) }

    var followUpPrompt: String {
        switch self {
        case .explain: return "还有哪里不明白？"
        case .translate: return "换个说法，或问问这句话…"
        case .rewrite: return "想怎么改？"
        case .replyCoach: return "想用什么语气回复？"
        case .save, .pickColor: return ""
        }
    }
}

// MARK: - 应用外观（R172）

/// nil 存储用于离屏检查；正式界面仅保存用户手动选择的明暗。
@MainActor final class POAppearancePreference {
    static let storageKey = "PinPinAppearance"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let saved = defaults?.string(forKey: Self.storageKey) else { return }
        let name: NSAppearance.Name
        switch saved {
        case "light": name = .aqua
        case "dark": name = .darkAqua
        default: return
        }
        NSApplication.shared.appearance = NSAppearance(named: name)
    }

    func toggle() {
        let app = NSApplication.shared
        let wasDark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        app.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
        defaults?.set(wasDark ? "light" : "dark", forKey: Self.storageKey)
    }
}
