//
//  StoreKitSessionTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import PaidUpKit
import StoreKit
import StoreKitTest
import UIKit
import XCTest

/// Real StoreKit 2 against the checked-in `PaidUp.storekit` configuration.
/// These run only under `xcodebuild test` on a simulator; the pure state
/// machine is covered by the package's `swift test` suite.
final class StoreKitSessionTests: XCTestCase {
    private var session: SKTestSession!
    private var directory: URL!
    private let userID = UUID()

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try SKTestSession(configurationFileNamed: "PaidUp")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaidUpSampleTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        session.clearTransactions()
        session = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeStore(
        remoteProvider: (any EntitlementProvider)? = nil,
        refreshOnForeground: Bool = true,
        onError: (@Sendable (PaidUpError) -> Void)? = nil
    ) -> PaidUp {
        var config = PaidUpConfiguration.default
        config.storageDirectory = directory
        config.remoteProvider = remoteProvider
        config.refreshOnForeground = refreshOnForeground
        config.onError = onError
        return PaidUp(products: ["pro.monthly", "pro.yearly", "lifetime"], userID: userID, configuration: config)
    }

    private func assertNothingUnfinished(file: StaticString = #filePath, line: UInt = #line) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result {
                XCTFail("transaction \(tx.id) (\(tx.productID)) left unfinished", file: file, line: line)
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        pokeForeground: Bool = false,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            if pokeForeground {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: UIApplication.willEnterForegroundNotification,
                        object: nil
                    )
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("Timed out after \(timeout)s")
    }

