//
//  FakeStoreKitClient.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation
import XCTest
@testable import PaidUpKit

/// Scriptable StoreKit: tests set what `currentEntitlements` returns, push
/// events into `Transaction.updates`, decide purchase outcomes, and observe
/// every `finish()` call.
final class FakeStoreKitClient: StoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var entitlementEvents: [TransactionEvent] = []
    private var unfinishedEvents: [TransactionEvent] = []
    private var replayedUpdates: [TransactionEvent] = []
    private var updateContinuations: [UUID: AsyncStream<TransactionEvent>.Continuation] = [:]
    private var finishLog: [UInt64] = []
    private var tokensLog: [UUID?] = []
    private var syncCalls = 0
    private var productsCalls = 0
    private var currentEntitlementsCalls = 0

    var catalog: [ProductInfo] = [
        ProductInfo(id: "pro.monthly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "pro.yearly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil),
    ]
    var renewalStateByProductID: [String: RenewalState] = [:]
    var productsError: Error?
    var syncError: Error?
    var purchaseHandler: @Sendable (String, UUID?) async throws -> PurchaseOutcome = { _, _ in .userCancelled }
    let currentEntitlementsGate = AsyncGate(open: true)

    func products(for ids: Set<String>) async throws -> [ProductInfo] {
        let (error, catalog) = withLock { () -> (Error?, [ProductInfo]) in
            productsCalls += 1
            return (productsError, self.catalog)
        }
        if let error { throw error }
        return catalog.filter { ids.contains($0.id) }
    }

    func currentEntitlements() -> AsyncStream<TransactionEvent> {
        withLock { currentEntitlementsCalls += 1 }
        let gate = currentEntitlementsGate
        return AsyncStream { continuation in
            Task {
                await gate.wait()
                let events = self.withLock { self.entitlementEvents }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func unfinishedTransactions() -> AsyncStream<TransactionEvent> {
        let events = withLock { unfinishedEvents }
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: TransactionEvent.self)
        lock.lock()
        updateContinuations[id] = continuation
        let replay = replayedUpdates
        lock.unlock()
        for event in replay {
            continuation.yield(event)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.updateContinuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    func renewalStates(for transactions: [VerifiedTransaction]) async -> [UInt64: RenewalState] {
        withLock {
            transactions.reduce(into: [:]) { result, tx in
                result[tx.id] = renewalStateByProductID[tx.productID]
            }
        }
    }

    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        let handler = withLock { () -> @Sendable (String, UUID?) async throws -> PurchaseOutcome in
            tokensLog.append(appAccountToken)
            return purchaseHandler
        }
        return try await handler(id, appAccountToken)
    }

    func sync() async throws {
        let error = withLock { () -> Error? in
            syncCalls += 1
            return syncError
        }
        if let error { throw error }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func setCurrentEntitlements(_ transactions: [VerifiedTransaction]) {
        setCurrentEntitlementEvents(transactions.map { .verified($0) })
    }

    func setReplayedUpdates(_ events: [TransactionEvent]) {
        lock.lock()
        replayedUpdates = events
        lock.unlock()
    }

    func setUnfinishedTransactions(_ transactions: [VerifiedTransaction]) {
        lock.lock()
        unfinishedEvents = transactions.map { .verified($0) }
        lock.unlock()
    }

    func setCurrentEntitlementEvents(_ events: [TransactionEvent]) {
        lock.lock()
        entitlementEvents = events
        lock.unlock()
    }

    func emitTransactionUpdate(_ event: TransactionEvent) {
        lock.lock()
        let targets = Array(updateContinuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func makeTransaction(
        id: UInt64,
        productID: String,
        kind: ProductKind = .autoRenewable,
        group: String? = "group.pro",
        expires: Date? = Date().addingTimeInterval(3600),
        revoked: Date? = nil,
        upgraded: Bool = false,
        ownership: Entitlement.Ownership = .purchased
    ) -> VerifiedTransaction {
        VerifiedTransaction(
            id: id,
            productID: productID,
            kind: kind,
            subscriptionGroupID: kind == .autoRenewable ? group : nil,
            purchaseDate: Date(),
            expirationDate: kind == .autoRenewable ? expires : nil,
            revocationDate: revoked,
            isUpgraded: upgraded,
            ownership: ownership,
            finish: { [weak self] in self?.recordFinish(id) }
        )
    }

    private func recordFinish(_ id: UInt64) {
        lock.lock()
        finishLog.append(id)
        lock.unlock()
    }

    var finishedTransactionIDs: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return finishLog
    }

    var appAccountTokens: [UUID?] {
        lock.lock()
        defer { lock.unlock() }
        return tokensLog
    }

    var currentEntitlementsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentEntitlementsCalls
    }

    var syncCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return syncCalls
    }

    var updateListenerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return updateContinuations.count
    }
}
