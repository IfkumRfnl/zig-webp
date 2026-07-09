# Plan 020: Record libwebp's internal decode time in webp-bench.sh so speed ratios lose the file-I/O asterisk

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- tools/webp-bench.sh PROGRESS.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf (measurement)
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

Every decode-speed ratio this project has recorded against libwebp carries a
caveat written into `tools/webp-bench.sh` itself: `dwebp` reads and writes real
files (PAM formatting included), while `zig build bench` times decode in
memory, so recorded ratios like "bryce ≈1.65×" are indicative, not exact.
`dwebp -v` prints its *internal* decode time ("Time to decode picture:"),
which excludes output formatting. Capturing that removes the asterisk from
every future ratio recorded in `PROGRESS.MD` — and plans 021–024 all gate on
such ratios. This plan touches only the measurement script; no library code.

## Current state

- `tools/webp-bench.sh` — the libwebp side of the same-machine comparison.
  Times `dwebp` (stills) / `anim_dump` (animations) / `cwebp` by wall clock,
  best-of-N runs, and prints a fixed-width table. It SKIPs gracefully when
  libwebp tools are absent and is not wired into CI.

Excerpt of the caveat and the report header as they exist today
(`tools/webp-bench.sh:13-16, 89-90`):

```sh
# Caveat for honest comparison: dwebp/cwebp read and write real files, so their
# times include input read + output formatting/write; `zig build bench` times
# decode/encode in memory only. The ratio is indicative of codec speed, not an
# exact apples-to-apples measurement — note that whenever you record it.
...
printf '# webp-bench: best of %d runs, milliseconds. decode = dwebp (still) / anim_dump (animation); cwebp = re-encode.\n' "$runs"
printf '%-44s %12s %14s %14s\n' "file" "decode_ms" "cwebp_ll_ms" "cwebp_q75_ms"
```

The script defines `min_ms()` (best-of-`runs` wall time in integer ms via GNU
`date` nanoseconds, printing `FAIL` on nonzero exit) and `is_animation()`
(webpinfo ANMF probe). The per-file loop lives at lines 92–118.

Repo conventions that apply:

- Shell tools under `tools/` are POSIX-ish bash with `set -u`, graceful SKIP
  when a binary is missing, and never become build dependencies. Match
  `tools/webp-oracle.sh` and the existing style of this script.
- `AGENTS.MD` honest-benchmarking rule: record *what dimension* a number
  measures. The new column measures libwebp's internal decode time only.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check, compile, all tests) |
| Run the script | `tools/webp-bench.sh -n 3 testdata/libwebp-test-data/bryce.webp` | table row for the file, or `SKIP` if dwebp absent |
| Check dwebp verbose timing | `dwebp -v <file> -o /dev/null 2>&1 \| grep -i "time to decode"` | a line like `Time to decode picture: 0.123s` |

(`zig build ci` is unaffected by this plan but is the repo's mandatory
hand-back gate — run it once at the end to prove you broke nothing.)

## Suggested executor toolkit

- Read `tools/webp-oracle.sh` for the house style of tool-probing shell
  helpers before editing.

## Scope

**In scope** (the only files you should modify):
- `tools/webp-bench.sh`
- `PROGRESS.MD` (one short note; see Step 4)

**Out of scope** (do NOT touch, even though they look related):
- `tools/zig-webp-bench.zig` — the Zig harness already measures in memory;
  nothing to fix there.
- `build.zig`, any `src/` file — this plan is measurement-only.
- `.github/workflows/ci.yml` — timing scripts stay out of CI by design.

## Git workflow

- Branch: `bench-dwebp-internal-timing`
- One commit; message style: imperative summary line, e.g.
  `Record dwebp internal decode time in webp-bench.sh`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the dwebp verbose timing line exists

Run (any still WebP in `testdata/` works):

```sh
dwebp -v testdata/libwebp-test-data/bryce.webp -o /dev/null 2>&1 | grep -i "time to decode"
```

If `dwebp` is not installed, this plan cannot be verified on this machine —
STOP and report. If `dwebp -v` prints **no** decode-time line, STOP and
report the exact `-v` output (the parsing step below would be guesswork).

