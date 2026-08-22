//
//  EntitledSampleApp.swift
//  Cheers Vegas Slots
//
//  Created by Nimish Khandelwal.
//

import EntitledKit
import SwiftUI

@main
struct EntitledSampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum Products {
    static let monthly = "pro.monthly"
    static let yearly = "pro.yearly"
    static let lifetime = "lifetime"
    static let proGroup = "21000001"
    static let all: Set<String> = [monthly, yearly, lifetime]
}

/// One `Entitled` for the app's lifetime. The UI test launches the app with
/// `-entitledResetCache` to start from a clean cache.
@MainActor
final class StoreModel: ObservableObject {
    @Published var entitlements: Set<Entitlement> = []
    @Published var lastResult = "—"
    @Published var lastError = "none"

    let store: Entitled

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitledSample", isDirectory: true)
        if CommandLine.arguments.contains("-entitledResetCache") {
            try? FileManager.default.removeItem(at: directory)
        }

        var config = EntitledConfiguration.default
        config.storageDirectory = directory
        let errorBox = ErrorBox()
        config.onError = { error in
            Task { @MainActor in errorBox.owner?.lastError = "\(error)" }
        }
        store = Entitled(
            products: Products.all,
            userID: UUID(uuidString: "00000000-0000-4000-8000-0000000000AA"),
            configuration: config
        )
        errorBox.owner = self
        entitlements = store.entitlements
    }

    var isPro: Bool {
        entitlements.contains {
            $0.subscriptionGroupID == Products.proGroup || $0.productID == Products.lifetime
        }
    }

    func observe() async {
        for await entitlements in store.updates {
            self.entitlements = entitlements
        }
    }

    func subscribe() async {
        let result = await store.purchase(Products.monthly)
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

final class ErrorBox: @unchecked Sendable {
    weak var owner: StoreModel?
}

struct ContentView: View {
    @StateObject private var model = StoreModel()

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Text("Entitled Sample")
                    .font(.title)
                if model.isPro {
                    Text("PRO")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.yellow)
                        .cornerRadius(6)
                        .accessibilityIdentifier("proBadge")
                }
            }
            Button("Subscribe") {
                Task { await model.subscribe() }
            }
            .accessibilityIdentifier("subscribeButton")
            Button("Restore") {
                Task { await model.restore() }
            }
            .accessibilityIdentifier("restoreButton")
            Text("Last result: \(model.lastResult)")
                .font(.footnote)
                .accessibilityIdentifier("lastResultLabel")
            Text("Last error: \(model.lastError)")
                .font(.footnote)
                .accessibilityIdentifier("lastErrorLabel")
            Text(model.entitlements.map(\.productID).sorted().joined(separator: ", "))
                .font(.footnote)
                .accessibilityIdentifier("entitlementsLabel")
        }
        .padding()
        .task { await model.observe() }
    }
}
