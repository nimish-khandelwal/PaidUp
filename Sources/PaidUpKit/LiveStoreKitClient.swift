//
//  LiveStoreKitClient.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation
import StoreKit

/// Real StoreKit 2. Nothing newer than iOS 15 is used; see COMPATIBILITY.md.
struct LiveStoreKitClient: StoreKitClient {
    func products(for ids: Set<String>) async throws -> [ProductInfo] {
        try await Product.products(for: ids).map { product in
            ProductInfo(
                id: product.id,
                kind: Self.productKind(of: product.type),
                subscriptionGroupID: product.subscription?.subscriptionGroupID
            )
        }
    }

    func currentEntitlements() -> AsyncStream<TransactionEvent> {
        Self.makeEventStream(from: Transaction.currentEntitlements)
    }

    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        Self.makeEventStream(from: Transaction.updates)
    }

    func unfinishedTransactions() -> AsyncStream<TransactionEvent> {
        Self.makeEventStream(from: Transaction.unfinished)
    }

    func renewalStates(for transactions: [VerifiedTransaction]) async -> [UInt64: RenewalState] {
        var result: [UInt64: RenewalState] = [:]
        let subscriptions = transactions.filter { $0.kind == .autoRenewable && $0.subscriptionGroupID != nil }
        let groupIDs = Set(subscriptions.compactMap(\.subscriptionGroupID))
        for groupID in groupIDs {
            let statuses = (try? await Product.SubscriptionInfo.status(for: groupID)) ?? []
            for transaction in subscriptions where transaction.subscriptionGroupID == groupID {
                let match = statuses.first { Self.verifiedID(of: $0) == transaction.id }
                    ?? statuses.first { Self.verifiedProductID(of: $0) == transaction.productID }
                if let match, let state = Self.renewalState(from: match.state) {
                    result[transaction.id] = state
                }
            }
        }
        return result
    }

    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [id]).first else {
            throw PaidUpError.productNotFound(id)
        }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken {
            options.insert(.appAccountToken(appAccountToken))
        }

        let result: Product.PurchaseResult
        do {
            result = try await Task { @MainActor in
                try await product.purchase(options: options)
            }.value
        } catch Product.PurchaseError.purchaseNotAllowed {
            throw PurchaseFailure.notAllowed
        } catch Product.PurchaseError.productUnavailable {
            throw PaidUpError.productNotFound(id)
        } catch StoreKitError.userCancelled {
            return .userCancelled
        }

        switch result {
        case .success(let verification):
            return .success(Self.transactionEvent(from: verification))
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    private static func makeEventStream(
        from source: Transaction.Transactions
    ) -> AsyncStream<TransactionEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await result in source {
                    if Task.isCancelled { break }
                    continuation.yield(transactionEvent(from: result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func transactionEvent(from result: VerificationResult<Transaction>) -> TransactionEvent {
        switch result {
        case .verified(let tx):
            return .verified(
                VerifiedTransaction(
                    id: tx.id,
                    productID: tx.productID,
                    kind: productKind(of: tx.productType),
                    subscriptionGroupID: tx.subscriptionGroupID,
                    purchaseDate: tx.purchaseDate,
                    expirationDate: tx.expirationDate,
                    revocationDate: tx.revocationDate,
                    isUpgraded: tx.isUpgraded,
                    ownership: tx.ownershipType == .familyShared ? .familyShared : .purchased,
                    finish: { await tx.finish() }
                )
            )
        case .unverified(let tx, _):
            return .unverified(productID: tx.productID)
        }
    }

    private static func verifiedID(of status: Product.SubscriptionInfo.Status) -> UInt64? {
        guard case .verified(let tx) = status.transaction else { return nil }
        return tx.id
    }

    private static func verifiedProductID(of status: Product.SubscriptionInfo.Status) -> String? {
        guard case .verified(let tx) = status.transaction else { return nil }
        return tx.productID
    }

    private static func productKind(of type: Product.ProductType) -> ProductKind {
        switch type {
        case .autoRenewable: return .autoRenewable
        case .nonConsumable: return .nonConsumable
        default: return .other
        }
    }

    private static func renewalState(from state: Product.SubscriptionInfo.RenewalState) -> RenewalState? {
        switch state {
        case .subscribed: return .subscribed
        case .inGracePeriod: return .inGracePeriod
        case .inBillingRetryPeriod: return .inBillingRetryPeriod
        case .expired: return .expired
        case .revoked: return .revoked
        default: return nil
        }
    }
}
