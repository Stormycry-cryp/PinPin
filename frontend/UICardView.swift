import SwiftUI

// MARK: - Result card content (design-system.md §7). The window supplies the system material.

struct POCardView: View {
    @ObservedObject var model: POCardModel

    private var isSaved: Bool { if case .saved = model.content { return true } else { return false } }
    private var isColor: Bool { if case .pickedColor = model.content { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let question = model.question {
                POQuestionLine(text: question)
                    .transition(.opacity)
            }
            ZStack(alignment: .topLeading) {
                bodyContent
                    .id(model.content.phase)
                    .transition(.opacity)
            }
            .animation(POMotion.swap, value: model.content.phase)

            if model.expanded, model.supportsFollowUp, let feature = model.content.feature {
                POFollowUpField(model: model, prompt: feature.followUpPrompt)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(POMetrics.cardPadding)
        .frame(width: POMetrics.cardWidth, alignment: .leading)
        // The short card is one click target: a click opens the dialog (R103). Buttons and tag chips
        // inside keep their own clicks; in the dialog the gesture is off so text can be selected.
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { model.onOpen() },
                 including: !model.expanded && model.canExpand ? .all : .subviews)
        .accessibilityAction(named: "展开对话框") { if !model.expanded && model.canExpand { model.onOpen() } }
        .onExitCommand { model.onClose() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            headerLabel
            if model.isSample { POSampleBadge() }
            Spacer(minLength: 8)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(POPalette.inkTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            HStack(spacing: 2) {
                if model.plainText != nil && !model.answering {
                    POIconButton(symbol: "doc.on.doc", label: "复制") { model.copy() }
                }
                if isSaved || isColor {
                    POIconButton(symbol: "tray.full", label: "资产看板") { model.onShowLibrary() }
                }
                if isSaved {
                    POIconButton(symbol: "bookmark.slash", label: "取消收藏") { model.onUnsave() }
                }
                if model.collapsible {
                    POIconButton(symbol: "chevron.down", label: "收起") { model.onClose() }
                } else {
                    POIconButton(symbol: "xmark", label: "关闭") { model.onClose() }
                }
            }
            .opacity(model.hovering || model.expanded || model.content.isFailure ? 1 : 0)
            .allowsHitTesting(model.hovering || model.expanded || model.content.isFailure)
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: model.hovering || model.expanded)
    }

    @ViewBuilder private var headerLabel: some View {
        switch model.content {
        case .failure:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(POPalette.danger)
                    .accessibilityHidden(true)
                Text("没能完成")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(POPalette.inkSecondary)
        case .saved:
            HStack(spacing: 7) {
                POFeatureToken(symbol: "bookmark.fill", feature: .save)
                Text("已收藏")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(POPalette.inkSecondary)
        case .pickingColor, .pickedColor:
            HStack(spacing: 7) {
                POFeatureToken(symbol: PointOutAction.pickColor.symbol, feature: .pickColor)
                Text(PointOutAction.pickColor.title)
                if case .pickedColor(let color) = model.content {
                    Text(color.colorSpace).fontWeight(.regular).foregroundStyle(POPalette.inkTertiary)
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(POPalette.inkSecondary)
        case .loading(let f), .answer(let f, _, _):
            HStack(spacing: 7) {
                POFeatureToken(symbol: f.symbol, feature: f)
                Text(f.title)
                if case .answer(_, _, let subtitle?) = model.content {
                    Text(subtitle).fontWeight(.regular).foregroundStyle(POPalette.inkTertiary)
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(POPalette.inkSecondary)
        }
    }

    // MARK: Body

    @ViewBuilder private var bodyContent: some View {
        switch model.content {
        case .loading:
            POSkeleton(animating: model.isShown)
        case .answer(_, let text, _):
            // A follow-up streams into the same body; until its first text arrives, the skeleton shows.
            if text.isEmpty {
                POSkeleton(animating: model.isShown)
            } else {
                POAnswerText(text: text, expanded: model.expanded)
            }
        case .failure(let message, let kind):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(POPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .screenCapturePermission {
                    POPillButton(title: "去开启") { POSystemSettings.open(POSystemSettings.screenCapture) }
                        .accessibilityLabel("开启屏幕录制")
                }
            }
        case .pickingColor:
            Text("正在取色")
                .font(.system(size: 13))
                .foregroundStyle(POPalette.inkSecondary)
        case .pickedColor(let color):
            VStack(alignment: .leading, spacing: 6) {
                POPickedColorBody(model: model, color: color)
                if let state = model.colorPersistence {
                    Text(state == .saving ? "正在保存到资产" : state == .saved ? "已存入资产" : "未能存入资产，仍可复制")
                        .font(.system(size: 11))
                        .foregroundStyle(POPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .saved(let item, let suggestions):
            POSavedBody(model: model, item: item, suggestions: suggestions)
        }
    }
}

/// 取色结果使用协议中的 sRGB 通道，不随主题或功能图标颜色变化。
struct POPickedColorBody: View {
    @ObservedObject var model: POCardModel
    let color: PickedColor

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: POMetrics.pickedColorRadius, style: .continuous)
                .fill(Color(.sRGB, red: Double(color.red) / 255,
                            green: Double(color.green) / 255, blue: Double(color.blue) / 255, opacity: 1))
                .overlay(RoundedRectangle(cornerRadius: POMetrics.pickedColorRadius, style: .continuous)
                    .strokeBorder(POPalette.hairline, lineWidth: 0.5))
                .frame(width: POMetrics.pickedColorSide, height: POMetrics.pickedColorSide)
                .accessibilityLabel("颜色样本，\(color.hex)，\(color.colorSpace)")
            VStack(alignment: .leading, spacing: 6) {
                valueRow("HEX", value: color.hex, format: .hex)
                valueRow("RGB", value: color.rgb, format: .rgb)
            }
        }
        .padding(.vertical, 2)
    }

    private func valueRow(_ label: String, value: String, format: POCardModel.ColorFormat) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(POPalette.inkTertiary)
                .frame(width: 28, alignment: .leading)
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(POPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 2)
            POIconButton(symbol: "doc.on.doc", label: "复制 \(label) \(value)") { model.copyColor(format) }
        }
    }
}

/// The action's glyph on a small raised key at the start of the header: the ball, in the card.
/// The glyph has the function's own color (R128), the same as on the wheel and the ball; it follows
/// a color change from settings in place (R145). Only this token observes the colors, so a change
/// redraws a glyph, never a card's layout. Drawn from the same symbol image as the wheel and the
/// balls (POGlyph), so all three show the same glyph variant.
struct POFeatureToken: View {
    let symbol: String
    let feature: PointOutAction
    @ObservedObject private var colors = POFeatureColors.shared

    init(symbol: String, feature: PointOutAction) {
        self.symbol = symbol
        self.feature = feature
    }

    var body: some View {
        POGlyph(symbol: symbol, size: 9.5, weight: .bold, color: colors.tint(feature).color)
            .frame(width: 20, height: 20)
            .background(Circle().poRaisedFill(depth: 1.2))
            .accessibilityHidden(true)
    }
}

/// The follow-up being answered, above the answer it produced.
struct POQuestionLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(text).lineLimit(2)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(POPalette.inkSecondary)
        .frame(width: POMetrics.cardTextWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("追问：\(text)")
    }
}

// MARK: - Answer text: 3 lines collapsed, scrolls beyond 260pt when expanded

struct POAnswerText: View {
    let text: String
    let expanded: Bool

    var body: some View {
        let content = Text(POText.attributed(text))
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(POPalette.ink)
            .frame(width: POMetrics.cardTextWidth, alignment: .leading)

        if expanded {
            // The dialog: selectable, as tall as the text, scrolling only beyond 260pt.
            POCappedScroll(limit: POMetrics.expandedTextMax) { content.textSelection(.enabled) }
        } else {
            // The short card: three lines; a click opens the dialog, so no text selection here.
            content
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Loading placeholder: a calm opacity pulse, like system placeholders

/// The pulse runs only while the card is on screen and reduce motion is off;
/// removing the pulsing view stops the repeating animation.
struct POSkeleton: View {
    let animating: Bool

    var body: some View {
        Group {
            if animating && !POMotion.reduceMotion {
                POPulse { bars }
            } else {
                bars
            }
        }
        .accessibilityElement()
        .accessibilityLabel("正在生成")
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().poWellFill().frame(width: POMetrics.cardTextWidth, height: 8)
            Capsule().poWellFill().frame(width: POMetrics.cardTextWidth * 0.6, height: 8)
        }
        .padding(.vertical, 4)
    }
}

private struct POPulse<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var dim = false

    var body: some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Follow-up field

struct POFollowUpField: View {
    @ObservedObject var model: POCardModel
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $model.draft, prompt: Text(prompt).foregroundStyle(POPalette.inkTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(POPalette.ink)
                .focused($focused)
                .onSubmit { model.submitFollowUp() }
                .disabled(model.answering)
                .accessibilityLabel("追问")
            let ready = !model.draft.trimmingCharacters(in: .whitespaces).isEmpty && !model.answering
            Button { model.submitFollowUp() } label: {
                // A raised graphite key when there is something to send; a plain raised plate otherwise.
                Image(systemName: "arrow.up")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(ready ? POPalette.onAccent : POPalette.inkTertiary)
                    .frame(width: 20, height: 20)
                    .background {
                        if ready {
                            // The one dark key: raised graphite, lit on its top-left edge.
                            Circle().fill(POPalette.accentFill
                                .shadow(.drop(color: POPalette.lightEdge, radius: 2, x: -1.4, y: -1.4))
                                .shadow(.drop(color: POPalette.darkEdge, radius: 2, x: 1.4, y: 1.4))
                                .shadow(.inner(color: POPalette.edgeLight, radius: 0.8, x: 0.6, y: 0.6)))
                        } else {
                            Circle().poRaisedFill(depth: 1.2)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityLabel("发送追问")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 30)
        .poWell(radius: 15)
        .onChange(of: focused) { _, value in model.inputFocused = value }
        .onChange(of: model.inputFocused) { _, value in
            if focused != value { focused = value }
        }
    }
}

// MARK: - Saved card body

struct POSavedBody: View {
    @ObservedObject var model: POCardModel
    let item: SavedItem
    let suggestions: [String]
    @State private var adding = false
    @State private var newTag = ""
    @FocusState private var tagFocused: Bool

    private var allTags: [String] {
        var seen = Set<String>()
        return (item.tags + suggestions).filter { seen.insert($0).inserted }
    }

    private var source: String {
        [item.appName, item.windowTitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = item.imageURL {
                POSavedImage(url: url, point: item.pointInImage, expanded: model.expanded,
                             width: POMetrics.cardTextWidth, label: item.text)
            }
            if item.text.isEmpty {
                // An image save: its description arrives a moment later.
                POSkeleton(animating: model.isShown)
            } else {
                let text = Text(item.text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(item.imageURL == nil ? POPalette.ink : POPalette.inkSecondary)
                    .lineLimit(model.expanded ? 6 : 2)
                    .frame(width: POMetrics.cardTextWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Selectable only in the dialog; the short card is one click target.
                if model.expanded { text.textSelection(.enabled) } else { text }
            }

            POFlowLayout(spacing: 5) {
                ForEach(allTags, id: \.self) { tag in
                    POTagChip(title: tag, selected: item.tags.contains(tag)) { model.toggleTag(tag) }
                }
                if adding {
                    TextField("", text: $newTag, prompt: Text("新标签").foregroundStyle(POPalette.inkTertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(POPalette.ink)
                        .focused($tagFocused)
                        .frame(width: 64, height: 20)
                        .padding(.horizontal, 8)
                        .poWellCapsule()
                        .onSubmit(commitTag)
                        .onExitCommand { adding = false; newTag = "" }
                        .accessibilityLabel("新标签")
                } else {
                    Button {
                        adding = true
                        DispatchQueue.main.async { tagFocused = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(POPalette.inkSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().poRaisedFill())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加标签")
                    .accessibilityLabel("添加标签")
                }
            }
            // Suggested tags arrive shortly after the save; they fade in instead of jumping.
            .animation(POMotion.swap, value: allTags)

            if model.expanded, !source.isEmpty {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(POPalette.inkTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .onChange(of: tagFocused) { _, focused in
            if !focused { commitTag() }
        }
    }

    private func commitTag() {
        model.addTag(newTag)
        newTag = ""
        adding = false
    }
}

// MARK: - Saved image: a pressed-in frame; expanded shows the whole picture and where it was pointed

struct POSavedImage: View {
    let url: URL
    let point: CGPoint?
    let expanded: Bool
    let width: CGFloat
    let label: String
    @State private var image: CGImage?
    @State private var loaded = false

    var body: some View {
        let maxHeight: CGFloat = expanded ? 180 : 64
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            if let image {
                let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                let fitted = CGSize(width: min(width, maxHeight * aspect), height: min(maxHeight, width / aspect))
                let size = expanded ? fitted : CGSize(width: width, height: maxHeight)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: expanded ? .fit : .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(POPalette.hairline, lineWidth: 0.5))
                    .overlay(alignment: .topLeading) {
                        if expanded, let point {
                            POPointDot().position(x: point.x * size.width, y: point.y * size.height)
                        }
                    }
            } else {
                shape.poWellFill()
                    .frame(width: width, height: maxHeight)
                    .overlay {
                        if loaded {
                            Image(systemName: "photo")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(POPalette.inkTertiary)
                        }
                    }
            }
        }
        .task(id: url) {
            image = await POImageLoader.load(url, maxPixel: 720)
            loaded = true
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(label.isEmpty ? "收藏的图片" : label)
    }
}

/// Where the user pointed, in a saved picture: a small graphite pebble like the marker.
struct POPointDot: View {
    var body: some View {
        Circle()
            .fill(POPalette.accentFill)
            .overlay(Circle().strokeBorder(POPalette.onAccent.opacity(0.9), lineWidth: 1))
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Minimal wrapping layout for chips

struct POFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? POMetrics.cardTextWidth
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
