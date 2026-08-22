# Cross-platform subscriptions: why StoreKit isn't enough and how to wire the provider

A user who subscribes on Android has nothing in `Transaction.currentEntitlements`.

## The problem

StoreKit knows only Apple purchases. Google Play Billing knows only Google
purchases. No client code can bridge that. The only thing that sees both
stores is **your server**:

```
iOS app  ──StoreKit 2────▶ Apple  ──App Store Server Notifications v2──▶
                                                                        your backend
Android  ──Play Billing──▶ Google ──Real-time Developer Notifications──▶ entitlements table
                                                                        keyed by YOUR user id
```

Each store tells your backend "user X paid"; any device on any platform asks
the backend what user X has.

## The trap: appAccountToken

An Apple purchase is tied to an *Apple ID*, not to your user account. Apple's
notification arrives at your server with no idea which of your users it
belongs to — unless the purchase was tagged:

```swift
try await product.purchase(options: [.appAccountToken(userUUID)])
```

Apple echoes that UUID in every notification for that subscription, forever.
Miss it once and attribution for that purchase is broken for good. Google
Play has the same concept (`obfuscatedAccountId`).

PaidUp does this for you: the `userID` you pass to `init` is attached as
`appAccountToken` to every `purchase()`. Pass `nil` only if you genuinely
have no user accounts.

## Wiring the provider

```swift
struct MyBackendProvider: EntitlementProvider {
    let api: API
    func currentEntitlements() async throws -> Set<String> {
        try await api.get("/me/entitlements").productIDs
    }
}

var config = PaidUpConfiguration.default
config.remoteProvider = MyBackendProvider(api: api)
config.remoteTimeout = 5
let store = PaidUp(products: products, userID: user.id, configuration: config)
```

PaidUp calls the provider at `init`, when the app returns to the
foreground (if `refreshOnForeground`), and after every successful
`purchase()` and `restore()`. The result is merged as
`union(StoreKit, remote)` and surfaced through the same `updates` stream, so
"paid on Android, opens iOS" just works.

**One rule, tested:** remote can add entitlements, never remove a locally
verified one. A server outage or bug must never lock out a user Apple says
has paid. On failure or timeout the last good remote set is kept and
`onError(.remoteProviderFailed)` fires.

## Other edge cases the same design handles

- **Family Sharing** — `ownership == .familyShared`; revoked when they leave.
- **Upgrade / downgrade / crossgrade** — check the group, not the product ID.
- **Two Apple IDs on one device** — entitlements flip on the next refresh
  (foreground or `restore()`).
- **Offer codes / promotional offers** — normal entitlements.
- **Tampered device** — only `.verified` transactions count. If you want a
  second opinion, send the JWS to your server from your own code; PaidUp
  does not transmit anything.
- **Clock tampering** — PaidUp never compares `expirationDate` to the
  device clock. When a remote provider is present, server time wins by
  construction.