    func testPurchaseEntitlesAndCarriesAppAccountToken() async throws {
        let store = makeStore()
        let result = await store.purchase("pro.monthly")
        guard case .success(let entitlement) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(entitlement.productID, "pro.monthly")
        XCTAssertEqual(entitlement.subscriptionGroupID, "21000001")
        XCTAssertEqual(entitlement.state, .active)
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "21000001"))

        var tokens: [UUID?] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified(let tx) = verification {
                tokens.append(tx.appAccountToken)
            }
        }
        XCTAssertEqual(tokens, [userID])
        await assertNothingUnfinished()
    }

    func testPurchaseIsVisibleToAFreshInstanceOnNextLaunch() async throws {
        let first = makeStore()
        guard case .success = await first.purchase("lifetime") else {
            return XCTFail("purchase failed")
        }
        let second = makeStore()
        XCTAssertTrue(second.isEntitled(to: "lifetime"), "cache answers before StoreKit does")
        let stream = second.updates
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        XCTAssertTrue(second.isEntitled(to: "lifetime"))
        await assertNothingUnfinished()
    }

    func testExpiredSubscriptionIsNotEntitled() async throws {
        let store = makeStore()
        guard case .success = await store.purchase("pro.monthly") else {
            return XCTFail("purchase failed")
        }
        try session.expireSubscription(productIdentifier: "pro.monthly")

        try await waitUntil(pokeForeground: true) { !store.isEntitled(to: "pro.monthly") }

        let fresh = makeStore()
        try await waitUntil { !fresh.isEntitled(to: "pro.monthly") }
    }

    func testRenewalsKeepEntitlementAndExpiryAfterAutoRenewOffRemovesIt() async throws {
        session.timeRate = .oneRenewalEveryTwoSeconds
        let store = makeStore()
        guard case .success(let first) = await store.purchase("pro.monthly") else {
            return XCTFail("purchase failed")
        }
        let firstExpiry = try XCTUnwrap(first.expirationDate)

        try await waitUntil(timeout: 20) {
            (store.entitlements.first?.expirationDate ?? firstExpiry) > firstExpiry
        }
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"), "entitled through renewals")
        XCTAssertGreaterThan(session.allTransactions().count, 1)

        let original = try XCTUnwrap(session.allTransactions().first)
        try session.disableAutoRenewForTransaction(identifier: original.originalTransactionIdentifier)
        try await waitUntil(timeout: 20, pokeForeground: true) { !store.isEntitled(to: "pro.monthly") }
    }

    func testRefundRevokesImmediately() async throws {
        let store = makeStore()
        guard case .success = await store.purchase("lifetime") else {
            return XCTFail("purchase failed")
        }
        let tx = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: tx.identifier)

        try await waitUntil { !store.isEntitled(to: "lifetime") }
        XCTAssertTrue(store.entitlements.isEmpty)
        await assertNothingUnfinished()
    }

    func testAskToBuyIsPendingThenArrivesViaUpdates() async throws {
        session.askToBuyEnabled = true
        let store = makeStore()
        let result = await store.purchase("pro.yearly")
        guard case .pending = result else {
            return XCTFail("expected pending, got \(result)")
        }
        XCTAssertFalse(store.isEntitled(to: "pro.yearly"))

        let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        try await waitUntil { store.isEntitled(to: "pro.yearly") }
        await assertNothingUnfinished()
    }

    func testRestoreFindsPurchaseMadeOutsideTheSDK() async throws {
        _ = try await session.buyProduct(identifier: "lifetime")
        let store = makeStore()
        let result = await store.restore()
        guard case .restored(let set) = result else {
            return XCTFail("expected restored, got \(result)")
        }
        XCTAssertTrue(set.contains { $0.productID == "lifetime" })
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
        await assertNothingUnfinished()
    }

    func testRestoreAfterClearingTransactionsRemovesEntitlementAndCache() async throws {
        let store = makeStore()
        guard case .success = await store.purchase("lifetime") else {
            return XCTFail("purchase failed")
        }
        session.clearTransactions()
        let result = await store.restore()
        guard case .restored(let set) = result else {
            return XCTFail("expected restored, got \(result)")
        }
        XCTAssertTrue(set.isEmpty)
        XCTAssertFalse(store.isEntitled(to: "lifetime"))

        let fresh = makeStore()
        XCTAssertFalse(fresh.isEntitled(to: "lifetime"), "cache was replaced by the StoreKit answer")
    }

    func testForegroundRefreshCallsProviderOnlyWhenEnabled() async throws {
        let enabled = CountingProvider()
        let disabled = CountingProvider()
        let on = makeStore(remoteProvider: enabled, refreshOnForeground: true)
        let off = makeStore(remoteProvider: disabled, refreshOnForeground: false)
        try await waitUntil { enabled.callCount == 1 && disabled.callCount == 1 }

        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        try await waitUntil { enabled.callCount == 2 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(disabled.callCount, 1)
        _ = (on, off)
    }

    func testSimulatedPurchaseNotAllowedIsTyped() async throws {
        try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
        let store = makeStore()
        let result = await store.purchase("lifetime")
        guard case .failed(.purchaseNotAllowed) = result else {
            return XCTFail("expected purchaseNotAllowed, got \(result)")
        }
        XCTAssertFalse(store.isEntitled(to: "lifetime"))
    }

    func testSimulatedLoadProductsFailureIsProductNotFound() async throws {
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let store = makeStore()
        let result = await store.purchase("lifetime")
        guard case .failed(let error) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        switch error {
        case .productNotFound, .storeKit: break
        default: XCTFail("unexpected error \(error)")
        }
    }

    func testUpgradeKeepsGroupEntitled() async throws {
        let store = makeStore()
        guard case .success = await store.purchase("pro.monthly") else {
            return XCTFail("monthly purchase failed")
        }
        guard case .success(let yearly) = await store.purchase("pro.yearly") else {
            return XCTFail("yearly purchase failed")
        }
        XCTAssertEqual(yearly.productID, "pro.yearly")
        XCTAssertTrue(store.isEntitled(toGroup: "21000001"))
        try await waitUntil(pokeForeground: true) { !store.isEntitled(to: "pro.monthly") }
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertTrue(store.isEntitled(toGroup: "21000001"))
        await assertNothingUnfinished()
    }

    func testGroupStaysEntitledThroughoutUpgrade() async throws {
        let store = makeStore()
        guard case .success = await store.purchase("pro.monthly") else {
            return XCTFail("monthly purchase failed")
        }
        let stream = store.updates
        let seen = SetLog()
        let consumer = Task {
            for await set in stream { seen.append(set) }
        }
        guard case .success = await store.purchase("pro.yearly") else {
            return XCTFail("yearly purchase failed")
        }
        try await waitUntil(pokeForeground: true) { !store.isEntitled(to: "pro.monthly") }
        consumer.cancel()
        XCTAssertFalse(seen.values.isEmpty)
        for set in seen.values {
            XCTAssertTrue(set.contains { $0.subscriptionGroupID == "21000001" }, "group dropped mid-upgrade: \(set)")
        }
    }

    func testUpdatesStreamDrivesUI() async throws {
        let store = makeStore()
        let stream = store.updates
        let gotEntitled = expectation(description: "updates emits the purchase")
        let consumer = Task {
            for await set in stream where set.contains(where: { $0.productID == "lifetime" }) {
                gotEntitled.fulfill()
                break
            }
        }
        guard case .success = await store.purchase("lifetime") else {
            return XCTFail("purchase failed")
        }
        await fulfillment(of: [gotEntitled], timeout: 10)
        consumer.cancel()
    }
}

final class CountingProvider: EntitlementProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func currentEntitlements() async throws -> Set<String> {
        lock.lock()
        calls += 1
        lock.unlock()
        return []
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class SetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Set<Entitlement>] = []

    func append(_ value: Set<Entitlement>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Set<Entitlement>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
