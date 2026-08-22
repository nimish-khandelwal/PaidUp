# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-08-22

### Added
- `Entitled` with the four-symbol public API: `init(products:userID:configuration:)`,
  `entitlements` / `isEntitled(to:)` / `isEntitled(toGroup:)`, `updates`,
  `purchase(_:)` (+ `restore()`).
- `Transaction.updates` listener started at `init` and cancelled at `deinit`;
  every verified transaction finished exactly once per process.
- Entitlement computation from `Transaction.currentEntitlements` with
  grace-period labelling via `Product.SubscriptionInfo.Status`
  (`status(for:)` on iOS 17+, `Product.subscription.status` fallback on
  iOS 15/16). Unverified transactions treated as absent and reported.
- Atomic on-disk cache (`Application Support/Entitled/<bundle-id>`), read
  synchronously at `init`, replaced by the first StoreKit answer.
- `appAccountToken` on every purchase from the `userID` passed to `init`.
- Optional `EntitlementProvider` hook; merge rule `union(local, remote)` where
  remote can never remove a locally verified entitlement; bounded by
  `remoteTimeout`; last good remote set kept on failure.
- Typed `EntitledError` and typed `PurchaseResult` / `RestoreResult`.
- XCTest suite on a scripted StoreKit fake (state table, merge rule, cache,
  purchase/restore, listener lifecycle, concurrency) — clean under the
  Thread Sanitizer. `SKTestSession` suite and XCUITest in the sample app.
- SPM and CocoaPods distribution (module `EntitledKit`, pod `Entitled`),
  binary XCFramework script, privacy manifest, DocC catalog, CI on two iOS
  versions.
