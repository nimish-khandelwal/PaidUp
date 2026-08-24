# PaidUp

[![CI](https://github.com/nimish-khandelwal/PaidUp/actions/workflows/ci.yml/badge.svg)](https://github.com/nimish-khandelwal/PaidUp/actions/workflows/ci.yml)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![iOS 15+](https://img.shields.io/badge/iOS-15%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey)

A small Swift library that answers one question for your iOS app: **what has
this user paid for, right now?** It sits on top of StoreKit 2, keeps the
answer correct as renewals, refunds and family-sharing changes happen, and
gives you a simple way to read it from anywhere in the app.

```swift
import PaidUpKit

let store = PaidUp(
    products: ["pro.monthly", "pro.yearly", "lifetime"],
    userID: currentUser.id,   // attached to every purchase as appAccountToken
    configuration: .default
)

if store.isEntitled(toGroup: "21000001") { unlockPro() }

for await entitlements in store.updates {
    unlockPro(if: !entitlements.isEmpty)
}

let result = await store.purchase("pro.yearly")
```

That is most of the API already. There is also `restore()`, and that's it.
No dependencies, no backend, no UI.

## Why I built it

I shipped subscriptions in a production app and kept running into the same
StoreKit 2 traps everyone hits: the `Transaction.updates` listener that
starts a moment too late and misses a refund, the transaction nobody
`finish()`ed that keeps coming back, the upgrade from monthly to yearly that
locks the user out because the code checked the old product ID, the purchase
that was never tagged with `appAccountToken` so the server could not tell
whose it was. None of this is hard, but it is easy to get subtly wrong, and
every app rewrites it from scratch.

PaidUp is that logic extracted into a package, with the rules written down
and tested:

- It listens to `Transaction.updates` from the moment it exists until it is
  deallocated, so nothing lands while no one is watching.
- Apple decides who is entitled. The answer comes from
  `Transaction.currentEntitlements`; PaidUp never compares expiry dates
  itself, so grace periods and billing retry behave the way Apple defines
  them and a tampered device clock changes nothing.
- Only cryptographically verified transactions count. Unverified ones are
  ignored and reported through `onError`.
- Every transaction is finished exactly once, including ones left over from
  a previous launch.
- The last known answer is cached on disk and loaded synchronously, so the
  very first frame of your app shows the right thing. As soon as StoreKit
  responds, the cache is replaced. The cache never wins over StoreKit.
- `isEntitled` is a plain synchronous call, safe from any thread. All the
  mutable state lives inside one actor.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/nimish-khandelwal/PaidUp.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'PaidUp', '~> 0.1'
```

Prefer a binary? A `PaidUpKit.xcframework.zip` is attached to every release
on GitHub.

(The package also declares macOS 12, but that exists only so the test suite
runs with `swift test`. The SDK is for iOS.)

## Using it

Create one instance early, for example in your `App` struct or app delegate,
and keep it alive for the whole run:

```swift
let store = PaidUp(products: products, userID: user.id, configuration: .default)
```

Ask whether something is unlocked. For subscriptions, check the
*subscription group*, not the product ID. When a user upgrades from monthly
to yearly the product ID changes but the group stays the same:

```swift
store.isEntitled(toGroup: "21000001")   // subscriptions
store.isEntitled(to: "lifetime")        // one-time purchases
```

React to changes. The stream gives you the current set immediately, then a
new set every time something changes:

```swift
for await set in store.updates { render(set) }
```

Buy and restore. Nothing throws; you always get a typed result:

```swift
switch await store.purchase("pro.yearly") {
case .success(let entitlement): // unlocked, already reflected in `entitlements`
case .userCancelled:            // user closed the payment sheet
case .pending:                  // Ask to Buy etc. — arrives via `updates` if approved
case .failed(let error):        // a PaidUpError telling you exactly what happened
}

await store.restore()   // shows an App Store prompt, so only call it from a Restore button
```

## Which states count as entitled

This table is the heart of the library:

| StoreKit says | Entitled? | `Entitlement.state` |
| --- | --- | --- |
| `subscribed` | yes | `.active` |
| `inGracePeriod` | yes | `.gracePeriod` |
| `inBillingRetryPeriod` (no grace) | no | — |
| `expired` / `revoked` | no | — |
| non-consumable, not refunded | yes | `.lifetime` |
| unverified | no, and `onError(.unverified)` fires | — |
| pending (Ask to Buy) | not yet; `purchase()` returns `.pending` | — |

The longer version, including Family Sharing, upgrades and offer codes, is in
[Which subscription states count as entitled, and why](Sources/PaidUpKit/Documentation.docc/EntitlementStates.md).

## What about purchases made on Android or the web?

StoreKit only knows about Apple purchases. If your product also sells through
Google Play or Stripe, the only place that sees everything is your own
server. PaidUp has a small hook for that:

```swift
struct MyBackendProvider: EntitlementProvider {
    func currentEntitlements() async throws -> Set<String> {
        try await api.get("/me/entitlements").productIDs
    }
}

var config = PaidUpConfiguration.default
config.remoteProvider = MyBackendProvider()
```

PaidUp then reports the union of what StoreKit and your server say. One rule
is enforced and tested: your server can *add* entitlements but can never
remove one StoreKit verified locally. A backend outage must never lock out a
customer Apple says has paid.

How to wire the server side, and why missing `appAccountToken` once breaks
attribution forever: [Cross-platform subscriptions](Sources/PaidUpKit/Documentation.docc/CrossPlatform.md).

## Configuration

```swift
var config = PaidUpConfiguration.default
config.remoteProvider = MyBackendProvider()   // optional, default nil
config.remoteTimeout = 5                      // seconds, default 10
config.refreshOnForeground = true             // default true
config.storageDirectory = nil                 // default: App Support/PaidUp/<bundle-id>/<userID>
config.onError = { error in print(error) }    // please set this one
```

`onError` is where every background failure surfaces: `productNotFound`,
`unverified`, `purchaseNotAllowed`, `storeKit`, `storageFailed`,
`remoteProviderFailed`. PaidUp never fails silently, but it only speaks if
you listen.

## What it deliberately does not do

Consumables, paywall screens, receipt parsing, refund requests, and anything
requiring a server. Auto-renewable subscriptions and non-consumables only.
Keeping the scope small is the point.

## Tests

- `swift test` runs 77 tests against a scripted StoreKit stand-in: the state
  table, the merge rule, the disk cache (including the nasty case of being
  deallocated mid-read), purchases, restores, listener lifetime, and
  concurrent reads from eight queues at once. The suite is clean under the
  Thread and Address Sanitizers.
- `Examples/PaidUpSample` is a small SwiftUI app with a StoreKit
  configuration file checked in. Its test targets talk to real StoreKit
  through `SKTestSession`: buy, expire, refund, accelerated renewals, Ask to
  Buy, restore, upgrade. A UI test taps Subscribe, checks the PRO badge
  appears, expires the subscription behind the app's back, relaunches, and
  checks the badge is gone. Run it with `cd Examples/PaidUpSample &&
  xcodegen generate`, open the project, press Cmd-U.

CI runs all of the above on every push, on two iOS simulator versions.

## If something looks wrong

- **User paid but the app is locked.** Set `onError` first. If it prints
  `unverified`, StoreKit rejected the transaction signature. If it prints
  nothing, you are probably checking a product ID where you should be
  checking the group.
- **Sandbox renews every few minutes and my UI flickers.** Renewals change
  the expiration date, so `updates` emits a new set each time. The user is
  still entitled. Base your UI on `isEntitled`, not on comparing sets.
- **Entitled on iPhone but not on iPad.** Same Apple ID: bring the app to the
  foreground or tap Restore. Different Apple IDs: that is how the App Store
  works; Family Sharing is the supported answer.
- **Paid on Android, locked on iOS.** Expected until you wire the remote
  provider above.

More cases, with the reasoning: [Troubleshooting](Sources/PaidUpKit/Documentation.docc/Troubleshooting.md).

## More docs

The full documentation is a DocC catalog: open the package in Xcode and hit
*Product → Build Documentation*, or read the markdown directly in
`Sources/PaidUpKit/Documentation.docc/`. Related reading:
[COMPATIBILITY.md](COMPATIBILITY.md) for the support policy,
[PERFORMANCE.md](PERFORMANCE.md) for binary size and leak measurements,
[CHANGELOG.md](CHANGELOG.md) for history.

## License

MIT. Do what you like with it.
