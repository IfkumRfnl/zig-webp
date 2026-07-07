# Plan 016: Measure the lossy-encoder method 5/6 headroom and recommend (or reject) the next quality lever

> **Executor instructions**: Follow this plan step by step. This is a
> **measurement spike**: it changes NO library code — its deliverable is a
> dated, reproducible report in PROGRESS.MD plus a written recommendation.
> Run every verification command and confirm the expected result. If
> anything in the "STOP conditions" section occurs, stop and report. When
> done, update the status row in `plans/README.md` — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- src/vp8/encoder.zig src/options.zig tools/zig-webp-encode-lossy-report.zig tools/webp-oracle.sh`
> If any in-scope-for-reading file changed since this plan was written,
> compare the "Current state" excerpts against the live code before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M (measurement + analysis; no src/ changes)
- **Risk**: LOW (read-only on the codebase; scratch scripts only)
- **Depends on**: none. Requires `cwebp` and `dwebp` (libwebp 1.5.x) on PATH
  and the reference clones under `references/` (see STOP conditions).
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

`EncoderOptions.method` is documented `cwebp -m` compatible (0..6), but
methods 5 and 6 are a shipped no-op: they clamp to method 4's search
(`src/options.zig:28-32`, `src/vp8/encoder.zig:145-165`). That is honest
today — the step-8b search is exhaustive over the modes this encoder
implements — but it means the knob's top third does nothing, while `cwebp
-m 5/-m 6` buy real quality through features this encoder lacks (adaptive
coefficient probabilities, trellis-like token-cost refinement, multiple
token partitions, richer loop-filter/segmentation search). `AGENTS.md` calls
lossy quality a long-term research goal and demands data before quality
claims. Before anyone builds an m5/m6 lever, this spike quantifies the
actual gap per candidate lever, so the maintainer can pick the one with the
best dB-per-effort — or decide, with recorded numbers, that the current
parity (+0.08 dB vs `cwebp -q 75 -m 4` at matched size) is enough and close
the question.

## Current state

- `src/vp8/encoder.zig:145-165` — the `Effort` tier map:

  ```zig
  ///   * 0..1: DC mode only, no B_PRED, no segmentation (fastest).
  ///   * 2..3: all four 16x16/chroma modes, still no B_PRED or segmentation.
  ///   * 4..6: full search — B_PRED, segmentation, every mode.
  /// Methods 5..6 match method 4 rather than regress below it: the step-8b
  /// search is already exhaustive over the modes this encoder implements, so
  /// "equal or more search" means equal here.
  ```

- `src/options.zig:28-32` — the public knob's doc: "methods 5–6 currently
  clamp to 4 (no extra search above the 8b baseline yet)."
- Known missing-vs-libwebp features (from README.MD:38-39 and PROGRESS.MD's
  step-8 rows): coefficient probabilities stay at the RFC 6386 defaults
  (libwebp adapts them per frame), one token partition, no trellis
  quantization, no near-lossless. The 8b gate result: at matched output size
  on the photo corpus, mean luma PSNR +0.08 dB vs `cwebp -q 75 -m 4`
  (PROGRESS.MD, 2026-06-21 row).
- Measurement tooling that exists:
  - `zig build encode-lossy-report` — TSV over the encode corpus with
    per-file class, sizes, and `luma_psnr_db` (tool:
    `tools/zig-webp-encode-lossy-report.zig`; run from repo root, it is a
    `cwd_repo_root` tool).
  - `tools/webp-oracle.sh compare-encode-lossy` — dwebp-validity check over
    the encoded corpus.
  - `zig build encode-lossy -- IN.webp OUT.webp Q` (tool `zig-webp-encode`)
    — re-encodes a still WebP at quality Q; also installed as
    `zig-out/bin/zig-webp-encode` by `zig build`.
  - `src/testing/metrics.zig` — the luma-PSNR definition both sides must
    use: libwebp's integer `VP8RGBToY` weights
    (`16839*r + 33059*g + 6420*b`, YUV_FIX=16, +16<<16 offset).
- **Two measurement pitfalls, learned the hard way (respect both):**
  1. The matched-size methodology: the step-8b/8c comparisons are luma PSNR
     **at matched output size**, not matched quality number. Procedure per
     photo: decode the (lossless) source `testdata/photos/*.webp` to a
     pristine reference (`dwebp -ppm`); encode the reference with `cwebp -q
     75 -m N` and record size; sweep this library's encoder over quality
     (e.g. 40..96) to the output size closest to cwebp's; compare the two
     luma PSNRs at that size. There is no committed harness — build a
     scratch script (keep it out of the repo, or under your scratch
     directory; do NOT commit it).
  2. `encode-lossy-report`'s headline mean EXCLUDES files whose PSNR is
     `inf` (losslessly reconstructed flats), so corpus-wide means mislead
     across encoder variants. Compare on the **photo corpus rows only**
     (`awk -F'\t' '$1=="photo"'`), and filter `$9!="inf"` (the literal
     string `inf` parses as 0 in naive awk).
- `references/libwebp` — the oracle clone (recreate per PLAN.MD's clone
  commands if absent). Per `AGENTS.md`: study behavior and configuration,
  never copy code.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Baseline sanity | `zig build ci` | exit 0 |
| Build tools | `zig build` | `zig-out/bin/zig-webp-encode` exists |
| Corpus report | `zig build encode-lossy-report` | TSV on stdout |
| cwebp/dwebp present | `cwebp -version && dwebp -version` | 1.5.x printed |
| Validity oracle | `tools/webp-oracle.sh compare-encode-lossy` | `0` invalid |

## Scope

**In scope** (the only repo files you should modify):

- `PROGRESS.MD` — the dated measurement report.
- `plans/README.md` — status row + one-line outcome.

**Out of scope** (do NOT touch):

- EVERYTHING under `src/` and `tools/`, `build.zig`, PLAN.MD, README.MD.
  No encoder changes, no new committed harness, no doc rewrites — if the
  recommendation is "build lever X", that becomes a future plan.
- Near-lossless preprocessing (a lossless-encoder refinement,
  PLAN.MD:399-401) — note it in the report's follow-ups if relevant, do not
  measure it here.

## Git workflow

- Branch: `lossy-m56-gap-measurement` (repo convention: `<slug>`).
- Commit style: single imperative summary line, e.g.
  `Record lossy m5/m6 headroom measurements and recommendation`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Establish the cwebp method ladder (the ceiling)

For each photo in `testdata/photos/` (pristine reference via `dwebp -ppm` of
the lossless source), encode with `cwebp -q 75 -m 4`, `-m 5`, `-m 6`
(`-noalpha`), recording size and luma PSNR (vs the pristine reference, using
the metrics.zig luma definition) for each. This measures how much m5/m6 buy
*libwebp itself* on this corpus — the honest ceiling for any lever this
project could build. Also record encode wall-time per method (rough,
`time`), since method is a speed/quality trade.

**Verify**: a table (file × method → size, PSNR, time) exists in your
scratch notes; cwebp sizes strictly non-increasing or PSNR non-decreasing
from m4→m6 on most files (if m5/m6 change nothing on this corpus, that
itself is the headline finding — record it and continue).

### Step 2: Position this encoder against the ladder at matched size

Using the matched-size methodology from "Current state" (sweep Q 40..96),
measure this library's encoder against each of cwebp m4, m5, m6 target
sizes per photo. Deliverable: mean luma PSNR delta vs each method tier at
matched size (m4 should reproduce ≈+0.08 dB, confirming your harness against
the recorded 8b gate — if it doesn't reproduce within ~0.05 dB, debug the
harness before trusting anything else).

**Verify**: your m4 delta reproduces the PROGRESS.MD 8b result within
tolerance; deltas vs m5/m6 recorded per file and in aggregate.

### Step 3: Attribute the gap to candidate levers

For each candidate lever, estimate its share of the step-2 gap using
config-level experiments with cwebp where possible (no code written):

- **Adaptive coefficient probabilities** — study
  `references/libwebp/src/enc/frame_enc.c` behavior descriptions/stats
  output (`cwebp -v`/`-print_psnr`) to see what proportion of header+token
  bytes the default-vs-adapted probabilities represent on these photos
  (e.g. compare token partition sizes reported, or literature: RFC 6386
  §13). Where direct isolation isn't possible, say so and bound it.
- **Multiple token partitions** — `cwebp -partitions N` exists (0..3):
  measure its actual size/PSNR effect at q75 on the photos.
- **Trellis / token-cost refinement** — m5/m6 vs m4 in cwebp largely toggle
  trellis (`config.use_delta_palette` aside, method mapping is in
  `references/libwebp/src/enc/config_enc.c`) — attribute the step-1 ladder
  delta to it and note which pieces (rd_opt levels) kick in at 5 vs 6.
- **Sharper segmentation / loop-filter search** — bound by comparing
  `cwebp -segments 1` vs default at m4.

The attribution will be approximate — the report must label each number as
measured, bounded, or literature-derived. Precision matters less than
ranking the levers.

**Verify**: each lever has a number (dB and/or bytes) with its epistemic
label; the levers are ranked by expected dB per implementation effort
(state your effort guess per lever: S/M/L against this codebase's
`src/vp8/` module structure).

### Step 4: Write the report and recommendation

Add a dated entry to `PROGRESS.MD` (match the existing oracle-row style:
date, what was measured, exact commands/corpus, numbers, honest caveats):

- the cwebp m4/m5/m6 ladder on the photo corpus;
- this encoder's matched-size position vs each tier;
- the lever attribution table with epistemic labels;
- a recommendation: either "build lever X as the real m5 tier (expected
  ≈Y dB for effort Z) — author an implementation plan" or "the headroom is
  ≈Y dB for L-sized effort; recommend keeping m5/m6 clamped and documented
  as-is" — whichever the numbers support;
- follow-ups NOT measured (near-lossless, sharp-yuv interactions,
  non-photo asset classes).

Update `plans/README.md` with the outcome one-liner.

**Verify**: `zig build ci` → exit 0 (nothing but markdown changed);
`git status` → only PROGRESS.MD and plans/README.md modified.

## Test plan

None — measurement only. The reproducibility requirement substitutes: every
number in the report must carry the exact command that produced it, so the
next session can re-run the ladder after any encoder change.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] PROGRESS.MD contains the dated report with: cwebp m4/m5/m6 ladder,
      matched-size deltas (m4 delta reproducing ≈+0.08 dB), lever
      attribution with epistemic labels, and an explicit recommendation.
- [ ] `git status` shows only PROGRESS.MD and plans/README.md modified.
- [ ] `zig build ci` exits 0.
- [ ] `plans/README.md` status row updated with the outcome.

## STOP conditions

Stop and report back (do not improvise) if:

- `cwebp`/`dwebp` are not on PATH or `references/libwebp` /
  `testdata/photos/` are absent — the measurement cannot run; report what's
  missing (PLAN.MD has the clone commands, but installing system tools may
  need the operator).
- Your step-2 m4 matched-size delta does NOT reproduce the recorded +0.08 dB
  within ~0.05 dB after checking the luma formula and the size-matching
  logic twice — the harness is wrong or the encoder drifted; either way the
  discrepancy IS the report, do not proceed to lever attribution on top of a
  broken baseline.
- You feel the urge to "quickly try" an encoder change to test a lever —
  that is explicitly out of scope; write it into the recommendation instead.

## Maintenance notes

- If the recommendation is "build lever X", the follow-up plan must include
  re-running this exact ladder as its acceptance measurement, and must keep
  `EncoderOptions.method`'s monotonicity documentation honest
  (`src/vp8/encoder.zig:145-154` — each tier strictly ≥ search of the one
  below).
- The scratch matched-size harness is deliberately uncommitted; if a third
  session needs it, consider promoting it to `tools/` in its own small plan
  (with the `cwd_repo_root` pattern) rather than rebuilding it a fourth
  time.
