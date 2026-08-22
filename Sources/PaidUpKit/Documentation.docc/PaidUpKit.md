# ``PaidUpKit``

A lightweight StoreKit 2 entitlement layer for iOS with a four-symbol API.

## Overview

PaidUp answers one question — *what is this user entitled to right now* —
and keeps that answer correct over time. It listens to `Transaction.updates`
from the moment it exists, computes entitlements from
`Transaction.currentEntitlements`, accepts only verified transactions, caches
the last-known answer to disk so the first frame is right, and exposes the
result as one synchronous value plus an `AsyncStream` of changes.

```swift
let store = PaidUp(
    products: ["pro.monthly", "pro.yearly", "lifetime"],
    userID: currentUser.id,
    configuration: .default
)

if store.isEntitled(toGroup: "21000001") { unlockPro() }

for await entitlements in store.updates {
    unlockPro(if: !entitlements.isEmpty)
}

let result = await store.purchase("pro.yearly")
```

It is not a paywall UI and not a backend. In scope: auto-renewable
subscriptions and non-consumables. Out of scope: consumables, receipts,
refund requests, any server.

## Topics

### Essentials

- <doc:GettingStarted>
- ``PaidUp``
- ``Entitlement``

### The contract

- <doc:EntitlementStates>
- <doc:CrossPlatform>
- <doc:Troubleshooting>

### Configuration

- ``PaidUpConfiguration``
- ``EntitlementProvider``

### Results and errors

- ``PurchaseResult``
- ``RestoreResult``
- ``PaidUpError``
- ``RemoteProviderTimeout``
