//
//  ProductInfo.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

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
