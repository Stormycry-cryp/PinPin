import AppKit
import Foundation
import SwiftUI

/// Everything a result card can show (design-system.md §7).
enum POCardContent: Equatable {
    case loading(POFeature)
    case answer(POFeature, text: String, subtitle: String?)
    case saved(SavedItem, suggestions: [String])
    case pickingColor
    case pickedColor(PickedColor)
    case failure(String, ResultFailureKind?)

    var feature: POFeature? {
        switch self {
        case .loading(let f), .answer(let f, _, _): return f
        case .saved: return .save
        case .pickingColor, .pickedColor: return .pickColor
        case .failure: return nil
        }
    }

    var isLoading: Bool { if case .loading = self { return true } else { return false } }
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
    /// Coarse identity used for cross-fades, so streaming text does not re-trigger transitions.
    var phase: Int {
        switch self {
        case .loading: return 0
        case .answer: return 1
        case .saved: return 2
        case .failure: return 3
        case .pickingColor: return 4
        case .pickedColor: return 5
        }
    }
}

@MainActor final class POCardModel: ObservableObject {
    @Published var content: POCardContent = .loading(.explain)
    @Published var colorPersistence: AssetPersistenceState?
    /// The follow-up the body answers; nil for the first result.
    @Published var question: String?
    /// A follow-up answer is streaming: the input is disabled and an empty answer shows the skeleton.
    @Published var answering = false
    @Published var expanded = false
    @Published var draft = "" {
        didSet { if draft != oldValue { onDraftChanged(draft) } }
    }
    @Published var inputFocused = false
    @Published var notice: String?
    @Published var hovering = false
    /// False for a card with no ball to return to (a failure): its close button closes instead of collapsing.
    @Published var collapsible = true
    /// True only between show and the end of the hide fade; drives the loading pulse.
    @Published var isShown = false
    /// True only for preview content; shows a small sample badge.
    @Published var isSample = false

    /// Wired by the presenter.
    /// Collapse into the ball (close button, Esc). Nothing is cancelled.
    var onClose: () -> Void = {}
    /// The short card was clicked: open the dialog.
    var onOpen: () -> Void = {}
    /// Returns false when the question could not be sent; the draft is then kept.
    var onFollowUp: (String) -> Bool = { _ in false }
    var onDraftChanged: (String) -> Void = { _ in }
    var announces = true
    var onAddTag: (String) -> Void = { _ in }
    var onRemoveTag: (String) -> Void = { _ in }
    var onUnsave: () -> Void = {}
    var onShowLibrary: () -> Void = {}
    var onCopy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var noticeTask: Task<Void, Never>?

    deinit { noticeTask?.cancel() }

    var canExpand: Bool {
        switch content {
        case .answer, .saved, .pickedColor: return true
        case .loading, .failure, .pickingColor: return false
        }
    }

    var supportsFollowUp: Bool {
        if case .answer(let feature, _, _) = content { return feature != .save && feature != .pickColor }
        return false
    }

    enum ColorFormat { case hex, rgb }

    func copyColor(_ format: ColorFormat) {
        guard case .pickedColor(let color) = content else { return }
        onCopy(format == .hex ? color.hex : color.rgb)
        flash(format == .hex ? "已复制 HEX" : "已复制 RGB")
    }

    /// Text the copy button works on, without inline Markdown markers.
    var plainText: String? {
        switch content {
        case .answer(_, let text, _): return text.isEmpty ? nil : POText.plain(text)
        case .saved(let item, _): return item.text.isEmpty ? nil : item.text
        default: return nil
        }
    }

    /// `dialog`: the card is the dialog (clicked), else the short card. Expansion is never driven by hover.
    func reset(to content: POCardContent, question: String?, answering: Bool, sample: Bool, dialog: Bool,
               draft: String = "") {
        noticeTask?.cancel()
        self.content = content
        self.question = question
        self.answering = answering
        isSample = sample
        expanded = dialog && canExpand
        self.draft = draft
        notice = nil
        inputFocused = false
    }

    /// Clears transient state and cancels pending tasks when the card is dismissed.
    func didDismiss() {
        suspendNotice()
        hovering = false
        expanded = false
        inputFocused = false
    }

    func suspendNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    /// Hover only shows the header buttons; the presenter decides when a peeked card closes.
    func setHover(_ inside: Bool) {
        if hovering != inside { hovering = inside }
    }

    func submitFollowUp() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsFollowUp, !question.isEmpty, !answering else { return }
        // Cleared first: a failure reported during the call may restore it.
        let typed = draft
        draft = ""
        if !onFollowUp(question) {
            draft = typed
            flash("现在不能追问")
        }
    }

    func copy() {
        guard let text = plainText else { return }
        onCopy(text)
        flash("已复制")
    }

    func toggleTag(_ tag: String) {
        guard case .saved(let item, _) = content else { return }
        if item.tags.contains(tag) { onRemoveTag(tag) } else { onAddTag(tag) }
    }

    func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, tag.count <= 16, case .saved = content else { return }
        onAddTag(tag)
    }

    func flash(_ text: String, long: Bool = false) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.14)) { notice = text }
        if announces {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: long ? 3_000_000_000 : 1_600_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.notice = nil }
        }
    }
}
