# Plan 003: Put ReclaimScanner's cache and result mapping under test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` and append the **Verification report** (see the
> required-deliverable section near the end) to the bottom of this file.
>
> **Drift check (run first)**: `git diff --stat cd2e253..HEAD -- Sources/StorageBar/ReclaimScanner.swift Tests/StorageBarTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW–MED (adds two injectable init parameters with defaults; production call sites unchanged)
- **Depends on**: none (safe to run before or after 001; no file overlap)
- **Category**: tests
- **Planned at**: commit `cd2e253`, 2026-07-06

## Why this matters

`ReclaimScanner` owns the Reclaim Space submenu's behavior: a 5-minute result
cache, an in-flight guard, manual cache invalidation, and the mapping of
filesystem reality onto three user-visible states (`size`/`denied`/`missing` —
which drive the "no access" hints and the Grant Full Disk Access rows). None of
it is tested, and async completion + cache logic is exactly where regressions
hide silently: a broken cache means either a rescan of the whole Caches tree on
every submenu hover (slow, I/O heavy) or stale sizes that never update. Two
small injection seams (targets and a clock) make the whole class testable
against real temp directories.

## Current state

Files:

- `Sources/StorageBar/ReclaimScanner.swift` — the whole class (100 lines).
- `Sources/StorageBar/SystemStats.swift:91-108` — `directorySize(_:)`, which
  `scan` delegates to; returns `nil` when the directory itself is unreadable
  (that becomes `.denied`).
- `Sources/StorageBar/AppDelegate.swift:35` — the single production
  instantiation: `private lazy var reclaimScanner = ReclaimScanner()`.
- `Tests/StorageBarTests/SystemStatsTests.swift:75-91` — existing temp-dir test
  pattern (`testDirectorySizeCountsFiles`) to model filesystem fixtures on.

Key excerpts as of `cd2e253`:

```swift
// ReclaimScanner.swift:23-33
private static let cacheDuration: TimeInterval = 300

private let fileManager: FileManager
private(set) var targets: [Target]
private var scannedAt: Date?
private var isScanning = false

