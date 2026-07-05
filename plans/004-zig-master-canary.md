# Plan 004: Add a scheduled Zig-master canary workflow (toolchain + fuzz-runner watch)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1aa7670..HEAD -- .github/workflows/`
> If the workflows directory changed since this plan was written, compare
> against the "Current state" excerpt before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `1aa7670`, 2026-06-13

## Why this matters

The project's one moving dependency is the Zig toolchain, and PLAN.MD's
toolchain policy says upgrades land as dedicated, carefully tested commits.
Today nothing watches the horizon: CI pins 0.16.0 only, so breaking std/API
changes in upcoming Zig releases surface only when someone attempts an
upgrade. Worse, a concrete capability is gated on upstream: coverage-guided
fuzzing (`zig build test --fuzz`) is blocked by a documented Zig 0.16.0 bug
in the bundled test runner (PROGRESS.MD:36-41 — "Revisit when the toolchain
updates"), and nothing will announce when it's fixed. A weekly, allow-fail
canary on Zig master answers both: early warning of breakage, and an
automatic signal (the fuzz step turning green) that the fuzz blocker has
cleared.

## Current state

- `.github/workflows/ci.yml` is the only workflow. Its toolchain setup:

```yaml
# .github/workflows/ci.yml:12-17
    steps:
      - uses: actions/checkout@v4

      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
```

- `mlugg/setup-zig@v2` accepts `version: master` to install the latest
  master snapshot.
- PROGRESS.MD:36-41 documents the fuzz blocker: "Coverage-guided runs via
  `zig build test --fuzz` are currently blocked by an upstream Zig 0.16.0
  bug: the bundled `lib/compiler/test_runner.zig` fails to compile under
  fuzz instrumentation (`*builtin.StackTrace` vs `*debug.StackTrace`
  mismatch)."
- The corpus regression inside `zig build test` skips gracefully when
  `testdata/` is present (it is committed), so the canary can run the full
  suite.
- Note: `zig build test --fuzz` runs indefinitely once fuzzing works; the
  canary step must bound it with `timeout` and treat the *compile* phase as
  the signal (see Step 1).

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|--------------------------|---------------------|
| YAML sanity | `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/zig-master-canary.yml'))"` | exit 0 |
| Local sanity on stable | `zig build test` | exit 0 (the canary itself can only run in CI) |

## Scope

**In scope** (the only files you should create/modify):
- `.github/workflows/zig-master-canary.yml` (create)

**Out of scope** (do NOT touch):
- `.github/workflows/ci.yml` — the PR-gating workflow stays pinned to
  0.16.0; the canary must never gate PRs.
- `build.zig`, `src/**` — no code changes to make master pass; if master
  breaks the build, that is the canary *working*.

## Git workflow

- Branch: `claude/zig-master-canary`
- Single imperative commit, e.g. `Add weekly Zig-master canary workflow`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create the workflow

Create `.github/workflows/zig-master-canary.yml`:

```yaml
name: Zig master canary

# Early warning for toolchain breakage, and a watch on the upstream bug
# that blocks coverage-guided fuzzing on 0.16.0 (see PROGRESS.MD). This
# workflow is informational: it never gates pull requests.

on:
  schedule:
    - cron: "17 5 * * 1" # weekly, Monday 05:17 UTC
  workflow_dispatch:

jobs:
  canary:
    name: Build and test on Zig master
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - uses: actions/checkout@v4

      - uses: mlugg/setup-zig@v2
        with:
          version: master

      - name: Zig version
        run: zig version

      - name: Check formatting
        run: zig fmt --check .

      - name: Run tests
        run: zig build test

      # Probes whether the upstream fuzz-runner compile bug is fixed.
      # While the bug persists this step fails fast at compile time; once
      # fixed, fuzzing starts and the bounded timeout exits 124, which we
      # treat as success ("fuzzing ran").
      - name: Probe coverage-guided fuzzing
        run: |
          set +e
          timeout 120 zig build test --fuzz
          status=$?
          if [ "$status" = "124" ]; then
            echo "Fuzzing ran until the time bound: upstream blocker appears FIXED."
            exit 0
          fi
          echo "fuzz probe exit: $status (non-124 means still blocked or test failure)"
          exit "$status"
```

**Verify**: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/zig-master-canary.yml'))"` → exit 0.

### Step 2: Confirm stable CI is untouched

**Verify**: `git diff --name-only` → lists only
`.github/workflows/zig-master-canary.yml` (plus `plans/README.md` when you
update the index).

## Test plan

No code tests. The workflow can only be exercised in CI: if the operator
allows pushing, trigger it once via `workflow_dispatch` and record the
outcome; otherwise note in the report that the first scheduled run will
validate it.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `.github/workflows/zig-master-canary.yml` exists and parses as YAML
- [ ] `grep -n "continue-on-error: true" .github/workflows/zig-master-canary.yml` → 1 match
- [ ] `grep -n "version: master" .github/workflows/zig-master-canary.yml` → 1 match
- [ ] `grep -c "pull_request" .github/workflows/zig-master-canary.yml` returns 0 (never gates PRs)
- [ ] `git diff --name-only 1aa7670..HEAD -- .github/workflows/ci.yml` is empty
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A workflow named like a canary already exists under `.github/workflows/`
  (someone landed one since planning).
- The operator's environment rejects `mlugg/setup-zig@v2` `version: master`
  (check the action's README only if the dispatch run fails; do not switch
  actions on your own).

## Maintenance notes

- When the fuzz probe starts reporting "FIXED", the follow-up (not this
  plan) is PROGRESS.MD's own TODO: revisit coverage-guided fuzzing, give CI
  a fixed fuzz time budget per target (PLAN.MD step 11), and update
  PROGRESS.MD:36-41.
- When a new stable Zig releases, the upgrade commit (per PLAN.MD toolchain
  policy) should bump `ci.yml`; the canary needs no change — it always
  tracks master.
- `continue-on-error: true` means failures show as green-with-annotation at
  the run level; the maintainer should watch the workflow's run list (or
  add a notification later) rather than expect a red badge.