**Verify**: the command prints one line containing a seconds value, e.g.
`Time to decode picture: 0.0xxs`.

### Step 2: Add an internal-decode-time column for stills

In `tools/webp-bench.sh`:

1. Add a helper `min_internal_decode_ms()` next to `min_ms()` (same
   best-of-`$runs` structure). Each iteration runs
   `dwebp -v "$f" -o /dev/null 2>&1`, extracts the seconds value from the
   "Time to decode" line (e.g.
   `sed -n 's/.*[Tt]ime to decode picture: *\([0-9.]*\)s.*/\1/p'`), converts
   to integer milliseconds (`awk 'END { printf "%d", s * 1000 }'` or
   equivalent), and keeps the minimum. Nonzero dwebp exit or a missing
   timing line → print `FAIL` for that file (mirror `min_ms`'s behavior).
2. In the per-file loop, populate the new column for stills only; print `-`
   for animations (`anim_dump` has no equivalent internal timer).
3. Widen the header: add `decode_int_ms` between `decode_ms` and
   `cwebp_ll_ms`, and extend the `#` comment line to say the new column is
   dwebp's self-reported decode time (excludes file I/O and PAM/PNG
   formatting).
4. Soften the file-top caveat comment (lines 13–16): wall-clock columns keep
   the caveat; the `decode_int_ms` column does not. Say exactly that.

**Verify**:
`tools/webp-bench.sh -n 3 testdata/libwebp-test-data/bryce.webp` → one data
row with 4 numeric-ish columns; `decode_int_ms` ≤ `decode_ms` and > 0.

### Step 3: Regression-check the SKIP and animation paths

- Temporarily run with a PATH that hides libwebp
  (`env PATH=/usr/bin:/bin tools/webp-bench.sh ...` if that hides it, or
  verify by reading the guard) — the script must still SKIP cleanly, not
  error, when `dwebp`/`cwebp` are absent. If you cannot simulate absence,
  verify by code inspection that the new helper is only reached behind the
  existing `has_tool dwebp` guards, and say so in your report.
- Run with the default file set (`tools/webp-bench.sh -n 2`) and confirm the
  animation row(s) print `-` in the new column and every still prints a
  number or `FAIL`.

**Verify**: `tools/webp-bench.sh -n 2` → full table, no bash errors
(`set -u` is on — unset-variable bugs abort the script visibly).

### Step 4: Record the measurement-protocol note

Append one sentence to `PROGRESS.MD`'s "Cross-Cutting Practices" section (do
not touch any other section; the file has in-flight edits from other work):
future decode-speed ratios vs libwebp should be recorded against
`decode_int_ms` (dwebp's internal decode time via `-v`), which removes the
recorded PAM-formatting caveat from the 10a baseline rows.

**Verify**: `git diff PROGRESS.MD` shows only the added sentence.

## Test plan

This is a measurement script; there is no Zig test to write. The verification
is the three script invocations in Steps 1–3 plus:

- `zig build ci` → exit 0 (proves the repo gate is untouched).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `tools/webp-bench.sh -n 2` exits 0 and prints a `decode_int_ms` column
- [ ] Stills show a numeric `decode_int_ms` (or `FAIL`); animations show `-`
- [ ] `grep -c "decode_int_ms" tools/webp-bench.sh` ≥ 2 (header + comment)
- [ ] `zig build ci` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `dwebp` is absent on the executing machine (the script's behavior can't be
  verified; report and hand back).
- `dwebp -v` prints no decode-time line (parsing would be invented).
- The current `tools/webp-bench.sh` no longer matches the excerpts above
  (drifted; re-plan).

## Maintenance notes

- Plans 021–024 record before/after ratios; their instructions assume this
  column exists. If libwebp changes its `-v` output format, the sed pattern
  is the single point of repair.
- Reviewer should scrutinize: the `FAIL` path (a missing timing line must
  not silently print 0), and that the wall-clock columns are unchanged
  (existing recorded baselines stay comparable).
- Deferred deliberately: per-stage attribution inside the Zig harness
  (would instrument hot paths; not worth the noise), and any CI wiring
  (timing flakes).
