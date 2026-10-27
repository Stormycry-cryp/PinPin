import AppKit
import Foundation

struct TargetAnchor: Sendable {
    let id: UUID
    /// Core Graphics global coordinates, top-left origin.
    let screenPoint: CGPoint
    /// AppKit global coordinates, bottom-left origin.
    let presentationPoint: CGPoint
    let processID: pid_t
    let startedAt: TimeInterval
    /// Frozen from WindowServer mouse hit-testing before showing our own wheel.
    var windowID: CGWindowID? = nil
    /// Source bounds at the same hit test, retained for asynchronous window tracking.
    var windowFrame: CGRect? = nil
}

enum GestureEvent: Sendable {
    case began(TargetAnchor)
    case moved(CGPoint)
    case released(CGPoint)
    case closed
    case permissionLost
    case clearAllMarkers
}

/// Only samples owned by the native listener reach the synchronous recognizer.
/// Coordinates stay in the original CG space; recognition must never wait for UI or AX.
enum NativeGestureSample: Sendable {
    case down(point: CGPoint, time: TimeInterval, startsSession: Bool)
    case dragged(CGPoint)
    case up(point: CGPoint, time: TimeInterval)
    case reset
}

/// Built-in wheel actions. The presentation layer adds titles, symbols and sector angles.
enum PointOutAction: String, CaseIterable, Sendable, Codable {
    case explain, translate, rewrite, save, pickColor, replyCoach
}

/// One sampled screen pixel converted to 8-bit sRGB, without model interpretation.
struct PickedColor: Codable, Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    var rgb: String { "\(red), \(green), \(blue)" }
    var colorSpace: String { "sRGB" }
}

/// Local wheel preferences. An empty slot has no action and never starts model work.
struct WheelColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

struct WheelSettings: Codable, Equatable, Sendable {
    /// Ordered slots; repeated built-in actions are allowed. The wheel has 1 through 8 slots.
    var slots: [PointOutAction?]
    /// Missing entries use the design system's original feature colors.
    var colors: [PointOutAction: WheelColor]
    /// Only controls wheel activation. The settings shortcut stays available.
    var triggerEnabled: Bool = true

    init(slots: [PointOutAction?], colors: [PointOutAction: WheelColor], triggerEnabled: Bool = true) {
        self.slots = slots
        self.colors = colors
        self.triggerEnabled = triggerEnabled
    }

    private enum CodingKeys: String, CodingKey { case slots, colors, triggerEnabled }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        slots = try values.decode([PointOutAction?].self, forKey: .slots)
        colors = try values.decode([PointOutAction: WheelColor].self, forKey: .colors)
        triggerEnabled = try values.decodeIfPresent(Bool.self, forKey: .triggerEnabled) ?? true
    }

    static let defaults = WheelSettings(slots: [.save, .translate, .rewrite, .explain], colors: [:])
    var isValid: Bool {
        (1...8).contains(slots.count) && colors.values.allSatisfy(\.isValid)
    }
}

struct ReplyCoachingContext: Sendable {
    let intent: String
    let strategy: String
    /// Jev's validated probabilities[intent], retained for display and follow-ups.
    let intentProbability: Double?

    init(intent: String, strategy: String, intentProbability: Double? = nil) {
        self.intent = intent
        self.strategy = strategy
        self.intentProbability = intentProbability
    }
}

struct CapturedContext: Sendable {
    var sessionID: UUID
    /// Only explicit selected text. Unselected content is represented by images, never AX/OCR text.
    var targetText: String
    var surroundingText: String
    var appName: String
    var windowTitle: String
    var source: String
    var canExpandVisual: Bool = false
    var canCaptureVisual: Bool = false
    var imageData: Data? = nil
    var imageMIME: String = "image/jpeg"
    /// The same selected range without the model-only pointer annotation, for local collections.
    var originalImageData: Data? = nil
    /// Normalized top-left-origin position of the original click inside the screenshot.
    var pointInImage: CGPoint? = nil
    /// Explicit selection only; retained with targetText for the result's short follow-up.
    var passageText: String = ""
    var screenCapturePermissionMissing = false

    var replyCoaching: ReplyCoachingContext? = nil

    var hasSelection: Bool { !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum AcquisitionPlan: String, Sendable {
    case useCurrent = "use_current"
    case expandVisual = "expand_visual"
    /// Local-only attachment for an explicit text selection; never a Jev choice.
    case selectionContext = "selection_context"
}

struct ExplanationResult: Sendable {
    let text: String
    let metrics: [String: Double]
    let route: String
    let jevModel: String?
    let answerModel: String?
    /// Short label shown next to the action title, e.g. 英 → 中.
    var subtitle: String? = nil
    /// The context actually used, after any supplement. Follow-ups reuse it.
    var context: CapturedContext? = nil
}

/// A saved snippet. Stored locally only; tags are the only organization.
struct SavedItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var appName: String
    var windowTitle: String
    var tags: [String]
    var createdAt: Date
    /// Owned by the local library; never a remote URL supplied by a model.
    var imageURL: URL? = nil
    /// Top-left normalized original pointer in the saved, unannotated image.
    var pointInImage: CGPoint? = nil
}

/// A durable local pixel sample. Source strings follow the saved library's existing bounds.
struct ColorRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let color: PickedColor
    let createdAt: Date
    let appName: String
    let windowTitle: String
}

