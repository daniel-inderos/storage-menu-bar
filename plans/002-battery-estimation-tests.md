# Plan 002: Put the battery estimation helpers under test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` and append the **Verification report** (see the
> required-deliverable section near the end) to the bottom of this file.
>
> **Drift check (run first)**: `git diff --stat cd2e253..HEAD -- Sources/StorageBar/SystemStats.swift Tests/StorageBarTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (visibility change `private` → internal + new tests; no logic changes)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `cd2e253`, 2026-07-06

## Why this matters

The "est. Xh Ym to full" battery estimate (shipped in commit `caa8682`) rests on
four small pure functions with genuinely subtle logic: sentinel values (0, −1,
65535 all mean "unknown"), a 7-day sanity cap, a ≥100 mA charge-rate gate, a
1.2× taper fudge factor, and — most fragile of all — a sign convention where
*negative* `BatteryPower` milliwatts means charging. None of it is tested,
because all four functions are `private`. A future edit that flips the sign
check or off-by-ones a threshold would silently produce absurd estimates on
users' machines. These are the cheapest high-value tests in the repo.

## Current state

Files:

- `Sources/StorageBar/SystemStats.swift` — the four helpers, lines 248–282, all `private static`.
- `Tests/StorageBarTests/CPUTickTests.swift` — the structural pattern to copy (tests a pure `SystemStats` function via `@testable import`).

The exact code under test as of `cd2e253` (do NOT change its logic — only its visibility):

```swift
// SystemStats.swift:248-251
private static func batteryMinutes(_ value: Int?) -> Int? {
    guard let value, value > 0, value < 7 * 24 * 60 else { return nil }
    return value
}

// SystemStats.swift:253-266
private static func estimatedChargeMinutes(
    currentCapacity: Int?,
    maxCapacity: Int?,
    chargeRateMilliamps: Int?
) -> Int? {
    guard let currentCapacity,
          let maxCapacity,
          maxCapacity > currentCapacity,
          let chargeRateMilliamps,
          chargeRateMilliamps >= 100 else { return nil }
    let remaining = maxCapacity - currentCapacity
    let linearMinutes = Double(remaining) / Double(chargeRateMilliamps) * 60
    return batteryMinutes(Int((linearMinutes * 1.2).rounded()))
}

// SystemStats.swift:268-277
private static func telemetryChargeRateMilliamps(
    batteryPowerMilliwatts: Int?,
    voltageMillivolts: Int?
) -> Int? {
    guard let batteryPowerMilliwatts,
          batteryPowerMilliwatts < 0,
          let voltageMillivolts,
          voltageMillivolts > 0 else { return nil }
    return abs(batteryPowerMilliwatts) * 1000 / voltageMillivolts
}

