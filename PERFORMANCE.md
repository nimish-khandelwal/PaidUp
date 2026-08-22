# Performance notes

## Binary size

Measured 2026-08-23, Swift 6.3.2 (Xcode 26.5), release configuration, arm64:

```
swift build -c release
xcrun clang -dynamiclib -o libEntitledKit.dylib .build/release/EntitledKit.build/*.o \
  -framework Foundation -framework StoreKit \
  -L"$(xcrun --show-sdk-path)/usr/lib/swift" \
  -L"$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
strip -x libEntitledKit.dylib
du -k libEntitledKit.dylib   # → 248 KB
```

**~248 KB** as a stripped dynamic library. Statically linked into a host app
(the SPM default), the linker dead-strips unused paths, so the real
contribution to a host binary is lower. Zero third-party dependencies; the
only frameworks touched are Foundation, StoreKit, and (on iOS) UIKit for the
foreground notification.

Per-object breakdown, release mode, unlinked (upper bound — includes
relocation and symbol overhead the linker removes):

| Object | KB |
| --- | --- |
| EntitledCore | 276 |
| LiveStoreKitClient | 120 |
| Entitlement | 104 |
| Entitled | 88 |
| EntitlementStore | 76 |
| StoreKitClient | 68 |
| EntitlementSnapshot | 56 |
| EntitledConfiguration | 36 |
| EntitledError | 32 |
| Results | 24 |
| ForegroundObserver | 12 |
| EntitlementProvider | 12 |

## Memory / ARC

Design properties, verified by the test suite and the Thread Sanitizer:

- **No retain cycles by construction.** The `Transaction.updates` listener
  task captures the actor `weak`; the actor cancels it in `deinit` and the
  public `Entitled` cancels it again in its own `deinit`. The refresh chains
  and the foreground observer also capture `weak`.
- **Deallocation mid-purchase is safe.** The `purchase()` continuation holds
  the actor alive until StoreKit answers, the transaction is finished, and
  the result is returned; nothing is left unfinished.
- **`isEntitled` cost at the call site** is one `NSLock` acquire and a set
  scan — no `await`, no disk, no StoreKit. `testConcurrentReadsFromManyQueuesWhileMutating`
  reads 4,000 times from 8 concurrent queues while the actor recomputes 200
  times.

## Leaks + memory pass (recorded 2026-08-23, v0.1.0)

Measured with the `leaks` tool (the same detection engine Instruments'
Leaks template uses) against a release-built stress harness
(`Scripts/LeakHarness`) that exercises every lifecycle path: 50 full
create → subscribe to `updates` → 20 refresh/update cycles → `purchase()` →
`restore()` → deallocate cycles against a scripted StoreKit client with a
remote provider, half of them leaving an `updates` consumer un-cancelled.

```
$ cd Scripts/LeakHarness && swift build -c release -Xswiftc -enable-testing
$ leaks --atExit -- ./.build/release/LeakHarness
listeners remaining: 0
Process 77894: 0 leaks for 0 total leaked bytes.
```

**Zero leaks, zero leaked bytes** across 50 `Entitled` lifecycles, and the
fake client reports **0 remaining `Transaction.updates` listeners** — every
listener task was cancelled when its instance died.

Memory footprint of the same run (`/usr/bin/time -l`, arm64 release):

- peak memory footprint: **4.3 MB** for the whole process — Swift runtime
  and harness included
- maximum resident set size: 13.3 MB

To reproduce in the GUI instead: profile `Examples/EntitledSample` under
**Instruments → Leaks + Allocations**, tap *Subscribe*, background and
foreground the app 3×. Expect zero leaks; the allocation graph returns to
baseline after each refresh, and only the cache file persists.

## Thread Sanitizer

`swift test --sanitize=thread` runs the full suite — including the 8-queue
concurrent read test and the concurrent purchase/restore/update test — and
is clean as of 0.1.0. CI enforces this on every push.
