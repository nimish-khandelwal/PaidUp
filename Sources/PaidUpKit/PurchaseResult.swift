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
    /// Waiting on Ask to Buy or an SCA challenge. If approved later, the
    /// entitlement arrives through ``PaidUp/updates`` automatically.
    case pending
    case failed(PaidUpError)
}
