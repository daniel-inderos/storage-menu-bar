# Plan 005: Build the Developer ID signing + notarization pipeline (dormant until credentials exist)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` and append the **Verification report** (see the
> required-deliverable section near the end) to the bottom of this file.
>
> **Drift check (run first)**: `git diff --stat cd2e253..HEAD -- .github/workflows/release.yml build-app.sh`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch, treat
> it as a STOP condition. (If Plan 004 already landed, its known_hosts change in
> the tap step is expected drift — proceed; anything else is a STOP.)

## Status

- **Priority**: P1 (deadline-driven: Homebrew removes `--no-quarantine` ~September 2026 and plans to disable casks failing Gatekeeper — the cask install path breaks then unless releases are notarized)
- **Effort**: M
- **Risk**: MED (edits the release workflow; mitigated because every new step is skipped until secrets exist, so current releases are bit-for-bit unaffected)
- **Depends on**: none (coordinate with 004 — same file; land 004 first, see its Scope note)
- **Category**: migration / direction
- **Planned at**: commit `cd2e253`, 2026-07-06

## Why this matters

StorageBar releases are ad-hoc signed and unnotarized. That is honestly
documented in the README, but Homebrew's ~September 2026 removal of
`--no-quarantine` (already quoted in README lines 74–83) will break the cask
path for unnotarized apps. Whether to enroll in the Apple Developer Program
($99/yr) is the maintainer's decision and explicitly NOT part of this plan.
This plan removes all the engineering from that decision: after it lands, the
pipeline signs with Developer ID + hardened runtime, notarizes, staples, and
verifies — **automatically, on the day six repository secrets are configured** —
and until that day, every new step self-skips and releases behave exactly as
today. Enrollment becomes a 30-minute secrets-configuration task instead of an
engineering project under deadline pressure.

## Current state

Files:

- `build-app.sh` (32 lines) — builds the universal binary, assembles the bundle, then ad-hoc signs:

```sh
# build-app.sh:30 (second-to-last command)
# Ad-hoc sign so macOS treats the bundle as a stable identity
codesign --force --sign - "$APP"
```

- `.github/workflows/release.yml` — job `build` on `macos-15`, steps in order:
  "Check tagged version" → "Build StorageBar.app" (runs `./build-app.sh`, with
  `APP_VERSION` on tag builds) → "Zip app bundle"
  (`ditto -c -k --keepParent StorageBar.app StorageBar.zip`) → "Verify release
  artifact" → "Create release" (uploads `StorageBar.zip`) → "Update Homebrew tap"
  (computes `SHA=$(shasum -a 256 StorageBar.zip ...)` and pushes the cask).
  **Ordering constraint that matters**: the tap's sha256 and the uploaded asset
  both read `StorageBar.zip`, so notarization + stapling must replace
  `StorageBar.zip` BEFORE "Verify release artifact".

- `ci.yml` runs `./build-app.sh` on every push with no signing env — the
  default path must keep working credential-free.

- `Info.plist` — bundle ID `io.github.daniel-inderos.StorageBar`; the app uses
  no restricted entitlements (no JIT, no camera/mic, plain AppKit + IOKit
  reads), so hardened runtime needs no entitlements file.

Secrets that will exist **later** (referenced by name only — never echo any of
these in workflow logs, and never write their values anywhere in this repo):

| Secret name | Content |
|---|---|
| `DEVELOPER_ID_P12` | base64 of the "Developer ID Application" certificate exported as .p12 |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12 export password |
| `DEVELOPER_ID_IDENTITY` | the identity string, e.g. `Developer ID Application: <Name> (<TEAMID>)` |
| `APPLE_ID` | the Apple ID email used for notarization |
| `APPLE_TEAM_ID` | the 10-character team ID |
| `NOTARY_PASSWORD` | an app-specific password for notarytool |

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| YAML sanity | `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'` | prints `ok` |
| Shell sanity | `bash -n build-app.sh` | exit 0 |
| Default build unchanged | `./build-app.sh` | exit 0, `Built StorageBar.app` |
| Inspect signature | `codesign -dv StorageBar.app 2>&1` | contains `Signature=adhoc` on the default path |
| Tests still pass | `swift test` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `build-app.sh`
- `.github/workflows/release.yml`

**Out of scope** (do NOT touch, even though they look related):
- `README.md` — it currently (correctly) says releases are unnotarized;
  rewriting it belongs to activation day, not now (see Maintenance notes for
  the prepared wording).
- `ci.yml` — the credential-free path must keep passing; if it needs edits,
  something in this plan went wrong.
