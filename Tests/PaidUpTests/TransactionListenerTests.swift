//
//  TransactionListenerTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import PaidUpKit

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
        var engines: [WeakEngine] = []
        for i in 0..<20 {
            let store = try makeStore(client: client, directory: directory)
            engines.append(WeakEngine(store.engine))
            if i.isMultiple(of: 3) {
                continue
            }
            await store.startupTask.value
            let stream = store.updates
            let consumer = Task { for await _ in stream {} }
            XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
            if i.isMultiple(of: 2) { consumer.cancel() }
        }
        try await waitUntil { client.updateListenerCount == 0 }
        try await waitUntil { engines.allSatisfy { $0.engine == nil } }
    }

    func testUnfinishedTransactionsReplayedOnSubscribeAreFinishedOnce() async throws {
        let client = FakeStoreKitClient()
        let current = client.makeTransaction(id: 1, productID: "pro.monthly")
        let revoked = client.makeTransaction(id: 2, productID: "pro.yearly", revoked: Date())
        client.setCurrentEntitlements([current])
        client.setReplayedUpdates([.verified(current), .verified(revoked)])
        let store = try makeStore(client: client)
        await store.startupTask.value
        try await waitUntil { Set(client.finishedTransactionIDs) == [1, 2] }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.finishedTransactionIDs.count, 2)
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
        XCTAssertFalse(store.isEntitled(to: "pro.yearly"))
    }

    func testUnverifiedUpdateIsReportedWithoutRecompute() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let log = ErrorLog()
        let store = try makeStore(client: client) { $0.onError = log.handler }
        await store.startupTask.value
        let reads = client.currentEntitlementsCallCount

        client.emitTransactionUpdate(.unverified(productID: "pro.monthly"))
        try await waitUntil { !log.errors.isEmpty }
        guard case .unverified("pro.monthly")? = log.errors.first else {
            return XCTFail("expected unverified, got \(log.errors)")
        }
        XCTAssertFalse(store.isEntitled(to: "pro.monthly"))
        XCTAssertEqual(client.currentEntitlementsCallCount, reads)
    }

    func testPurchaseInFlightSurvivesDeinitAndStillFinishes() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let gate = AsyncGate(open: false)
        let tx = client.makeTransaction(id: 7, productID: "lifetime", kind: .nonConsumable)
        client.purchaseHandler = { _, _ in
            await gate.wait()
            return .success(.verified(tx))
        }
        var purchaseTask: Task<PurchaseResult, Never>?
        weak var weakEngine: EntitlementEngine?
        do {
            let store = try makeStore(client: client)
            await store.startupTask.value
            weakEngine = store.engine
            let engine = store.engine
            purchaseTask = Task { await engine.purchase("lifetime") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await waitUntil { client.updateListenerCount == 0 }
        XCTAssertNotNil(weakEngine, "engine stays alive while a purchase is in flight")
        gate.open()
        let result = await purchaseTask!.value
        guard case .pending = result else {
            return XCTFail("expected pending after shutdown, got \(result)")
        }
        XCTAssertEqual(client.finishedTransactionIDs, [7])
        try await waitUntil { weakEngine == nil }
    }

    func testUnconsumedStreamKeepsOnlyLatestValue() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        await store.startupTask.value
        let stream = store.updates

        for id in 1...3 as ClosedRange<UInt64> {
            let tx = client.makeTransaction(id: id, productID: "pro.monthly", expires: Date().addingTimeInterval(Double(id) * 100))
            client.setCurrentEntitlements([tx])
            await store.engine.refreshAll()
        }
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest, store.entitlements)
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

    func testCancelledConsumerIsRemovedFromBroadcaster() async throws {
        let broadcaster = EntitlementBroadcaster()
        let stream = broadcaster.makeStream()
        XCTAssertEqual(broadcaster.subscriberCount, 1)
        let task = Task { for await _ in stream {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value
        try await waitUntil { broadcaster.subscriberCount == 0 }
        let entitlement = Entitlement(productID: "x", subscriptionGroupID: nil, expirationDate: nil,
                                      state: .lifetime, ownership: .purchased, source: .storeKit)
        XCTAssertTrue(broadcaster.replace(with: [entitlement]))
        XCTAssertEqual(broadcaster.current, [entitlement])
    }

    func testStreamInitialValueIsNeverStale() async throws {
        let broadcaster = EntitlementBroadcaster()
        let a = Entitlement(productID: "a", subscriptionGroupID: nil, expirationDate: nil,
                            state: .lifetime, ownership: .purchased, source: .storeKit)
        let b = Entitlement(productID: "b", subscriptionGroupID: nil, expirationDate: nil,
                            state: .lifetime, ownership: .purchased, source: .storeKit)
        let writer = Task.detached {
            for i in 0..<2000 {
                broadcaster.replace(with: i.isMultiple(of: 2) ? [a] : [b])
            }
        }
        for _ in 0..<200 {
            let stream = broadcaster.makeStream()
            var iterator = stream.makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertNotNil(first)
        }
        await writer.value
        let final = broadcaster.current
        let stream = broadcaster.makeStream()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, final)
    }
}

final class WeakEngine {
    weak var engine: EntitlementEngine?
    init(_ engine: EntitlementEngine) { self.engine = engine }
}

extension TransactionListenerTests {
    func testBurstOfUpdatesCoalescesIntoFewRefreshes() async throws {
        let client = FakeStoreKitClient()
        client.currentEntitlementsGate.close()
        client.setCurrentEntitlements([])
        let store = try makeStore(client: client)
        try await waitUntil { client.updateListenerCount == 1 }

        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        for _ in 0..<25 {
            client.emitTransactionUpdate(.verified(tx))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        client.currentEntitlementsGate.open()
        await store.startupTask.value
        try await waitUntil { store.isEntitled(to: "pro.monthly") }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertLessThanOrEqual(client.currentEntitlementsCallCount, 3)
        XCTAssertEqual(client.finishedTransactionIDs, [1])
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
