import Foundation

/// Compile-time capabilities: direct builds retain AX selection and window notifications.
enum CapturePlatformPolicy {
#if PINPIN_APP_STORE
    static let allowsAccessibilitySelection = false
    static let sourceWindowCheckInterval: TimeInterval? = 0.250
#else
    static let allowsAccessibilitySelection = true
    static let sourceWindowCheckInterval: TimeInterval? = nil
#endif
}
