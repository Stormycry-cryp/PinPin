import Foundation

enum CloudProcessingConsentError: Error, LocalizedError {
    case declined
    var errorDescription: String? { "已取消云端处理。" }
}

/// One user action may include a decision and an answer; both share its billing identity.
enum ModelUsageContext {
    @TaskLocal static var actionID: UUID?

    static func run(id: UUID, operation: () async -> Void) async {
        #if PINPIN_APP_STORE
        await $actionID.withValue(id, operation: operation)
        #else
        await operation()
        #endif
    }

    static func annotate(_ request: inout URLRequest) {
        #if PINPIN_APP_STORE
        if let actionID {
            request.setValue(actionID.uuidString.lowercased(), forHTTPHeaderField: "X-PinPin-Action-ID")
        }
        #endif
    }
}
