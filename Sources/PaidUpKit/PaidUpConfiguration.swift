//
//  PaidUpConfiguration.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import Foundation

/// Tuning knobs for an ``PaidUp`` instance.
///
/// Start with ``default`` and override only what you need:
///
/// ```swift
/// var config = PaidUpConfiguration.default
/// config.remoteProvider = MyBackendProvider()
/// config.onError = { error in print(error) }
/// ```
public struct PaidUpConfiguration: Sendable {
    /// Your backend's view of the user's entitlements. Optional; `nil` means
    /// StoreKit is the only source. Default: `nil`.
    public var remoteProvider: (any EntitlementProvider)?

    /// Seconds to wait for the remote provider before giving up and keeping
    /// the last good remote set. Default: 10.
    public var remoteTimeout: TimeInterval

    /// Re-read StoreKit and the remote provider whenever the app returns to
    /// the foreground. Default: `true`.
    public var refreshOnForeground: Bool

    /// Directory for the on-disk cache. `nil` uses
    /// `Application Support/PaidUp/<bundle-id>`. Default: `nil`.
    public var storageDirectory: URL?

    /// Called on an arbitrary queue whenever something fails in the
    /// background. PaidUp never fails silently; if you care, listen here.
    /// Default: `nil`.
    public var onError: (@Sendable (PaidUpError) -> Void)?

    /// The recommended starting point.
    public static let `default` = PaidUpConfiguration()

    public init(
        remoteProvider: (any EntitlementProvider)? = nil,
        remoteTimeout: TimeInterval = 10,
        refreshOnForeground: Bool = true,
        storageDirectory: URL? = nil,
        onError: (@Sendable (PaidUpError) -> Void)? = nil
    ) {
        self.remoteProvider = remoteProvider
        self.remoteTimeout = max(0.1, remoteTimeout)
        self.refreshOnForeground = refreshOnForeground
        self.storageDirectory = storageDirectory
        self.onError = onError
    }

    func normalized() -> PaidUpConfiguration {
        PaidUpConfiguration(
            remoteProvider: remoteProvider,
            remoteTimeout: remoteTimeout,
            refreshOnForeground: refreshOnForeground,
            storageDirectory: storageDirectory,
            onError: onError
        )
    }
}
