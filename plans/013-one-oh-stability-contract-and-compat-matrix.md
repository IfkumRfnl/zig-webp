# Plan 013: Define the 1.0 API stability contract and make "compatibility testing" a checkable gate

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- RELEASING.MD PLAN.MD README.MD src/root.zig .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (new CI jobs can be flaky; everything else is docs)
- **Depends on**: none (plan 012 lands a new API this contract will cover —
  execute 012 first if possible so the tier list includes it)
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

`PLAN.MD` conditions the 1.0.0 release on "docs, and compatibility testing"
— but "compatibility testing" is defined nowhere in PLAN.MD, PROGRESS.MD, or
RELEASING.MD, so the gate can never be honestly checked. Likewise, step 12
requires stabilizing the public API, yet `src/root.zig` exports ~40 `vp8_*`/
`vp8l_*` internal modules with only a vague "less stable" note, so nobody can
say what 1.0 actually promises. Concretely known gaps: big-endian targets are
"untested until CI covers one" (`PLAN.MD:34-38`), CI runs on `ubuntu-latest`
only, and the ≥2-browser render check (the last open step-9 item) has no
recorded procedure or result. This plan turns all of that into checkable
state: a written stability-tier contract, a compatibility matrix in
RELEASING.MD, a big-endian CI job, a macOS CI job, and a recorded
browser-check procedure.

## Current state

- `RELEASING.MD` — maps release gates to concrete checks (lines 19–28) with
  an honesty note (lines 30–35) about what runs in CI vs. local oracles.
  Lines 12–15 state the 1.0.0 bar: "the 8b and 8c lossy-encode gates,
  animation encode, metadata, hardening (step 11), docs, and compatibility
  testing". No definition of the last item exists.
- `PLAN.MD:34-38` — portability stance: "development and CI test
  little-endian 64-bit targets. Code must not assume host endianness, but
  big-endian targets remain untested until CI covers one."
- `PLAN.MD:375-391` — step 12: stabilize APIs, document formats/ownership/
  errors, release criteria.
- `src/root.zig:14-17` — the only stability statement today:

  ```zig
  //! The `vp8_*` and `vp8l_*` exports expose codec internals for tooling,
  //! tests, and advanced callers; their APIs are less stable than the
  //! functions above.
  ```

- `.github/workflows/ci.yml` — one job (`test`) on `ubuntu-latest`:
  `zig fmt --check .`, `zig build check`, `zig build test`, using the local
  composite action `.github/actions/setup-zig` (pinned `0.16.0`).
- `.github/actions/setup-zig/action.yml` — composite bash action: resolves
  `"$(uname -m)-$(uname -s | tr ...)"` against ziglang.org's `index.json`,
  downloads a `.tar.xz`, verifies SHA-256. This works as-is on Linux and
  macOS runners. It does NOT work on Windows runners (index key
  `x86_64-windows` is a `.zip`; `uname -s` under Git-bash reports
  `MINGW64_NT-...`) — Windows is therefore explicitly deferred, not silently
  skipped (see step 5).
- `README.MD:66-68` — the browser gate: "The only open step-9 item is the
  manual ≥2-browser render confirmation (two sample animations under
  `testdata/animation/`)." The samples are
  `testdata/animation/anim_minimized_lossless.webp` and
  `testdata/animation/anim_minimized_lossy.webp`.
- `PROGRESS.MD` — the log of dated results; browser-check results belong
  here once run.
- Zig 0.16.0 supports cross-compilation to big-endian targets and can run
  foreign-target test binaries under QEMU via the `-fqemu` build flag.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 |
| Cross-compile test binary (BE) | `zig build test -Dtarget=powerpc64-linux -fqemu` | exit 0 with `qemu-ppc64` installed; see step 3 |
| Install qemu locally (Debian/Ubuntu) | `sudo apt-get install qemu-user-static` | qemu-ppc64 on PATH |
| Validate workflow syntax | `gh workflow list` after push, or a YAML linter | file parses |

## Scope

**In scope** (the only files you should modify):

