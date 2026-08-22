//
//  EntitledError.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Every failure Entitled can surface. No `NSError` blobs, no silent drops.
///
/// `purchase()` and `restore()` return these inside their typed results.
/// Background failures (unverified transactions, cache I/O, remote provider)
/// arrive through ``EntitledConfiguration/onError``.
public enum EntitledError: Error, Sendable {
    /// The product ID is not in the `products` set passed to `init`, or the
    /// App Store does not know it.
    case productNotFound(String)

    /// StoreKit returned a transaction whose signature failed verification.
    /// It is treated as absent; the user is not entitled through it.
    case unverified(productID: String)

    /// Purchases are disabled on this device (parental controls, MDM, or
    /// the account cannot make payments).
    case purchaseNotAllowed

    /// Any other StoreKit failure, wrapped.
    case storeKit(underlying: Error)

    /// Reading or writing the on-disk entitlement cache failed. The SDK
    /// keeps working from memory.
    case storageFailed(underlying: Error)

    /// The host's ``EntitlementProvider`` threw or timed out. The last good
    /// remote set is kept.
    case remoteProviderFailed(underlying: Error)
}

extension EntitledError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .productNotFound(let id):
            return "Entitled: product not found – \(id)"
        case .unverified(let id):
            return "Entitled: unverified transaction ignored – \(id)"
        case .purchaseNotAllowed:
            return "Entitled: purchases are not allowed on this device"
        case .storeKit(let underlying):
            return "Entitled: StoreKit failure – \(underlying)"
        case .storageFailed(let underlying):
            return "Entitled: cache failure – \(underlying)"
        case .remoteProviderFailed(let underlying):
            return "Entitled: remote provider failure – \(underlying)"
        }
    }
}

/// The provider timed out; surfaced as the `underlying` error of
/// ``EntitledError/remoteProviderFailed(underlying:)``.
public struct RemoteProviderTimeout: Error, Sendable, Equatable {
    public let seconds: TimeInterval
}
