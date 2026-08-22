//
//  FakeEntitlementProvider.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation
@testable import PaidUpKit

final class FakeEntitlementProvider: EntitlementProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Set<String>, Error>]
    private var calls = 0
    private var delaySeconds: TimeInterval = 0
    var ignoresCancellation = false

    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return delaySeconds }
        set { lock.lock(); delaySeconds = newValue; lock.unlock() }
    }

    init(_ results: Result<Set<String>, Error>...) {
        self.results = results
    }

    func currentEntitlements() async throws -> Set<String> {
        let (next, delay) = take()
        if delay > 0 {
            if ignoresCancellation {
                let deadline = Date().addingTimeInterval(delay)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            } else {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        guard let next else { return [] }
        return try next.get()
    }

    private func take() -> (Result<Set<String>, Error>?, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let next = results.count > 1 ? results.removeFirst() : results.first
        return (next, delaySeconds)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
