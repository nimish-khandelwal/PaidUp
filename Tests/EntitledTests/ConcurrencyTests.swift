//
//  ConcurrencyTests.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import XCTest
@testable import EntitledKit

final class ConcurrencyTests: XCTestCase {
    func testConcurrentReadsFromManyQueuesWhileMutating() async throws {
        let client = FakeStoreKitClient()
        let tx = client.makeTransaction(id: 1, productID: "pro.monthly")
        client.setEntitlements([tx])
        let store = try makeStore(client: client)
        await store.startTask.value

        let mutator = Task {
            for i in 0..<200 {
                if i.isMultiple(of: 2) {
                    client.setEntitlements([])
                } else {
                    client.setEntitlements([tx])
                }
                await store.core.refreshAll()
            }
        }

        let reads = ReadCounter()
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
        client.setEntitlements([])
        let tx = client.makeTransaction(id: 1, productID: "pro.yearly")
        client.purchaseHandler = { _, _ in
            client.setEntitlements([tx])
            return .success(.verified(tx))
        }
        let store = try makeStore(client: client)
        await store.startTask.value

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
                    client.emit(.verified(tx))
                }
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.isEntitled(to: "pro.yearly"))
        XCTAssertEqual(client.finishedIDs, [1])
    }

    func testSnapshotIsThreadSafeUnderContention() {
        let snapshot = EntitlementSnapshot()
        let group = DispatchGroup()
        let entitlement = Entitlement(productID: "x", subscriptionGroupID: nil, expirationDate: nil,
                                      state: .lifetime, ownership: .purchased, source: .storeKit)
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<1000 {
                    if (i + j).isMultiple(of: 2) {
                        snapshot.replace(with: [entitlement])
                    } else {
                        snapshot.replace(with: [])
                    }
                    _ = snapshot.current
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertLessThanOrEqual(snapshot.current.count, 1)
    }
}

final class ReadCounter: @unchecked Sendable {
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
