//
//  EntitlementProvider.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Hook for the host's own backend — the only thing that can see purchases
/// made on other platforms (Google Play, web). See <doc:CrossPlatform>.
///
/// Return the product IDs your server currently considers active for the
/// signed-in user. PaidUp reports `union(StoreKit, remote)`: the provider
/// can **add** entitlements but can never remove one StoreKit has verified
/// locally, so a server outage can never lock out a paying Apple customer.
public protocol EntitlementProvider: Sendable {
    func currentEntitlements() async throws -> Set<String>
}
