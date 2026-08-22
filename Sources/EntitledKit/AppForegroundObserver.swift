//
//  AppForegroundObserver.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Re-reads StoreKit and the remote provider when the app returns to the
/// foreground. `NotificationCenter` only — no swizzling, nothing to wire up.
final class AppForegroundObserver: @unchecked Sendable {
    private let refresh: @Sendable () async -> Void
    private var observer: NSObjectProtocol?

    init(refresh: @escaping @Sendable () async -> Void) {
        self.refresh = refresh
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let refresh = self.refresh
            Task { await refresh() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif
