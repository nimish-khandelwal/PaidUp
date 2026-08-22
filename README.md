# Entitled

[![CI](https://github.com/nimish-khandelwal/Entitled/actions/workflows/ci.yml/badge.svg)](https://github.com/nimish-khandelwal/Entitled/actions/workflows/ci.yml)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![iOS 15+](https://img.shields.io/badge/iOS-15%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey)

**A tiny Swift library that answers "what is this user entitled to right
now?" from StoreKit 2 — and keeps that answer correct over time.**

```swift
import EntitledKit

let store = Entitled(
    products: ["pro.monthly", "pro.yearly", "lifetime"],
    userID: currentUser.id,          // becomes appAccountToken on every purchase
    configuration: .default
)

if store.isEntitled(toGroup: "21000001") { unlockPro() }

for await entitlements in store.updates {
    unlockPro(if: !entitlements.isEmpty)
}

let result = await store.purchase("pro.yearly")
```

That's the whole API: `init`, `isEntitled` / `entitlements`, `updates`,
`purchase` (+ `restore`). Zero dependencies.

## The problem

Every subscription app rewrites the same piece badly:

- Forget to listen to `Transaction.updates` from launch → a refund, a renewal
  or an Ask-to-Buy approval lands while no one is listening.
- Forget to `finish()` a transaction → it comes back forever.
- Trust an unverified transaction → a jailbroken device gets Pro for free.
- Re-derive "expired" from dates → grace periods and billing retry are wrong
  and the device clock becomes an attack surface.
- Check the product ID → an upgrade from monthly to yearly locks the user out.
- Forget `appAccountToken` once → your server can never attribute that
  purchase to your user.
- Read StoreKit on the main thread at launch → the paywall flashes locked.

## The idea

Entitled is **just the entitlement layer**. Not a paywall, not a backend.

1. **Listen from the first moment.** `Transaction.updates` is consumed from
   `init` until `deinit`; nothing is missed.
2. **Apple decides yes/no.** Entitlements come from
   `Transaction.currentEntitlements`; the SDK never compares dates. Renewal
   state is read only to label `.active` / `.gracePeriod`.
3. **Verified only.** Unverified transactions are absent, and reported.
4. **Finish exactly once.** Every transaction, including ones from a
   previous launch.
5. **Right on the first frame.** The last-known set is cached to disk, read
   synchronously at `init`, and replaced the moment StoreKit answers.
6. **Your server can add, never remove.** The optional provider hook merges
   `union(StoreKit, remote)` for cross-platform purchases, and a server
   outage can never lock out a user Apple says has paid.
7. **Read from anywhere.** `isEntitled` is a synchronous, lock-guarded
   read; all mutation lives in one actor. No singletons, no swizzling.

## Install

**Swift Package Manager**

```swift
.package(url: "https://github.com/nimish-khandelwal/Entitled.git", from: "0.1.0")
```

**CocoaPods**

```ruby
pod 'Entitled', '~> 0.1'
```

**Binary** — `EntitledKit.xcframework.zip` is attached to each GitHub release.

## Using it

```swift
// 1. Create one instance and keep it alive (App / AppDelegate / root model).
let store = Entitled(products: products, userID: user.id, configuration: .default)

// 2. Ask from anywhere, any thread, no await.
store.isEntitled(toGroup: "21000001")   // subscriptions: check the group
store.isEntitled(to: "lifetime")        // non-consumables: check the product

// 3. React to changes — emits the current set immediately, then on every change.
for await set in store.updates { render(set) }

// 4. Buy and restore with typed results. Nothing throws.
switch await store.purchase("pro.yearly") {
case .success(let entitlement): …
case .userCancelled: …
case .pending: …                       // Ask to Buy; arrives via `updates` later
case .failed(let error): …             // EntitledError
}
await store.restore()                   // user-initiated button only
```

## Which states count as entitled

| StoreKit renewal state | Entitled? | `Entitlement.state` |
| --- | --- | --- |
| `subscribed` | **yes** | `.active` |
| `inGracePeriod` | **yes** | `.gracePeriod` |
| `inBillingRetryPeriod` (no grace) | no | — |
| `expired` / `revoked` | no | — |
| non-consumable, not revoked | **yes** | `.lifetime` |
| unverified | no, + `onError(.unverified)` | — |
| pending (Ask to Buy) | not yet; `purchase()` → `.pending` | — |

Full reasoning, Family Sharing, upgrades, offers and the remote merge rule:
[*Which subscription states count as entitled, and why*](Sources/EntitledKit/Documentation.docc/EntitlementStates.md).

## Cross-platform purchases

StoreKit cannot see a Google Play subscription. Your server can. Wire it:

```swift
struct MyBackendProvider: EntitlementProvider {
    func currentEntitlements() async throws -> Set<String> {
        try await api.get("/me/entitlements").productIDs
    }
}
var config = EntitledConfiguration.default
config.remoteProvider = MyBackendProvider()
```

Read [*Cross-platform subscriptions*](Sources/EntitledKit/Documentation.docc/CrossPlatform.md)
for the `appAccountToken` trap and the architecture diagram.

## Configuration

```swift
var config = EntitledConfiguration.default
config.remoteProvider = MyBackendProvider()   // optional (default nil)
config.remoteTimeout = 5                      // seconds (default 10)
config.refreshOnForeground = true             // default true
config.storageDirectory = nil                 // default App Support/Entitled/<bundle-id>
config.onError = { error in print(error) }    // set this!
```

Errors you can get in `onError` / results: `productNotFound`, `unverified`,
`purchaseNotAllowed`, `storeKit`, `storageFailed`, `remoteProviderFailed`.

## Scope

**In:** auto-renewable subscriptions, non-consumables ("lifetime").
**Out:** consumables, paywall UI, receipts / `AppTransaction`, refund
requests, any backend.

## Testing

- `swift test` — 52 tests on a scripted StoreKit fake: the state table, the
  merge rule, the cache, purchase/restore, listener lifecycle, concurrent
  reads from 8 queues. Clean under `--sanitize=thread`.
- `Examples/EntitledSample` — SwiftUI app with a checked-in
  `Entitled.storekit`, an `SKTestSession` suite (purchase, expiry,
  accelerated renewals, refund, Ask to Buy, restore, upgrade) and an XCUITest
  that taps *Subscribe*, asserts the PRO badge, expires the subscription,
  relaunches and asserts it is gone. `cd Examples/EntitledSample && xcodegen
  generate` then ⌘U.

## Quick troubleshooting

- **User paid but still locked?** Set `onError`. `unverified` = StoreKit
  rejected the signature. Otherwise check the group, not the product ID.
- **Sandbox renews every 5 minutes and my logic flips?** Each renewal changes
  `expirationDate`, so `updates` emits a new set — still entitled. Drive UI
  from `isEntitled`, not set equality.
- **Entitled on iPhone, not on iPad?** Same Apple ID → foreground or
  `restore()`. Different Apple ID → that's the App Store, use Family Sharing.
- **Paid on Android, locked on iOS?** You need the remote provider.

Longer answers: [Troubleshooting](Sources/EntitledKit/Documentation.docc/Troubleshooting.md).

## Docs

Build the DocC catalog in Xcode (*Product → Build Documentation*) or read the
articles directly under `Sources/EntitledKit/Documentation.docc/`. See also
[COMPATIBILITY.md](COMPATIBILITY.md), [PERFORMANCE.md](PERFORMANCE.md),
[CHANGELOG.md](CHANGELOG.md).

## License

MIT.