// SystemStats.swift:279-282
private static func batteryChargeRateMilliamps(_ amperage: Int?) -> Int? {
    guard let amperage, amperage != 0 else { return nil }
    return abs(amperage)
}
```

Repo test conventions (match them): XCTest, one focused `XCTestCase` class per
concern, plain `XCTAssertEqual`/`XCTAssertNil`, `@testable import StorageBar`.
Exemplar: `Tests/StorageBarTests/CPUTickTests.swift` — note how
`SystemStats.cpuUsage(from:to:)` was made internal precisely so it could be
tested; this plan applies the same pattern.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Tests | `swift test` | exit 0; 24 tests pass before this plan, 24 + new count after |
| Run only the new tests | `swift test --filter BatteryEstimationTests` | all new tests pass |

## Scope

**In scope** (the only files you should modify):
- `Sources/StorageBar/SystemStats.swift` — ONLY the `private` keyword on the four functions above.
- `Tests/StorageBarTests/BatteryEstimationTests.swift` (create)

**Out of scope** (do NOT touch, even though they look related):
- `SystemStats.battery()` and `smartBatteryDetails()` — they read live IOKit
  state and are deliberately untested; wrapping IOKit in a protocol is not worth
  it at this app's size.
- `StatusPresentation.chargeText` — already tested in `StatusPresentationTests.swift`.
- Any behavioral change to the four helpers, however tempting.

## Git workflow

- Branch: `advisor/002-battery-tests`
- Single commit is fine; message style: short imperative (e.g. `Test battery charge estimation helpers`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make the four helpers internal

In `Sources/StorageBar/SystemStats.swift`, delete the `private` keyword from
`batteryMinutes`, `estimatedChargeMinutes`, `telemetryChargeRateMilliamps`, and
`batteryChargeRateMilliamps` (leaving `static func ...`). Do not change
signatures, bodies, or doc comments.

**Verify**: `swift build` → exit 0. `swift test` → all existing tests still pass.

### Step 2: Write the tests

Create `Tests/StorageBarTests/BatteryEstimationTests.swift`, modeled
structurally on `CPUTickTests.swift`. Cover at minimum:

`batteryMinutes`:
- `nil` input → `nil`
- `0` and `-1` (IOKit "unknown/calculating" sentinels) → `nil`
- `65535` (the other sentinel; also above the cap) → `nil`
- boundary: `10079` (7×24×60 − 1) → `10079`; `10080` → `nil`
- normal: `712` → `712`

`estimatedChargeMinutes`:
- happy path: `currentCapacity: 2000, maxCapacity: 5000, chargeRateMilliamps: 1000`
  → 3000 mAh remaining / 1000 mA = 180 min linear × 1.2 = `216`
- `nil` for: nil current, nil max, `maxCapacity <= currentCapacity` (test equal
  and less-than), nil rate, rate `99` (below the 100 mA gate)
- rate exactly `100` with `current: 4900, max: 5000` → 100/100·60 = 60 × 1.2 = `72` (gate is inclusive)

`telemetryChargeRateMilliamps`:
- charging sign convention: `batteryPowerMilliwatts: -15_000, voltageMillivolts: 12_000` → `1250`
- positive power (discharging) → `nil`; zero power → `nil`
- nil power or nil voltage → `nil`; voltage `0` → `nil`

`batteryChargeRateMilliamps`:
- `nil` → `nil`; `0` → `nil`
- `-1500` → `1500`; `1500` → `1500`

**Verify**: `swift test --filter BatteryEstimationTests` → all pass.
`swift test` → full suite passes.

### Step 3: Prove the tests bite (mutation check)

Temporarily flip the sign guard in `telemetryChargeRateMilliamps` from
`batteryPowerMilliwatts < 0` to `batteryPowerMilliwatts > 0` and run
`swift test --filter BatteryEstimationTests` → **at least one test must fail**.
Then temporarily change the gate in `estimatedChargeMinutes` from
`chargeRateMilliamps >= 100` to `> 100` → the inclusive-boundary test must fail.
**Revert both mutations** (`git diff Sources/` must be empty except the
`private` removals from Step 1). Record both failing test names and their
failure messages in the Verification report.

**Verify**: after reverting, `swift test` → all pass, and
`git diff Sources/StorageBar/SystemStats.swift` shows only four deleted
`private ` tokens.

## Test plan

Covered by Steps 2–3: ~16 new assertions across four functions in one new file,
following `CPUTickTests.swift`. Final gate: `swift test` all green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift test` exits 0; `BatteryEstimationTests` exists and passes
- [ ] `git diff cd2e253 -- Sources/StorageBar/SystemStats.swift` contains only visibility changes (removal of `private` on the four named functions), no logic edits
- [ ] Both mutation-check failures are documented in the Verification report, and the mutations are reverted
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The four functions at `SystemStats.swift:248-282` don't match the excerpts
  (drift — someone changed the estimation logic since `cd2e253`).
- A test you believe is correct per this plan fails against the *unmodified*
  logic — that means the plan's expected value or the code is wrong; report the
  discrepancy instead of adjusting the expectation to match the code.
- Making the functions internal somehow breaks the build (it cannot, absent drift).

## Required deliverable: Verification report

Append a `## Verification report` section to the bottom of this file containing:

1. **Environment**: macOS version, `swift --version` output, base commit.
2. **Reproduction of the gap (before)**: output of
   `grep -n "private static func batteryMinutes\|private static func estimatedChargeMinutes\|private static func telemetryChargeRateMilliamps\|private static func batteryChargeRateMilliamps" Sources/StorageBar/SystemStats.swift`
   on the unmodified code (4 matches — proving the helpers were untestable), plus
   `swift test 2>&1 | grep -ci battery` style evidence that no battery-estimation
   test existed before.
3. **Confirmation (after)**: final `swift test` summary line showing the new test count.
4. **Mutation evidence**: the two failing test names + messages from Step 3,
   proving the tests detect real regressions, and confirmation the mutations were reverted.

## Verification report

### 1. Environment

- macOS: `ProductName: macOS`, `ProductVersion: 27.0`, `BuildVersion: 26A5353q`
- `swift --version`: `swift-driver version: 1.167 Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)`, Target: `arm64-apple-macosx27.0.0`
- Base commit: `cd2e253` (HEAD at plan start; drift check `git diff --stat cd2e253..HEAD -- Sources/StorageBar/SystemStats.swift Tests/StorageBarTests/` produced no output — no drift).

