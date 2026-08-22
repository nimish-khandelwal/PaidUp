//
//  RestoreResult.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Outcome of ``PaidUp/restore()``.
public enum RestoreResult: Sendable {
    /// The full entitlement set after syncing with the App Store.
    case restored(Set<Entitlement>)
    case failed(PaidUpError)
}
