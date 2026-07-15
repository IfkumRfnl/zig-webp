# Plan 026: Add a luma SSIM metric to the lossy encode report

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 7686a55..HEAD -- src/testing/metrics.zig tools/zig-webp-encode-lossy-report.zig PROGRESS.MD plans/README.md`
> This plan was refreshed against `origin/main` after the decode-performance
> campaign. Compare any later in-scope changes against the contracts below;
> treat a metric/report shape mismatch as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (measurement-only; no codec changes)
- **Depends on**: none. This is an optional internal A/B metric; plan 016's
  matched-size `cwebp` recommendation remains PSNR-based and does not consume
  this report automatically.
- **Category**: perf (quality measurement) / tests
- **Planned at**: commit `7686a55`, refreshed 2026-07-15 (originally authored
  at `29be0df`)

## Why this matters

The lossy encoder's quality record is PSNR-only: the step-8b gate is
matched-size **luma PSNR** vs `cwebp -q 75 -m 4` (recorded +0.08 dB). PSNR
rewards mean-squared closeness and is blind to the structural/perceptual
artifacts that VP8 encoders actually trade against (banding, blockiness,
detail loss from segmentation choices). A structural metric is useful for
future internal encoder A/B work, but it does not replace the matched-size
PSNR comparison against `cwebp` and is not a prerequisite for plan 016. This
plan adds windowed luma SSIM to
`src/testing/metrics.zig` and a column to the lossy encode report. It is a
measurement change only; no encoder behavior changes.

## Current state

- `src/testing/metrics.zig` (127 lines) — MSE/PSNR helpers: `mseBytes`,
  `psnrFromMse`, `psnrBytes`, `lumaBt601` (integer BT.601, libwebp-rounding:
  `(19595*R + 38470*G + 7471*B + 32768) >> 16`), `lumaMse`, `psnrLuma`.
  Pure functions over equal-length buffers, `channels` parameter (3 = rgb,
  4 = rgba), R,G,B order assumed. Doc comment at `:1-17` states the
  module's conventions. Tests at `:81-126` pin hand-computed values (e.g.
  MSE 12.5 → 37.1617 dB) and libwebp luma primaries (76/150/29).
- `tools/zig-webp-encode-lossy-report.zig` — the `zig build
  encode-lossy-report` tool. It decodes source + reconstruction to RGBA and
  calls `metrics.psnrLuma`; the SSIM column slots in beside it. Two existing
  report defects are in scope because they would make the new summary
  misleading:
  - its module comment says the TSV feeds `compare-encode-lossy`, but that
    oracle does not parse the TSV;
  - `Stats.luma_psnr_sum` skips `inf` rows while the mean still divides by
    `Stats.sources`. Current output has 34 rows, 30 finite: it prints 37.13 dB,
    while the finite-row mean is 42.0847 dB.
- Consumers of `metrics.zig`: the lossy quality gates in the test suite and
  the report tool. Adding functions is additive; do not change existing
  signatures.

Repo conventions that apply:

- `AGENTS.MD`: do not copy reference implementation code. libwebp has its
  own SSIM variant (`-print_ssim`); we implement **textbook SSIM** (Wang et
  al. 2004) independently and document that the two are *not* directly
  comparable — ours is a consistent internal A/B axis, not a cwebp-parity
  number. State this in the doc comment.
- Pure-function style of the module: no allocation in the metric itself if
  avoidable; explicit `f64` accumulation; assertions on preconditions.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 |
| Lossy report | `zig build encode-lossy-report` | per-source table incl. new SSIM column |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/testing/metrics.zig`
- `tools/zig-webp-encode-lossy-report.zig`
- `PROGRESS.MD` (one dated note with the first SSIM numbers)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch):
- Any encoder/decoder source — this plan changes no codec behavior.
- The step-8 PSNR gates in the test suite — SSIM is reported, not gated,
  until a baseline history exists.
- `plans/016-*.md` — its separate matched-size harness remains unchanged.

## Git workflow

- Branch: `metrics-luma-ssim`
- One or two commits; message style: imperative summary, e.g.
  `Add windowed luma SSIM to the encode metrics`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Implement `ssimLuma` in `src/testing/metrics.zig`

Textbook SSIM on the BT.601 luma plane (reuse `lumaBt601`):

- Window: 8×8, sliding with stride 4 (documented; stride 4 keeps it cheap
  on 512² photos). Mean SSIM over all windows whose top-left originates on
  the stride-4 grid and whose full 8×8 extent lies inside the image —
  edge strips narrower than one window are therefore not covered by a
  sliding window (do not claim "every pixel region"). When **either**
  `width` or `height` is below 8, require a single whole-image window over
  the entire luma plane (not a hard-coded 1.0 for identical buffers and
  not an optional fallback — always the whole-image window); assert and
  document that.
- Per window: means, **population** variances, and **population**
  covariance in `f64` (normalize by `N = window_w * window_h`, not
  `N-1` / sample Bessel correction);
  `C1 = (0.01 * 255)^2`, `C2 = (0.03 * 255)^2`;
  `ssim = ((2*mu_x*mu_y + C1) * (2*cov + C2)) / ((mu_x^2 + mu_y^2 + C1) * (var_x + var_y + C2))`.
- Signature mirrors the module's existing shape:
  `pub fn ssimLuma(a: []const u8, b: []const u8, width: usize, height: usize, channels: usize) f64`
  (SSIM is spatial — it needs `width`/`height`, unlike `psnrLuma`; assert
  `a.len == b.len` and separately assert
  `a.len == width * height * channels`).