- `src/root.zig` — module doc comment only (stability tiers).
- `README.MD` — stability statement + compatibility summary.
- `RELEASING.MD` — the compatibility-matrix section and gate table rows.
- `PLAN.MD` — replace the vague "compatibility testing" phrase with a pointer
  to the RELEASING.MD matrix.
- `PROGRESS.MD` — dated entries for the new CI coverage and (if you can run
  it) the browser check.
- `.github/workflows/ci.yml` — new jobs.
- `plans/README.md` — status row.

**Out of scope** (do NOT touch, even though they look related):

- `.github/actions/setup-zig/action.yml` — extending it for Windows `.zip`
  handling is deliberately deferred (record it, don't build it).
- Any `src/` code change. If a big-endian test failure appears, that is a
  finding to report, not to fix here (STOP condition).
- `build.zig` — no new build steps are needed; the jobs reuse existing ones.

## Git workflow

- Branch: `one-oh-compat-matrix` (repo convention: `<slug>`).
- Commit style: single imperative summary line, e.g.
  `Define 1.0 stability tiers and add BE/macOS CI compatibility jobs`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the API stability tiers

In `src/root.zig`'s module doc comment (the `//!` block, lines 1–17), replace
the vague "less stable" sentence with an explicit two-tier contract:

- **Tier 1 (stable at 1.0, semver-governed)**: the named entry points and
  types the module doc already lists — `decodeStatic`, `decodeAnimation`,
  `AnimationDecoder`, `encodeLossless`, `encodeLossy`, `encodeStatic`,
  `encodeAnimation`, `encodeAnimationFromBuffers`, `encodeAnimationMinimized`,
  `parseFeatures`, `parseWebP`, `isWebP`, `parseHeader`, `parseChunkHeader`,
  `errorCategory`, plus their parameter/result types (`DecoderOptions`,
  `EncoderOptions`, `ResourceLimits`, `ImageBuffer`, `Dimensions`,
  `PixelFormat` via `image`, `Error`/`ErrorCategory`, `FeatureSummary`,
  `DemuxResult`, the animation option/frame types, `MetadataPayloads`).
  Include `decodeStaticInto` if plan 012 has landed (check
  `grep -c decodeStaticInto src/root.zig`).
- **Tier 2 (internals, no stability promise)**: the `vp8_*` and `vp8l_*`
  module exports and their aliased types, plus `bit_reader`/`bit_writer`,
  `testing`, and other module re-exports — exported for tooling and advanced
  callers, may change in any release.

State the rule in one sentence: additions to `errors.Error` are not breaking;
removals/renames of Tier 1 names are.

Mirror the same two-tier statement in `README.MD` (one short paragraph near
the version note at lines 6–8).

**Verify**: `zig build test` → exit 0 (doc-comment-only change);
`grep -n "Tier" src/root.zig README.MD` → matches in both.

### Step 2: Define the compatibility matrix in RELEASING.MD

Add a section `## Compatibility matrix (1.0 gate)` defining "compatibility
testing" as exactly these rows, each with where-it-runs and pass condition,
matching the existing gate-table style:

| Dimension | Check | Where | Pass |
|---|---|---|---|
| Linux x86_64 (LE, 64-bit) | `zig build ci` | CI, every PR | exit 0 |
| macOS aarch64 (LE, 64-bit) | `zig build check` + `zig build test` | CI, every PR | exit 0 |
| Big-endian (powerpc64) | `zig build test -Dtarget=powerpc64-linux -fqemu` | CI, every PR | exit 0 |
| Browsers (≥2) | manual render of the two `testdata/animation/anim_minimized_*.webp` samples | manual, recorded in PROGRESS.MD before tagging 1.0 | moving region animates correctly in both |
| Windows | deferred | — | recorded as deferred with reason (setup-zig action is tar.xz/uname-based) |

Also update `PLAN.MD`'s 1.0.0 criterion (the "compatibility testing" phrase
at lines ~390-391) to reference this matrix by name, and add one sentence to
the portability stance (PLAN.MD:34-38) noting big-endian is now CI-covered
(only after step 3 actually works).

**Verify**: `grep -n "Compatibility matrix" RELEASING.MD PLAN.MD` → both hit.

### Step 3: Big-endian CI job — prove it locally first

First run locally (this is the risky step; do it before touching CI):

