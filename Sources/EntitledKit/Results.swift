//
//  Results.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Outcome of ``Entitled/purchase(_:)``. Never throws; every branch is typed.
public enum PurchaseResult: Sendable {
    /// Verified, finished, and already reflected in ``Entitled/entitlements``.
    case success(Entitlement)
    /// The user dismissed the payment sheet.
    case userCancelled
    /// Waiting on Ask to Buy or an SCA challenge. If approved later, the
    /// entitlement arrives through ``Entitled/updates`` automatically.
    case pending
    case failed(EntitledError)
}

/// Outcome of ``Entitled/restore()``.
public enum RestoreResult: Sendable {
    /// The full entitlement set after syncing with the App Store.
    case restored(Set<Entitlement>)
    case failed(EntitledError)
}
