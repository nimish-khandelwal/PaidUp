//
//  EntitlementEngine.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// The single place all mutable state lives: the `Transaction.updates`
/// listener, the StoreKit and remote entitlement sets, the disk cache, and
/// the refresh chains. Everything public reads the ``EntitlementBroadcaster``
/// this actor rewrites on every change.
actor EntitlementEngine {
    private let productIDs: Set<String>
    private let userID: UUID?
    private let config: PaidUpConfiguration
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
    private var storeKitRefreshQueued = false
    private var remoteRefreshChain: Task<Void, Never>?
    private var remoteRefreshQueued = false
    private var isShutDown = false

    init(
        products: Set<String>,
        userID: UUID?,
        config: PaidUpConfiguration,
        client: StoreKitClient,
        broadcaster: EntitlementBroadcaster
    ) {
        self.productIDs = products
        self.userID = userID
        self.config = config
        self.client = client
        self.broadcaster = broadcaster

        let directory = config.storageDirectory ?? EntitlementDiskCache.defaultDirectory(userID: userID)
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
        self.remoteProductIDs = config.remoteProvider == nil ? [] : Set(cached?.remote ?? [])
        let seedCatalog = (cached?.remoteSubscriptionGroupIDs ?? [:]).reduce(into: [String: ProductInfo]()) {
            $0[$1.key] = ProductInfo(id: $1.key, kind: .autoRenewable, subscriptionGroupID: $1.value)
        }
        broadcaster.replace(with: Self.merge(storeKit: storeKitEntitlements, remote: remoteProductIDs, catalog: seedCatalog))
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
                guard let self else { return }
                Task { await self.handleTransactionUpdate(event) }
                if Task.isCancelled { return }
            }
        }
        let catalogLoad = Task { [weak self] in await self?.loadProductCatalog() }
        await refreshFromStoreKit()
        guard !isShutDown else { return }
        await finishUnfinishedTransactions()
        await catalogLoad.value
        guard !isShutDown else { return }
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
        if productCatalog.isEmpty {
            await loadProductCatalog()
        }
        await refreshRemote()
    }

    func purchase(_ id: String) async -> PurchaseResult {
        guard productIDs.contains(id) else { return .failed(.productNotFound(id)) }
        if productCatalog.isEmpty {
            await loadProductCatalog()
        }
        if productCatalog[id]?.kind == .other {
            return .failed(.productNotFound(id))
        }

        let outcome: PurchaseOutcome
        do {
            outcome = try await client.purchase(id, appAccountToken: userID)
        } catch PurchaseFailure.notAllowed {
            return .failed(.purchaseNotAllowed)
        } catch let error as PaidUpError {
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
            Task { [weak self] in await self?.refreshRemote() }
            if let entitlement = storeKitEntitlements.first(where: { $0.productID == tx.productID }) {
                return .success(entitlement)
            }
            return tx.kind == .other ? .failed(.productNotFound(id)) : .pending
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
        if storeKitRefreshQueued, let queued = storeKitRefreshChain {
            await queued.value
            return
        }
        storeKitRefreshQueued = true
        let previous = storeKitRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.runQueuedStoreKitRefresh()
        }
        storeKitRefreshChain = task
        await task.value
    }

    func refreshRemote() async {
        guard config.remoteProvider != nil, !isShutDown else { return }
        if remoteRefreshQueued, let queued = remoteRefreshChain {
            await queued.value
            return
        }
        remoteRefreshQueued = true
        let previous = remoteRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.runQueuedRemoteRefresh()
        }
        remoteRefreshChain = task
        await task.value
    }

    private func runQueuedStoreKitRefresh() async {
        storeKitRefreshQueued = false
        guard !isShutDown else { return }
        await recomputeFromStoreKit()
    }

    private func runQueuedRemoteRefresh() async {
        remoteRefreshQueued = false
        guard !isShutDown else { return }
        await fetchRemoteEntitlements()
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

    private func finishUnfinishedTransactions() async {
        for await event in client.unfinishedTransactions() {
            if case .verified(let tx) = event {
                await finishOnce(tx)
            }
        }
    }

    private func loadProductCatalog() async {
        guard productCatalog.isEmpty, !productIDs.isEmpty else { return }
        do {
            let products = try await client.products(for: productIDs)
            productCatalog = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            if !remoteProductIDs.isEmpty {
                publishMergedEntitlements()
            }
        } catch is CancellationError {
            return
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
        guard !Task.isCancelled, !isShutDown else { return }

        let subscriptions = found.filter { $0.kind == .autoRenewable }
        let states = subscriptions.isEmpty ? [:] : await client.renewalStates(for: subscriptions)
        let previous = storeKitEntitlements
        var fresh: Set<Entitlement> = []
        for tx in found {
            let state = states[tx.id] ?? Self.previousRenewalState(for: tx.productID, in: previous)
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
            guard !isShutDown, !Task.isCancelled else { return }
            remoteProductIDs = ids
            publishMergedEntitlements()
        } catch is CancellationError {
            return
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
        let changed = broadcaster.replace(
            with: Self.merge(storeKit: storeKitEntitlements, remote: remoteProductIDs, catalog: productCatalog)
        )
        if changed {
            writeCache()
        }
    }

    private func writeCache() {
        guard let diskCache else { return }
        do {
            try diskCache.save(
                EntitlementDiskCache.CachedEntitlements(
                    entitlements: Array(storeKitEntitlements),
                    remote: Array(remoteProductIDs).sorted(),
                    remoteSubscriptionGroupIDs: remoteProductIDs.reduce(into: [:]) { groups, id in
                        groups[id] = productCatalog[id]?.subscriptionGroupID
                    },
                    savedAt: Date()
                )
            )
        } catch {
            config.onError?(.storageFailed(underlying: error))
        }
    }

    static func previousRenewalState(
        for productID: String,
        in entitlements: Set<Entitlement>
    ) -> RenewalState? {
        guard let previous = entitlements.first(where: { $0.productID == productID && $0.source == .storeKit })
        else { return nil }
        return previous.state == .gracePeriod ? .inGracePeriod : nil
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
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let resumer = OnceResumer(continuation)
        let work = Task {
            do {
                resumer.resume(.success(try await operation()))
            } catch {
                resumer.resume(.failure(error))
            }
        }
        let timer = Task {
            guard seconds.isFinite else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            resumer.resume(.failure(RemoteProviderTimeout(seconds: seconds)))
            work.cancel()
        }
        resumer.onResume = { timer.cancel() }
    }
}

/// Resumes a continuation at most once, no matter how many racers finish.
final class OnceResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cleanup: (() -> Void)?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    var onResume: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return cleanup }
        set { lock.lock(); cleanup = newValue; lock.unlock() }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let cleanup = self.cleanup
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
        cleanup?()
    }
}
