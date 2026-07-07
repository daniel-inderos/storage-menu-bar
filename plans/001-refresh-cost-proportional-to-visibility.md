# Plan 001: Make refresh cost proportional to what is visible

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` and append the **Verification report** (see the
> required-deliverable section near the end) to the bottom of this file.
>
> **Drift check (run first)**: `git diff --stat cd2e253..HEAD -- Sources/StorageBar/AppDelegate.swift Sources/StorageBar/SystemStats.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches the app's main refresh path; no unit-test safety net over AppDelegate)
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `cd2e253`, 2026-07-06

## Why this matters

StorageBar recently gained a 1-second refresh option (commit `cd2e253`), and the
refresh timer runs in `.common` run-loop mode so it fires even while a menu is
open. But `refresh()` always does *full-menu* work — even when the menu is
closed and nothing but the status-bar title is visible. Per tick that includes:
an `SMAppService.mainApp.status` query (an XPC round-trip to launchd, ~86,000
calls/day at 1 s), a full teardown-and-rebuild of the Volumes submenu, a
background enumeration that stats **every mounted volume** (which can keep
network mounts like SMB awake), and IORegistry battery reads. For an app whose
entire pitch is "tiny", this is real energy and I/O waste, and rebuilding the
Volumes submenu every second while it is open can reset hover state / flicker.
After this plan, a closed-menu tick reads only the startup disk; everything
else runs only while the menu is actually open.

## Current state

Files:

- `Sources/StorageBar/AppDelegate.swift` — all refresh logic lives here (628 lines).
- `Sources/StorageBar/SystemStats.swift` — `VolumeInfo` struct (lines 18–23); gains `Equatable` in this plan.

Key excerpts as of `cd2e253` (confirm these before editing):

`AppDelegate.swift:93-102` — the timer always calls full `refresh()`:

```swift
private func startTimer() {
    timer?.invalidate()
    // Use .common so the timer keeps firing while a menu is open (event-tracking mode).
    let newTimer = Timer(timeInterval: Prefs.refreshInterval, repeats: true) { [weak self] _ in
        self?.refresh()
    }
    newTimer.tolerance = Prefs.refreshInterval / 6
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer
}
```

`AppDelegate.swift:315-348` — `refresh()` does everything every tick: disk +
status button + low-space check, then `refreshVolumes()`, memory, CPU, uptime,
`refreshBattery()`, and ends with `updateSettingsChecks()`.

`AppDelegate.swift:300-311` — `updateSettingsChecks()` ends with the XPC call:

```swift
loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
```

`AppDelegate.swift:412-445` — `refreshVolumes()` re-renders the cached snapshot
every tick (`renderVolumes(volumeSnapshot)` does `volumesMenu.removeAllItems()`
and rebuilds) and then kicks `enumerateVolumesIfNeeded()`, which dispatches
`SystemStats.otherVolumes()` on a background queue on every tick (guarded only
against *concurrent* runs by `isEnumeratingVolumes`, not against frequency).

`AppDelegate.swift:516-522` — the delegate only implements `menuWillOpen`:

```swift
func menuWillOpen(_ menu: NSMenu) {
    if menu === self.menu {
        refresh()
    } else if menu === reclaimMenu {
        scanReclaimTargetsIfStale()
    }
}
```

`AppDelegate.swift:203-206` — `settingsMenu` currently has **no delegate**
(only `reclaimMenu.delegate = self` is set, in `buildReclaimMenu()` at line 219).

