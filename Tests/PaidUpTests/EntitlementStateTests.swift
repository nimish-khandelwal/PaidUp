//
//  EntitlementStateTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import PaidUpKit

final class EntitlementStateTests: XCTestCase {
    func testSubscribedIsActiveAndEntitled() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        client.renewalStateByProductID["pro.monthly"] = .subscribed
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        XCTAssertEqual(store.entitlements.first?.state, .active)
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
    }

    func testGracePeriodIsEntitledAndLabelled() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        client.renewalStateByProductID["pro.monthly"] = .inGracePeriod
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(store.entitlements.first?.state, .gracePeriod)
    }

    func testBillingRetryWithoutGraceIsNotEntitledBecauseStoreKitOmitsIt() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.renewalStateByProductID["pro.monthly"] = .inBillingRetryPeriod
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testExpiredIsNotEntitledBecauseStoreKitOmitsIt() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        client.renewalStateByProductID["pro.monthly"] = .expired
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
    }

    func testRevokedTransactionIsNotEntitledEvenIfStoreKitListsIt() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 1, productID: "pro.monthly", revoked: Date()),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(client.finishedTransactionIDs, [1])
    }

    func testNonConsumableIsLifetime() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 7, productID: "lifetime", kind: .nonConsumable),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value

        let entitlement = try XCTUnwrap(store.entitlements.first)
        XCTAssertEqual(entitlement.state, .lifetime)
        XCTAssertNil(entitlement.expirationDate)
        XCTAssertNil(entitlement.subscriptionGroupID)
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testUnverifiedIsAbsentAndReported() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlementEvents([
            .unverified(productID: "pro.monthly"),
            .verified(client.makeTransaction(id: 2, productID: "lifetime", kind: .nonConsumable)),
        ])
        let log = ErrorLog()
        let store = try makeStore(client: client) { $0.onError = log.handler }
        await store.startupTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
        guard case .unverified(let id)? = log.errors.first else {
            return XCTFail("expected unverified error, got \(log.errors)")
        }
        XCTAssertEqual(id, "pro.monthly")
        XCTAssertEqual(client.finishedTransactionIDs, [2])
    }

    func testRefundMidPeriodFlipsImmediately() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.yearly")])
        let store = try makeStore(client: client)
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        client.setCurrentEntitlements([])
        client.emitTransactionUpdate(.verified(client.makeTransaction(id: 1, productID: "pro.yearly", revoked: Date())))

        try await waitUntil { !store.isEntitled(to: "pro.yearly") }
        XCTAssertTrue(store.entitlements.isEmpty)
        XCTAssertEqual(client.finishedTransactionIDs, [1])
    }

    func testFamilySharedIsEntitledUntilRevoked() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 3, productID: "pro.yearly", ownership: .familyShared),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(store.entitlements.first?.ownership, .familyShared)

        client.setCurrentEntitlements([])
        client.emitTransactionUpdate(.verified(client.makeTransaction(
            id: 3, productID: "pro.yearly", revoked: Date(), ownership: .familyShared
        )))
        try await waitUntil { !store.isEntitled(to: "pro.yearly") }
    }

    func testUpgradeKeepsGroupEntitledWhileProductIDChanges() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let store = try makeStore(client: client)
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))

        let yearly = client.makeTransaction(id: 2, productID: "pro.yearly")
        client.setCurrentEntitlements([yearly])
        client.emitTransactionUpdate(.verified(client.makeTransaction(id: 1, productID: "pro.monthly", upgraded: true)))
        client.emitTransactionUpdate(.verified(yearly))

        try await waitUntil { store.isEntitled(to: "pro.yearly") }
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        XCTAssertEqual(Set(client.finishedTransactionIDs), [1, 2])
        XCTAssertEqual(client.finishedTransactionIDs.count, 2)
    }

    func testUpgradedTransactionInCurrentEntitlementsIsIgnored() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 1, productID: "pro.monthly", upgraded: true),
            client.makeTransaction(id: 2, productID: "pro.yearly"),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
    }

    func testConsumablesAreIgnoredButFinished() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 9, productID: "coins", kind: .other, group: nil),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertTrue(store.entitlements.isEmpty)
        XCTAssertEqual(client.finishedTransactionIDs, [9])
    }

    func testAccountSwitchFlipsEntitlements() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let store = try makeStore(client: client)
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))

        client.setCurrentEntitlements([client.makeTransaction(id: 50, productID: "lifetime", kind: .nonConsumable)])
        await store.engine.refreshAll()

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testEveryTransactionFinishedExactlyOnceAcrossRefreshes() async throws {
        let client = FakeStoreKitClient()
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        let store = try makeStore(client: client)
        await store.startupTask.value

        await store.engine.refreshAll()
        client.emitTransactionUpdate(.verified(tx))
        await store.engine.refreshAll()
        let sentinel = client.makeTransaction(id: 2, productID: "lifetime", kind: .nonConsumable)
        client.setCurrentEntitlements([tx, sentinel])
        client.emitTransactionUpdate(.verified(sentinel))
        try await waitUntil { client.finishedTransactionIDs.contains(2) }

        XCTAssertEqual(client.finishedTransactionIDs, [1, 2])
    }

    func testRenewalThroughUpdatesAdvancesExpirationAndFinishesBoth() async throws {
        let client = FakeStoreKitClient()
        let first = client.makeTransaction(id: 1, productID: "pro.monthly", expires: Date().addingTimeInterval(60))
        client.setCurrentEntitlements([first])
        let store = try makeStore(client: client)
        await store.startupTask.value
        let before = try XCTUnwrap(store.entitlements.first?.expirationDate)

        let renewal = client.makeTransaction(id: 2, productID: "pro.monthly", expires: Date().addingTimeInterval(3600))
        client.setCurrentEntitlements([renewal])
        client.emitTransactionUpdate(.verified(renewal))
        try await waitUntil { (store.entitlements.first?.expirationDate ?? before) > before }

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(store.entitlements.count, 1)
        XCTAssertEqual(Set(client.finishedTransactionIDs), [1, 2])
    }

    func testGraceLabelIsKeptWhenStatusLookupFails() async throws {
        let client = FakeStoreKitClient()
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        client.renewalStateByProductID["pro.monthly"] = .inGracePeriod
        let store = try makeStore(client: client)
        await store.startupTask.value
        XCTAssertEqual(store.entitlements.first?.state, .gracePeriod)

        client.renewalStateByProductID = [:]
        await store.engine.refreshAll()
        XCTAssertEqual(store.entitlements.first?.state, .gracePeriod)
    }

    func testTwoTransactionsForOneProductReportBoth() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([
            client.makeTransaction(id: 1, productID: "pro.yearly"),
            client.makeTransaction(id: 2, productID: "pro.yearly", ownership: .familyShared),
        ])
        let store = try makeStore(client: client)
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(Set(store.entitlements.map(\.ownership)), [.purchased, .familyShared])
    }

    func testUnfinishedTransactionsFromPreviousLaunchAreFinishedOnce() async throws {
        let client = FakeStoreKitClient()
        let stale = client.makeTransaction(id: 41, productID: "pro.monthly", revoked: Date())
        let current = client.makeTransaction(id: 42, productID: "lifetime", kind: .nonConsumable)
        client.setCurrentEntitlements([current])
        client.setUnfinishedTransactions([stale, current])
        let store = try makeStore(client: client)
        await store.startupTask.value

        XCTAssertEqual(Set(client.finishedTransactionIDs), [41, 42])
        XCTAssertEqual(client.finishedTransactionIDs.count, 2)
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testPureStateMapping() {
        let client = FakeStoreKitClient()
        let sub = client.makeTransaction(id: 1, productID: "pro.monthly")
        XCTAssertEqual(EntitlementEngine.entitlement(from: sub, renewalState: .subscribed)?.state, .active)
        XCTAssertEqual(EntitlementEngine.entitlement(from: sub, renewalState: .inGracePeriod)?.state, .gracePeriod)
        XCTAssertEqual(EntitlementEngine.entitlement(from: sub, renewalState: nil)?.state, .active)
        XCTAssertNil(EntitlementEngine.entitlement(
            from: client.makeTransaction(id: 2, productID: "pro.monthly", revoked: Date()),
            renewalState: .subscribed
        ))
        XCTAssertNil(EntitlementEngine.entitlement(
            from: client.makeTransaction(id: 3, productID: "pro.monthly", upgraded: true),
            renewalState: .subscribed
        ))
        XCTAssertEqual(
            EntitlementEngine.entitlement(
                from: client.makeTransaction(id: 4, productID: "lifetime", kind: .nonConsumable),
                renewalState: nil
            )?.state,
            .lifetime
        )
        XCTAssertNil(EntitlementEngine.entitlement(
            from: client.makeTransaction(id: 5, productID: "coins", kind: .other),
            renewalState: nil
        ))
    }
}
