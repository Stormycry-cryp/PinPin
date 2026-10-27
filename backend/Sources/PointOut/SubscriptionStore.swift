import Combine
import Foundation
import StoreKit

struct SubscriptionProduct: Equatable, Sendable {
    let id: String
    /// Comes exclusively from Product.displayPrice; never a configured or estimated price.
    let displayPrice: String
}

struct VerifiedSubscriptionTransaction: Sendable {
    let id: UInt64
    let productID: String
    let signedTransaction: String
    let finish: @Sendable () async -> Void
}

enum SubscriptionTransactionEvent: Sendable {
    case verified(VerifiedSubscriptionTransaction)
    case unverified
}

enum SubscriptionPurchaseResult: Sendable {
    case success(SubscriptionTransactionEvent)
    case pending
    case cancelled
}

@MainActor
protocol SubscriptionStoreKitProviding: AnyObject {
    func loadProduct() async throws -> SubscriptionProduct?
    func purchase(productID: String, appAccountToken: UUID) async throws -> SubscriptionPurchaseResult
    func updates() -> AsyncStream<SubscriptionTransactionEvent>
    func currentEntitlements() async -> [SubscriptionTransactionEvent]
    func sync() async throws
}

/// The only production StoreKit adapter. Test adapters cannot construct native StoreKit verification results.
@MainActor
final class NativeSubscriptionStoreKit: SubscriptionStoreKitProviding {
    private var product: Product?

    nonisolated static func signedAppTransaction() async throws -> String {
        let result = try await AppTransaction.shared
        return try checkedAppTransaction(result)
    }

    nonisolated private static func checkedAppTransaction(_ result: VerificationResult<AppTransaction>) throws -> String {
        guard case .verified(let value) = result,
              !value.appTransactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubscriptionError.identityUnavailable
        }
        return result.jwsRepresentation
    }

    func loadProduct() async throws -> SubscriptionProduct? {
        product = nil
        let products = try await Product.products(for: [SubscriptionStore.productID])
        guard let candidate = products.first(where: { $0.id == SubscriptionStore.productID }),
              candidate.type == .autoRenewable, candidate.price > 0,
              candidate.subscription?.subscriptionPeriod.unit == .month,
              candidate.subscription?.subscriptionPeriod.value == 1,
              !candidate.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        product = candidate
        return SubscriptionProduct(id: candidate.id, displayPrice: candidate.displayPrice)
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> SubscriptionPurchaseResult {
        guard let product, product.id == productID, productID == SubscriptionStore.productID else {
            throw SubscriptionError.productUnavailable
        }
        switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
        case .success(let verification): return .success(Self.event(verification))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw SubscriptionError.invalidResponse
        }
    }

    func updates() -> AsyncStream<SubscriptionTransactionEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await verification in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.event(verification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentEntitlements() async -> [SubscriptionTransactionEvent] {
        var values: [SubscriptionTransactionEvent] = []
        for await verification in Transaction.currentEntitlements {
            if Task.isCancelled { break }
            values.append(Self.event(verification))
        }
        // Unfinished transactions include deliveries interrupted before server confirmation.
        for await verification in Transaction.unfinished {
            if Task.isCancelled { break }
            values.append(Self.event(verification))
        }
        return values
    }

    func sync() async throws {
        try await AppStore.sync()
        // Only this explicit recovery action may refresh AppTransaction and prompt for an account.
        do { _ = try await Self.signedAppTransaction() }
        catch { _ = try Self.checkedAppTransaction(try await AppTransaction.refresh()) }
    }

    nonisolated private static func event(_ verification: VerificationResult<Transaction>) -> SubscriptionTransactionEvent {
        guard case .verified(let transaction) = verification else { return .unverified }
        return .verified(VerifiedSubscriptionTransaction(id: transaction.id, productID: transaction.productID,
                         signedTransaction: verification.jwsRepresentation, finish: { await transaction.finish() }))
    }
}

