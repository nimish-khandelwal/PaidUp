//
//  VerifiedTransaction.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

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
