# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-08-22

### Added
- `PaidUp` with the four-call public API: `init(products:userID:configuration:)`,
  `entitlements` / `isEntitled(to:)` / `isEntitled(toGroup:)`, `updates`,
  `purchase(_:)` (+ `restore()`).
- `Transaction.updates` listener started at `init` and cancelled at `deinit`;
  every verified transaction finished exactly once per process.
- Entitlement computation from `Transaction.currentEntitlements` with
  grace-period labelling via `Product.SubscriptionInfo.status(for:)`, one
  call per subscription group per recompute, matched by transaction ID.
  Unverified transactions treated as absent and reported.
- `Transaction.unfinished` swept at startup so transactions left unfinished
  by a previous launch are finished exactly once.
- Atomic on-disk cache (`Application Support/PaidUp/<bundle-id>/<userID>`),
  read synchronously at `init`, replaced by the first StoreKit answer, never
  written from a cancelled or shut-down refresh, written only when the set
  changes.
- `appAccountToken` on every purchase from the `userID` passed to `init`.
- Optional `EntitlementProvider` hook; merge rule `union(local, remote)` where
  remote can never remove a locally verified entitlement; hard deadline at
  `remoteTimeout` even for providers that ignore cancellation; last good
  remote set kept on failure; `purchase()` never waits on the provider.
- Typed `PaidUpError` and typed `PurchaseResult` / `RestoreResult`.
- XCTest suite on a scripted StoreKit fake (state table, merge rule, cache,
  purchase/restore, listener lifecycle, shutdown edge cases, concurrency) —
  clean under the Thread and Address Sanitizers. `SKTestSession` suite and
  XCUITest in the sample app.
- SPM and CocoaPods distribution (module `PaidUpKit`, pod `PaidUp`),
  binary XCFramework script, privacy manifest, DocC catalog, CI on two iOS
  versions.
