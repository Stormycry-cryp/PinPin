import AppKit
import ImageIO
import SwiftUI

// MARK: - Neumorphic surfaces (design-system.md §1, §3)
// One light source at the top left. Raised: the surface itself, casting light up-left and shade
// down-right. Pressed: a slightly deeper floor with the shade inside its top-left edge and the light
// inside its bottom-right edge.

extension Shape {
    /// Pressed into the surface: inputs, the skeleton, a selected tag, a held button.
    func poWellFill(depth: CGFloat = 1.5) -> some View {
        fill(POPalette.surfaceDeep
            .shadow(.inner(color: POPalette.darkEdge, radius: depth * 1.4, x: depth, y: depth))
            .shadow(.inner(color: POPalette.lightEdge, radius: depth * 1.4, x: -depth, y: -depth)))
    }

    /// Raised out of the surface: buttons and tags at rest.
    func poRaisedFill(depth: CGFloat = 1.5) -> some View {
        fill(POPalette.surface
            .shadow(.drop(color: POPalette.lightEdge, radius: depth * 1.4, x: -depth, y: -depth))
            .shadow(.drop(color: POPalette.darkEdge, radius: depth * 1.4, x: depth, y: depth)))
    }
}

/// Inputs and other pressed-in areas. Increase Contrast adds a hairline, since depth alone is faint.
struct POWell<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(shape.poWellFill())
            .overlay {
                if contrast == .increased { shape.strokeBorder(POPalette.hairline, lineWidth: 0.5) }
            }
    }
}

extension View {
    func poWell(radius: CGFloat = 7) -> some View {
        modifier(POWell(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    func poWellCapsule() -> some View {
        modifier(POWell(shape: Capsule()))
    }
}

// MARK: - Symbol button: a raised round key, pressed in while held

struct POIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        POIconButtonBody(configuration: configuration)
    }
}

private struct POIconButtonBody: View {
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? POPalette.ink : POPalette.inkSecondary)
            .frame(width: 22, height: 22)
            .background {
                if configuration.isPressed { Circle().poWellFill(depth: 1.2) }
                else { Circle().poRaisedFill(depth: 1.2) }
            }
            .contentShape(Circle())
    }
}

// MARK: - Pill button: a raised capsule key with ink text, pressed in while held

struct POPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(POPillStyle())
    }
}

private struct POPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(POPalette.ink)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background {
                if configuration.isPressed { Capsule().poWellFill(depth: 1.2) }
                else { Capsule().poRaisedFill(depth: 1.5) }
            }
            .contentShape(Capsule())
    }
}

struct POIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(POIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Tag token: raised when idle; pressed in, full ink, when selected

struct POTagChip: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? POPalette.ink : POPalette.inkSecondary)
                .padding(.horizontal, 9)
                .frame(height: 21)
                .background {
                    if selected { Capsule().poWellFill(depth: 1.3) } else { Capsule().poRaisedFill(depth: 1.3) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small label shown only by the preview entry, so sample content is never mistaken for a
/// connected feature or real saved data.
struct POSampleBadge: View {
    var body: some View {
        Text("示例")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(POPalette.inkTertiary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .poWellCapsule()
            .accessibilityLabel("示例内容")
    }
}

// MARK: - Grows with its content up to a limit, then scrolls (design-system.md §7, §9)

/// Height comes from the content's own size at the proposed width, never from the proposed
/// height. A measuring pass with an open height (the floating window's ideal-size pass) therefore
/// gets the content's real height: short content is exactly as tall as it is, long content stops
/// at `limit` and scrolls. Replaces `ViewThatFits`, which falls back to its last (fixed-height,
/// scrolling) child when the proposed height is open, so every expanded answer measured 260pt.
struct POCappedScroll<Content: View>: View {
    let limit: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        POCapLayout(limit: limit) {
            ScrollView(.vertical, showsIndicators: true) {
                content.fixedSize(horizontal: false, vertical: true)
            }
            // Short content does not rubber-band; only content taller than the limit scrolls.
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct POCapLayout: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // A vertical ScrollView's ideal height along its axis is its content's height.
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: min(natural.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - Saved images: local files only, decoded and downsampled off the main thread

@MainActor enum POImageLoader {
    private static let cache = NSCache<NSString, CGImage>()
    /// Preview pictures live only in memory, so previews never write files.
    private static var samples: [URL: CGImage] = [:]

    static func registerSample(_ image: CGImage, for url: URL) { samples[url] = image }

    static func load(_ url: URL, maxPixel: Int) async -> CGImage? {
        if let sample = samples[url] { return sample }
        guard url.isFileURL else { return nil }
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// Deep links to the two privacy panes PinPin needs.
enum POSystemSettings {
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let screenCapture = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    @MainActor static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Inline markdown text (bold / code only; never blocks rendering)

enum POText {
    static func attributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    /// The same text without inline Markdown markers, for copying and replacing.
    static func plain(_ raw: String) -> String {
        String(attributed(raw).characters)
    }
}