@MainActor
final class SubscriptionStore: ObservableObject {
    nonisolated static let productID = "com.pointout.app.pro.monthly"

    enum Phase: Equatable {
        case idle, loading, purchasing, pending, cancelled, confirming, confirmed
        case failed(String)
    }

    enum Entitlement: Equatable {
        case unknown, loading
        case available(SubscriptionSnapshot)
        case unavailable(String)
    }

    @Published private(set) var product: SubscriptionProduct?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entitlement: Entitlement = .unknown
    @Published private(set) var isBusy = false
    /// Survives ordinary refreshes: a Free snapshot cannot prove an Apple pending purchase was declined.
    @Published private(set) var purchaseAwaitingResolution = false

    private let api: any SubscriptionServicing
    private let storeKit: any SubscriptionStoreKitProviding
    private let now: () -> Date
    private var updatesTask: Task<Void, Never>?
    private var processing: [UInt64: (jws: String, task: Task<Void, Never>)] = [:]
    private var acknowledged: [UInt64: String] = [:]
    private var finished: Set<UInt64> = []
    private var stateRevision = 0
    private var accountRevision = 0
    private var awaitingApproval = false
    private var hasUnverifiedPurchase = false
    private var unconfirmedTransactions: Set<UInt64> = []
    private var isRestoring = false

    init(api: any SubscriptionServicing, storeKit: (any SubscriptionStoreKitProviding)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.storeKit = storeKit ?? NativeSubscriptionStoreKit()
        self.now = now
    }

    deinit {
        updatesTask?.cancel()
        processing.values.forEach { $0.task.cancel() }
    }

    var canPurchase: Bool {
        currentSnapshot?.plan == .free && product?.id == Self.productID && !isBusy && !purchaseAwaitingResolution && processing.isEmpty &&
        phase != .pending && phase != .confirming
    }

    /// Call once at application lifetime start, not once per settings panel presentation.
    func start() {
        guard updatesTask == nil else { return }
        let stream = storeKit.updates()
        updatesTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
    }

    func stop() {
        updatesTask?.cancel(); updatesTask = nil
    }

    /// A stale snapshot is not a current entitlement. Gateway authorization is always enforced server-side.
    var currentSnapshot: SubscriptionSnapshot? {
        guard case .available(let value) = entitlement, value.periodEnd > now() else { return nil }
        return value
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true; phase = .loading
        defer { isBusy = false }
        await loadProduct()
        _ = await synchronizeEntitlements()
        _ = await refreshState()
        if phase == .loading { phase = awaitingApproval ? .pending : .idle }
    }

