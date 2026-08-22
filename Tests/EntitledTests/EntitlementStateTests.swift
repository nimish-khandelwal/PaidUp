//
//  EntitlementStateTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class EntitlementStateTests: XCTestCase {
    func testSubscribedIsActiveAndEntitled() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        client.renewalStates["pro.monthly"] = .subscribed
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        XCTAssertEqual(store.entitlements.first?.state, .active)
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
    }

    func testGracePeriodIsEntitledAndLabelled() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        client.renewalStates["pro.monthly"] = .inGracePeriod
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(store.entitlements.first?.state, .gracePeriod)
    }

    func testBillingRetryWithoutGraceIsNotEntitled() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        client.renewalStates["pro.monthly"] = .inBillingRetryPeriod
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testExpiredIsNotEntitled() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        client.renewalStates["pro.monthly"] = .expired
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
    }

    func testRevokedTransactionIsNotEntitledEvenIfStoreKitListsIt() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([
            client.makeTransaction(id: 1, productID: "pro.monthly", revoked: Date()),
        ])
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(client.finishedIDs, [1])
    }

    func testNonConsumableIsLifetime() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([
            client.makeTransaction(id: 7, productID: "lifetime", kind: .nonConsumable),
        ])
        let store = try makeStore(client: client)
        await store.startTask.value

        let entitlement = try XCTUnwrap(store.entitlements.first)
        XCTAssertEqual(entitlement.state, .lifetime)
        XCTAssertNil(entitlement.expirationDate)
        XCTAssertNil(entitlement.subscriptionGroupID)
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testUnverifiedIsAbsentAndReported() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlementEvents([
            .unverified(productID: "pro.monthly"),
            .verified(client.makeTransaction(id: 2, productID: "lifetime", kind: .nonConsumable)),
        ])
        let log = ErrorLog()
        let store = try makeStore(client: client) { $0.onError = log.handler }
        await store.startTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
        guard case .unverified(let id)? = log.errors.first else {
            return XCTFail("expected unverified error, got \(log.errors)")
        }
        XCTAssertEqual(id, "pro.monthly")
        XCTAssertEqual(client.finishedIDs, [2])
    }

    func testRefundMidPeriodFlipsImmediately() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.yearly")])
        let store = try makeStore(client: client)
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        client.setEntitlements([])
        client.emit(.verified(client.makeTransaction(id: 1, productID: "pro.yearly", revoked: Date())))

        try await waitUntil { !store.isEntitled(to: "pro.yearly") }
        XCTAssertTrue(store.entitlements.isEmpty)
        XCTAssertEqual(client.finishedIDs, [1])
    }

    func testFamilySharedIsEntitledUntilRevoked() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([
            client.makeTransaction(id: 3, productID: "pro.yearly", ownership: .familyShared),
        ])
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(store.entitlements.first?.ownership, .familyShared)

        client.setEntitlements([])
        client.emit(.verified(client.makeTransaction(
            id: 3, productID: "pro.yearly", revoked: Date(), ownership: .familyShared
        )))
        try await waitUntil { !store.isEntitled(to: "pro.yearly") }
    }

    func testUpgradeKeepsGroupEntitledWhileProductIDChanges() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let store = try makeStore(client: client)
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))

        let yearly = client.makeTransaction(id: 2, productID: "pro.yearly")
        client.setEntitlements([yearly])
        client.emit(.verified(client.makeTransaction(id: 1, productID: "pro.monthly", upgraded: true)))
        client.emit(.verified(yearly))

        try await waitUntil { store.isEntitled(to: "pro.yearly") }
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        XCTAssertEqual(Set(client.finishedIDs), [1, 2])
        XCTAssertEqual(client.finishedIDs.count, 2)
    }

    func testUpgradedTransactionInCurrentEntitlementsIsIgnored() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([
            client.makeTransaction(id: 1, productID: "pro.monthly", upgraded: true),
            client.makeTransaction(id: 2, productID: "pro.yearly"),
        ])
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
    }

    func testConsumablesAreIgnoredButFinished() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([
            client.makeTransaction(id: 9, productID: "coins", kind: .other, group: nil),
        ])
        let store = try makeStore(client: client)
        await store.startTask.value

        XCTAssertTrue(store.entitlements.isEmpty)
        XCTAssertEqual(client.finishedIDs, [9])
    }

    func testAccountSwitchFlipsEntitlements() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let store = try makeStore(client: client)
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))

        client.setEntitlements([client.makeTransaction(id: 50, productID: "lifetime", kind: .nonConsumable)])
        await store.core.refreshAll()

        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertTrue(store.isEntitled(to: "lifetime"))
    }

    func testEveryTransactionFinishedExactlyOnceAcrossRefreshes() async throws {
        let client = FakeStoreKitClient()
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setEntitlements([tx])
        let store = try makeStore(client: client)
        await store.startTask.value

        await store.core.refreshAll()
        client.emit(.verified(tx))
        await store.core.refreshAll()
        try await waitUntil { client.finishedIDs.count >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.finishedIDs, [1])
    }

    func testPureStateMapping() {
        let client = FakeStoreKitClient()
        let sub = client.makeTransaction(id: 1, productID: "pro.monthly")
        XCTAssertEqual(EntitledCore.entitlement(from: sub, renewalState: .subscribed)?.state, .active)
        XCTAssertEqual(EntitledCore.entitlement(from: sub, renewalState: .inGracePeriod)?.state, .gracePeriod)
        XCTAssertEqual(EntitledCore.entitlement(from: sub, renewalState: nil)?.state, .active)
        XCTAssertNil(EntitledCore.entitlement(
            from: client.makeTransaction(id: 2, productID: "pro.monthly", revoked: Date()),
            renewalState: .subscribed
        ))
        XCTAssertNil(EntitledCore.entitlement(
            from: client.makeTransaction(id: 3, productID: "pro.monthly", upgraded: true),
            renewalState: .subscribed
        ))
        XCTAssertEqual(
            EntitledCore.entitlement(
                from: client.makeTransaction(id: 4, productID: "lifetime", kind: .nonConsumable),
                renewalState: nil
            )?.state,
            .lifetime
        )
        XCTAssertNil(EntitledCore.entitlement(
            from: client.makeTransaction(id: 5, productID: "coins", kind: .other),
            renewalState: nil
        ))
    }
}
