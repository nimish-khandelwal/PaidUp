//
//  PurchaseRestoreTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class PurchaseRestoreTests: XCTestCase {
    func testSuccessfulPurchaseCarriesAppAccountTokenAndEntitles() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let userID = UUID()
        let tx = client.makeTransaction(id: 10, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in
            client.setCurrentEntitlements([tx])
            return .success(.verified(tx))
        }
        let store = try makeStore(client: client, userID: userID)
        await store.startupTask.value

        let result = await store.purchase("pro.yearly")
        guard case .success(let entitlement) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(entitlement.productID, "pro.yearly")
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(client.appAccountTokens, [userID])
        XCTAssertEqual(client.finishedTransactionIDs, [10])
    }

    func testPurchaseTriggersRemoteRefresh() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let tx = client.makeTransaction(id: 10, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in
            client.setCurrentEntitlements([tx])
            return .success(.verified(tx))
        }
        let provider = FakeEntitlementProvider(.success([]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startupTask.value
        XCTAssertEqual(provider.callCount, 1)

        _ = await store.purchase("pro.yearly")
        XCTAssertEqual(provider.callCount, 2)
    }

    func testUserCancelled() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { _, _ in .userCancelled }
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .userCancelled = await store.purchase("pro.monthly") else {
            return XCTFail("expected userCancelled")
        }
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testPendingThenApprovedArrivesViaUpdates() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { _, _ in .pending }
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .pending = await store.purchase("pro.monthly") else {
            return XCTFail("expected pending")
        }
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))

        let tx = client.makeTransaction(id: 11, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { store.isEntitled(to: "pro.monthly") }
        XCTAssertEqual(client.finishedTransactionIDs, [11])
    }

    func testProductNotInSetIsProductNotFound() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .failed(.productNotFound(let id)) = await store.purchase("unknown") else {
            return XCTFail("expected productNotFound")
        }
        XCTAssertEqual(id, "unknown")
        XCTAssertTrue(client.appAccountTokens.isEmpty)
    }

    func testStoreKitProductNotFoundPassesThrough() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { id, _ in throw EntitledError.productNotFound(id) }
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .failed(.productNotFound("pro.monthly")) = await store.purchase("pro.monthly") else {
            return XCTFail("expected productNotFound")
        }
    }

    func testPurchaseNotAllowed() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { _, _ in throw PurchaseFailure.notAllowed }
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .failed(.purchaseNotAllowed) = await store.purchase("pro.monthly") else {
            return XCTFail("expected purchaseNotAllowed")
        }
    }

    func testOtherStoreKitErrorsAreWrapped() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { _, _ in throw TestError() }
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .failed(.storeKit(let underlying)) = await store.purchase("pro.monthly") else {
            return XCTFail("expected storeKit error")
        }
        XCTAssertTrue(underlying is TestError)
    }

    func testUnverifiedPurchaseFailsAndReports() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.purchaseHandler = { id, _ in .success(.unverified(productID: id)) }
        let log = ErrorLog()
        let store = try makeStore(client: client) { $0.onError = log.handler }
        await store.startupTask.value

        guard case .failed(.unverified(let id)) = await store.purchase("pro.monthly") else {
            return XCTFail("expected unverified")
        }
        XCTAssertEqual(id, "pro.monthly")
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        guard case .unverified? = log.errors.last else {
            return XCTFail("expected unverified in onError")
        }
    }

    func testNilUserIDSendsNoToken() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client, userID: nil)
        await store.startupTask.value
        _ = await store.purchase("pro.monthly")
        XCTAssertEqual(client.appAccountTokens.count, 1)
        XCTAssertNil(client.appAccountTokens[0])
    }

    func testRestoreSyncsAndReturnsFullSet() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["pro.yearly"]))
        }
        await store.startupTask.value
        XCTAssertFalse(store.isEntitled(to: "lifetime"))

        client.setCurrentEntitlements([client.makeTransaction(id: 5, productID: "lifetime", kind: .nonConsumable)])
        let result = await store.restore()
        guard case .restored(let set) = result else {
            return XCTFail("expected restored, got \(result)")
        }
        XCTAssertEqual(client.syncCallCount, 1)
        XCTAssertEqual(Set(set.map(\.productID)), ["lifetime", "pro.yearly"])
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testRestoreFailureIsTyped() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.syncError = TestError()
        let store = try makeStore(client: client)
        await store.startupTask.value

        guard case .failed(.storeKit(let underlying)) = await store.restore() else {
            return XCTFail("expected storeKit failure")
        }
        XCTAssertTrue(underlying is TestError)
    }
}
