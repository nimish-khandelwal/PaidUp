//
//  FakeEntitlementProvider.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation
@testable import EntitledKit

final class FakeEntitlementProvider: EntitlementProvider, @unchecked Sendable {
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