```sh
sudo apt-get install -y qemu-user-static   # or confirm qemu-ppc64 is on PATH
zig build test -Dtarget=powerpc64-linux -fqemu
```

Expected: exit 0, all tests pass (this exercises the full suite including the
SHA-256 corpus regression, which is exactly the point — decoded planes must
be identical on a big-endian host).

If it passes, add a `big-endian` job to `.github/workflows/ci.yml` alongside
the existing `test` job (same checkout + setup-zig steps, `runs-on:
ubuntu-latest`), with an apt install of `qemu-user-static` and the command
above. Keep the existing job untouched.

If it fails, see STOP conditions — a genuine big-endian bug is a valuable
audit finding that must be reported, not patched here; a QEMU/std.Io
infrastructure failure means downgrading this row to compile-only
(`zig build check -Dtarget=powerpc64-linux` — wait, `check` builds tools too,
which is fine since they're pure Zig; use it) and recording the downgrade
honestly in RELEASING.MD.

**Verify**: local command → exit 0; after the CI change, the workflow YAML
parses and the job appears in `gh workflow view CI` (or by pushing the branch
if the operator allows).

### Step 4: macOS CI job

Add a `macos` job: `runs-on: macos-latest`, same checkout and
`./.github/actions/setup-zig` steps (the composite action's
`uname -m`-`uname -s` key resolves to `aarch64-macos`, which exists in
ziglang.org's index), then `zig build check` and `zig build test`. Do not run
`zig fmt --check` there (redundant with the Linux job).

**Verify**: workflow parses; job present. If the operator permits pushing the
branch, confirm both new jobs go green before merging.

### Step 5: Record results and the deferred items

- `PROGRESS.MD`: dated entry — compatibility matrix defined; big-endian and
  macOS CI jobs added (with the first green run's date if available); Windows
  deferred with the setup-zig reason; browser check procedure written.
- If you are running interactively with a human who can open a browser, ask
  them to run the browser check (open the two sample files in two browsers)
  and record the result in PROGRESS.MD; otherwise record the procedure and
  leave the result row empty — it is a pre-tag manual gate, not a CI gate.
- `plans/README.md`: update this plan's row.

**Verify**: `zig build ci` → exit 0; `git status` clean except in-scope files.

## Test plan

No new Zig tests — this plan's "tests" are the two new CI jobs themselves.
The big-endian job is the substantive one: it runs all existing tests,
including the byte-exact corpus regression, on a BE host for the first time.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0.
- [ ] `src/root.zig` and `README.MD` contain the two-tier stability contract.
- [ ] `RELEASING.MD` contains the compatibility matrix; `PLAN.MD` references
      it instead of the bare phrase "compatibility testing".
- [ ] `.github/workflows/ci.yml` has `big-endian` and `macos` jobs (or the
      documented compile-only downgrade for BE, with the reason in
      RELEASING.MD).
- [ ] `zig build test -Dtarget=powerpc64-linux -fqemu` exits 0 locally (or
      the downgrade is recorded).
- [ ] PROGRESS.MD has the dated entry; `plans/README.md` row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- Any test genuinely fails under `-Dtarget=powerpc64-linux -fqemu` for an
  endianness reason (wrong decoded bytes, hash mismatch): this is a real
  portability bug — report the failing test and stop; fixing codec code is
  out of scope.
- `qemu-user-static` cannot run Zig's test binary at all (immediate crash,
  unsupported syscall): downgrade to compile-only per step 3 and say so in
  your report; do not spend more than two attempts on QEMU flags.
- The setup-zig action fails on `macos-latest` (index key mismatch): report;
  do not rewrite the action (out of scope).

## Maintenance notes

- When Zig is upgraded (toolchain policy in PLAN.MD), the two new jobs pin
  through the same setup-zig `version` input — nothing extra to update.
- Windows support is the recorded deferred item: it needs the setup-zig
  action taught to handle `x86_64-windows` `.zip` archives. Whoever picks it
  up should extend the composite action, not add a third-party action (see
  the rationale comment in the action file).
- The browser check remains manual by design; RELEASING.MD's procedure is
  what makes it auditable. Re-run it whenever animation encode output
  changes.
