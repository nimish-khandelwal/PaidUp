//
//  SubscriptionStoreModel.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import PaidUpKit
import Foundation

/// One `PaidUp` for the app's lifetime. The UI test launches the app with
/// `-paidUpResetCache` to start from a clean cache.
@MainActor
final class SubscriptionStoreModel: ObservableObject {
    @Published var entitlements: Set<Entitlement> = []
    @Published var lastResult = "—"
    @Published var lastError = "none"

    let store: PaidUp

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaidUpSample", isDirectory: true)
        if CommandLine.arguments.contains("-paidUpResetCache") {
            try? FileManager.default.removeItem(at: directory)
        }

        var config = PaidUpConfiguration.default
        config.storageDirectory = directory
        let errorBox = ErrorHandlerBox()
        config.onError = { error in
            Task { @MainActor in errorBox.owner?.lastError = "\(error)" }
        }
        store = PaidUp(
            products: SampleProducts.all,
            userID: UUID(uuidString: "00000000-0000-4000-8000-0000000000AA"),
            configuration: config
        )
        errorBox.owner = self
        entitlements = store.entitlements
    }

    var isPro: Bool {
        entitlements.contains {
            $0.subscriptionGroupID == SampleProducts.proGroup || $0.productID == SampleProducts.lifetime
        }
    }

    func observeEntitlements() async {
        for await entitlements in store.updates {
            self.entitlements = entitlements
        }
    }

    func subscribe() async {
        let result = await store.purchase(SampleProducts.monthly)
        switch result {
        case .success(let entitlement): lastResult = "purchased \(entitlement.productID)"
        case .userCancelled: lastResult = "cancelled"
        case .pending: lastResult = "pending approval"
        case .failed(let error): lastResult = "failed: \(error)"
        }
    }

    func restore() async {
        switch await store.restore() {
        case .restored(let set): lastResult = "restored \(set.count) entitlement(s)"
        case .failed(let error): lastResult = "restore failed: \(error)"
        }
    }
}

final class ErrorHandlerBox: @unchecked Sendable {
    weak var owner: SubscriptionStoreModel?
}
