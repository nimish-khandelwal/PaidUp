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
    private var updateContinuations: [UUID: AsyncStream<TransactionEvent>.Continuation] = [:]
    private var finishLog: [UInt64] = []
    private var tokensLog: [UUID?] = []
    private var syncCalls = 0
    private var productsCalls = 0

    var catalog: [ProductInfo] = [
        ProductInfo(id: "pro.monthly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "pro.yearly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil),
    ]
    var renewalStates: [String: RenewalState] = [:]
    var productsError: Error?
    var syncError: Error?
    var purchaseHandler: @Sendable (String, UUID?) throws -> PurchaseOutcome = { _, _ in .userCancelled }
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

    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: TransactionEvent.self)
        lock.lock()
        updateContinuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.updateContinuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    func renewalState(for transaction: VerifiedTransaction) async -> RenewalState? {
        withLock { renewalStates[transaction.productID] }
    }

    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        let handler = withLock { () -> @Sendable (String, UUID?) throws -> PurchaseOutcome in
            tokensLog.append(appAccountToken)
            return purchaseHandler
        }
        return try handler(id, appAccountToken)
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
