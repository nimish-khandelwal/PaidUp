//
//  RemoteMergeRuleTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import PaidUpKit

final class RemoteMergeRuleTests: XCTestCase {
    func testRemoteAddsEntitlementsStoreKitDoesNotKnow() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["pro.yearly"]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startupTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        let entitlement = try XCTUnwrap(store.entitlements.first)
        XCTAssertEqual(entitlement.source, .remote)
        XCTAssertNil(entitlement.expirationDate)
        XCTAssertEqual(entitlement.state, .active)
    }

    func testRemoteNeverRemovesLocallyVerifiedEntitlement() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let provider = FakeEntitlementProvider(.success([]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startupTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
    }

    func testLocalWinsWhenBothReportSameProduct() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let provider = FakeEntitlementProvider(.success(["pro.monthly"]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startupTask.value

        XCTAssertEqual(store.entitlements.count, 1)
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
        XCTAssertNotNil(store.entitlements.first?.expirationDate)
    }

    func testRemoteFailureKeepsLastGoodSetAndReports() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["pro.yearly"]), .failure(TestError()))
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.onError = log.handler
        }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        await store.engine.refreshRemote()

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        guard case .remoteProviderFailed? = log.errors.last else {
            return XCTFail("expected remoteProviderFailed, got \(log.errors)")
        }
    }

    func testRemoteTimeoutIsReportedAndKeepsLastGoodSet() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["lifetime"]))
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.remoteTimeout = 0.2
            $0.onError = log.handler
        }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "lifetime"))

        provider.delay = 2
        await store.engine.refreshRemote()

        XCTAssertTrue(store.isEntitled(to: "lifetime"))
        guard case .remoteProviderFailed(let underlying)? = log.errors.last else {
            return XCTFail("expected remoteProviderFailed, got \(log.errors)")
        }
        XCTAssertTrue(underlying is RemoteProviderTimeout)
    }

    func testRemoteRevocationRemovesRemoteOnlyEntitlement() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["pro.yearly"]), .success([]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        await store.engine.refreshRemote()
        XCTAssertFalse(store.isEntitled(to: "pro.yearly"))
    }

    func testProviderNotCalledWhenAbsent() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let log = ErrorLog()
        let store = try makeStore(client: client) { $0.onError = log.handler }
        await store.startupTask.value
        await store.engine.refreshRemote()
        XCTAssertTrue(store.entitlements.isEmpty)
        XCTAssertTrue(log.errors.isEmpty)
    }

    func testNonCooperativeProviderStillHitsTheDeadline() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["lifetime"]))
        provider.ignoresCancellation = true
        provider.delay = 3
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.remoteTimeout = 0.2
            $0.onError = log.handler
        }
        let started = Date()
        await store.startupTask.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .remoteProviderFailed(let underlying)? = log.errors.last else {
            return XCTFail("expected remoteProviderFailed, got \(log.errors)")
        }
        XCTAssertTrue(underlying is RemoteProviderTimeout)
        XCTAssertFalse(store.isEntitled(to: "lifetime"))
    }

    func testPurchaseDoesNotWaitForSlowProvider() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let tx = client.makeTransaction(id: 10, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in
            client.setCurrentEntitlements([tx])
            return .success(.verified(tx))
        }
        let provider = FakeEntitlementProvider(.success([]))
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.remoteTimeout = 5
        }
        await store.startupTask.value
        provider.delay = 4
        let started = Date()
        guard case .success = await store.purchase("pro.yearly") else {
            return XCTFail("expected success")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await waitUntil(timeout: 6) { provider.callCount == 2 }
    }

    func testRemoteIDOutsideProductSetIsEntitledButNotPurchasable() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["android.premium"]))
        }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "android.premium"))
        XCTAssertNil(store.entitlements.first?.subscriptionGroupID)
        guard case .failed(.productNotFound) = await store.purchase("android.premium") else {
            return XCTFail("expected productNotFound")
        }
    }

    func testProductCatalogFailureIsReportedAndRetriedOnRefresh() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.productsError = TestError()
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["pro.yearly"]))
            $0.onError = log.handler
        }
        await store.startupTask.value
        guard case .storeKit? = log.errors.first else {
            return XCTFail("expected storeKit error, got \(log.errors)")
        }
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertFalse(store.isEntitled(toGroup: "group.pro"))

        client.productsError = nil
        await store.engine.refreshAll()
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
    }

    func testPurchaseNotYetInCurrentEntitlementsIsPending() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let tx = client.makeTransaction(id: 10, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in .success(.verified(tx)) }
        let store = try makeStore(client: client)
        await store.startupTask.value
        guard case .pending = await store.purchase("pro.yearly") else {
            return XCTFail("expected pending")
        }
        XCTAssertFalse(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(client.finishedTransactionIDs, [10])
    }

    func testConsumableInCatalogIsRejectedBeforePurchase() async throws {
        let client = FakeStoreKitClient()
        client.catalog.append(ProductInfo(id: "coins", kind: .other, subscriptionGroupID: nil))
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client, products: ["coins", "lifetime"])
        await store.startupTask.value
        guard case .failed(.productNotFound("coins")) = await store.purchase("coins") else {
            return XCTFail("expected productNotFound")
        }
        XCTAssertTrue(client.appAccountTokens.isEmpty)
    }

    func testPureMergeRule() {
        let local: Set<Entitlement> = [
            Entitlement(productID: "pro.monthly", subscriptionGroupID: "g", expirationDate: Date(),
                        state: .active, ownership: .purchased, source: .storeKit),
        ]
        let merged = EntitlementEngine.merge(
            storeKit: local,
            remote: ["pro.monthly", "lifetime"],
            catalog: ["lifetime": ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil)]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.productID == "pro.monthly" }?.source, .storeKit)
        XCTAssertEqual(merged.first { $0.productID == "lifetime" }?.source, .remote)
        XCTAssertEqual(EntitlementEngine.merge(storeKit: local, remote: [], catalog: [:]), local)
    }
}
