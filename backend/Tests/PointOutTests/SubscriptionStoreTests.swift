import XCTest
@testable import PointOut

private actor SubscriptionFinishCounter {
    var count = 0
    func finish() { count += 1 }
}

private actor SubscriptionServiceFixture: SubscriptionServicing {
    let session = SubscriptionSession(accessToken: "offline-fixture-token", expiresAt: .distantFuture,
                                      appAccountToken: UUID(uuidString: "93F6AB06-A947-4548-877E-FA970C0548CF")!)
    var snapshot = SubscriptionServiceFixture.free
    var submissions: [String] = []
    var reject = false
    var rejectedTransactions: Set<String> = []
    var stateUnavailable = false
    var invalidations = 0
    var gate: CheckedContinuation<Void, Never>?
    var shouldHold = false
    var onSubmit: (() -> Void)?
    static let free = SubscriptionSnapshot(plan: .free, periodStart: Date(timeIntervalSince1970: 0),
                                           periodEnd: .distantFuture, limit: 20, committed: 0, reserved: 0, remaining: 20)
    static let pro = SubscriptionSnapshot(plan: .pro, periodStart: Date(timeIntervalSince1970: 0),
                                          periodEnd: .distantFuture, limit: 1000, committed: 5, reserved: 0, remaining: 995)
    func ensureSession() async throws -> SubscriptionSession { session }
    func invalidateSession() async throws { invalidations += 1 }
    func fetchState() async throws -> SubscriptionSnapshot {
        if stateUnavailable { throw SubscriptionError.transport }
        return snapshot
    }
    func submitTransaction(signedTransaction: String) async throws -> SubscriptionSnapshot {
        submissions.append(signedTransaction)
        if shouldHold {
            await withCheckedContinuation { continuation in gate = continuation; onSubmit?() }
        } else { onSubmit?() }
        if reject || rejectedTransactions.contains(signedTransaction) { throw SubscriptionError.http(503) }
        snapshot = Self.pro
        return snapshot
    }
    func configure(reject: Bool = false, unavailable: Bool = false, hold: Bool = false,
                   rejectedTransactions: Set<String> = [], onSubmit: (() -> Void)? = nil) {
        self.reject = reject; self.stateUnavailable = unavailable; self.shouldHold = hold; self.onSubmit = onSubmit
        self.rejectedTransactions = rejectedTransactions
    }
    func release() { shouldHold = false; gate?.resume(); gate = nil }
}