- Doc comment: textbook Wang et al., box window, NOT comparable to
  `cwebp -print_ssim` (different kernel), exists as an internal A/B axis.

**Verify**: `zig build test` → exit 0 with the new unit tests (Step 3
below written alongside).

### Step 2: Add the column to the lossy report

In `tools/zig-webp-encode-lossy-report.zig`:

1. Compute `ssimLuma` where the tool computes `psnrLuma` (same decoded
   buffers, width, and height).
2. Append an SSIM column at the END of each row so the existing column order
   stays stable, and include mean SSIM in the stderr summary.
3. Add a separate finite-PSNR row count. Increment it only when
   `luma_psnr` is finite, and divide `luma_psnr_sum` by that count (not by
   total sources). The current corpus should therefore report approximately
   42.08 dB over 30 finite rows instead of the erroneous 37.13 dB over 34.
4. Correct the module comment: the report is a human/internal A/B report; it
   does not feed `tools/webp-oracle.sh compare-encode-lossy`.

Do **not** treat `tools/webp-oracle.sh compare-encode-lossy` as a consumer
of this report TSV. Its contract is a **corpus directory**:
`tools/webp-oracle.sh compare-encode-lossy [CORPUS_DIR]` (default
`testdata/libwebp-test-data`), which walks still WebPs under
`testdata/photos` and `CORPUS_DIR`, re-encodes them with
`zig-out/bin/zig-webp-encode`, and pairs sizes against `cwebp`. Optional
sanity (not a report-parse gate): if `dwebp`/`cwebp` are present, run the
oracle with no args; otherwise skip it with a note.

**Verify**: `zig build encode-lossy-report` → table with the SSIM column;
all SSIM values finite and in [-1, 1]; identical-pixels rows (if any) print
1.0; stderr reports 34 total sources, 30 finite PSNR sources, and a finite-row
PSNR mean of approximately 42.08 dB on the unchanged corpus.

### Step 3: Record the first numbers

Append a short dated note to `PROGRESS.MD` (Cross-Cutting Practices or a
Recently Completed entry): mean luma SSIM over the lossy report corpus at
default settings, stated as a new internal quality axis and explicitly not
comparable to cwebp's SSIM. Record the corrected finite-row PSNR summary
(approximately 42.08 dB over 30 rows) and explain that the historical
37.13 dB headline divided the finite-only sum by all 34 sources. Do not
reinterpret the separate matched-size +0.08 dB cwebp gate; that result came
from a different photo-only harness.

**Verify**: `zig fmt .`; `zig build ci` → exit 0;
`git diff PROGRESS.MD` shows only the added note.

## Test plan

New tests in `src/testing/metrics.zig`, following the file's
hand-computed-value style (`:95-108`):

1. Identical buffers → SSIM exactly 1.0 (any size, incl. < 8×8).
2. A hand-computable single-window case: 8×8 constant luma vs constant
   luma+k — with zero variance the formula reduces to
   `(2*mu_x*mu_y + C1) / (mu_x^2 + mu_y^2 + C1)`; assert against the
   closed-form value to 1e-9.
3. Symmetry: `ssimLuma(a, b, ...) == ssimLuma(b, a, ...)` on a small
   pseudo-random pair (fixed seed).
4. Monotonicity sanity: heavier uniform noise → strictly lower SSIM than
   lighter noise on the same base image (fixed seed).
5. Alpha-blindness: same RGB, different alpha → 1.0 (mirrors the existing
   `lumaMse` alpha test at `:120-126`).
6. Anti-correlation: complementary 0/255 checkerboards produce a finite
   negative SSIM in [-1, 0), proving covariance is signed and not clamped.

Verification: `zig build test` → all pass, 6 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0; `zig build wasm-check` exits 0
- [ ] `grep -n "pub fn ssimLuma" src/testing/metrics.zig` → present, with
      the not-cwebp-comparable doc comment
- [ ] `zig build encode-lossy-report` prints an SSIM column, with every
      value finite and in [-1, 1]; identical buffers produce exactly 1.0
- [ ] The report's PSNR summary divides by a separate finite-row count:
      unchanged corpus output reports 34 total / 30 finite and approximately
      42.08 dB, not 37.13 dB
- [ ] The tool comment, plan text, and done criteria do not claim
      `compare-encode-lossy` parses the report TSV; any optional oracle run
      uses its corpus-directory contract only
- [ ] 6 new metric tests pass
- [ ] `PROGRESS.MD` note records both first SSIM numbers and the corrected
      PSNR denominator
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The report tool does not actually have width/height + both RGBA buffers
  in hand where PSNR is computed (the plan's premise) — report the tool's
  real data flow.
- You are tempted to transcribe libwebp's SSIM kernel for comparability —
  that violates the no-copy rule; the textbook metric is the deliverable.

## Maintenance notes

- Plan 016 (m5/m6 headroom measurement) should quote both PSNR and SSIM
  columns once this lands; if 016 runs first, its recommendation should be
  re-checked against SSIM afterward.
- Reviewer should scrutinize: window accounting at image edges (fully
  inside windows on the stride-4 grid only — uncovered edge strips are
  expected; do not invent partial windows), population (`/N`) vs sample
  (`/(N-1)`) variance/covariance, the mandatory whole-image window when
  either extent is < 8, and that stride/window changes reset SSIM history
  comparability.
- Deferred deliberately: gating any test on SSIM thresholds (needs history
  first), and RGB SSIM variants.
