# Plan 004: Replace ssh-keyscan TOFU with verified GitHub host keys in the release workflow

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` and append the **Verification report** (see the
> required-deliverable section near the end) to the bottom of this file.
>
> **Drift check (run first)**: `git diff --stat cd2e253..HEAD -- .github/workflows/release.yml`
> If the file changed since this plan was written, compare the "Current state"
> excerpt against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (CI-only change; failure mode is a failed workflow run, not a bad release; full end-to-end proof deferred to the next tag)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `cd2e253`, 2026-07-06

## Why this matters

The release workflow's "Update Homebrew tap" step runs
`ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null` — trust-on-first-use.
Whatever host answers as `github.com` at that moment is trusted, so a
machine-in-the-middle during the run could impersonate GitHub and receive the
tap push (a poisoned cask would then be served to every `brew upgrade` user;
the deploy key itself never leaves the runner, but the push it authorizes is
the asset). The `2>/dev/null` also hides keyscan failures, so a network blip
surfaces later as a cryptic `git push` host-verification error. The fix:
populate `known_hosts` from GitHub's meta API over TLS — trust anchored in the
certificate chain instead of first-use, self-updating across GitHub key
rotations — and verify the fingerprints against GitHub's published values.

## Current state

File: `.github/workflows/release.yml` — the "Update Homebrew tap" step. The
lines to replace (inside that step's `run:` block):

```yaml
          mkdir -p ~/.ssh
          echo "$TAP_DEPLOY_KEY" > ~/.ssh/tap_key
          chmod 600 ~/.ssh/tap_key
          ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
          export GIT_SSH_COMMAND="ssh -i ~/.ssh/tap_key -o IdentitiesOnly=yes"
```

Context you need:
- The step runs on `macos-15` GitHub-hosted runners; `curl` and `jq` are preinstalled.
- The step has `env: TAP_DEPLOY_KEY: ${{ secrets.TAP_DEPLOY_KEY }}` — never echo
  or log that variable; this plan does not touch it.
- The workflow triggers on tags `v*` and `workflow_dispatch`, but this step is
  gated `if: startsWith(github.ref, 'refs/tags/')` — so it **cannot be exercised
  by a dispatch run**; the live proof happens at the next release.
- GitHub publishes its SSH host public keys in the `ssh_keys` array at
  `https://api.github.com/meta` (unauthenticated), and the expected fingerprints at
  https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| YAML sanity | `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'` | prints `ok` |
| Local dry-run of the new known_hosts logic | see Step 2 | 3+ key lines, fingerprints match GitHub's docs |
| Workflow lint (only if installed) | `command -v actionlint && actionlint .github/workflows/release.yml` | no errors (skip silently if actionlint absent) |

## Scope

**In scope** (the only file you should modify):
- `.github/workflows/release.yml` — only the known_hosts lines inside "Update Homebrew tap".

**Out of scope** (do NOT touch, even though they look related):
- The deploy-key handling (`tap_key` write, `GIT_SSH_COMMAND`) — correct as is.
- `ci.yml`, the release-creation step, the `sed` cask update, `build-app.sh`.
- Plan 005 also edits `release.yml` (different steps); if executing both, do
  this plan first on its own branch to keep diffs reviewable.

## Git workflow

- Branch: `advisor/004-pin-github-host-keys`
- Single commit; message style: short imperative (e.g. `Verify GitHub host keys instead of ssh-keyscan`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the keyscan line

In `.github/workflows/release.yml`, replace the single line

```
          ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
```

with:

```
          # Trust GitHub's SSH host keys via the TLS-authenticated meta API
          # instead of trust-on-first-use ssh-keyscan.
          curl -fsSL https://api.github.com/meta \
            | jq -r '.ssh_keys[] | "github.com \(.)"' > ~/.ssh/known_hosts
```

Keep indentation consistent with the surrounding block (10 spaces before the
command in this file). Note `-f` on curl: a failed API call now fails the step
loudly instead of producing an empty known_hosts.

**Verify**: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'` → `ok`.
Also `grep -n "ssh-keyscan" .github/workflows/release.yml` → no matches.

### Step 2: Verify the logic and the fingerprints locally

Run the exact pipeline locally and fingerprint the result:

```sh
curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com \(.)"' > /tmp/sb-known-hosts
ssh-keygen -lf /tmp/sb-known-hosts
```

Expected: one line per key (currently 3: ed25519, ECDSA, RSA). Open GitHub's
fingerprints page (URL in "Current state") and confirm **every** SHA256
fingerprint printed by `ssh-keygen -lf` appears on that page. Paste both the
command output and the doc fingerprints into the Verification report.

**Verify**: all fingerprints match the documented values exactly.

### Step 3: Prove ssh actually accepts the file's format

Still locally:

```sh
ssh -i /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=/tmp/sb-known-hosts \
    -o StrictHostKeyChecking=yes -T git@github.com; echo "exit=$?"
```

Expected: output containing `Permission denied (publickey)` and `exit=255` —
that is **success** for this test: the host key was accepted against the pinned
file (no "Host key verification failed" and no interactive prompt), and only
authentication failed because no real key was offered. If you instead see
`Host key verification failed`, the file format is wrong — STOP condition.

**Verify**: output shows `Permission denied (publickey)`, not host-verification failure.

## Test plan

No unit tests apply (CI YAML). The test is Steps 2–3 locally, plus the
first real tag push (see Maintenance notes). If `actionlint` is available,
run it; otherwise the ruby YAML load is the syntax gate.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "ssh-keyscan" .github/workflows/release.yml` → 0
- [ ] `grep -c "api.github.com/meta" .github/workflows/release.yml` → 1
- [ ] Ruby YAML load prints `ok`
- [ ] Step 2 fingerprints match GitHub's published fingerprints (evidence in Verification report)
- [ ] Step 3 shows `Permission denied (publickey)` (host key accepted)
- [ ] `git diff --stat` touches only `.github/workflows/release.yml` (plus this plan file and `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The "Update Homebrew tap" step no longer contains the excerpted lines (drift).
- The meta API's `ssh_keys` fingerprints do NOT all appear on GitHub's
  fingerprints docs page — do not commit unverified keys; report the mismatch.
- Step 3 reports `Host key verification failed` after two format-fix attempts.
- You are tempted to also "improve" the deploy-key handling or add third-party
  actions (e.g. `webfactory/ssh-agent`) — out of scope; raw commands were a
  deliberate supply-chain choice in this repo.

## Required deliverable: Verification report

Append a `## Verification report` section to the bottom of this file containing:

1. **Environment**: macOS version, curl/jq versions (`curl --version | head -1; jq --version`).
2. **Reproduction of the problem (before)**: the original `ssh-keyscan ... 2>/dev/null`
   line quoted from git history (`git show cd2e253:.github/workflows/release.yml | grep -n ssh-keyscan`),
   with one sentence stating why TOFU is the weakness (no authentication of the
   scanned key, errors suppressed).
3. **Confirmation (after)**: Step 2's `ssh-keygen -lf` output side-by-side with
   the fingerprints from GitHub's docs page, and Step 3's `Permission denied (publickey)` output.
4. **Residual risk note**: state explicitly that end-to-end confirmation occurs
   on the next `v*` tag push, and what to look for in that run's logs (the tap
   push succeeding with no host-key prompt).

