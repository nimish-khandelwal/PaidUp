//
//  StoreKitClient.swift
//  Entitled
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
    func renewalState(for transaction: VerifiedTransaction) async -> RenewalState?
    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome
    func sync() async throws
}
