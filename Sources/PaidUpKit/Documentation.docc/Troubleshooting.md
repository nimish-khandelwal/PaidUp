# Troubleshooting

Written for the reports that actually come in.

## First: set `onError`

```swift
config.onError = { error in print(error) }
```

PaidUp never fails silently. Most reports below are explained by one line
from this handler.

## "User paid but app still locked"

1. **`onError` prints `unverified`** — StoreKit could not verify the
   transaction's signature. Common on jailbroken devices and with some
   sandbox accounts; also happens when the bundle ID of the build does not
   match the one the purchase was made under. The user is not entitled
   through that transaction, by design.
2. **You are checking the wrong key.** After an upgrade the product ID
   changes; use `isEntitled(toGroup:)`. For non-consumables use
   `isEntitled(to:)` with the exact product ID.
3. **The purchase happened on another Apple ID.** `restore()` on the current
   Apple ID will not find it. Ask which account they bought with.
4. **The purchase happened on another platform.** See <doc:CrossPlatform>;
   you need a remote provider.
5. **Billing retry without a grace period.** Apple stops granting access;
   so does PaidUp. Enable Billing Grace Period in App Store Connect if you
   want those days covered — they will then arrive as `.gracePeriod`.
6. **The instance was deallocated.** Create one `PaidUp` and keep it alive.

## "Sandbox renews every 5 minutes and my logic flips"

Sandbox subscriptions renew on an accelerated schedule and expire after a
handful of renewals. Each renewal changes `expirationDate`, so `updates`
emits a new `Set<Entitlement>` — the set is **different**, but the user is
still entitled. Derive your UI from `isEntitled(...)` or `!set.isEmpty`,
not from set equality. When the sandbox subscription finally expires, it is
correct for PaidUp to report nothing; buy again.

## "PaidUp on iPhone, not on iPad"

Same Apple ID? Then the iPad will see the purchase on its next refresh
(foreground or `restore()`). If the iPad still shows nothing, check
`onError` for `unverified` and confirm both builds share the bundle ID.
Different Apple IDs: the purchase belongs to the first one; that is how the
App Store works. Family Sharing (enabled per product in App Store Connect,
and turned on by the user) is the supported way to share.

Note that PaidUp's disk cache is per-device; it never syncs anything.

## "Paid on Android, locked on iOS"

Expected without a remote provider — see <doc:CrossPlatform>. With one
configured, check `onError` for `remoteProviderFailed`: the server call
threw or exceeded `remoteTimeout`. PaidUp keeps the last good remote set,
so if the very first call after install fails, nothing remote is known yet.

## "`purchase()` returned `.pending` and nothing happened"

Ask to Buy (or a bank's SCA challenge). When the approver acts, the
transaction arrives through `Transaction.updates`, PaidUp recomputes, and
`updates` emits. Keep the instance alive and keep listening.

## "`restore()` shows a sign-in sheet"

`AppStore.sync()` may prompt. Call `restore()` only from a user-initiated
*Restore Purchases* button, never on launch.

## "Every SKTestSession test fails with `productNotFound` on the simulator"

Look for `[SKTestSession] Error saving configuration file: SKInternalErrorDomain
Code=3` in the log. On iOS 26.x simulator runtimes the StoreKit testing
daemon rejects every `SKTestSession` call when the tests are launched by
`xcodebuild` rather than an Xcode debug session. Run on an iOS 17.x / 18.x
simulator, or run from Xcode.

## Still stuck

Open an issue with the StoreKit environment (configuration file / sandbox /
production), the transaction ID, your `onError` output, and what
`store.entitlements` prints.