@MainActor
private final class SubscriptionStoreKitFixture: SubscriptionStoreKitProviding {
    var product: SubscriptionProduct? = SubscriptionProduct(id: SubscriptionStore.productID, displayPrice: "US$4.99")
    var result: SubscriptionPurchaseResult = .cancelled
    var entitlements: [SubscriptionTransactionEvent] = []
    var purchases = 0
    var suppliedAccountToken: UUID?
    var subscriptions = 0
    var syncs = 0
    var continuation: AsyncStream<SubscriptionTransactionEvent>.Continuation?
    var onTerminate: (() -> Void)?
    func loadProduct() async throws -> SubscriptionProduct? { product }
    func purchase(productID: String, appAccountToken: UUID) async throws -> SubscriptionPurchaseResult {
        purchases += 1; suppliedAccountToken = appAccountToken; return result
    }
    func updates() -> AsyncStream<SubscriptionTransactionEvent> {
        subscriptions += 1
        return AsyncStream { continuation in
            self.continuation = continuation
            let onTerminate = self.onTerminate
            continuation.onTermination = { _ in onTerminate?() }
        }
    }
    func currentEntitlements() async -> [SubscriptionTransactionEvent] { entitlements }
    func sync() async throws { syncs += 1 }
}

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    /// These tests inject synthetic verified events; they do not prove a StoreKit Sandbox purchase or Apple signature.
    private func transaction(_ counter: SubscriptionFinishCounter, jws: String = "offline-fixture-jws",
                             product: String = SubscriptionStore.productID, id: UInt64 = 42) -> SubscriptionTransactionEvent {
        .verified(VerifiedSubscriptionTransaction(id: id, productID: product, signedTransaction: jws,
                                                  finish: { await counter.finish() }))
    }

    func testPendingAndCancellationNeverGrantProOrFinish() async throws {
        for result in [SubscriptionPurchaseResult.pending, .cancelled] {
            let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
            let store = SubscriptionStore(api: api, storeKit: kit)
            await store.refresh()
            kit.result = result
            await store.purchase()
            XCTAssertEqual(store.currentSnapshot?.plan, .free)
            XCTAssertEqual(store.currentSnapshot?.remaining, 20)
            let submissions = await api.submissions
            XCTAssertEqual(submissions.count, 0)
            switch result {
            case .pending: XCTAssertEqual(store.phase, .pending)
            default: XCTAssertEqual(store.phase, .cancelled)
            }
            XCTAssertEqual(kit.syncs, 0)
        }
    }

    func testBackendRejectionKeepsTransactionUnfinishedThenRecoveryFinishesOnce() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter(); let event = transaction(counter)
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        await api.configure(reject: true)
        kit.result = .success(event)
        await store.purchase()
        let beforeRecovery = await counter.count
        XCTAssertEqual(beforeRecovery, 0)
        XCTAssertNil(store.currentSnapshot)
        guard case .failed(let message) = store.phase else { return XCTFail("Must show server confirmation failure") }
        XCTAssertTrue(message.contains("尚未同步"))

        await api.configure()
        kit.entitlements = [event, event]
        await store.refresh()
        XCTAssertEqual(store.currentSnapshot?.plan, .pro)
        let afterRecovery = await counter.count; let submissions = await api.submissions
        XCTAssertEqual(afterRecovery, 1)
        XCTAssertEqual(submissions.count, 2)
        await store.restore()
        let afterRestore = await counter.count
        XCTAssertEqual(afterRestore, 1)
        XCTAssertEqual(kit.syncs, 1)
        let accountToken = api.session.appAccountToken
        XCTAssertEqual(kit.suppliedAccountToken, accountToken)
    }

    func testServerConfirmationPrecedesFinishAndRepeatedClickDoesNotPurchaseAgain() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter()
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        let submitted = expectation(description: "server submit waiting")
        await api.configure(hold: true, onSubmit: { submitted.fulfill() })
        kit.result = .success(transaction(counter))
        let purchase = Task { await store.purchase() }
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(store.phase, .confirming)
        XCTAssertNil(store.currentSnapshot)
        let whileWaiting = await counter.count
        XCTAssertEqual(whileWaiting, 0)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 1)
        await api.release()
        await purchase.value
        let confirmed = await counter.count
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(store.phase, .confirmed)
        XCTAssertEqual(store.currentSnapshot?.remaining, 995)
    }

    func testOneListenerConcurrentDuplicateAndCancellation() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter(); let event = transaction(counter)
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        let terminated = expectation(description: "listener cancelled")
        kit.onTerminate = { terminated.fulfill() }
        store.start(); store.start()
        XCTAssertEqual(kit.subscriptions, 1)
        let submitted = expectation(description: "one transaction in flight")
        await api.configure(hold: true, onSubmit: { submitted.fulfill() })
        kit.result = .success(event)
        let purchase = Task { await store.purchase() }
        await fulfillment(of: [submitted], timeout: 2)
        kit.continuation?.yield(event)
        await api.release()
        await purchase.value
        // Refresh replays the same transaction after the concurrent purchase/update deliveries.
        kit.entitlements = [event]
        await store.refresh()
        let submissions = await api.submissions; let finishes = await counter.count
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(finishes, 1)
        store.stop()
        await fulfillment(of: [terminated], timeout: 2)
    }

    func testListenerDoesNotRetainStoreAfterDeinit() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let terminated = expectation(description: "deinit cancels updates")
        kit.onTerminate = { terminated.fulfill() }
        var store: SubscriptionStore? = SubscriptionStore(api: api, storeKit: kit)
        weak var weakStore = store
        store?.start()
        store = nil
        XCTAssertNil(weakStore)
        await fulfillment(of: [terminated], timeout: 2)
    }

    func testUnknownProductsBlankPriceAndUnverifiedTransactionsNeverGrant() async throws {
        for product in [SubscriptionProduct(id: "unknown", displayPrice: "¥29"), SubscriptionProduct(id: SubscriptionStore.productID, displayPrice: "  ")] {
            let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
            kit.product = product
            let store = SubscriptionStore(api: api, storeKit: kit)
            await store.refresh(); await store.purchase()
            XCTAssertFalse(store.canPurchase)
            XCTAssertNil(store.product)
            XCTAssertEqual(kit.purchases, 0)
        }
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter()
        kit.entitlements = [transaction(counter, product: "unknown"), .unverified]
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        kit.result = .success(.unverified)
        await store.purchase()
        let submissions = await api.submissions; let finishes = await counter.count
        XCTAssertEqual(submissions.count, 0)
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(store.product?.displayPrice, "US$4.99")
        XCTAssertEqual(store.currentSnapshot?.plan, .free)
    }

    func testUnavailableServiceAndExpiredSnapshotDoNotShowCurrentEntitlement() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        XCTAssertEqual(store.currentSnapshot?.plan, .free)
        await api.configure(unavailable: true)
        await store.refresh()
        XCTAssertNil(store.currentSnapshot)
        guard case .unavailable = store.entitlement else { return XCTFail("Expected unavailable entitlement") }
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 0, "An unknown entitlement must not open a new purchase")
        let expired = SubscriptionStore(api: SubscriptionServiceFixture(), storeKit: kit, now: { .distantFuture })
        await expired.refresh()
        XCTAssertNil(expired.currentSnapshot)
        XCTAssertFalse(expired.canPurchase)
        await expired.purchase()
        XCTAssertEqual(kit.purchases, 0, "An expired snapshot must not open a purchase")
    }

    func testApplePendingCannotBeRepurchasedOrClearedByFreeRefreshOrEmptyRestore() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter()
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh()
        kit.result = .pending
        await store.purchase()
        XCTAssertTrue(store.purchaseAwaitingResolution)
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        await store.refresh()
        XCTAssertEqual(store.phase, .pending)
        XCTAssertEqual(store.currentSnapshot?.plan, .free)
        XCTAssertTrue(store.purchaseAwaitingResolution)
        await store.purchase()
        await store.restore()
        XCTAssertTrue(store.purchaseAwaitingResolution, "Empty entitlements plus Free cannot prove Apple declined the request")
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 1)

        store.start()
        let confirmed = expectation(description: "verified approval reaches server")
        await api.configure(onSubmit: { confirmed.fulfill() })
        kit.continuation?.yield(transaction(counter))
        await fulfillment(of: [confirmed], timeout: 2)
        for _ in 0..<100 where store.purchaseAwaitingResolution { await Task.yield() }
        XCTAssertFalse(store.purchaseAwaitingResolution)
        XCTAssertEqual(store.currentSnapshot?.plan, .pro)
        let finishes = await counter.count
        XCTAssertEqual(finishes, 1)
        store.stop()
    }

    func testBackgroundConfirmationAndFailedServerSyncBlockDirectPurchaseCalls() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let counter = SubscriptionFinishCounter(); let event = transaction(counter)
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.refresh(); store.start()
        let submitted = expectation(description: "background confirmation waiting")
        await api.configure(reject: true, hold: true, onSubmit: { submitted.fulfill() })
        kit.continuation?.yield(event)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertFalse(store.isBusy, "This is an updates delivery, not a UI operation")
        XCTAssertEqual(store.phase, .confirming)
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 0)
        await api.release()
        for _ in 0..<100 where store.phase == .confirming { await Task.yield() }
        XCTAssertTrue(store.purchaseAwaitingResolution)
        await store.refresh()
        await store.restore()
        XCTAssertEqual(store.currentSnapshot?.plan, .free)
        XCTAssertTrue(store.purchaseAwaitingResolution, "Previously seen unfinished ID remains unresolved even if an empty snapshot omits it")
        await store.purchase()
        XCTAssertEqual(kit.purchases, 0)

        kit.entitlements = [event]
        await api.configure(unavailable: true)
        await store.restore()
        XCTAssertTrue(store.purchaseAwaitingResolution, "Transaction confirmation alone cannot finish a restore whose final state request failed")
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 0)
        await api.configure()
        await store.restore()
        XCTAssertFalse(store.purchaseAwaitingResolution)
        let finishes = await counter.count
        XCTAssertEqual(finishes, 1)
        store.stop()
    }

    func testRestoreKeepsUnresolvedFlagWhenAnyTransactionFails() async throws {
        let api = SubscriptionServiceFixture(); let kit = SubscriptionStoreKitFixture()
        let rejectedCounter = SubscriptionFinishCounter(); let acceptedCounter = SubscriptionFinishCounter()
        kit.entitlements = [transaction(rejectedCounter, jws: "reject-this-fixture", id: 81),
                            transaction(acceptedCounter, jws: "accept-this-fixture", id: 82)]
        await api.configure(rejectedTransactions: ["reject-this-fixture"])
        let store = SubscriptionStore(api: api, storeKit: kit)
        await store.restore()
        XCTAssertEqual(store.currentSnapshot?.plan, .pro)
        XCTAssertTrue(store.purchaseAwaitingResolution, "One confirmed Pro transaction must not erase another unfinished transaction")
        XCTAssertFalse(store.canPurchase)
        await store.purchase()
        XCTAssertEqual(kit.purchases, 0)
        let failedFinishes = await rejectedCounter.count; let acceptedFinishes = await acceptedCounter.count
        XCTAssertEqual(failedFinishes, 0)
        XCTAssertEqual(acceptedFinishes, 1)
        await api.configure()
        await store.restore()
        XCTAssertFalse(store.purchaseAwaitingResolution)
        let recoveredFinishes = await rejectedCounter.count; let replayFinishes = await acceptedCounter.count
        XCTAssertEqual(recoveredFinishes, 1)
        XCTAssertEqual(replayFinishes, 1)
    }
}