init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    targets = Self.defaultTargets(fileManager: fileManager)
}
```

```swift
// ReclaimScanner.swift:39-64 (abridged)
func scanIfStale(
    resultHandler: @escaping (Target, Result) -> Void,
    completion: @escaping ([ScanResult]) -> Void
) {
    guard !isScanning else { return }
    if let scannedAt, Date().timeIntervalSince(scannedAt) < Self.cacheDuration { return }

    isScanning = true
    ...
    DispatchQueue.global(qos: .utility).async { [weak self] in
        var scanResults: [ScanResult] = []
        for target in targets {
            let result = Self.scan(target.url, fileManager: fileManager)
            scanResults.append((target, result))
            DispatchQueue.main.async { resultHandler(target, result) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
            self?.scannedAt = Date()
            completion(scanResults)
        }
    }
}
```

```swift
// ReclaimScanner.swift:93-99
private static func scan(_ url: URL, fileManager: FileManager) -> Result {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return .missing }
    guard let size = SystemStats.directorySize(url) else { return .denied }
    return .size(size)
}
```

Note: `Result` is a nested enum with no `Equatable` conformance, and `Target`
has no `Equatable` either — tests will pattern-match with `if case` / add
conformance as Step 1 describes. Callbacks are delivered on the **main queue**;
tests must use `XCTestExpectation`, not sleeps. `scannedAt`/`isScanning` are
only touched on the main thread (call `scanIfStale` from the test's main thread
and let expectations drain the main queue).

Repo test conventions: XCTest, temp-dir fixtures under
`FileManager.default.temporaryDirectory` with UUID suffixes and `defer` cleanup —
copy `testDirectorySizeCountsFiles` exactly for that shape.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Full tests | `swift test` | exit 0, all pass |
| Only new tests | `swift test --filter ReclaimScannerTests` | all pass |

## Scope

**In scope** (the only files you should modify):
- `Sources/StorageBar/ReclaimScanner.swift` — add two injectable init
  parameters (defaults preserve production behavior) and `Equatable` on `Result`.
- `Tests/StorageBarTests/ReclaimScannerTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- `Sources/StorageBar/AppDelegate.swift` — the production `ReclaimScanner()`
  call must keep compiling unchanged (that's what the default parameter values are for).
- `SystemStats.directorySize` — already tested; do not add a seam for it.
- `defaultTargets(fileManager:)` — the real target list; tests bypass it via injection, they don't assert on the user's machine state.

## Git workflow

- Branch: `advisor/003-reclaim-scanner-tests`
- Commits: one for the seams, one for the tests; message style: short imperative.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the injection seams

In `ReclaimScanner.swift`:

1. Change the init to:

```swift
init(
    fileManager: FileManager = .default,
    targets: [Target]? = nil,
    now: @escaping () -> Date = Date.init
) {
    self.fileManager = fileManager
    self.now = now
    self.targets = targets ?? Self.defaultTargets(fileManager: fileManager)
}
```

   with a new stored property `private let now: () -> Date`.
2. In `scanIfStale`, replace the two `Date()` uses with `now()`:
   the staleness check (`now().timeIntervalSince(scannedAt)`) and the
   `self?.scannedAt = Date()` in the completion (`self?.scannedAt = self?.now() ?? Date()`
   — or capture `let now = now` before the dispatch and use `now()`; prefer the capture).
3. Add `Equatable` to the nested `Result` enum: `enum Result: Equatable`.
   (`Int64` payload synthesizes fine.)

**Verify**: `swift build` → exit 0. `swift test` → all existing tests pass
(production behavior unchanged: `ReclaimScanner()` still compiles via defaults).

### Step 2: Write the result-mapping tests

Create `Tests/StorageBarTests/ReclaimScannerTests.swift`. Build a fixture in
`setUp`/helper: a temp root under `FileManager.default.temporaryDirectory`
(UUID-suffixed, removed in `tearDown` — copy the pattern from
`SystemStatsTests.swift:80-91`) containing:

- `sized/` with two files of 10,000 and 20,000 bytes → expect `.size(n)` with `n >= 30_000`
- `denied/` with one file, then `try FileManager.default.setAttributes([.posixPermissions: 0o000], ofPath: denied.path)`
  → expect `.denied`. **Restore permissions to `0o755` in `tearDown` before
  removal**, or removal fails and pollutes the temp dir.
  Guard this test with `try XCTSkipIf(geteuid() == 0, "root ignores permission bits")`.
- a path that does not exist → expect `.missing`
- a plain **file** (not directory) at the target path → expect `.missing`
  (the `isDirectory.boolValue` branch)

Drive them through the public API: construct
`ReclaimScanner(targets: [Target(label: "T", url: fixtureURL, accessHint: .filesAndFolders)], now: { self.fakeNow })`
and call `scanIfStale`, collecting `resultHandler` invocations and asserting on
the `completion` array. Use `XCTestExpectation` with a 5-second timeout.

**Verify**: `swift test --filter ReclaimScannerTests` → all pass.

### Step 3: Write the cache and reentrancy tests

Same file, using an injected mutable clock:

```swift
var fakeNow = Date(timeIntervalSince1970: 1_000_000)
let scanner = ReclaimScanner(targets: [target], now: { fakeNow })
```

- **Cache fresh**: first `scanIfStale` completes (expectation). Advance
  `fakeNow += 299`. Call `scanIfStale` again with an **inverted** expectation on
  `completion` (`expectation.isInverted = true`, short 0.5 s wait) → no rescan.
- **Cache stale**: advance `fakeNow += 2` (total 301 > 300) → `scanIfStale`
  completes again.
- **invalidateCache**: after a completed scan (cache fresh), call
  `invalidateCache()` → next `scanIfStale` completes.
- **Reentrancy**: point a target at a directory big enough to take a moment
  (create ~50 small files), call `scanIfStale` twice back-to-back on the main
  thread → exactly one `completion` fires (count completions; assert 1 after
  waiting).

**Verify**: `swift test --filter ReclaimScannerTests` → all pass, no flakiness
across 3 consecutive runs (`for i in 1 2 3; do swift test --filter ReclaimScannerTests || break; done`).

### Step 4: Prove the tests bite (mutation check)

Temporarily change `cacheDuration` from `300` to `0` → the "cache fresh" test
must fail. Separately, temporarily delete the `guard !isScanning else { return }`
line → the reentrancy test must fail (2 completions). **Revert both**; record
the failing test names and messages in the Verification report.

**Verify**: after reverting, `swift test` → all pass;
`git diff Sources/StorageBar/ReclaimScanner.swift` shows only the Step 1 seams.

## Test plan

Covered by Steps 2–3: one new file, ~8 tests (4 result-mapping, 3 cache, 1
reentrancy), modeled on `SystemStatsTests.swift` fixtures. Final gate:
`swift test` all green, stable across 3 runs.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift test` exits 0; `ReclaimScannerTests` exists with tests covering size/denied/missing/file-at-path, cache fresh/stale, invalidateCache, and reentrancy
- [ ] `git diff cd2e253 -- Sources/StorageBar/ReclaimScanner.swift` shows only: the init signature change, the `now` property, `Date()` → `now()`/captured-clock substitutions, and `Result: Equatable`
- [ ] `Sources/StorageBar/AppDelegate.swift` is unmodified (`git diff cd2e253 -- Sources/StorageBar/AppDelegate.swift` empty)
- [ ] 3 consecutive `swift test --filter ReclaimScannerTests` runs pass
- [ ] Mutation-check failures documented in the Verification report and reverted
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift since `cd2e253`).
- The chmod-000 `denied` test does not produce `.denied` on your machine even as
  non-root — report the observed `Result` instead of weakening the assertion
  (this would mean `directorySize`'s unreadable-directory contract changed).
- The inverted-expectation cache test is flaky across the 3 runs — the async
  timing assumptions need a human decision, not a longer sleep.
- You find yourself wanting to change `scanIfStale`'s dispatch structure to make
  testing easier — that's a production behavior change, out of scope.

## Required deliverable: Verification report

Append a `## Verification report` section to the bottom of this file containing:

1. **Environment**: macOS version, `swift --version`, base commit, and whether
   the denied-permissions test ran or was skipped (euid).
2. **Reproduction of the gap (before)**: output of
   `ls Tests/StorageBarTests/` and `swift test 2>&1 | grep -ic reclaim` on the
   unmodified code (0 reclaim tests) — proving the class had zero coverage.
3. **Confirmation (after)**: final `swift test` summary line with the new count,
   plus the 3-consecutive-runs loop output showing stability.
4. **Mutation evidence**: the failing test names + messages from Step 4, and
   confirmation both mutations were reverted.

## Maintenance notes

- Plan 001 adds a similar time-throttle pattern in `AppDelegate` for volume
  enumeration; if someone later unifies the two throttles, these tests are the
  safety net for the scanner side.
- Reviewer should scrutinize: that the default init parameters really leave the
  production instantiation byte-for-byte equivalent, and that `tearDown` restores
  permissions before deleting the fixture.
- Deferred: testing the `defaultTargets` list itself (it reads the real home
  directory; asserting on it would couple tests to the machine).

## Verification report

### 1. Environment

- macOS: ProductVersion 27.0, BuildVersion 26A5353q
- `swift --version`: swift-driver version 1.167, Apple Swift version 6.4
  (swiftlang-6.4.0.20.104 clang-2100.3.20.102), Target arm64-apple-macosx27.0.0
- Base commit: `cd2e253` (drift check `git diff --stat cd2e253..HEAD --
  Sources/StorageBar/ReclaimScanner.swift Tests/StorageBarTests/` was empty
  before starting — no drift)
- Denied-permissions test: **ran** (not skipped) — `id -u` / `geteuid()` on
  this machine is `502` (non-root); `testScanUnreadableDirectoryReturnsDenied`
  executed and passed.

### 2. Reproduction of the gap (before)

`ls Tests/StorageBarTests/` on the unmodified tree:

```
CPUTickTests.swift
StatusPresentationTests.swift
SystemStatsTests.swift
UpdateCheckerNetworkTests.swift
```

No `ReclaimScannerTests.swift`. Baseline `swift test 2>&1 | grep -ic reclaim`
→ `0` (case-insensitive match count of "reclaim" across the full baseline
test-run log — zero occurrences). Baseline `swift test` summary:
`Executed 24 tests, with 0 failures (0 unexpected) in 0.147 (0.150) seconds` —
confirming `ReclaimScanner` had zero coverage before this plan.

### 3. Confirmation (after)

Final full-suite `swift test` summary line:

```
Executed 32 tests, with 0 failures (0 unexpected) in 1.202 (1.207) seconds
```

(24 pre-existing + 8 new `ReclaimScannerTests`.)

3-consecutive-runs loop (`swift test --filter ReclaimScannerTests` x3),
captured output per run:

```
=== RUN 1 ===
	 Executed 8 tests, with 0 failures (0 unexpected) in 1.036 (1.037) seconds
=== RUN 1 EXIT: 0 ===
=== RUN 2 ===
	 Executed 8 tests, with 0 failures (0 unexpected) in 1.051 (1.053) seconds
=== RUN 2 EXIT: 0 ===
=== RUN 3 ===
	 Executed 8 tests, with 0 failures (0 unexpected) in 1.042 (1.043) seconds
=== RUN 3 EXIT: 0 ===
```

No flakiness across 3 runs. No leftover directories were found under the temp
root (`$TMPDIR`) after the suite ran (checked via `find "$TMPDIR" -maxdepth 1
-iname "storagebar-reclaim-test-*"` — empty) — the `denied/` fixture's
permissions are restored to `0o755` in `tearDown` before the temp root is
removed, so cleanup never fails.

### 4. Mutation evidence

**Mutation A** — `cacheDuration` changed from `300` to `0`:

```
Test Case '-[StorageBarTests.ReclaimScannerTests testCacheFreshSkipsRescan]' started.
.../Tests/StorageBarTests/ReclaimScannerTests.swift:87: error: -[StorageBarTests.ReclaimScannerTests testCacheFreshSkipsRescan] : Fulfilled inverted expectation "fresh cache skips completion".
Test Case '-[StorageBarTests.ReclaimScannerTests testCacheFreshSkipsRescan]' failed (0.039 seconds).
```
Result: `Executed 8 tests, with 1 failure (0 unexpected)` — exactly the
cache-fresh test failed, all others passed. Reverted (`cacheDuration` restored
to `300`); confirmed via `git diff Sources/StorageBar/ReclaimScanner.swift`
showing no change before applying mutation B.

**Mutation B** — deleted the `guard !isScanning else { return }` line in
`scanIfStale`:

```
Test Case '-[StorageBarTests.ReclaimScannerTests testConcurrentCallsOnlyRescanOnce]' started.
.../Tests/StorageBarTests/ReclaimScannerTests.swift:131: error: -[StorageBarTests.ReclaimScannerTests testConcurrentCallsOnlyRescanOnce] : Fulfilled inverted expectation "second scan completion".
.../Tests/StorageBarTests/ReclaimScannerTests.swift:140: error: -[StorageBarTests.ReclaimScannerTests testConcurrentCallsOnlyRescanOnce] : XCTAssertEqual failed: ("2") is not equal to ("1")
Test Case '-[StorageBarTests.ReclaimScannerTests testConcurrentCallsOnlyRescanOnce]' failed (0.067 seconds).
```
Result: `Executed 8 tests, with 2 failures (0 unexpected)` — the reentrancy
test failed with 2 completions delivered instead of 1, all others passed.

Both mutations were reverted individually (verified each revert with
`git diff Sources/StorageBar/ReclaimScanner.swift` showing an empty diff
before moving to the next mutation, and an empty diff again after the final
revert), and the full `swift test` afterward passed 32/32 with 0 failures.

### Tooling note

The configured Codex default model in `~/.codex/config.toml` is
`gpt-5.6-sol`, which this ChatGPT account plan rejects
(`"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT
account."`). All `codex exec` invocations were run with an explicit
`-c model="gpt-5.5"` override to honor the operator's actual intent (gpt-5.5,
xhigh reasoning — xhigh remained the effective default and was not
overridden). Two Codex runs were used: one for the Step 1 seams, one for the
Step 2–3 test file. No corrective-feedback rounds were needed — both diffs
matched spec on first pass upon manual review.