### 2. Reproduction of the gap (before)

```
$ grep -n "private static func batteryMinutes\|private static func estimatedChargeMinutes\|private static func telemetryChargeRateMilliamps\|private static func batteryChargeRateMilliamps" Sources/StorageBar/SystemStats.swift
248:    private static func batteryMinutes(_ value: Int?) -> Int? {
253:    private static func estimatedChargeMinutes(
268:    private static func telemetryChargeRateMilliamps(
279:    private static func batteryChargeRateMilliamps(_ amperage: Int?) -> Int? {
```

4 matches, confirming all four helpers were `private` (untestable) before this plan.

Baseline `swift test` (unmodified code): `Executed 24 tests, with 0 failures (0 unexpected)`. Grepping that run's output for "battery" (case-insensitive) returned 0 matches — no battery-estimation test existed before this plan.

### 3. Confirmation (after)

After Step 1 (visibility change) and Step 2 (new test file), final full-suite run:

```
Test Suite 'All tests' passed at 2026-07-06 19:35:54.115.
	 Executed 49 tests, with 0 failures (0 unexpected) in 0.132 (0.136) seconds
```

49 = 24 baseline + 25 new tests in `BatteryEstimationTests` (7 for `batteryMinutes`, 8 for `estimatedChargeMinutes`, 6 for `telemetryChargeRateMilliamps`, 4 for `batteryChargeRateMilliamps` — one more than the plan's "~16" estimate because a couple of guard-clause branches were split into separate test methods, e.g. nil-vs-equal-vs-less-than for `maxCapacity`/`currentCapacity`). `swift test --filter BatteryEstimationTests` in isolation: `Executed 25 tests, with 0 failures (0 unexpected)`.

### 4. Mutation evidence

**Mutation A** — `telemetryChargeRateMilliamps`: changed `batteryPowerMilliwatts < 0` to `batteryPowerMilliwatts > 0`. Ran `swift test --filter BatteryEstimationTests`:

```
Tests/StorageBarTests/BatteryEstimationTests.swift:126: error: -[StorageBarTests.BatteryEstimationTests testTelemetryChargeRateMilliampsReturnsNilForPositivePower] : XCTAssertNil failed: "1250"
Tests/StorageBarTests/BatteryEstimationTests.swift:116: error: -[StorageBarTests.BatteryEstimationTests testTelemetryChargeRateMilliampsUsesChargingSignConvention] : XCTAssertEqual failed: ("nil") is not equal to ("Optional(1250)")
Test Suite 'BatteryEstimationTests' failed ... Executed 25 tests, with 2 failures (0 unexpected)
```

Two failing tests, as expected (sign-flip breaks both the "discharging returns nil" case and the "charging returns 1250" case). Reverted immediately after capturing this output.

**Mutation B** — `estimatedChargeMinutes`: changed `chargeRateMilliamps >= 100` to `chargeRateMilliamps > 100`. Ran `swift test --filter BatteryEstimationTests`:

```
Tests/StorageBarTests/BatteryEstimationTests.swift:105: error: -[StorageBarTests.BatteryEstimationTests testEstimatedChargeMinutesAcceptsChargeRateAtGate] : XCTAssertEqual failed: ("nil") is not equal to ("Optional(72)")
Test Suite 'BatteryEstimationTests' failed ... Executed 25 tests, with 1 failure (0 unexpected)
```

One failing test, as expected (the inclusive-boundary test at exactly 100 mA). Reverted immediately after capturing this output.

**Revert confirmation**: after reverting both mutations, `git diff Sources/StorageBar/SystemStats.swift` shows only the four `private` → (removed) visibility changes from Step 1, no other lines changed (verified twice: once after reverting mutation A before applying mutation B, and once after reverting mutation B). Full-suite re-run after both reverts: `Executed 49 tests, with 0 failures (0 unexpected) in 0.128 (0.131) seconds`.

## Maintenance notes

- Anyone touching the estimation chain in `smartBatteryDetails()` (e.g. adding a
  new telemetry source) should extend these tests first — the sign convention
  (negative mW = charging) is the classic silent-flip hazard.
- Reviewer should scrutinize: that no `private` removal accidentally hit a
  function outside the four named ones.
- Deferred: testing `battery()`/`smartBatteryDetails()` themselves (IOKit-bound;
  would need a protocol seam that isn't worth it yet).
