//
//  Entitled.swift
//  Cheers Vegas Slots
//
//  Created by Nimish Khandelwal.
//

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// A lightweight StoreKit 2 entitlement layer.
///
/// ```swift
/// let store = Entitled(
///     products: ["pro.monthly", "pro.yearly", "lifetime"],
///     userID: currentUser.id,
///     configuration: .default
/// )
///
/// if store.isEntitled(to: "pro.monthly") { unlockPro() }
///
/// for await entitlements in store.updates {
///     unlockPro(if: !entitlements.isEmpty)
/// }
///
/// let result = await store.purchase("pro.yearly")
/// ```
///
/// ## Guarantees
/// - Listens to `Transaction.updates` from the moment the instance exists,
///   so renewals, refunds, revocations and Ask-to-Buy approvals are never
///   missed; the listener stops when the instance deallocates.
/// - Only `VerificationResult.verified` transactions count. Unverified ones
///   are treated as absent and reported via ``EntitledConfiguration/onError``.
/// - Every transaction is finished exactly once.
/// - `isEntitled` is a synchronous read from any thread; all mutation lives
///   in one actor.
/// - The last-known set is cached to disk so the first frame is right, and
///   replaced the moment StoreKit answers. The cache never outranks StoreKit.
/// - Every `purchase()` carries your `userID` as `appAccountToken`.
/// - A remote provider can add entitlements, never remove locally verified
///   ones.
/// - No singletons, no swizzling, no main-thread assumptions, no UI.
public final class Entitled: @unchecked Sendable {
    let core: EntitledCore
    let startTask: Task<Void, Never>
    private let snapshot: EntitlementSnapshot
    #if canImport(UIKit) && !os(watchOS)
    private let foregroundObserver: ForegroundObserver?
    #endif

    /// Creates an independent instance and starts listening immediately.
    ///
    /// - Parameters:
    ///   - products: Product IDs you sell. `purchase` accepts only these.
    ///   - userID: Your user's stable UUID; sent as `appAccountToken` on every
    ///     purchase so App Store Server Notifications can be attributed to
    ///     your user. Pass `nil` only if you have no accounts.
    ///   - configuration: Tuning knobs; start with `.default`.
    public convenience init(
        products: Set<String>,
        userID: UUID?,
        configuration: EntitledConfiguration = .default
    ) {
        self.init(
            products: products,
            userID: userID,
            configuration: configuration,
            client: LiveStoreKitClient()
        )
    }

    init(
        products: Set<String>,
        userID: UUID?,
        configuration: EntitledConfiguration,
        client: StoreKitClient
    ) {
        let configuration = configuration.normalized()
        let snapshot = EntitlementSnapshot()
        let core = EntitledCore(
            products: products,
            userID: userID,
            config: configuration,
            client: client,
            snapshot: snapshot
        )
        self.core = core
        self.snapshot = snapshot
        self.startTask = Task { await core.start() }

        #if canImport(UIKit) && !os(watchOS)
        if configuration.refreshOnForeground {
            foregroundObserver = ForegroundObserver { [weak core] in
                await core?.refreshAll()
            }
        } else {
            foregroundObserver = nil
        }
        #endif
    }

    deinit {
        startTask.cancel()
        let core = self.core
        Task { await core.shutdown() }
    }

    /// Everything the user has right now. Synchronous; safe from any thread.
    public var entitlements: Set<Entitlement> {
        snapshot.current
    }

    /// `true` if an entitlement for this exact product ID exists.
    public func isEntitled(to productID: String) -> Bool {
        snapshot.current.contains { $0.productID == productID }
    }

    /// `true` if any entitlement belongs to this subscription group. Use this
    /// for subscriptions — it stays `true` across upgrades and downgrades,
    /// where the product ID changes.
    public func isEntitled(toGroup groupID: String) -> Bool {
        snapshot.current.contains { $0.subscriptionGroupID == groupID }
    }

    /// Emits the current set immediately, then again on every change. Each
    /// call returns an independent stream; it ends when this instance
    /// deallocates.
    public var updates: AsyncStream<Set<Entitlement>> {
        snapshot.makeStream()
    }

    /// Buys a product, tagging it with `userID` as `appAccountToken`. Never
    /// throws; never leaves a transaction unfinished.
    public func purchase(_ productID: String) async -> PurchaseResult {
        await core.purchase(productID)
    }

    /// Calls `AppStore.sync()` and recomputes. Prompts for App Store
    /// credentials — call only from a user-initiated *Restore* button.
    public func restore() async -> RestoreResult {
        await core.restore()
    }
}
