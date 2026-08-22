//
//  EntitlementDiskCache.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Atomic JSON file holding the last-known entitlement set, so the app has
/// the right answer on the first frame and offline. Never trusted over a
/// fresh StoreKit answer; it only bridges the gap before one arrives.
struct EntitlementDiskCache: Sendable {
    struct CachedEntitlements: Codable, Sendable, Equatable {
        var entitlements: [Entitlement]
        var remote: [String]
        var savedAt: Date
    }

    let fileURL: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("entitlements.json")
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "default"
        return base
            .appendingPathComponent("Entitled", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    func load() throws -> CachedEntitlements? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CachedEntitlements.self, from: data)
    }

    func save(_ contents: CachedEntitlements) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
