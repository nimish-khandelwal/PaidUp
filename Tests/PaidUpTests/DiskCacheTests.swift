//
//  DiskCacheTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import PaidUpKit

final class DiskCacheTests: XCTestCase {
    func testCacheSeedsSnapshotBeforeStoreKitAnswers() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([first.makeTransaction(id: 1, productID: "pro.monthly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startupTask.value
        XCTAssertTrue(warm.isEntitled(to: "pro.monthly"))

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        second.setCurrentEntitlements([second.makeTransaction(id: 1, productID: "pro.monthly")])
        let cold = try makeStore(client: second, directory: directory)

        XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))
        let hasAnswer = await cold.engine.hasReceivedStoreKitAnswer
        XCTAssertFalse(hasAnswer)

        second.currentEntitlementsGate.open()
        await cold.startupTask.value
        XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))
        let answered = await cold.engine.hasReceivedStoreKitAnswer
        XCTAssertTrue(answered)
    }

    func testCacheNeverWinsOverFreshStoreKitAnswer() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([first.makeTransaction(id: 1, productID: "pro.yearly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startupTask.value
        XCTAssertTrue(warm.isEntitled(to: "pro.yearly"))

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        second.setCurrentEntitlements([])
        let cold = try makeStore(client: second, directory: directory)
        XCTAssertTrue(cold.isEntitled(to: "pro.yearly"))

        var seen: [Set<Entitlement>] = []
        let stream = cold.updates
        var iterator = stream.makeAsyncIterator()
        if let first = await iterator.next() {
            seen.append(first)
        }
        second.currentEntitlementsGate.open()
        while let value = await iterator.next() {
            seen.append(value)
            if value.isEmpty { break }
        }
        XCTAssertFalse(cold.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(seen.first?.count, 1)
    }

    func testRemoteSetIsCachedUntilProviderAnswers() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([])
        let warm = try makeStore(client: first, directory: directory) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["pro.yearly"]))
        }
        await warm.startupTask.value
        XCTAssertTrue(warm.isEntitled(toGroup: "group.pro"))

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        let provider = FakeEntitlementProvider(.success([]))
        provider.delay = 0.3
        let cold = try makeStore(client: second, directory: directory) { $0.remoteProvider = provider }
        XCTAssertTrue(cold.isEntitled(to: "pro.yearly"))
        XCTAssertTrue(cold.isEntitled(toGroup: "group.pro"), "cached remote entry keeps its group on the first frame")
        XCTAssertEqual(cold.entitlements.first?.source, .remote)

        second.currentEntitlementsGate.open()
        await cold.startupTask.value
        XCTAssertFalse(cold.isEntitled(to: "pro.yearly"))
    }

    func testCachedRemoteIsIgnoredWhenNoProviderConfigured() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([])
        let warm = try makeStore(client: first, directory: directory) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["lifetime"]))
        }
        await warm.startupTask.value
        XCTAssertTrue(warm.isEntitled(to: "lifetime"))

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        let cold = try makeStore(client: second, directory: directory)
        XCTAssertFalse(cold.isEntitled(to: "lifetime"))
        second.currentEntitlementsGate.open()
        await cold.startupTask.value
    }

    func testDeinitMidStoreKitReadDoesNotTruncateCache() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([first.makeTransaction(id: 1, productID: "pro.monthly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startupTask.value
        XCTAssertTrue(warm.isEntitled(to: "pro.monthly"))

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        second.setCurrentEntitlements([])
        do {
            let cold = try makeStore(client: second, directory: directory)
            try await waitUntil { second.updateListenerCount == 1 }
            XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))
        }
        try await waitUntil { second.updateListenerCount == 0 }
        second.currentEntitlementsGate.open()
        try await Task.sleep(nanoseconds: 100_000_000)

        let cached = try XCTUnwrap(EntitlementDiskCache(directory: directory).load())
        XCTAssertEqual(cached.entitlements.map(\.productID), ["pro.monthly"])
    }

    func testCachePreservedWhenRemotePublishesBeforeStoreKitAnswers() async throws {
        let directory = try makeTemporaryDirectory()
        let first = FakeStoreKitClient()
        first.setCurrentEntitlements([first.makeTransaction(id: 1, productID: "pro.monthly")])
        let warm = try makeStore(client: first, directory: directory)
        await warm.startupTask.value

        let second = FakeStoreKitClient()
        second.currentEntitlementsGate.close()
        second.setCurrentEntitlements([])
        let provider = FakeEntitlementProvider(.success(["lifetime"]))
        let cold = try makeStore(client: second, directory: directory) { $0.remoteProvider = provider }
        await cold.engine.refreshRemote()
        XCTAssertTrue(cold.isEntitled(to: "lifetime"))
        XCTAssertTrue(cold.isEntitled(to: "pro.monthly"))

        let cached = try XCTUnwrap(EntitlementDiskCache(directory: directory).load())
        XCTAssertEqual(cached.entitlements.map(\.productID), ["pro.monthly"])
        XCTAssertEqual(cached.remote, ["lifetime"])
        second.currentEntitlementsGate.open()
        await cold.startupTask.value
    }

    func testCorruptCacheSelfHealsAfterStartup() async throws {
        let directory = try makeTemporaryDirectory()
        try Data("{".utf8).write(to: directory.appendingPathComponent("entitlements.json"))
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "lifetime", kind: .nonConsumable)])
        let store = try makeStore(client: client, directory: directory)
        await store.startupTask.value
        let cached = try XCTUnwrap(EntitlementDiskCache(directory: directory).load())
        XCTAssertEqual(cached.entitlements.map(\.productID), ["lifetime"])
    }

    func testStorageFailureMidRunIsReportedAndEntitlementsStillCorrect() async throws {
        let directory = try makeTemporaryDirectory()
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let log = ErrorLog()
        let store = try makeStore(client: client, directory: directory) { $0.onError = log.handler }
        await store.startupTask.value

        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { store.isEntitled(to: "pro.monthly") }
        try await waitUntil { log.errors.contains { if case .storageFailed = $0 { return true }; return false } }
    }

    func testUnusableStorageDirectoryReportsAndStillWorks() async throws {
        let parent = try makeTemporaryDirectory()
        let filePath = parent.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: filePath)
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let log = ErrorLog()
        let store = try makeStore(client: client, directory: filePath) { $0.onError = log.handler }
        guard case .storageFailed? = log.errors.first else {
            return XCTFail("expected storageFailed, got \(log.errors)")
        }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
    }

    func testDefaultStorageDirectoryIsPerBundleAndUser() {
        let userID = UUID()
        let url = EntitlementDiskCache.defaultDirectory(userID: userID)
        let components = url.pathComponents
        XCTAssertEqual(components.suffix(3).first, "PaidUp")
        XCTAssertEqual(components.last, userID.uuidString)
        XCTAssertEqual(EntitlementDiskCache.defaultDirectory(userID: nil).lastPathComponent, "anonymous")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testRemoteTimeoutIsClamped() {
        var config = PaidUpConfiguration.default
        config.remoteTimeout = 0
        XCTAssertEqual(config.normalized().remoteTimeout, 0.1)
        config.remoteTimeout = -5
        XCTAssertEqual(config.normalized().remoteTimeout, 0.1)
        config.remoteTimeout = .infinity
        XCTAssertEqual(config.normalized().remoteTimeout, 3600)
        config.remoteTimeout = .nan
        XCTAssertEqual(config.normalized().remoteTimeout, 3600)
        XCTAssertEqual(PaidUpConfiguration(remoteTimeout: 10_000).remoteTimeout, 3600)
    }

    func testLegacyCacheWithoutRemoteGroupsStillLoads() throws {
        let directory = try makeTemporaryDirectory()
        let json = """
        {"entitlements":[],"remote":["pro.yearly"],"savedAt":"2026-01-01T00:00:00Z"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("entitlements.json"))
        let cached = try XCTUnwrap(EntitlementDiskCache(directory: directory).load())
        XCTAssertEqual(cached.remote, ["pro.yearly"])
        XCTAssertEqual(cached.remoteSubscriptionGroupIDs, [:])
    }

    func testCorruptCacheIsReportedAndIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("entitlements.json"))
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let log = ErrorLog()
        let store = try makeStore(client: client, directory: directory) { $0.onError = log.handler }

        guard case .storageFailed? = log.errors.first else {
            return XCTFail("expected storageFailed, got \(log.errors)")
        }
        await store.startupTask.value
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
    }

    func testCacheFileShapeIsStable() async throws {
        let directory = try makeTemporaryDirectory()
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "lifetime", kind: .nonConsumable)])
        let store = try makeStore(client: client, directory: directory) {
            $0.remoteProvider = FakeEntitlementProvider(.success(["pro.yearly"]))
        }
        await store.startupTask.value

        let data = try Data(contentsOf: directory.appendingPathComponent("entitlements.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["entitlements", "remote", "remoteSubscriptionGroupIDs", "savedAt"])
        XCTAssertEqual(json["remote"] as? [String], ["pro.yearly"])
        let entitlements = try XCTUnwrap(json["entitlements"] as? [[String: Any]])
        XCTAssertEqual(entitlements.first?["productID"] as? String, "lifetime")
        XCTAssertEqual(entitlements.first?["state"] as? String, "lifetime")
    }

    func testDiskCacheRoundTrip() throws {
        let cache = try EntitlementDiskCache(directory: makeTemporaryDirectory())
        XCTAssertNil(try cache.load())
        let contents = EntitlementDiskCache.CachedEntitlements(
            entitlements: [
                Entitlement(productID: "a", subscriptionGroupID: "g", expirationDate: Date(timeIntervalSince1970: 1000),
                            state: .gracePeriod, ownership: .familyShared, source: .storeKit),
            ],
            remote: ["b"],
            savedAt: Date(timeIntervalSince1970: 2000)
        )
        try cache.save(contents)
        XCTAssertEqual(try cache.load(), contents)
        try cache.clear()
        XCTAssertNil(try cache.load())
    }
}
