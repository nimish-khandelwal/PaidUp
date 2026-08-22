//
//  TestSupport.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation
import XCTest
@testable import EntitledKit

final class AsyncGate: @unchecked Sendable {
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