- Enrolling, creating certificates, or configuring secrets — maintainer-only.
- Third-party signing actions (`apple-actions/import-codesign-certs` etc.) —
  this repo deliberately avoids third-party actions in the release path;
  use raw `security` / `xcrun` commands.

## Git workflow

- Branch: `advisor/005-notarization-prep`
- Two commits: one for `build-app.sh`, one for the workflow; short imperative messages.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Teach build-app.sh an optional real identity

Replace the ad-hoc signing line with an env-driven identity that defaults to
today's behavior:

```sh
# Sign the bundle. Default is ad-hoc (stable local identity, no Apple account).
# Set CODESIGN_IDENTITY to a "Developer ID Application: ..." identity to produce
# a distributable build; hardened runtime + timestamp are notarization requirements.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
fi
```

**Verify**: `bash -n build-app.sh` → exit 0. `./build-app.sh` → exit 0.
`codesign -dv StorageBar.app 2>&1 | grep Signature` → `Signature=adhoc`.
`codesign --verify --deep --strict StorageBar.app` → exit 0.

### Step 2: Gate the workflow on secret presence

GitHub Actions cannot reference `secrets` directly in step `if:` conditions;
the reliable pattern is a job-level env flag. In `release.yml`, add to the
`build` job (directly under `runs-on: macos-15`):

```yaml
    env:
      HAVE_SIGNING: ${{ secrets.DEVELOPER_ID_P12 != '' }}
```

**Verify**: ruby YAML load → `ok`.

### Step 3: Import the certificate before the build step

Insert a new step between "Check tagged version" and "Build StorageBar.app":

```yaml
      - name: Import Developer ID certificate
        if: env.HAVE_SIGNING == 'true'
        env:
          P12_BASE64: ${{ secrets.DEVELOPER_ID_P12 }}
          P12_PASSWORD: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
        run: |
          KEYCHAIN_PASSWORD="$(uuidgen)"
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security set-keychain-settings -lut 21600 build.keychain
          echo "$P12_BASE64" | base64 -d > cert.p12
          security import cert.p12 -k build.keychain -P "$P12_PASSWORD" -T /usr/bin/codesign
          rm -f cert.p12
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" build.keychain > /dev/null
```

And extend the existing "Build StorageBar.app" step so the build signs with the
real identity when present, changing only its `run:` invocation lines to export
the identity first:

```yaml
        env:
          CODESIGN_IDENTITY: ${{ env.HAVE_SIGNING == 'true' && secrets.DEVELOPER_ID_IDENTITY || '-' }}
```

(Attach that `env:` block to the existing build step; the script body is
unchanged — `build-app.sh` reads `CODESIGN_IDENTITY` from the environment.)

**Verify**: ruby YAML load → `ok`.

### Step 4: Notarize, staple, and re-zip after "Zip app bundle"

Insert between "Zip app bundle" and "Verify release artifact":

```yaml
      - name: Notarize and staple
        if: env.HAVE_SIGNING == 'true'
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          NOTARY_PASSWORD: ${{ secrets.NOTARY_PASSWORD }}
        run: |
          xcrun notarytool submit StorageBar.zip --wait \
            --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$NOTARY_PASSWORD"
          xcrun stapler staple StorageBar.app
          # The stapled bundle is the shippable artifact: rebuild the zip so the
          # release asset and the Homebrew sha256 both see the stapled app.
          ditto -c -k --keepParent StorageBar.app StorageBar.zip
          spctl --assess --type execute --verbose StorageBar.app
```

The trailing `spctl` assessment fails the job if Gatekeeper wouldn't accept the
stapled app — that's the point.

**Verify**: ruby YAML load → `ok`. Confirm step order with
`grep -n "name:" .github/workflows/release.yml` →
`Check tagged version` < `Import Developer ID certificate` <
`Build StorageBar.app` < `Zip app bundle` < `Notarize and staple` <
`Verify release artifact` < `Create release` < `Update Homebrew tap`.

### Step 5: Prove the dormant path is truly dormant

Without any secrets configured locally, the only executable proof is that
nothing changed for the credential-free path:

1. `./build-app.sh` → `Signature=adhoc` (as in Step 1).
2. `swift test` → all pass.
3. `git diff cd2e253 -- .github/workflows/release.yml` — read every hunk and
   confirm each added step carries `if: env.HAVE_SIGNING == 'true'`, and that
   no pre-existing step's commands were altered (the build step gained only an
   `env:` block; Plan 004's known_hosts lines are the only other permitted delta).

