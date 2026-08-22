# PaidUpSample

One screen: *Subscribe*, *Restore*, and a `PRO` badge bound to
`store.updates`. The scheme runs against `PaidUp.storekit`
(`pro.monthly` + `pro.yearly` in group `21000001`, `lifetime` non-consumable).

```
brew install xcodegen
xcodegen generate
open PaidUpSample.xcodeproj     # ⌘R to play, ⌘U to run the tests
```

- `PaidUpSampleTests` — `SKTestSession` against real StoreKit 2: purchase →
  entitled, `appAccountToken` attached, expiry, accelerated renewals via
  `timeRate`, refund → revoked, Ask to Buy approval, restore, upgrade keeps
  the group entitled.
- `PaidUpSampleUITests` — taps *Subscribe*, asserts the badge, expires the
  subscription, relaunches, asserts the badge is gone.

## Known simulator issue

On iOS 26.x simulator runtimes, `SKTestSession` fails every call with
`SKInternalErrorDomain Code=3` ("Error saving configuration file") when
launched by `xcodebuild` outside an Xcode debug session, so every StoreKit
test fails with `productNotFound`. Run the suite on an iOS 17.x or 18.x
simulator (`-destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'`),
which is what CI does.
