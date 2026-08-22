//
//  StoreKitClient.swift
//  Cheers Vegas Slots
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

struct ProductInfo: Sendable, Hashable {
    let id: String
    let kind: ProductKind
    let subscriptionGroupID: String?
}

enum ProductKind: Sendable, Hashable {
    case autoRenewable
    case nonConsumable
    case other
}

enum RenewalState: Sendable, Hashable {
    case subscribed
    case inGracePeriod
    case inBillingRetryPeriod
    case expired
    case revoked
}

/// A transaction StoreKit already verified, flattened to the fields the
/// state machine needs plus a `finish` hook. Whoever consumes it owns
/// finishing it exactly once.
struct VerifiedTransaction: Sendable {
    let id: UInt64
    let productID: String
    let kind: ProductKind
    let subscriptionGroupID: String?
    let purchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool
    let ownership: Entitlement.Ownership
    let finish: @Sendable () async -> Void
}

enum TransactionEvent: Sendable {
    case verified(VerifiedTransaction)
    case unverified(productID: String)
}

enum PurchaseOutcome: Sendable {
    case success(TransactionEvent)
    case userCancelled
    case pending
}

enum PurchaseFailure: Error, Sendable {
    case notAllowed
}