**Verify**: all three checks pass; paste the diff-review summary into the
Verification report.

## Test plan

No unit tests apply. The gates are: `bash -n`, ruby YAML load, unchanged
ad-hoc `codesign -dv` output, full `swift test`, and the dormancy diff-review
in Step 5. The signed path can only be end-to-end tested after enrollment —
that residual is documented in the Verification report and Maintenance notes,
not silently ignored.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `./build-app.sh` with no env → exit 0 and `codesign -dv StorageBar.app 2>&1 | grep -c "Signature=adhoc"` → 1
- [ ] `bash -n build-app.sh` and ruby YAML load both succeed
- [ ] `grep -c "HAVE_SIGNING" .github/workflows/release.yml` → ≥ 3 (job env + two step gates)
- [ ] `grep -n "name:" .github/workflows/release.yml` shows the step order from Step 4's verify
- [ ] `swift test` exits 0
- [ ] No secret **values** appear anywhere in the diff (names only) — `git diff cd2e253 | grep -ci "BEGIN CERTIFICATE\|PRIVATE KEY"` → 0
- [ ] `git status` shows no modified files outside `build-app.sh` and `.github/workflows/release.yml` (plus plan files)
- [ ] `plans/README.md` status row updated to DONE-DORMANT (pipeline built, awaiting credentials)

## STOP conditions

Stop and report back (do not improvise) if:

- The release.yml step order or the tap step's `shasum` line differs from
  "Current state" (beyond Plan 004's expected change).
- You cannot express the secret-presence gate without referencing `secrets.*`
  inside a step-level `if:` — report rather than shipping a gate you haven't
  seen documented working.
- Anything requires modifying `ci.yml` or `README.md`.
- You are asked (by anyone or anything) to output, decode, or store certificate
  or password material — this plan never handles real secret values.

## Required deliverable: Verification report

Append a `## Verification report` section to the bottom of this file containing:

1. **Environment**: macOS version, `swift --version`, base commit.
2. **Reproduction of the current state (before)**: `git show cd2e253:build-app.sh | grep -n "codesign"`
   output (the unconditional ad-hoc sign) and one sentence on the Homebrew
   deadline this pipeline pre-empts.
3. **Confirmation (after)**: the `codesign -dv` adhoc output proving the default
   path is unchanged; the `grep -n "name:"` step-order listing; the Step 5
   diff-review summary confirming every new step is gated.
4. **Activation checklist** (for the maintainer, verbatim): enroll in the Apple
   Developer Program → create a "Developer ID Application" certificate in Xcode
   or developer.apple.com → export as .p12 with a password → `base64 -i cert.p12 | pbcopy`
   → add the six repository secrets named in this plan (Settings → Secrets and
   variables → Actions) → generate an app-specific password at appleid.apple.com
   for `NOTARY_PASSWORD` → push the next `v*` tag and watch the "Notarize and
   staple" step run → then update README's install sections (remove the
   `--no-quarantine` guidance and the "not notarized" caveats).

## Maintenance notes

- **First activated release**: watch `notarytool submit --wait` output; if
  Apple rejects (e.g. a hardened-runtime violation), the likely fix is an
  entitlements file — none is expected for this app's API surface (AppKit,
  IOKit reads, ServiceManagement, UserNotifications are all fine unhardened).
- The Homebrew cask may also want `--no-quarantine` guidance removed from the
  tap's caveats on activation day — that lives in the `homebrew-tap` repo, not here.
- Reviewer should scrutinize: the zip→notarize→staple→re-zip ordering relative
  to the sha256 computation, and that `set -euo pipefail` (already at the top of
  build-app.sh) still guards the new branch.
