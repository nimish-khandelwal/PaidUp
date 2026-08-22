//
//  EntitlementSnapshot.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Lock-guarded copy of the entitlement set that the actor rewrites on every
/// change, so `isEntitled` is a synchronous read from any thread. Also fans
/// `updates` out to every subscribed continuation.
final class EntitlementSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<Entitlement> = []
    private var continuations: [UUID: AsyncStream<Set<Entitlement>>.Continuation] = [:]

    var current: Set<Entitlement> {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func replace(with new: Set<Entitlement>) -> Bool {
        lock.lock()
        guard new != value else {
            lock.unlock()
            return false
        }
        value = new
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(new)
        }
        return true
    }

    func makeStream() -> AsyncStream<Set<Entitlement>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Set<Entitlement>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        lock.lock()
        continuations[id] = continuation
        let initial = value
        lock.unlock()
        continuation.yield(initial)
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
