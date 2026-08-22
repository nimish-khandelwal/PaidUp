//
//  TransactionListenerTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class TransactionListenerTests: XCTestCase {
    func testListenerStartsAtInitAndReceivesUpdates() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        try await waitUntil { client.updateListenerCount == 1 }

        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { store.isEntitled(to: "pro.monthly") }
    }

    func testTwoInstancesBothListen() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let a = try makeStore(client: client)
        let b = try makeStore(client: client)
        await a.startupTask.value
        await b.startupTask.value
        XCTAssertEqual(client.updateListenerCount, 2)

        let tx = client.makeTransaction(id: 1, productID: "lifetime", kind: .nonConsumable)
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { a.isEntitled(to: "lifetime") && b.isEntitled(to: "lifetime") }
    }

    func testDeinitCancelsListenerAndReleasesCore() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        weak var weakEngine: EntitlementEngine?
        do {
            let store = try makeStore(client: client)
            await store.startupTask.value
            weakEngine = store.engine
            XCTAssertEqual(client.updateListenerCount, 1)
        }
        try await waitUntil { client.updateListenerCount == 0 }
        try await waitUntil { weakEngine == nil }
    }

    func testCreateDestroyCyclesLeaveNothingBehind() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([client.makeTransaction(id: 1, productID: "pro.monthly")])
        let directory = try makeTemporaryDirectory()
        for _ in 0..<20 {
            let store = try makeStore(client: client, directory: directory)
            await store.startupTask.value
            _ = store.updates
            XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        }
        try await waitUntil { client.updateListenerCount == 0 }
    }

    func testUpdatesEmitsCurrentThenChangesAndDedupes() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        await store.startupTask.value

        let collected = EntitlementSetCollector()
        let stream = store.updates
        let consumer = Task {
            for await value in stream {
                collected.append(value)
            }
        }
        try await waitUntil { collected.values.count == 1 }
        XCTAssertEqual(collected.values.first, [])

        await store.engine.refreshAll()
        await store.engine.refreshAll()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(collected.values.count, 1)

        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { collected.values.count == 2 }
        XCTAssertEqual(collected.values.last?.first?.productID, "pro.monthly")
        consumer.cancel()
    }

    func testUpdatesStreamEndsWhenInstanceDeallocates() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        var stream: AsyncStream<Set<Entitlement>>?
        do {
            let store = try makeStore(client: client)
            await store.startupTask.value
            stream = store.updates
        }
        var count = 0
        for await _ in try XCTUnwrap(stream) {
            count += 1
        }
        XCTAssertEqual(count, 1)
    }

    func testMultipleConsumersEachGetEveryChange() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        await store.startupTask.value

        let a = EntitlementSetCollector(), b = EntitlementSetCollector()
        let sa = store.updates, sb = store.updates
        let ta = Task { for await v in sa { a.append(v) } }
        let tb = Task { for await v in sb { b.append(v) } }
        try await waitUntil { a.values.count == 1 && b.values.count == 1 }

        let tx = client.makeTransaction(id: 1, productID: "lifetime", kind: .nonConsumable)
        client.setCurrentEntitlements([tx])
        client.emitTransactionUpdate(.verified(tx))
        try await waitUntil { a.values.count == 2 && b.values.count == 2 }
        ta.cancel()
        tb.cancel()
    }

    func testCancelledConsumerIsRemoved() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        await store.startupTask.value
        let stream = store.updates
        let task = Task { for await _ in stream {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(store.entitlements, [])
    }
}

final class EntitlementSetCollector: @unchecked Sendable {
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