Repo conventions: no third-party dependencies; pure logic is extracted into
enums like `StatusPresentation` (see `Sources/StorageBar/StatusPresentation.swift`)
with tests in `Tests/StorageBarTests/`; comments explain *why* (run-loop modes,
permission quirks), not *what*. Match that.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build` | exit 0 |
| Tests | `swift test` | exit 0, 24 tests pass (count may be higher if other plans landed) |
| Run the app for manual verification | `swift run` | menu bar item appears (notifications are disabled in bare-binary mode — expected) |
| App bundle build | `./build-app.sh` | exit 0, prints `Built StorageBar.app` |

## Scope

**In scope** (the only files you should modify):
- `Sources/StorageBar/AppDelegate.swift`
- `Sources/StorageBar/SystemStats.swift` (only to add `Equatable` to `VolumeInfo`)
- `Tests/StorageBarTests/SystemStatsTests.swift` (optional small test, see Test plan)

**Out of scope** (do NOT touch, even though they look related):
- `Sources/StorageBar/ReclaimScanner.swift` — already lazy (scans only from
  `menuWillOpen` of its submenu, with its own 5-minute cache). Plan 003 covers it.
- `Sources/StorageBar/StatusPresentation.swift`, `Preferences.swift`,
  `UpdateChecker.swift` — unrelated.
- The refresh-interval options list and timer `.common` mode — both are
  deliberate, recently shipped behavior.
- The `--screenshot-menu` code path (`AppDelegate.swift:79-135`) — tooling;
  it depends on `refresh()` having populated the menu at launch, so keep the
  launch-time full refresh (Step 2 does).

## Git workflow

- Branch: `advisor/001-refresh-cost`
- Commit per logical unit; message style: short imperative like the repo's
  history (e.g. `Move volume enumeration off main thread`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Track whether the main menu is open

In `AppDelegate.swift`, add a property `private var isMenuOpen = false` near
`lowSpaceNotified` (line 48). In `menuWillOpen`, set `isMenuOpen = true` inside
the `menu === self.menu` branch. Implement the matching delegate method:

```swift
func menuDidClose(_ menu: NSMenu) {
    if menu === self.menu {
        isMenuOpen = false
    }
}
```

**Verify**: `swift build` → exit 0.

### Step 2: Split refresh into a cheap status-bar path and a full path

Rename the existing `refresh()` to `refreshAll()`. Extract its first block
(the `SystemStats.disk()` read, `updateStatusButton`, `checkLowSpace`, and the
`" –"` fallback — currently lines 316-331) into a new method:

```swift
/// The only work needed while the menu is closed: the status-bar title
/// and the low-space warning both derive from the startup disk alone.
private func refreshStatusBar() {
    if let disk = SystemStats.disk() {
        updateStatusButton(with: disk)
        checkLowSpace(disk)
        updateStorageItems(with: disk)   // see note below
    } else {
        statusItem.button?.title = " –"
    }
}
```

Note on `updateStorageItems`: the four storage menu items (`volumeItem`,
`availableItem`, `freeItem`, `usedItem`) are currently set in the same block.
Extract that item-setting code into `private func updateStorageItems(with disk: DiskInfo)`
and call it from `refreshStatusBar()` — the disk data is already in hand, so
updating the (invisible) items costs nothing extra and keeps `refreshAll()`
simple: `refreshAll()` starts with `refreshStatusBar()` and then does volumes,
memory, CPU, uptime, battery.

Update the callers:
- Timer closure in `startTimer()`: `self?.isMenuOpen == true ? self?.refreshAll() : self?.refreshStatusBar()`
  (write it as an explicit `if let self` block for readability).
- `applicationDidFinishLaunching` (line 74): keep calling the full `refreshAll()`
  once at launch (the screenshot tooling and first-open UX rely on a populated menu).
- `menuWillOpen` main-menu branch: `refreshAll()`.
- `refreshClicked` (line 526-529): `refreshAll()`.
- `selectDisplay` / `selectWarnThreshold` (lines 592-611): `refreshStatusBar()`
  is sufficient (they only affect the title/severity), but calling `refreshAll()`
  is also acceptable — pick one and be consistent.

**Verify**: `swift build` → exit 0. `swift test` → all pass.

### Step 3: Stop querying SMAppService on every tick

Remove the `updateSettingsChecks()` call from the end of `refreshAll()`
(it was line 347). Wire it to menu opening instead: in `buildSettingsMenu()`,
add `settingsMenu.delegate = self`, and in `menuWillOpen` add:

```swift
} else if menu === settingsMenu {
    updateSettingsChecks()
}
```

Ensure every settings action still refreshes checkmarks explicitly: `selectInterval`
and `toggleLaunchAtLogin` already call `updateSettingsChecks()`; add an explicit
`updateSettingsChecks()` call to `selectDisplay` and `selectWarnThreshold`.

**Verify**: `swift build` → exit 0. Then confirm the only remaining callers:
`grep -n "updateSettingsChecks()" Sources/StorageBar/AppDelegate.swift` →
exactly 7 matches: the declaration, the `buildSettingsMenu()` call, the
`menuWillOpen` branch, and the four `@objc` action handlers. None inside `refreshAll()`.

### Step 4: Enumerate volumes only while the menu is open, throttled

In `AppDelegate.swift`:

- Move the `refreshVolumes()` call so it only happens in `refreshAll()`
  (it already will be, after Step 2 — confirm it is not in `refreshStatusBar()`).
- Add `private var lastVolumeEnumeration: Date?` and a constant
  `private static let volumeEnumerationInterval: TimeInterval = 10`.
  In `enumerateVolumesIfNeeded()`, before the `isEnumeratingVolumes` guard, add:

```swift
if let last = lastVolumeEnumeration,
   Date().timeIntervalSince(last) < Self.volumeEnumerationInterval { return }