    func purchase() async {
        guard currentSnapshot?.plan == .free else { return }
        guard !isBusy, !purchaseAwaitingResolution, processing.isEmpty,
              phase != .pending, phase != .confirming else { return }
        guard let product, product.id == Self.productID, !product.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed(SubscriptionError.productUnavailable.localizedDescription); return
        }
        isBusy = true; phase = .purchasing
        defer { isBusy = false }
        do {
            let session = try await api.ensureSession()
            switch try await storeKit.purchase(productID: product.id, appAccountToken: session.appAccountToken) {
            case .pending:
                awaitingApproval = true
                purchaseAwaitingResolution = true
                phase = .pending
            case .cancelled: phase = .cancelled
            case .success(let event):
                if case .verified(let transaction) = event, transaction.productID != Self.productID {
                    throw SubscriptionError.productUnavailable
                }
                await receive(event)
            }
        } catch { phase = .failed(Self.message(error)) }
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true; phase = .loading
        isRestoring = true
        stateRevision += 1; accountRevision += 1
        entitlement = .loading
        defer { isRestoring = false; isBusy = false }
        do {
            try await storeKit.sync()
            try await api.invalidateSession()
            // A restored App Store account may differ from the account used in this process earlier.
            acknowledged.removeAll()
            entitlement = .unknown
            _ = try await api.ensureSession()
            await loadProduct()
            let transactionsConfirmed = await synchronizeEntitlements()
            let stateConfirmed = await refreshState()
            if transactionsConfirmed && stateConfirmed { clearResolvedPurchase() }
            if phase == .loading { phase = awaitingApproval ? .pending : .idle }
        } catch {
            entitlement = .unavailable(Self.message(error)); phase = .failed(Self.message(error))
        }
    }

    private func loadProduct() async {
        do {
            let candidate = try await storeKit.loadProduct()
            guard let candidate, candidate.id == Self.productID,
                  !candidate.displayPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                product = nil; throw SubscriptionError.productUnavailable
            }
            product = candidate
        } catch { product = nil; phase = .failed(Self.message(error)) }
    }

    private func synchronizeEntitlements() async -> Bool {
        var confirmed = true
        for event in await storeKit.currentEntitlements() {
            if Task.isCancelled { return false }
            await receive(event)
            switch event {
            case .unverified: confirmed = false
            case .verified(let transaction):
                if transaction.productID == Self.productID && acknowledged[transaction.id] != transaction.signedTransaction {
                    confirmed = false
                }
            }
        }
        return confirmed
    }

    private func refreshState() async -> Bool {
        stateRevision += 1
        let revision = stateRevision
        entitlement = .loading
        do {
            let snapshot = try await api.fetchState()
            if revision == stateRevision { entitlement = .available(snapshot); return true }
        } catch {
            if revision == stateRevision { entitlement = .unavailable(Self.message(error)) }
        }
        return false
    }

    private func receive(_ event: SubscriptionTransactionEvent) async {
        guard case .verified(let transaction) = event else {
            hasUnverifiedPurchase = true
            purchaseAwaitingResolution = true
            phase = .failed(SubscriptionError.unverifiedTransaction.localizedDescription); return
        }
        guard transaction.productID == Self.productID else { return }
        // A changed JWS on the same ID can describe a revocation; do not discard that update.
        if acknowledged[transaction.id] == transaction.signedTransaction { return }
        if let running = processing[transaction.id] {
            await running.task.value
            if running.jws != transaction.signedTransaction { await receive(event) }
            return
        }
        unconfirmedTransactions.insert(transaction.id)
        purchaseAwaitingResolution = true
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                self.processing[transaction.id] = nil
                if self.processing.isEmpty && self.phase == .confirming { self.phase = .idle }
                if !self.isRestoring { self.clearResolvedPurchase() }
            }
            self.phase = .confirming
            self.stateRevision += 1
            let revision = self.stateRevision
            let account = self.accountRevision
            self.entitlement = .loading
            do {
                let snapshot = try await self.api.submitTransaction(signedTransaction: transaction.signedTransaction)
                guard !Task.isCancelled else { return }
                if account == self.accountRevision {
                    self.acknowledged[transaction.id] = transaction.signedTransaction
                    self.unconfirmedTransactions.remove(transaction.id)
                    if snapshot.plan == .pro {
                        self.awaitingApproval = false
                        self.hasUnverifiedPurchase = false
                    }
                }
                if !self.finished.contains(transaction.id) {
                    self.finished.insert(transaction.id)
                    await transaction.finish()
                }
                if revision == self.stateRevision {
                    self.entitlement = .available(snapshot)
                    self.phase = .confirmed
                }
            } catch {
                if revision == self.stateRevision {
                    self.entitlement = .unavailable(Self.message(error))
                    self.phase = .failed("购买信息尚未同步。" + Self.message(error))
                }
            }
        }
        processing[transaction.id] = (transaction.signedTransaction, task)
        await task.value
    }

    private func clearResolvedPurchase() {
        guard !awaitingApproval, !hasUnverifiedPurchase, unconfirmedTransactions.isEmpty, processing.isEmpty else { return }
        if purchaseAwaitingResolution { purchaseAwaitingResolution = false }
    }

    private static func message(_ error: Error) -> String {
        // Native errors and HTTP bodies may contain account details; show only controlled text.
        (error as? SubscriptionError)?.localizedDescription ?? "暂时无法完成，请稍后重试。"
    }
}