enum AssetRecord: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable { case saved(UUID), color(UUID) }
    case saved(SavedItem)
    case color(ColorRecord)

    var id: ID {
        switch self {
        case .saved(let item): return .saved(item.id)
        case .color(let item): return .color(item.id)
        }
    }
    var createdAt: Date {
        switch self {
        case .saved(let item): return item.createdAt
        case .color(let item): return item.createdAt
        }
    }
}

enum AssetEdit: Sendable { case delete(AssetRecord.ID) }
enum AssetPersistenceState: Equatable, Sendable { case saving, saved, failed }

/// Display-only subscription data. Entitlements and prices are supplied by the host.
struct SubscriptionPanelState: Equatable, Sendable {
    var isPro = false
    var periodEnd: Date? = nil
    var limit = 20
    var remaining: Int? = nil
    /// Localized StoreKit price; nil means no verified product has loaded.
    var displayPrice: String? = nil
    var message: String? = nil
    var isBusy = false
    var canPurchase = false
    var canRestore = true
    var entitlementKnown = false
}

enum SubscriptionControlAction: Sendable { case purchase, restore, manage, refresh, privacy, terms }

enum ResultFailureKind: String, Sendable {
    case screenCapturePermission, noReadableTarget, authentication, temporaryService, persistence
}

enum LibraryEdit: Sendable {
    case setTags(UUID, [String])
    case addTag(UUID, String)
    case removeTag(UUID, String)
    case delete(UUID)
}

/// The host coordinates functionality; the presentation owns every visual, motion and layout detail.
/// Result ids are the gesture anchor ids. A finished result keeps its marker until the user removes it.
@MainActor protocol PointOutPresentation: AnyObject {
    // Wheel
    /// Collapses only hover-opened short cards without cancelling their results.
    func showWheel(at point: CGPoint)
    /// For a visible wheel, selects by angular screen partition at any distance; only the center cancel zone returns nil.
    @discardableResult func updateWheel(pointer: CGPoint) -> PointOutAction?
    func hideWheel()
    /// Applies local preferences without model or capture requests. A visible gesture keeps its own hit geometry.
    func updateWheelSettings(_ settings: WheelSettings)
    func showSettings()
    func updateSubscription(_ state: SubscriptionPanelState)
    func showSubscription()

    // Results
    /// Drops a marker for `id` at the frozen point and shows the loading card.
    func beginResult(_ id: UUID, action: PointOutAction, at point: CGPoint, processID: pid_t)
    /// The source window remains authoritative after switching apps. Absolute AppKit point; hidden sources retain their state.
    func updateResultSource(_ id: UUID, at point: CGPoint, visible: Bool)
    /// Remove an existing result when its source is destroyed; idempotent and reports onForget.
    func removeResult(_ id: UUID)
    /// Cumulative streamed text of the initial answer or of the current follow-up answer.
    func updateResult(_ id: UUID, text: String, subtitle: String?)
    /// The initial answer or the current follow-up answer is complete.
    func finishResult(_ id: UUID)
    /// A failed initial result loses its marker; a failed follow-up keeps the previous answer.
    func failResult(_ id: UUID, message: String, kind: ResultFailureKind?)
    /// Save results: shows or refreshes the saved card for `id`; the result is finished.
    func showSaved(_ id: UUID, item: SavedItem, suggestions: [String])
    /// A local pixel sample. The presentation owns its swatch and copy controls.
    func showPickedColor(_ id: UUID, color: PickedColor)
    /// Explicit close (menu), affecting the foremost visible card only.
    /// An unfinished initial result is removed through `onForget`; an active follow-up uses `onCancel`.
    func closeCard()
    /// Option + double-click. Every removed result is reported through `onForget`.
    func clearAllMarkers()

    // Assets and saved-library compatibility
    /// Durable saved snippets and sampled colors, newest first.
    func updateAssets(_ items: [AssetRecord])
    /// Color cards stay usable when their independent local save fails.
    func updateColorPersistence(_ resultID: UUID, state: AssetPersistenceState)
    func updateLibrary(_ items: [SavedItem])
    /// `point` is AppKit global; nil places the panel near the top of the pointer's screen.
    func showLibrary(near point: CGPoint?)

    func showPermissionHelp(accessibility: Bool, screenCapture: Bool)

    /// Stop work for an unfinished result or follow-up. A finished result is kept.
    var onCancel: ((UUID) -> Void)? { get set }
    /// The result and its marker are gone; release everything kept for it.
    var onForget: ((UUID) -> Void)? { get set }
    var onFollowUp: ((UUID, String) -> Void)? { get set }
    var onLibraryEdit: ((LibraryEdit) -> Void)? { get set }
    var onAssetEdit: ((AssetEdit) -> Void)? { get set }
    /// Persist a user edit off the main thread. Returns after the local write finishes; false means it failed.
    var onWheelSettingsChange: ((WheelSettings) async -> Bool)? { get set }
    var onSubscriptionAction: ((SubscriptionControlAction) -> Void)? { get set }
}

extension PointOutPresentation {
    func failResult(_ id: UUID, message: String) { failResult(id, message: message, kind: nil) }
    func updateSubscription(_ state: SubscriptionPanelState) {}
    func showSubscription() {}
    var onSubscriptionAction: ((SubscriptionControlAction) -> Void)? {
        get { nil }
        set {}
    }
}
