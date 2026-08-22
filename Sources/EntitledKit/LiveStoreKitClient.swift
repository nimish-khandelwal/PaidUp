//
//  LiveStoreKitClient.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation
import StoreKit

/// Real StoreKit 2. Every newer API is guarded; iOS 15 is the floor.
struct LiveStoreKitClient: StoreKitClient {
    func products(for ids: Set<String>) async throws -> [ProductInfo] {
        try await Product.products(for: ids).map { product in
            ProductInfo(
                id: product.id,
                kind: Self.kind(of: product.type),
                subscriptionGroupID: product.subscription?.subscriptionGroupID
            )
        }
    }

    func currentEntitlements() -> AsyncStream<TransactionEvent> {
        Self.stream(Transaction.currentEntitlements)
    }

    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        Self.stream(Transaction.updates)
    }

    func renewalState(for transaction: VerifiedTransaction) async -> RenewalState? {
        guard transaction.kind == .autoRenewable,
              let groupID = transaction.subscriptionGroupID
        else { return nil }

        let statuses: [Product.SubscriptionInfo.Status]
        if #available(iOS 17.0, macOS 14.0, *) {
            statuses = (try? await Product.SubscriptionInfo.status(for: groupID)) ?? []
        } else {
            let products = (try? await Product.products(for: [transaction.productID])) ?? []
            statuses = (try? await products.first?.subscription?.status) ?? []
        }

        for status in statuses {
            guard case .verified(let tx) = status.transaction,
                  tx.productID == transaction.productID
            else { continue }
            return Self.map(status.state)
        }
        return nil
    }

    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [id]).first else {
            throw EntitledError.productNotFound(id)
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
        } catch StoreKitError.userCancelled {
            return .userCancelled
        }

        switch result {
        case .success(let verification):
            return .success(Self.map(verification))
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

    private static func stream(
        _ source: Transaction.Transactions
    ) -> AsyncStream<TransactionEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await result in source {
                    if Task.isCancelled { break }
                    continuation.yield(map(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func map(_ result: VerificationResult<Transaction>) -> TransactionEvent {
        switch result {
        case .verified(let tx):
            return .verified(
                VerifiedTransaction(
                    id: tx.id,
                    productID: tx.productID,
                    kind: kind(of: tx.productType),
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

    private static func kind(of type: Product.ProductType) -> ProductKind {
        switch type {
        case .autoRenewable: return .autoRenewable
        case .nonConsumable: return .nonConsumable
        default: return .other
        }
    }

    private static func map(_ state: Product.SubscriptionInfo.RenewalState) -> RenewalState? {
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
