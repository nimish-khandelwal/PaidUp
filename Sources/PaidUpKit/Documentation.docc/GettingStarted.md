# Getting Started

Create one instance, keep it alive, read it from anywhere.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/nimish-khandelwal/PaidUp.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'PaidUp', '~> 0.1'
```

The module is `PaidUpKit`; the main type is `PaidUp`.

## Create the instance once

```swift
import PaidUpKit

@MainActor
final class Store: ObservableObject {
    @Published var entitlements: Set<Entitlement> = []
    let store: PaidUp

    init(userID: UUID) {
        var config = PaidUpConfiguration.default
        config.onError = { error in print(error) }
        store = PaidUp(
            products: ["pro.monthly", "pro.yearly", "lifetime"],
            userID: userID,
            configuration: config
        )
        entitlements = store.entitlements
    }

    func observe() async {
        for await set in store.updates { entitlements = set }
    }
}
```

The listener for `Transaction.updates` starts in `init` and stops when the
instance deallocates, so create it early (app launch) and hold it for the
app's lifetime.

`userID` must be a `UUID` because Apple's `appAccountToken` is a UUID. If
your user IDs are strings, derive a stable one:

```swift
import CryptoKit

extension UUID {
    static func stable(from string: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(string.utf8))
        let digest = Array(hasher.finalize().prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                           digest[6] & 0x0F | 0x50, digest[7], digest[8] & 0x3F | 0x80, digest[9],
                           digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}
```

## Ask yes/no, synchronously

```swift
if store.isEntitled(toGroup: "21000001") { unlockPro() }   // subscriptions
if store.isEntitled(to: "lifetime") { unlockPro() }         // non-consumables
```

Prefer `isEntitled(toGroup:)` for subscriptions: an upgrade from monthly to
yearly changes the product ID but not the group.

## Purchase and restore

```swift
switch await store.purchase("pro.yearly") {
case .success(let entitlement): showThanks(entitlement)
case .userCancelled:            break
case .pending:                  showAskToBuyNotice()   // arrives via `updates` if approved
case .failed(let error):        showError(error)
}

switch await store.restore() {               // user-initiated only
case .restored(let set):  showRestored(set)
case .failed(let error):  showError(error)
}
```

## Testing your integration

Add a StoreKit configuration file to your scheme and drive it with
`SKTestSession` in your tests. The package's `Examples/PaidUpSample`
shows a full setup, including an XCUITest that taps *Subscribe* and asserts
the PRO badge.
