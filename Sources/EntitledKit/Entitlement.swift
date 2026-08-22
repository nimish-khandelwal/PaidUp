//
//  Entitlement.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// One thing the user currently has access to.
///
/// Only entitled states exist as values: if a product is expired, revoked,
/// or in billing retry without a grace period, there is simply no
/// `Entitlement` for it. See <doc:EntitlementStates> for the full table.
public struct Entitlement: Hashable, Codable, Sendable {
    /// The App Store product identifier, e.g. `"pro.monthly"`.
    public let productID: String

    /// Subscription group identifier. `nil` for non-consumables and for
    /// remote entitlements whose product is not in the local catalog.
    public let subscriptionGroupID: String?

    /// When the current period ends. `nil` for non-consumables and remote
    /// entitlements. Informational only — never re-derive "is entitled"
    /// from this date; StoreKit already did.
    public let expirationDate: Date?

    /// Why the user is entitled right now.
    public let state: State

    /// Whether the user bought it, or a family member did.
    public let ownership: Ownership

    /// Where the answer came from.
    public let source: Source

    public init(
        productID: String,
        subscriptionGroupID: String?,
        expirationDate: Date?,
        state: State,
        ownership: Ownership,
        source: Source
    ) {
        self.productID = productID
        self.subscriptionGroupID = subscriptionGroupID
        self.expirationDate = expirationDate
        self.state = state
        self.ownership = ownership
        self.source = source
    }

    /// Labels why an entitlement is active. Every case is "entitled".
    public enum State: String, Hashable, Codable, Sendable {
        /// Subscription is paid up.
        case active
        /// Billing failed but Apple is still granting access while it retries.
        /// A good moment to show a "fix your payment method" banner.
        case gracePeriod
        /// Non-consumable, owned forever unless refunded.
        case lifetime
    }

    public enum Ownership: String, Hashable, Codable, Sendable {
        /// Purchased by this Apple ID.
        case purchased
        /// Granted through Family Sharing; disappears if the purchaser
        /// leaves the family or disables sharing.
        case familyShared
    }

    public enum Source: String, Hashable, Codable, Sendable {
        /// Verified by StoreKit 2 on this device.
        case storeKit
        /// Reported by the host's ``EntitlementProvider`` (e.g. a Google
        /// Play purchase mirrored through the host's backend).
        case remote
    }
}
