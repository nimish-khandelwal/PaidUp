# Which subscription states count as entitled, and why

The one table worth more than the code.

## The rule

Entitled never re-derives "is this expired" from dates. Yes/no comes from
`Transaction.currentEntitlements`: Apple already applies expiry, revocation
and grace-period rules there, on device, from the signed receipt, and it
works offline. `Product.SubscriptionInfo.Status` is read only to *label* the
state so you can show a "fix your payment" banner.

| StoreKit renewal state | In `currentEntitlements`? | `Entitlement.state` | Entitled? |
| --- | --- | --- | --- |
| `subscribed` | yes | `.active` | **yes** |
| `inGracePeriod` | yes | `.gracePeriod` | **yes** |
| `inBillingRetryPeriod` (no grace) | no | — | no |
| `expired` | no | — | no |
| `revoked` (refund / left family) | no | — | no |
| non-consumable, not revoked | yes | `.lifetime` | **yes** |
| any, `VerificationResult.unverified` | treated as absent | — | no, plus `onError(.unverified)` |
| pending (Ask to Buy / SCA) | not yet | — | no; `purchase()` returns `.pending`, later arrives via `updates` |

Defensive filters on top of Apple's list, each a test case in
`EntitlementStateTests`: a transaction with a `revocationDate` or
`isUpgraded == true` is never an entitlement even if it shows up, and
consumables are finished but never reported.

## Ownership

`Entitlement.ownership` is `.familyShared` when
`Transaction.ownershipType == .familyShared`. The user is entitled through a
family member's purchase; when that member leaves the family or disables
sharing, the transaction is revoked and disappears from
`currentEntitlements`, and so from Entitled.

## Upgrades, downgrades, crossgrades

Within a subscription group, the old product's transaction gets
`isUpgraded = true` and leaves `currentEntitlements`; a new transaction for
the new product appears. `isEntitled(to: "pro.monthly")` flips to `false`;
`isEntitled(toGroup:)` stays `true` throughout. Check the group.

## Offer codes and promotional offers

Entitled does not care how much the user paid. A transaction with an offer
applied is a normal entitlement.

## Merge with a remote provider

`entitled = storeKitLocal ∪ remote`. Remote can **add** (a Google Play
purchase mirrored by your backend) but can **never remove** a locally
verified entitlement. Remote entries carry `source: .remote`,
`state: .active`, no `expirationDate`, and the subscription group ID when the
product is in the local catalog. If the provider fails or times out, the
last good remote set is kept and `onError(.remoteProviderFailed)` fires.

## The cache

The last-known set is written atomically to
`Application Support/Entitled/<bundle-id>/entitlements.json` and read
synchronously at `init`, so `isEntitled` is right on the first frame. It is
replaced wholesale the moment the first `currentEntitlements` pass completes.
The cache never wins an argument with StoreKit; it only answers before
StoreKit has spoken.

## Finishing transactions

Every verified transaction — from `currentEntitlements`, from `updates`, and
from `purchase()` — is finished exactly once per process, after the
entitlement set has been recomputed. Unverified transactions are not
finished, matching Apple's guidance.
