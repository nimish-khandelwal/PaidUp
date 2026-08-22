//
//  ThreadSafetyTests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import PaidUpKit

final class ThreadSafetyTests: XCTestCase {
    func testConcurrentReadsFromManyQueuesWhileMutating() async throws {
        let client = FakeStoreKitClient()
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setCurrentEntitlements([tx])
        let store = try makeStore(client: client)
        await store.startupTask.value

        let mutator = Task {
            for i in 0..<200 {
                if i.isMultiple(of: 2) {
                    client.setCurrentEntitlements([])
                } else {
                    client.setCurrentEntitlements([tx])
                }
                await store.engine.refreshAll()
            }
        }

        let reads = ThreadSafeCounter()
        for queueIndex in 0..<8 {
            let queue = DispatchQueue(label: "reader-\(queueIndex)", attributes: .concurrent)
            for _ in 0..<500 {
                queue.async {
                    _ = store.isEntitled(to: "pro.monthly")
                    _ = store.isEntitled(toGroup: "group.pro")
                    _ = store.entitlements
                    reads.increment()
                }
            }
        }
        try await waitUntil { reads.value == 4000 }
        await mutator.value

        XCTAssertEqual(reads.value, 4000)
        XCTAssertTrue(store.isEntitled(to: "pro.monthly"))
    }

    func testConcurrentPurchaseRestoreAndUpdates() async throws {
        let client = FakeStoreKitClient()
        client.setCurrentEntitlements([])
        let tx = client.makeTransaction(id: 1, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in
            client.setCurrentEntitlements([tx])
            return .success(.verified(tx))
        }
        let store = try makeStore(client: client)
        await store.startupTask.value

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    if i.isMultiple(of: 3) {
                        _ = await store.restore()
                    } else {
                        _ = await store.purchase("pro.yearly")
                    }
                }
                group.addTask {
                    client.emitTransactionUpdate(.verified(tx))
                }
            }
        }
        let sentinel = client.makeTransaction(id: 2, productID: "lifetime", kind: .nonConsumable)
        client.setCurrentEntitlements([tx, sentinel])
        client.emitTransactionUpdate(.verified(sentinel))
        try await waitUntil { client.finishedTransactionIDs.contains(2) }
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(client.finishedTransactionIDs, [1, 2])
    }

    func testBroadcasterIsThreadSafeUnderContention() {
        let broadcaster = EntitlementBroadcaster()
        let group = DispatchGroup()
        let entitlement = Entitlement(productID: "x", subscriptionGroupID: nil, expirationDate: nil,
                                      state: .lifetime, ownership: .purchased, source: .storeKit)
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<1000 {
                    if (i + j).isMultiple(of: 2) {
                        broadcaster.replace(with: [entitlement])
                    } else {
                        broadcaster.replace(with: [])
                    }
                    _ = broadcaster.current
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertLessThanOrEqual(broadcaster.current.count, 1)
    }
}

final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
