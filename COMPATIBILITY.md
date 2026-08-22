# Compatibility policy

## Support window

| | Supported |
| --- | --- |
| iOS deployment target | 15.0 and newer (StoreKit 2 floor) |
| Build SDK | Always the current released Xcode SDK (headers checked against Xcode 26; CI builds with Xcode 16.4) |
| Swift | 5.9+ (Xcode 15+) |
| macOS (for host tooling/tests) | 12.0 and newer |

The deployment target moves forward at most once per **major** version, and
never to an iOS version less than three years old at the time of release.

## Newer StoreKit APIs and their fallbacks

Verified against the StoreKit `.swiftinterface` in the Xcode 26 SDK:

| API | Introduced | What PaidUp does |
| --- | --- | --- |
| `Product.SubscriptionInfo.status(for: groupID)` | iOS 15.0 (lives in the iOS 15 extension; `Product.subscription.status` is an `@inlinable` wrapper over it) | Used to label `.gracePeriod`; one call per subscription group per recompute. No guard needed. |
| `Product.SubscriptionInfo.status(transactionID:)` | iOS 18.4 | Not used. |
| `Product.SubscriptionInfo.Status.all` | iOS 17.0 | Not used. |
| `Transaction.reason` | iOS 17.0 | Not used; PaidUp does not distinguish purchase from renewal. |
| `Transaction.offer` | iOS 17.2 (`offerType` exists since 15.0, deprecated 17.2) | Not used; offers do not change entitlement. |
| `Transaction.currentEntitlements(for:)` | iOS 18.4 | Not used; the all-products `currentEntitlements` is the source of truth on every OS. |
| `Product.purchase(options:)` | iOS 15.0 | Used on every OS. Unavailable on visionOS, which is not a supported platform. |

PaidUp currently touches nothing newer than iOS 15, so there are no
`@available` guards in the codebase. If a future version adopts a newer API
(or Apple deprecates one we wrap), it goes behind an `@available` guard with
a real fallback on the floor OS; the public API does not change within a
major version.

## API stability

- Versioning follows [Semantic Versioning 2.0](https://semver.org). Public
  API removals or source-breaking changes happen only in major releases.
- Everything `public` in this package is a commitment: we keep it working for
  at least one year or one major version, whichever is longer.
- `Entitlement` is `Codable` and its cache file shape (`entitlements`,
  `remote`, `remoteSubscriptionGroupIDs`, `savedAt`) is additive-only within
  a major version; older files without a key still load; an unreadable cache
  is reported via `onError(.storageFailed)` and ignored, never fatal.
- `Entitlement.init`, `PaidUpConfiguration.init` and `RemoteProviderTimeout`
  are public on purpose (host tests, SwiftUI previews, typed timeout
  inspection) and are covered by the same stability promise.

## Deprecation policy

1. A symbol is first marked `@available(*, deprecated, message:)` pointing at
   its replacement, in a **minor** release.
2. It keeps working, warnings only, for at least one full minor release cycle
   and at least 6 months.
3. It is removed in the next **major** release, and the removal is listed in
   the CHANGELOG migration notes.

## What we test against

CI runs `swift test` (plain and under the Thread Sanitizer) on macOS, and the
sample app's `SKTestSession` + XCUITest suite on the two most recent major
iOS simulators (see `.github/workflows/ci.yml`).
