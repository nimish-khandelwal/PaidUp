//
//  StoreKitClient.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// The seam between the SDK's logic and StoreKit 2. `LiveStoreKitClient`
/// wraps the real framework; tests script a fake so the state machine runs
/// under `swift test` on macOS where `SKTestSession` is unavailable.
protocol StoreKitClient: Sendable {
    func products(for ids: Set<String>) async throws -> [ProductInfo]
    func currentEntitlements() -> AsyncStream<TransactionEvent>
    func transactionUpdates() -> AsyncStream<TransactionEvent>
    func unfinishedTransactions() -> AsyncStream<TransactionEvent>
    func renewalStates(for transactions: [VerifiedTransaction]) async -> [UInt64: RenewalState]
    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome
    func sync() async throws
}
