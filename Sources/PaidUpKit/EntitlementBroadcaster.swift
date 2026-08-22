//
//  EntitlementBroadcaster.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Holds the latest entitlement set behind a lock, so `isEntitled` is a
/// synchronous read from any thread, and broadcasts every change to all
/// subscribed `updates` streams.
final class EntitlementBroadcaster: @unchecked Sendable {
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
        for continuation in continuations.values {
            continuation.yield(new)
        }
        lock.unlock()
        return true
    }

    func makeStream() -> AsyncStream<Set<Entitlement>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Set<Entitlement>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        lock.lock()
        continuations[id] = continuation
        continuation.yield(value)
        lock.unlock()
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
