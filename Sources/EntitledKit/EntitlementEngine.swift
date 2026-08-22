//
//  EntitlementEngine.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// The single place all mutable state lives: the `Transaction.updates`
/// listener, the storeKitEntitlements and remoteProductIDs entitlement sets, the cache, and the
/// refresh chains. Everything public reads a lock-guarded broadcaster this
/// actor rewrites on every change.
actor EntitlementEngine {
    private let productIDs: Set<String>
    private let userID: UUID?
    private let config: EntitledConfiguration
    private let client: StoreKitClient
    private let broadcaster: EntitlementBroadcaster
    private let diskCache: EntitlementDiskCache?

    private var productCatalog: [String: ProductInfo] = [:]
    private var storeKitEntitlements: Set<Entitlement>
    private var remoteProductIDs: Set<String>
    private var finishedTransactionIDs: Set<UInt64> = []
    private(set) var hasReceivedStoreKitAnswer = false

    private var listenerTask: Task<Void, Never>?
    private var storeKitRefreshChain: Task<Void, Never>?
    private var remoteRefreshChain: Task<Void, Never>?
    private var isShutDown = false

    init(
        products: Set<String>,
        userID: UUID?,
        config: EntitledConfiguration,
        client: StoreKitClient,
        broadcaster: EntitlementBroadcaster
    ) {
        self.productIDs = products
        self.userID = userID
        self.config = config
        self.client = client
        self.broadcaster = broadcaster

        let directory = config.storageDirectory ?? EntitlementDiskCache.defaultDirectory()
        var loadedCache: EntitlementDiskCache?
        var cached: EntitlementDiskCache.CachedEntitlements?
        do {
            let diskCache = try EntitlementDiskCache(directory: directory)
            loadedCache = diskCache
            cached = try diskCache.load()
        } catch {
            config.onError?(.storageFailed(underlying: error))
        }
        self.diskCache = loadedCache
        self.storeKitEntitlements = Set(cached?.entitlements ?? [])
        self.remoteProductIDs = Set(cached?.remote ?? [])
        broadcaster.replace(with: Self.merge(storeKit: storeKitEntitlements, remote: remoteProductIDs, catalog: [:]))
    }

    deinit {
        listenerTask?.cancel()
        storeKitRefreshChain?.cancel()
        remoteRefreshChain?.cancel()
    }

    func start() async {
        guard listenerTask == nil, !isShutDown else { return }
        let client = self.client
        listenerTask = Task { [weak self] in
            for await event in client.transactionUpdates() {
                guard let self, !Task.isCancelled else { return }
                await self.handleTransactionUpdate(event)
            }
        }
        await loadProductCatalog()
        await refreshFromStoreKit()
        await refreshRemote()
    }

    func shutdown() {
        isShutDown = true
        listenerTask?.cancel()
        listenerTask = nil
        storeKitRefreshChain?.cancel()
        remoteRefreshChain?.cancel()
        broadcaster.finishAll()
    }

    func refreshAll() async {
        await refreshFromStoreKit()
        await refreshRemote()
    }

    func purchase(_ id: String) async -> PurchaseResult {
        guard productIDs.contains(id) else { return .failed(.productNotFound(id)) }

        let outcome: PurchaseOutcome
        do {
            outcome = try await client.purchase(id, appAccountToken: userID)
        } catch PurchaseFailure.notAllowed {
            return .failed(.purchaseNotAllowed)
        } catch let error as EntitledError {
            return .failed(error)
        } catch {
            return .failed(.storeKit(underlying: error))
        }

        switch outcome {
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        case .success(.unverified(let productID)):
            config.onError?(.unverified(productID: productID))
            return .failed(.unverified(productID: productID))
        case .success(.verified(let tx)):
            await refreshFromStoreKit()
            await finishOnce(tx)
            await refreshRemote()
            if let entitlement = storeKitEntitlements.first(where: { $0.productID == tx.productID }) {
                return .success(entitlement)
            }
            let state = await client.renewalState(for: tx)
            if let entitlement = Self.entitlement(from: tx, renewalState: state) {
                return .success(entitlement)
            }
            return .failed(.productNotFound(id))
        }
    }

    func restore() async -> RestoreResult {
        do {
            try await client.sync()
        } catch {
            return .failed(.storeKit(underlying: error))
        }
        await refreshFromStoreKit()
        await refreshRemote()
        return .restored(broadcaster.current)
    }

    func refreshFromStoreKit() async {
        guard !isShutDown else { return }
        let previous = storeKitRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.recomputeFromStoreKit()
        }
        storeKitRefreshChain = task
        await task.value
    }

    func refreshRemote() async {
        guard config.remoteProvider != nil, !isShutDown else { return }
        let previous = remoteRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.fetchRemoteEntitlements()
        }
        remoteRefreshChain = task
        await task.value
    }


    private func handleTransactionUpdate(_ event: TransactionEvent) async {
        switch event {
        case .verified(let tx):
            await refreshFromStoreKit()
            await finishOnce(tx)
        case .unverified(let productID):
            config.onError?(.unverified(productID: productID))
        }
    }

    private func loadProductCatalog() async {
        guard productCatalog.isEmpty, !productIDs.isEmpty else { return }
        do {
            let products = try await client.products(for: productIDs)
            productCatalog = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        } catch {
            config.onError?(.storeKit(underlying: error))
        }
    }

    private func recomputeFromStoreKit() async {
        guard !Task.isCancelled else { return }
        var found: [VerifiedTransaction] = []
        for await event in client.currentEntitlements() {
            switch event {
            case .verified(let tx):
                found.append(tx)
            case .unverified(let productID):
                config.onError?(.unverified(productID: productID))
            }
        }

        var fresh: Set<Entitlement> = []
        for tx in found {
            let state = tx.kind == .autoRenewable ? await client.renewalState(for: tx) : nil
            if let entitlement = Self.entitlement(from: tx, renewalState: state) {
                fresh.insert(entitlement)
            }
        }
        for tx in found {
            await finishOnce(tx)
        }

        hasReceivedStoreKitAnswer = true
        storeKitEntitlements = fresh
        publishMergedEntitlements()
    }

    private func fetchRemoteEntitlements() async {
        guard let provider = config.remoteProvider, !Task.isCancelled else { return }
        do {
            let ids = try await withTimeout(config.remoteTimeout) {
                try await provider.currentEntitlements()
            }
            remoteProductIDs = ids
            publishMergedEntitlements()
        } catch {
            config.onError?(.remoteProviderFailed(underlying: error))
        }
    }

    private func finishOnce(_ tx: VerifiedTransaction) async {
        guard !finishedTransactionIDs.contains(tx.id) else { return }
        finishedTransactionIDs.insert(tx.id)
        await tx.finish()
    }

    private func publishMergedEntitlements() {
        broadcaster.replace(with: Self.merge(storeKit: storeKitEntitlements, remote: remoteProductIDs, catalog: productCatalog))
        writeCache()
    }

    private func writeCache() {
        guard let diskCache else { return }
        do {
            try diskCache.save(
                EntitlementDiskCache.CachedEntitlements(
                    entitlements: Array(storeKitEntitlements),
                    remote: Array(remoteProductIDs).sorted(),
                    savedAt: Date()
                )
            )
        } catch {
            config.onError?(.storageFailed(underlying: error))
        }
    }

    static func entitlement(
        from tx: VerifiedTransaction,
        renewalState: RenewalState?
    ) -> Entitlement? {
        guard tx.revocationDate == nil, !tx.isUpgraded else { return nil }
        switch tx.kind {
        case .nonConsumable:
            return Entitlement(
                productID: tx.productID,
                subscriptionGroupID: nil,
                expirationDate: nil,
                state: .lifetime,
                ownership: tx.ownership,
                source: .storeKit
            )
        case .autoRenewable:
            return Entitlement(
                productID: tx.productID,
                subscriptionGroupID: tx.subscriptionGroupID,
                expirationDate: tx.expirationDate,
                state: renewalState == .inGracePeriod ? .gracePeriod : .active,
                ownership: tx.ownership,
                source: .storeKit
            )
        case .other:
            return nil
        }
    }

    static func merge(
        storeKit storeKitEntitlements: Set<Entitlement>,
        remote remoteProductIDs: Set<String>,
        catalog productCatalog: [String: ProductInfo]
    ) -> Set<Entitlement> {
        var result = storeKitEntitlements
        let storeKitProductIDs = Set(storeKitEntitlements.map(\.productID))
        for id in remoteProductIDs where !storeKitProductIDs.contains(id) {
            result.insert(
                Entitlement(
                    productID: id,
                    subscriptionGroupID: productCatalog[id]?.subscriptionGroupID,
                    expirationDate: nil,
                    state: .active,
                    ownership: .purchased,
                    source: .remote
                )
            )
        }
        return result
    }
}

func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RemoteProviderTimeout(seconds: seconds)
        }
        guard let first = try await group.next() else {
            throw RemoteProviderTimeout(seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}
