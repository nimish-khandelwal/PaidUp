# Compatibility policy

## Support window

| | Supported |
| --- | --- |
| iOS deployment target | 15.0 and newer (StoreKit 2 floor) |
| Build SDK | Always the current released Xcode SDK |
| Swift | 5.9+ (Xcode 15+) |
| macOS (for host tooling/tests) | 12.0 and newer |

The deployment target moves forward at most once per **major** version, and
never to an iOS version less than three years old at the time of release.

## Newer StoreKit APIs and their fallbacks

Verified against Apple's headers in the Xcode 26 SDK:

| API | Introduced | What PaidUp does |
| --- | --- | --- |
| `Product.SubscriptionInfo.status(for: groupID)` | iOS 17.0 | Used to label `.gracePeriod`. On iOS 15/16 falls back to `Product.products(for:)` → `subscription?.status`. Same answer, one extra fetch. |
| `Product.SubscriptionInfo.Status.all` | iOS 17.0 | Not used. |
| `Transaction.reason` | iOS 17.0 | Not used; PaidUp does not distinguish purchase from renewal. |
| `Transaction.offer` / `offerType` | iOS 17.2 | Not used; offers do not change entitlement. |
| `Transaction.currentEntitlements(for:)` | iOS 18.4 | Not used; the all-products `currentEntitlements` is the source of truth on every OS. |
| `Product.purchase(options:)` | iOS 15.0 | Used on every OS. Unavailable on visionOS, which is not a supported platform. |

If Apple deprecates something PaidUp wraps, the wrapper keeps working
behind an `@available` guard with the replacement adopted on newer OSes;
the public API does not change within a major version.

## API stability

- Versioning follows [Semantic Versioning 2.0](https://semver.org). Public
  API removals or source-breaking changes happen only in major releases.
- Everything `public` in this package is a commitment: we keep it working for
  at least one year or one major version, whichever is longer.
- `Entitlement` is `Codable` and its cache file shape (`entitlements`,
  `remote`, `savedAt`) is additive-only within a major version; an
  unreadable cache is reported via `onError(.storageFailed)` and ignored,
  never fatal.

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