```

  and set `lastVolumeEnumeration = Date()` on the main queue in the completion
  block (next to `isEnumeratingVolumes = false`). The `Refresh` menu action
  should bypass staleness: in `refreshClicked()`, set `lastVolumeEnumeration = nil`
  before calling `refreshAll()`.

**Verify**: `swift build` → exit 0.

### Step 5: Rebuild the Volumes submenu only when its data changes

In `SystemStats.swift`, add `Equatable` conformance: `struct VolumeInfo: Equatable { ... }`
(all four stored properties are `Equatable`; the compiler synthesizes it).

In `AppDelegate.swift`:
- Delete the unconditional `renderVolumes(volumeSnapshot)` call from
  `refreshVolumes()` — the menu items persist between ticks; re-rendering
  identical data every tick is the flicker source.
- In the enumeration completion block, only re-render on change:

```swift
guard volumes != self.volumeSnapshot else { return }
self.volumeSnapshot = volumes
self.renderVolumes(volumes)
```

  (Keep the `defer { self.isEnumeratingVolumes = false }` and the
  `lastVolumeEnumeration` stamp *outside*/before this guard so throttling still works.)

**Verify**: `swift build` → exit 0. `swift test` → all pass.

### Step 6: Behavioral verification with temporary instrumentation

Add **temporary** log lines (they are removed in Step 7) at the top of:
`updateSettingsChecks()` → `NSLog("SB-PROBE settings-check")`,
the background block in `enumerateVolumesIfNeeded()` → `NSLog("SB-PROBE volume-enum")`,
`refreshBattery()` → `NSLog("SB-PROBE battery")`,
`refreshStatusBar()` → `NSLog("SB-PROBE status-only")`.

Build and run: `swift run 2>&1 | tee /tmp/sb-probe.log` (let it run; note
`swift run` skips notification code by design — unrelated to this test).
In the Settings submenu of the running app select "Refresh Every → 1 second". Then:

1. Leave the menu **closed** for 60 seconds.
2. Open the menu and keep it open for 15 seconds (hover the Volumes submenu if present).
3. Quit the app (menu → Quit StorageBar).

Expected in `/tmp/sb-probe.log`:
- During the closed minute: ~60 `status-only` lines; **zero** `settings-check`,
  `battery`, or `volume-enum` lines (except the single launch-time `refreshAll()` burst).
- While open: `battery` lines ~every second; `volume-enum` at most twice
  (launch + one 10-second-throttled re-enumeration); `settings-check` only if
  you opened the Settings submenu.

Copy the relevant log excerpt into your Verification report.

**Verify**: log content matches the expectations above.

### Step 7: Remove the instrumentation

Delete every `SB-PROBE` log line.

**Verify**: `grep -rn "SB-PROBE" Sources/` → no matches. `swift build` → exit 0.
`swift test` → all pass. `./build-app.sh` → exit 0.

## Test plan

AppDelegate has no unit-test seam (AppKit-bound), so the behavioral gate is the
instrumented run in Step 6, recorded in the Verification report. One small unit
test is still worthwhile: in `Tests/StorageBarTests/SystemStatsTests.swift`, add
to `DiskInfoTests` (or a new `VolumeInfoTests` class modeled on it) a test that
two `VolumeInfo` values with identical fields compare equal and differing
`available` values compare not-equal — this pins the `Equatable` conformance the
change-detection relies on.

Verification: `swift test` → all pass, including the new test (expect 25 total
if starting from 24).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0; `swift test` exits 0 with the new `VolumeInfo` equality test passing
- [ ] `grep -rn "SB-PROBE" Sources/` returns no matches
- [ ] `grep -n "updateSettingsChecks()" Sources/StorageBar/AppDelegate.swift` shows no call site inside `refreshAll()`
- [ ] `./build-app.sh` exits 0
- [ ] Step 6 log evidence pasted into the Verification report shows zero `settings-check`/`battery`/`volume-enum` lines while the menu was closed (post-launch)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift since `cd2e253`).
- After Step 2, the status-bar title stops updating while the menu is closed
  (watch it for 30 s at a 1-second interval) — the timer wiring is wrong; report
  rather than adding extra refresh calls.
- The Volumes submenu no longer appears at all after Step 5 (the initial render
  path was lost — `volumeSnapshot` starts empty, so the first enumeration result
  must always render).
- Fixing anything appears to require touching `ReclaimScanner.swift` or the
  screenshot code path.

## Required deliverable: Verification report

Append a `## Verification report` section to the bottom of this file containing:

