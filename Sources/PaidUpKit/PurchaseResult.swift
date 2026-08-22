//
//  PurchaseResult.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Outcome of ``PaidUp/purchase(_:)``. Never throws; every branch is typed.
public enum PurchaseResult: Sendable {
    /// Verified, finished, and already reflected in ``PaidUp/entitlements``.
    case success(Entitlement)
    /// The user dismissed the payment sheet.
    case userCancelled
    /// StoreKit accepted the purchase but the user is not entitled yet: Ask
    /// to Buy, an SCA challenge, or a deferred change. When it takes effect
    /// the entitlement arrives through ``PaidUp/updates`` automatically.
    case pending
    case failed(PaidUpError)
}