- Deferred by design: the enrollment decision itself; README rewording;
  Sparkle-style auto-updates (out of scope and contrary to the app's privacy stance).

## Verification report

### 1. Environment

- macOS: ProductVersion 27.0, BuildVersion 26A5353q
- `swift --version`: Swift toolchain used by `swift build`/`swift test` in this worktree (Xcode-bundled toolchain; targeting arm64e-apple-macos14.0 per test-run output)
- Base commit: `cd2e253` (plus this worktree's own Plan 004 commit `d715e9a "Verify GitHub host keys instead of ssh-keyscan"`, which is the tolerated drift this plan's drift-check text explicitly allows)

### 2. Reproduction of the current state (before)

`git show cd2e253:build-app.sh | grep -n "codesign"`:

```
29:# Ad-hoc sign so macOS treats the bundle as a stable identity
30:codesign --force --sign - "$APP"
```

Unconditional ad-hoc signing — every build, everywhere, gets the same "no real identity" signature. This pipeline pre-empts Homebrew's ~September 2026 removal of `--no-quarantine` support for casks (Homebrew plans to stop allowing the quarantine-bypass flag and disable casks that fail Gatekeeper); an unnotarized ad-hoc-signed app will not pass Gatekeeper, so the cask install path breaks on that date unless releases are signed with a Developer ID and notarized before then.

### 3. Confirmation (after)

**Default (credential-free) path unchanged** — `codesign -dv StorageBar.app 2>&1 | grep Signature`:

```
Signature=adhoc
```

(confirmed by two independent `./build-app.sh` runs, both exit 0, both `codesign --verify --deep --strict StorageBar.app` → exit 0)

**Step-order listing** — `grep -n "name:" .github/workflows/release.yml`:

```
1:name: Release
19:      - name: Check tagged version
29:      - name: Import Developer ID certificate
45:      - name: Build StorageBar.app
55:      - name: Zip app bundle
58:      - name: Notarize and staple
73:      - name: Verify release artifact
88:      - name: Create release
116:      - name: Update Homebrew tap
```

This matches the plan's required order exactly: Check tagged version < Import Developer ID certificate < Build StorageBar.app < Zip app bundle < Notarize and staple < Verify release artifact < Create release < Update Homebrew tap.

**Step 5 diff-review summary** (`git diff cd2e253 -- .github/workflows/release.yml build-app.sh`, read hunk by hunk):

- `build-app.sh`: only the signing block changed (ad-hoc default preserved via `CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"`; the swift build lines, version stamping, arch check, and final echo are byte-identical).
- `release.yml` job env: added `HAVE_SIGNING: ${{ secrets.DEVELOPER_ID_P12 != '' }}` at job level.
- New step "Import Developer ID certificate": carries `if: env.HAVE_SIGNING == 'true'`. ✓ gated.
- "Build StorageBar.app" step: gained only an `env:` block (`CODESIGN_IDENTITY: ...`); its `run:` body is untouched, byte-for-byte identical to the pre-existing script.
- New step "Notarize and staple": carries `if: env.HAVE_SIGNING == 'true'`. ✓ gated.
- The only other delta in `release.yml` versus `cd2e253` is Plan 004's already-landed `known_hosts` change in the "Update Homebrew tap" step (the `ssh-keyscan` line replaced by the `curl | jq` pipeline) — explicitly tolerated by this plan's drift-check note. No other pre-existing step's commands were altered.
- Secret-value scan — **correction**: the done criterion as written,
  `git diff cd2e253 | grep -ci "BEGIN CERTIFICATE\|PRIVATE KEY"`, actually returns `2`,
  not the `0` originally reported. Both matches are self-referential: they are this very
  plan document (committed alongside the code) quoting its own done-criterion text —
  one match is the criterion line itself in "Done criteria", the other is this report's
  earlier restatement of it. Neither is certificate or key material. (After this
  correction commit the unscoped count rises further, for the same self-referential
  reason: this paragraph also quotes the pattern.) The check that
  proves the criterion's intent — no secret values in the shipped code changes — is the
  scoped scan, which was run and observed:
  `git diff cd2e253..HEAD -- .github/workflows/release.yml build-app.sh | grep -ci "BEGIN CERTIFICATE\|PRIVATE KEY"` → `0`
  (grep exits 1, as expected for zero matches). No secret values, only secret names,
  appear anywhere in the code diff.
- `swift test` → 24 tests executed, 0 failures.

### 4. Activation checklist (for the maintainer, verbatim)

Enroll in the Apple Developer Program → create a "Developer ID Application" certificate in Xcode or developer.apple.com → export as .p12 with a password → `base64 -i cert.p12 | pbcopy` → add the six repository secrets named in this plan (Settings → Secrets and variables → Actions) → generate an app-specific password at appleid.apple.com for `NOTARY_PASSWORD` → push the next `v*` tag and watch the "Notarize and staple" step run → then update README's install sections (remove the `--no-quarantine` guidance and the "not notarized" caveats).

### Residual risk note

The signed/notarized path (the `if: env.HAVE_SIGNING == 'true'` branches) cannot be exercised end-to-end until the six secrets exist — no unit or integration test can substitute for a real Apple Developer Program identity and notarization round-trip. That residual is by design (documented here and in Maintenance notes, not silently ignored): the first activated release is the real test, and the "Maintenance notes" section above documents what to check if `notarytool submit --wait` rejects the build.
