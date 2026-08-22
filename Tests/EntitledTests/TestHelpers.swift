//
//  TestHelpers.swift
//  Cheers Vegas Slots
//
//  Created by Nimish Khandelwal.
//

import Foundation
import XCTest
@testable import EntitledKit

/// Scriptable StoreKit: tests set what `currentEntitlements` returns, push
/// events into `Transaction.updates`, decide purchase outcomes, and observe
/// every `finish()` call.
final class FakeStoreKitClient: StoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var entitlementEvents: [TransactionEvent] = []
    private var updateContinuations: [UUID: AsyncStream<TransactionEvent>.Continuation] = [:]
    private var finishLog: [UInt64] = []
    private var tokensLog: [UUID?] = []
    private var syncCalls = 0
    private var productsCalls = 0

    var catalog: [ProductInfo] = [
        ProductInfo(id: "pro.monthly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "pro.yearly", kind: .autoRenewable, subscriptionGroupID: "group.pro"),
        ProductInfo(id: "lifetime", kind: .nonConsumable, subscriptionGroupID: nil),
    ]
    var renewalStates: [String: RenewalState] = [:]
    var productsError: Error?
    var syncError: Error?
    var purchaseHandler: @Sendable (String, UUID?) throws -> PurchaseOutcome = { _, _ in .userCancelled }
    let entitlementsGate = Gate(open: true)

    func products(for ids: Set<String>) async throws -> [ProductInfo] {
        let (error, catalog) = withLock { () -> (Error?, [ProductInfo]) in
            productsCalls += 1
            return (productsError, self.catalog)
        }
        if let error { throw error }
        return catalog.filter { ids.contains($0.id) }
    }

    func currentEntitlements() -> AsyncStream<TransactionEvent> {
        let gate = entitlementsGate
        return AsyncStream { continuation in
            Task {
                await gate.wait()
                let events = self.withLock { self.entitlementEvents }
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func transactionUpdates() -> AsyncStream<TransactionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: TransactionEvent.self)
        lock.lock()
        updateContinuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.updateContinuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    func renewalState(for transaction: VerifiedTransaction) async -> RenewalState? {
        withLock { renewalStates[transaction.productID] }
    }

    func purchase(_ id: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        let handler = withLock { () -> @Sendable (String, UUID?) throws -> PurchaseOutcome in
            tokensLog.append(appAccountToken)
            return purchaseHandler
        }
        return try handler(id, appAccountToken)
    }

    func sync() async throws {
        let error = withLock { () -> Error? in
            syncCalls += 1
            return syncError
        }
        if let error { throw error }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func setEntitlements(_ transactions: [VerifiedTransaction]) {
        setEntitlementEvents(transactions.map { .verified($0) })
    }

    func setEntitlementEvents(_ events: [TransactionEvent]) {
        lock.lock()
        entitlementEvents = events
        lock.unlock()
    }

    func emit(_ event: TransactionEvent) {
        lock.lock()
        let targets = Array(updateContinuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func makeTransaction(
        id: UInt64,
        productID: String,
        kind: ProductKind = .autoRenewable,
        group: String? = "group.pro",
        expires: Date? = Date().addingTimeInterval(3600),
        revoked: Date? = nil,
        upgraded: Bool = false,
        ownership: Entitlement.Ownership = .purchased
    ) -> VerifiedTransaction {
        VerifiedTransaction(
            id: id,
            productID: productID,
            kind: kind,
            subscriptionGroupID: kind == .autoRenewable ? group : nil,
            purchaseDate: Date(),
            expirationDate: kind == .autoRenewable ? expires : nil,
            revocationDate: revoked,
            isUpgraded: upgraded,
            ownership: ownership,
            finish: { [weak self] in self?.recordFinish(id) }
        )
    }

    private func recordFinish(_ id: UInt64) {
        lock.lock()
        finishLog.append(id)
        lock.unlock()
    }

    var finishedIDs: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return finishLog
    }

    var purchaseTokens: [UUID?] {
        lock.lock()
        defer { lock.unlock() }
        return tokensLog
    }

    var syncCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return syncCalls
    }

    var updateListenerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return updateContinuations.count
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool) {
        isOpen = open
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if isOpenNow { return }
        await withCheckedContinuation { continuation in
            enqueue(continuation)
        }
    }

    private var isOpenNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isOpen {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }
}

final class FakeProvider: EntitlementProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Set<String>, Error>]
    private var calls = 0
    var delay: TimeInterval = 0

    init(_ results: Result<Set<String>, Error>...) {
        self.results = results
    }

    func currentEntitlements() async throws -> Set<String> {
        let (next, delay) = take()
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard let next else { return [] }
        return try next.get()
    }

    private func take() -> (Result<Set<String>, Error>?, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let next = results.count > 1 ? results.removeFirst() : results.first
        return (next, delay)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EntitledError] = []

    var handler: @Sendable (EntitledError) -> Void {
        { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.storage.append(error)
            self.lock.unlock()
        }
    }

    var errors: [EntitledError] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct TestError: Error, Equatable {}

let allProducts: Set<String> = ["pro.monthly", "pro.yearly", "lifetime"]

extension XCTestCase {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitledTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func makeStore(
        client: FakeStoreKitClient,
        products: Set<String> = allProducts,
        userID: UUID? = UUID(),
        directory: URL? = nil,
        configure: (inout EntitledConfiguration) -> Void = { _ in }
    ) throws -> Entitled {
        var config = EntitledConfiguration.default
        config.storageDirectory = try directory ?? makeTemporaryDirectory()
        configure(&config)
        return Entitled(products: products, userID: userID, configuration: config, client: client)
    }

    func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out after \(timeout)s waiting for condition")
    }
}