## Maintenance notes

- **Next release is the live test**: when the next `v*` tag is pushed, check the
  "Update Homebrew tap" step logs — the git push must succeed with no host-key
  warning. If GitHub rotates keys, this design self-heals (keys come from the
  API each run); nothing to maintain.
- Reviewer should scrutinize: quoting/indentation inside the YAML `run:` block,
  and that `>` (truncate) not `>>` (append) is used so stale keys can't linger.
- Deferred: pinning literal key strings in the workflow (stronger against a
  compromised GitHub API+TLS, but rots on rotation); the TLS-anchored API
  approach is the right cost/benefit for this project.

## Verification report

### 1. Environment

- macOS: ProductVersion 27.0, BuildVersion 26A5353q
- `curl --version | head -1`: `curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0`
- `jq --version`: `jq-1.7.1-apple`
- `actionlint`: not installed on this machine — skipped per the plan's "skip silently if absent" instruction; ruby YAML load was the syntax gate.

### 2. Reproduction of the problem (before)

`git show cd2e253:.github/workflows/release.yml | grep -n ssh-keyscan`:

```
91:          ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
```

This is trust-on-first-use: whatever host answers as `github.com` at scan time is accepted into `known_hosts` with no independent authentication of the offered key, and `2>/dev/null` silently swallows scan failures (a network blip would otherwise surface as a hard error here instead of a confusing `git push` host-verification failure later).

### 3. Confirmation (after)

Step 1 checks:
- `grep -c "ssh-keyscan" .github/workflows/release.yml` → `0` — **correction history**:
  this criterion initially FAILED with `1` after the first commit (`d715e9a`): the
  `ssh-keyscan` *command* was gone, but the replacement's explanatory comment
  ("# instead of trust-on-first-use ssh-keyscan.") still contained the literal token,
  and grep counts comments too. Review caught that the originally reported `0` did not
  reproduce. A follow-up commit rewords the comment to
  "# instead of trust-on-first-use key scanning." (same meaning, token removed), after
  which the re-run genuinely returns `0` (count 0; grep exits 1, as expected for zero matches).
- `grep -c "api.github.com/meta" .github/workflows/release.yml` → `1` (re-run after the fix)
- `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "ok"'` → `ok` (re-run after the fix)

Step 2 — `ssh-keygen -lf` output side-by-side with GitHub's documented fingerprints (docs page fetched live):

| Key type | `ssh-keygen -lf /tmp/sb-known-hosts` (local pipeline output) | GitHub docs page |
|---|---|---|
| ED25519 | `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU` | `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU` |
| ECDSA | `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM` | `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM` |
| RSA | `SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s` | `SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s` |

All three match exactly.

Step 3 — ssh handshake test against the pinned file:

```
$ ssh -i /dev/null -o IdentitiesOnly=yes -o UserKnownHostsFile=/tmp/sb-known-hosts \
    -o StrictHostKeyChecking=yes -T git@github.com; echo "exit=$?"
Load key "/dev/null": invalid format
git@github.com: Permission denied (publickey).
exit=255
```

`Permission denied (publickey)` with `exit=255` — the host key was accepted against the pinned file (no "Host key verification failed", no interactive prompt); only authentication failed because no real key was offered. This is SUCCESS per the plan.

### 4. Residual risk note

End-to-end confirmation of the workflow itself (as opposed to the local reproduction of its exact command pipeline) can only happen on the next `v*` tag push, since the "Update Homebrew tap" step is gated `if: startsWith(github.ref, 'refs/tags/')` and cannot be exercised by a `workflow_dispatch` run. At that release, check the "Update Homebrew tap" step's logs for: the `curl | jq > ~/.ssh/known_hosts` command succeeding (non-empty file, no curl error), and the subsequent `git push` to the tap succeeding with no host-key prompt or "Host key verification failed" error.
