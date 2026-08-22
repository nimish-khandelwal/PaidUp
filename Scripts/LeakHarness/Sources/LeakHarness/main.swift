//
//  main.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation
@testable import PaidUpKit

final class HarnessStoreKitClient: StoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TransactionEvent>.Continuation] = [:]
    private var entitled = true

    func products(for ids: Set<String>) async throws -> [ProductInfo] {
        [ProductInfo(id: "pro.monthly", kind: .autoRenewable, subscriptionGroupID: "g"),
         ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil)]
    }
    func currentEntitlements() -> AsyncStream<TransactionEvent> {
        let on = withLock { entitled }
        return AsyncStream { c in
            if on {
                c.yield(.verified(tx(1, "pro.monthly", .autoRenewable)))
                c.yield(.verified(tx(2, "lifetime", .nonConsumable)))
            }
            c.finish()
        }
    }
    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        let id = UUID()
        let (s, c) = AsyncStream.makeStream(of: TransactionEvent.self)
        withLock { continuations[id] = c }
        c.onTermination = { [weak self] _ in _ = self?.withLock { self?.continuations[id] = nil } }
        return s
    }
    func unfinishedTransactions() -> AsyncStream<TransactionEvent> {
        AsyncStream { $0.finish() }
    }
    func renewalStates(for transactions: [VerifiedTransaction]) async -> [UInt64: RenewalState] {
        transactions.reduce(into: [:]) { $0[$1.id] = .subscribed }
    }
    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        .success(.verified(tx(3, id, .autoRenewable)))
    }
    func sync() async throws {}
    func emitTransactionUpdate() { for c in withLock({ Array(continuations.values) }) { c.yield(.verified(tx(1, "pro.monthly", .autoRenewable))) } }
    func toggle() { withLock { entitled.toggle() } }
    var listeners: Int { withLock { continuations.count } }
    private func tx(_ id: UInt64, _ pid: String, _ kind: ProductKind) -> VerifiedTransaction {
        VerifiedTransaction(id: id, productID: pid, kind: kind, subscriptionGroupID: kind == .autoRenewable ? "g" : nil,
                            purchaseDate: Date(), expirationDate: kind == .autoRenewable ? Date().addingTimeInterval(3600) : nil,
                            revocationDate: nil, isUpgraded: false, ownership: .purchased, finish: {})
    }
    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

struct HarnessRemoteProvider: EntitlementProvider {
    func currentEntitlements() async throws -> Set<String> { ["remote.pro"] }
}

let client = HarnessStoreKitClient()
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LeakHarness-\(UUID().uuidString)")
let sem = DispatchSemaphore(value: 0)
Task {
    for cycle in 0..<50 {
        var config = PaidUpConfiguration.default
        config.storageDirectory = dir
        config.remoteProvider = HarnessRemoteProvider()
        let store = PaidUp(products: ["pro.monthly", "lifetime"], userID: UUID(), configuration: config, client: client)
        await store.startupTask.value
        let stream = store.updates
        let consumer = Task { for await _ in stream {} }
        for _ in 0..<20 {
            client.toggle()
            await store.engine.refreshAll()
            client.emitTransactionUpdate()
            _ = store.isEntitled(to: "pro.monthly")
        }
        _ = await store.purchase("pro.monthly")
        _ = await store.restore()
        if cycle % 2 == 0 { consumer.cancel() }
        _ = store.entitlements
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    print("listeners remaining: \(client.listeners)")
    try? FileManager.default.removeItem(at: dir)
    sem.signal()
}
sem.wait()
