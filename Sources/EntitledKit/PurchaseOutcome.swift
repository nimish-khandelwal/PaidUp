//
//  PurchaseOutcome.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

enum PurchaseOutcome: Sendable {
    case success(TransactionEvent)
    case userCancelled
    case pending
}

enum PurchaseFailure: Error, Sendable {
    case notAllowed
}