1. **Environment**: macOS version, Swift version (`swift --version`), commit the branch was cut from.
2. **Reproduction of the problem (before)**: run Step 6's instrumentation on the
   *unmodified* code first (stash your changes or do this before Step 1) with a
   1-second interval and the menu closed for 60 s; paste the log excerpt showing
   `settings-check` / `volume-enum` / `battery` firing every tick.
3. **Confirmation of the fix (after)**: the Step 6 log excerpt from the fixed
   build showing only `status-only` lines while closed.
4. **Command outputs**: final `swift test` summary line and `./build-app.sh` last line.

## Maintenance notes

- If a future feature puts battery or memory in the status-bar title, that stat
  must move from `refreshAll()` into `refreshStatusBar()`.
- Reviewer should scrutinize: the timer closure's weak-self dance, that
  `menuDidClose` really fires for the top-level status-item menu (it does for
  `NSStatusItem.menu`), and that the first-ever volume render still happens.
- Deferred: coalescing the two `renderVolumes` paths into a diffable data source —
  overkill at this app size.

## Verification report

### 1. Environment

- macOS 27.0 (Build 26A5353q), Apple Silicon (arm64)
- Swift 6.4 (swiftlang-6.4.0.20.104), swift-driver 1.167
- Branch cut from commit `cd2e253` (feat: add 1-second refresh option); work done on
  worktree branch `worktree-agent-a021bd63697490c7b`
- Drift check: `git diff --stat cd2e253..HEAD -- AppDelegate.swift SystemStats.swift` → empty (no drift)

### 2. Reproduction of the problem (before)

Instrumented the *unmodified* code (probes in `updateSettingsChecks`, the
`enumerateVolumesIfNeeded` background block, and `refreshBattery`), set the
bare-binary defaults domain to a 1-second interval
(`defaults write StorageBar refreshInterval -float 1` — the unbundled binary
resolves `UserDefaults.standard` to the executable-name domain, verified by the
1 s tick cadence in the log), launched `.build/debug/StorageBar`, and left the
menu closed for ~75 s. Every tick did full work — 77 `settings-check`,
76 `volume-enum`, 76 `battery` lines. Excerpt (`/tmp/sb-probe-before.log`):

```
2026-07-06 19:33:59.295 StorageBar[87012] SB-PROBE settings-check   <- launch
2026-07-06 19:33:59.318 StorageBar[87012] SB-PROBE volume-enum
2026-07-06 19:33:59.318 StorageBar[87012] SB-PROBE battery
2026-07-06 19:33:59.319 StorageBar[87012] SB-PROBE settings-check
2026-07-06 19:34:00.495 StorageBar[87012] SB-PROBE volume-enum      <- menu CLOSED, still full work every second
2026-07-06 19:34:00.495 StorageBar[87012] SB-PROBE battery
2026-07-06 19:34:00.496 StorageBar[87012] SB-PROBE settings-check
2026-07-06 19:34:01.492 StorageBar[87012] SB-PROBE volume-enum
2026-07-06 19:34:01.492 StorageBar[87012] SB-PROBE battery
2026-07-06 19:34:01.492 StorageBar[87012] SB-PROBE settings-check
... (identical trio every second for the whole closed-menu minute)
```

### 3. Confirmation of the fix (after)

