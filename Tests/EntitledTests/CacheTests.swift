//
//  CacheTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class CacheTests: XCTestCase {
    func testCacheSeedsSnapshotBeforeStoreKitAnswers() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setEntitlements([first.makeTransaction(id: 1, productID: "pro.monthly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startTask.value
        XCTAssertTrue(warm.isEntitled(to: "pro.monthly"))

        let second = FakeStoreKitClient()
        second.entitlementsGate.close()
        second.setEntitlements([second.makeTransaction(id: 1, productID: "pro.monthly")])
        let cold = try makeStore(client: second, directory: directory)

        XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))
        let hasAnswer = await cold.core.hasStoreKitAnswer
        XCTAssertFalse(hasAnswer)

        second.entitlementsGate.open()
        await cold.startTask.value
        XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))
    }

    func testCacheNeverWinsOverFreshStoreKitAnswer() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setEntitlements([first.makeTransaction(id: 1, productID: "pro.yearly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startTask.value
        XCTAssertTrue(warm.isEntitled(to: "pro.yearly"))

        let second = FakeStoreKitClient()
        second.entitlementsGate.close()
        second.setEntitlements([])
        let cold = try makeStore(client: second, directory: directory)
        XCTAssertTrue(cold.isEntitled(to: "pro.yearly"))

        var seen: [Set<Entitlement>] = []
        let stream = cold.updates
        second.entitlementsGate.open()
        for await value in stream {
            seen.append(value)
            if value.isEmpty { break }
        }
        XCTAssertFalse(cold.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(seen.first?.count, 1)
    }

    func testRemoteSetIsCachedToo() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setEntitlements([])
        let warm = try makeStore(client: first, directory: directory) {
            $0.remoteProvider = FakeProvider(.success(["lifetime"]))
        }
        await warm.startTask.value
        XCTAssertTrue(warm.isEntitled(to: "lifetime"))

        let second = FakeStoreKitClient()
        second.entitlementsGate.close()
        let cold = try makeStore(client: second, directory: directory)
        XCTAssertTrue(cold.isEntitled(to: "lifetime"))
        XCTAssertEqual(cold.entitlements.first?.source, .remote)
        second.entitlementsGate.open()
    }

    func testCorruptCacheIsReportedAndIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("entitlements.json"))
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let log = ErrorLog()
        let store = try makeStore(client: client, directory: directory) { $0.onError = log.handler }

        guard case .storageFailed? = log.errors.first else {
            return XCTFail("expected storageFailed, got \(log.errors)")
        }
        await store.startTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
    }

    func testCacheFileShapeIsStable() async throws {
        let directory = try makeTemporaryDirectory()
        let client = FakeStoreKitClient()
        client.setEntitlements([client.makeTransaction(id: 1, productID: "lifetime", kind: .nonConsumable)])
        let store = try makeStore(client: client, directory: directory) {
            $0.remoteProvider = FakeProvider(.success(["pro.yearly"]))
        }
        await store.startTask.value

        let data = try Data(contentsOf: directory.appendingPathComponent("entitlements.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["entitlements", "remote", "savedAt"])
        XCTAssertEqual(json["remote"] as? [String], ["pro.yearly"])
        let entitlements = try XCTUnwrap(json["entitlements"] as? [[String: Any]])
        XCTAssertEqual(entitlements.first?["productID"] as? String, "lifetime")
        XCTAssertEqual(entitlements.first?["state"] as? String, "lifetime")
    }

    func testStoreRoundTrip() throws {
        let store = try EntitlementStore(directory: makeTemporaryDirectory())
        XCTAssertNil(try store.load())
        let snapshot = EntitlementStore.Snapshot(
            entitlements: [
                Entitlement(productID: "a", subscriptionGroupID: "g", expirationDate: Date(timeIntervalSince1970: 1000),
                            state: .gracePeriod, ownership: .familyShared, source: .storeKit),
            ],
            remote: ["b"],
            savedAt: Date(timeIntervalSince1970: 2000)
        )
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
