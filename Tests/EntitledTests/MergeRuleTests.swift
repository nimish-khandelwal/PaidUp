//
//  MergeRuleTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class MergeRuleTests: XCTestCase {
    func testRemoteAddsEntitlementsStoreKitDoesNotKnow() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        let provider = FakeProvider(.success(["pro.yearly"]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertTrue(store.isEntitled(toGroup: "group.pro"))
        let entitlement = try XCTUnwrap(store.entitlements.first)
        XCTAssertEqual(entitlement.source, .remote)
        XCTAssertNil(entitlement.expirationDate)
        XCTAssertEqual(entitlement.state, .active)
    }

    func testRemoteNeverRemovesLocallyVerifiedEntitlement() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let provider = FakeProvider(.success([]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startTask.value

        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
    }

    func testLocalWinsWhenBothReportSameProduct() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let provider = FakeProvider(.success(["pro.monthly"]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startTask.value

        XCTAssertEqual(store.entitlements.count, 1)
        XCTAssertEqual(store.entitlements.first?.source, .storeKit)
        XCTAssertNotNil(store.entitlements.first?.expirationDate)
    }

    func testRemoteFailureKeepsLastGoodSetAndReports() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        let provider = FakeProvider(.success(["pro.yearly"]), .failure(TestError()))
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.onError = log.handler
        }
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        await store.core.refreshRemote()

        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        guard case .remoteProviderFailed? = log.errors.last else {
            return XCTFail("expected remoteProviderFailed, got \(log.errors)")
        }
    }

    func testRemoteTimeoutIsReportedAndKeepsLastGoodSet() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        let provider = FakeProvider(.success(["lifetime"]))
        let log = ErrorLog()
        let store = try makeStore(client: client) {
            $0.remoteProvider = provider
            $0.remoteTimeout = 0.2
            $0.onError = log.handler
        }
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "lifetime"))

        provider.delay = 2
        await store.core.refreshRemote()

        XCTAssertTrue(store.isEntitled(to: "lifetime"))
        guard case .remoteProviderFailed(let underlying)? = log.errors.last else {
            return XCTFail("expected remoteProviderFailed, got \(log.errors)")
        }
        XCTAssertTrue(underlying is RemoteProviderTimeout)
    }

    func testRemoteRevocationRemovesRemoteOnlyEntitlement() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        let provider = FakeProvider(.success(["pro.yearly"]), .success([]))
        let store = try makeStore(client: client) { $0.remoteProvider = provider }
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))

        await store.core.refreshRemote()
        XCTAssertFalse(store.isEntitled(to: "pro.yearly"))
    }

    func testProviderNotCalledWhenAbsent() async throws {
        let client = FakeStoreKitClient()
        client.setEntitlements([])
        let store = try makeStore(client: client)
        await store.startTask.value
        await store.core.refreshRemote()
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testPureMergeRule() {
        let local: Set<Entitlement> = [
            Entitlement(productID: "pro.monthly", subscriptionGroupID: "g", expirationDate: Date(),
                        state: .active, ownership: .purchased, source: .storeKit),
        ]
        let merged = EntitledCore.merge(
            local: local,
            remote: ["pro.monthly", "lifetime"],
            catalog: ["lifetime": ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil)]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.productID == "pro.monthly" }?.source, .storeKit)
        XCTAssertEqual(merged.first { $0.productID == "lifetime" }?.source, .remote)
        XCTAssertEqual(EntitledCore.merge(local: local, remote: [], catalog: [:]), local)
    }
}