Same instrumentation plus the `refreshStatusBar()` → `status-only` probe on the
fixed build, 1 s interval, menu closed ~85 s (`/tmp/sb-probe-after.log`).
Counts over the whole run: `status-only` 85, `settings-check` 1,
`volume-enum` 1, `battery` 1 — the three expensive probes fired only in the
single launch-time `refreshAll()` burst (`settings-check` there is the
`buildSettingsMenu()` constructor call). Complete list of non-`status-only` lines:

```
2026-07-06 20:41:09.842 StorageBar[42135] SB-PROBE settings-check   <- launch burst only
2026-07-06 20:41:09.860 StorageBar[42135] SB-PROBE volume-enum
2026-07-06 20:41:09.860 StorageBar[42135] SB-PROBE battery
```

Closed-menu ticks (title kept updating every second — STOP condition "status bar
stops updating" did not occur):

```
2026-07-06 20:41:11.025 StorageBar[42135] SB-PROBE status-only
2026-07-06 20:41:12.025 StorageBar[42135] SB-PROBE status-only
2026-07-06 20:41:13.025 StorageBar[42135] SB-PROBE status-only
... (one per second through 20:42:34)
```

Open-menu evidence (executor adaptation: no human available to click, so the menu
was opened programmatically with the existing `--screenshot-menu` tooling flag,
which holds the menu open ~4 s): each open-state tick ran the full path
(`battery` every ~1 s), `volume-enum` did NOT re-fire (10 s throttle held),
`settings-check` did not fire (Settings submenu never opened):

```
2026-07-06 20:42:44.223 StorageBar[42579] SB-PROBE settings-check   <- buildSettingsMenu at launch
2026-07-06 20:42:44.225 StorageBar[42579] SB-PROBE status-only
2026-07-06 20:42:44.239 StorageBar[42579] SB-PROBE volume-enum      <- launch enumeration (only one in run)
2026-07-06 20:42:44.239 StorageBar[42579] SB-PROBE battery
2026-07-06 20:42:44.789 StorageBar[42579] SB-PROBE status-only     <- menu open from here on
2026-07-06 20:42:44.799 StorageBar[42579] SB-PROBE battery
2026-07-06 20:42:45.267 StorageBar[42579] SB-PROBE status-only
2026-07-06 20:42:45.288 StorageBar[42579] SB-PROBE battery
2026-07-06 20:42:46.404 StorageBar[42579] SB-PROBE status-only
2026-07-06 20:42:46.432 StorageBar[42579] SB-PROBE battery
2026-07-06 20:42:47.404 StorageBar[42579] SB-PROBE status-only
2026-07-06 20:42:47.428 StorageBar[42579] SB-PROBE battery
2026-07-06 20:42:48.241 StorageBar[42579] SB-PROBE status-only
2026-07-06 20:42:48.259 StorageBar[42579] SB-PROBE battery
```

First-ever Volumes render (STOP-condition path): with no extra volumes mounted the
menu screenshot correctly shows no Volumes row; after attaching a 20 MB APFS disk
image (`SBProbeVol`) and re-running `--screenshot-menu`, the captured menu shows
the Volumes submenu row — the first enumeration result renders even though the
unconditional per-tick `renderVolumes` call was removed. Test volume detached and
deleted afterwards. The temporary `StorageBar` defaults domain key was deleted
(`defaults delete StorageBar refreshInterval`; domain now empty).

### 4. Command outputs

- `swift test` (after Step 7 removal of probes):
  `Executed 25 tests, with 0 failures (0 unexpected) in 0.142 (0.145) seconds`
- `./build-app.sh` last line: `Built StorageBar.app — run with: open StorageBar.app`
- `grep -rn "SB-PROBE" Sources/` → no matches
- `grep -n "updateSettingsChecks()" Sources/StorageBar/AppDelegate.swift` → 7 matches, none in `refreshAll()`

### Executor adaptations (documented deviations)

- Step 6 was performed unattended: interval set via the bare-binary `StorageBar`
  defaults domain instead of the app's Settings menu; menu opening done via the
  `--screenshot-menu` tooling flag (~4 s open, ~5 open-state ticks) instead of a
  15 s manual hover; Quit replaced by killing the spawned PID.
- The plan's `plans/README.md` status-row update was skipped per operator
  instruction (reviewer maintains the index).
- `selectDisplay`/`selectWarnThreshold` use `refreshStatusBar()` (the plan's
  preferred lighter option), each followed by an explicit `updateSettingsChecks()`.
