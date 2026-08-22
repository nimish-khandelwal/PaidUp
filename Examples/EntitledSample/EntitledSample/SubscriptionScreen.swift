//
//  SubscriptionScreen.swift
//  Entitled
//
//  Created by Nimish Khandelwal.
//

import SwiftUI

struct SubscriptionScreen: View {
    @StateObject private var model = SubscriptionStoreModel()

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
        .task { await model.observeEntitlements() }
    }
}
