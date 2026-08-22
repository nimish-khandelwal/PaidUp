//
//  EntitledCore.swift
//  Cheers Vegas Slots
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// The single place all mutable state lives: the `Transaction.updates`
/// listener, the local and remote entitlement sets, the cache, and the
/// refresh chains. Everything public reads a lock-guarded snapshot this
/// actor rewrites on every change.
actor EntitledCore {
    private let productIDs: Set<String>
    private let userID: UUID?
    private let config: EntitledConfiguration
    private let client: StoreKitClient
    private let snapshot: EntitlementSnapshot
    private let store: EntitlementStore?

    private var catalog: [String: ProductInfo] = [:]
    private var local: Set<Entitlement>
    private var remote: Set<String>
    private var finishedIDs: Set<UInt64> = []
    private(set) var hasStoreKitAnswer = false

    private var listenerTask: Task<Void, Never>?
    private var localRefreshChain: Task<Void, Never>?
    private var remoteRefreshChain: Task<Void, Never>?
    private var isShutDown = false

    init(
        products: Set<String>,
        userID: UUID?,
        config: EntitledConfiguration,
        client: StoreKitClient,
        snapshot: EntitlementSnapshot
    ) {
        self.productIDs = products
        self.userID = userID
        self.config = config
        self.client = client
        self.snapshot = snapshot

        let directory = config.storageDirectory ?? EntitlementStore.defaultDirectory()
        var loadedStore: EntitlementStore?
        var cached: EntitlementStore.Snapshot?
        do {
            let store = try EntitlementStore(directory: directory)
            loadedStore = store
            cached = try store.load()
        } catch {
            config.onError?(.storageFailed(underlying: error))
        }
        self.store = loadedStore
        self.local = Set(cached?.entitlements ?? [])
        self.remote = Set(cached?.remote ?? [])
        snapshot.replace(with: Self.merge(local: local, remote: remote, catalog: [:]))
    }

    deinit {
        listenerTask?.cancel()
        localRefreshChain?.cancel()
        remoteRefreshChain?.cancel()
    }

    func start() async {
        guard listenerTask == nil, !isShutDown else { return }
        let client = self.client
        listenerTask = Task { [weak self] in
            for await event in client.transactionUpdates() {
                guard let self, !Task.isCancelled else { return }
                await self.handle(update: event)
            }
        }
        await loadCatalog()
        await refreshLocal()
        await refreshRemote()
    }

    func shutdown() {
        isShutDown = true
        listenerTask?.cancel()
        listenerTask = nil
        localRefreshChain?.cancel()
        remoteRefreshChain?.cancel()
        snapshot.finishAll()
    }

    func refreshAll() async {
        await refreshLocal()
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
            await refreshLocal()
            await finishOnce(tx)
            await refreshRemote()
            if let entitlement = local.first(where: { $0.productID == tx.productID }) {
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
        await refreshLocal()
        await refreshRemote()
        return .restored(snapshot.current)
    }

    func refreshLocal() async {
        guard !isShutDown else { return }
        let previous = localRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performLocalRefresh()
        }
        localRefreshChain = task
        await task.value
    }

    func refreshRemote() async {
        guard config.remoteProvider != nil, !isShutDown else { return }
        let previous = remoteRefreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRemoteRefresh()
        }
        remoteRefreshChain = task
        await task.value
    }

    var currentLocal: Set<Entitlement> { local }
    var currentRemote: Set<String> { remote }
    var finishedTransactionIDs: Set<UInt64> { finishedIDs }

    private func handle(update event: TransactionEvent) async {
        switch event {
        case .verified(let tx):
            await refreshLocal()
            await finishOnce(tx)
        case .unverified(let productID):
            config.onError?(.unverified(productID: productID))
        }
    }

    private func loadCatalog() async {
        guard catalog.isEmpty, !productIDs.isEmpty else { return }
        do {
            let products = try await client.products(for: productIDs)
            catalog = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        } catch {
            config.onError?(.storeKit(underlying: error))
        }
    }

    private func performLocalRefresh() async {
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

        hasStoreKitAnswer = true
        local = fresh
        publish()
    }

    private func performRemoteRefresh() async {
        guard let provider = config.remoteProvider, !Task.isCancelled else { return }
        do {
            let ids = try await withTimeout(config.remoteTimeout) {
                try await provider.currentEntitlements()
            }
            remote = ids
            publish()
        } catch {
            config.onError?(.remoteProviderFailed(underlying: error))
        }
    }

    private func finishOnce(_ tx: VerifiedTransaction) async {
        guard !finishedIDs.contains(tx.id) else { return }
        finishedIDs.insert(tx.id)
        await tx.finish()
    }

    private func publish() {
        snapshot.replace(with: Self.merge(local: local, remote: remote, catalog: catalog))
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(
                EntitlementStore.Snapshot(
                    entitlements: Array(local),
                    remote: Array(remote).sorted(),
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
        local: Set<Entitlement>,
        remote: Set<String>,
        catalog: [String: ProductInfo]
    ) -> Set<Entitlement> {
        var result = local
        let localIDs = Set(local.map(\.productID))
        for id in remote where !localIDs.contains(id) {
            result.insert(
                Entitlement(
                    productID: id,
                    subscriptionGroupID: catalog[id]?.subscriptionGroupID,
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
