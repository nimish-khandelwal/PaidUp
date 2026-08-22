//
//  EntitlementDiskCache.swift
//  PaidUp
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
        var remoteSubscriptionGroupIDs: [String: String]
        var savedAt: Date

        init(
            entitlements: [Entitlement],
            remote: [String],
            remoteSubscriptionGroupIDs: [String: String] = [:],
            savedAt: Date
        ) {
            self.entitlements = entitlements
            self.remote = remote
            self.remoteSubscriptionGroupIDs = remoteSubscriptionGroupIDs
            self.savedAt = savedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entitlements = try container.decode([Entitlement].self, forKey: .entitlements)
            remote = try container.decode([String].self, forKey: .remote)
            remoteSubscriptionGroupIDs = try container.decodeIfPresent(
                [String: String].self, forKey: .remoteSubscriptionGroupIDs
            ) ?? [:]
            savedAt = try container.decode(Date.self, forKey: .savedAt)
        }
    }

    let fileURL: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("entitlements.json")
    }

    static func defaultDirectory(userID: UUID?) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "default"
        return base
            .appendingPathComponent("PaidUp", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(userID?.uuidString ?? "anonymous", isDirectory: true)
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
