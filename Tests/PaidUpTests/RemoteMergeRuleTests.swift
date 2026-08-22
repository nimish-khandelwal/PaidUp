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
        let store = try makeStore(client: client)
        await store.startupTask.value
        await store.engine.refreshRemote()
        XCTAssertTrue(store.entitlements.isEmpty)
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
