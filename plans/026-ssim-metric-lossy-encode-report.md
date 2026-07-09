# Plan 026: Add a luma SSIM metric to the lossy encode report

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- src/testing/metrics.zig tools/zig-webp-encode-lossy-report.zig PROGRESS.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (measurement-only; no codec changes)
- **Depends on**: none (complements plans/016-lossy-method56-gap-measurement.md — 016 measures the m5/m6 headroom, this plan gives 016 and future encoder work a second quality axis)
- **Category**: perf (quality measurement) / tests
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

The lossy encoder's quality record is PSNR-only: the step-8b gate is
matched-size **luma PSNR** vs `cwebp -q 75 -m 4` (recorded +0.08 dB). PSNR
rewards mean-squared closeness and is blind to the structural/perceptual
artifacts that VP8 encoders actually trade against (banding, blockiness,
detail loss from segmentation choices). Before this project publicly claims
quality parity — and before plan 016 recommends investing in m5/m6
features like trellis quantization — the report tooling needs a structural
metric alongside PSNR. This plan adds windowed luma SSIM to
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
  encode-lossy-report` tool (`PROGRESS.MD` records it printing per-source
  encoded size and mean luma PSNR: "34 sources, mean luma 37.13 dB").
  Read the tool before editing: it decodes source + reconstruction to RGBA
  and calls `metrics.psnrLuma`; the SSIM column slots in beside it.
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

**Out of scope** (do NOT touch):
- Any encoder/decoder source — this plan changes no codec behavior.
- The step-8 PSNR gates in the test suite — SSIM is reported, not gated,
  until a baseline history exists.
- `plans/016-*.md` — 016 picks the column up automatically when it runs.

## Git workflow

- Branch: `metrics-luma-ssim`
- One or two commits; message style: imperative summary, e.g.
  `Add windowed luma SSIM to the encode metrics`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Implement `ssimLuma` in `src/testing/metrics.zig`

Textbook SSIM on the BT.601 luma plane (reuse `lumaBt601`):

- Window: 8×8, sliding with stride 4 (documented; stride 4 keeps it cheap
  on 512² photos while sampling every pixel region), mean SSIM over all
  windows fully inside the image. Images smaller than 8×8 in either extent
  return 1.0 for identical buffers / fall back to a single whole-image
  window — pick one, assert it, and document it.
- Per window: means, variances, covariance in `f64`;
  `C1 = (0.01 * 255)^2`, `C2 = (0.03 * 255)^2`;
  `ssim = ((2*mu_x*mu_y + C1) * (2*cov + C2)) / ((mu_x^2 + mu_y^2 + C1) * (var_x + var_y + C2))`.
- Signature mirrors the module's existing shape:
  `pub fn ssimLuma(a: []const u8, b: []const u8, width: usize, height: usize, channels: usize) f64`
  (SSIM is spatial — it needs `width`/`height`, unlike `psnrLuma`; assert
  `a.len == b.len == width * height * channels`).
- Doc comment: textbook Wang et al., box window, NOT comparable to
  `cwebp -print_ssim` (different kernel), exists as an internal A/B axis.

**Verify**: `zig build test` → exit 0 with the new unit tests (Step 3
below written alongside).

### Step 2: Add the column to the lossy report

In `tools/zig-webp-encode-lossy-report.zig`: compute `ssimLuma` where the
tool computes `psnrLuma` (same decoded buffers, it has width/height in
hand), add a column, and include SSIM in any mean-summary line the tool
prints. Keep the TSV shape otherwise identical (downstream:
`tools/webp-oracle.sh compare-encode-lossy` consumes the report — check its
column parsing before reordering anything; append the column at the END of
each row if the oracle script indexes columns positionally).

**Verify**: `zig build encode-lossy-report` → table with the SSIM column,
all values in (0, 1]; identical-pixels rows (if any) print 1.0. Then run
`tools/webp-oracle.sh compare-encode-lossy <report>` if `dwebp` is present
to prove the oracle script still parses the report; skip with a note
otherwise.

### Step 3: Record the first numbers

Append a short dated note to `PROGRESS.MD` (Cross-Cutting Practices or a
Recently Completed entry): mean luma SSIM over the lossy report corpus at
default settings, stated as the new internal quality axis alongside the
37.13 dB PSNR record, with the not-cwebp-comparable caveat.

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

Verification: `zig build test` → all pass, 5 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0; `zig build wasm-check` exits 0
- [ ] `grep -n "pub fn ssimLuma" src/testing/metrics.zig` → present, with
      the not-cwebp-comparable doc comment
- [ ] `zig build encode-lossy-report` prints an SSIM column, values in (0, 1]
- [ ] `tools/webp-oracle.sh compare-encode-lossy` still parses the report
      (run if dwebp present; else verified by reading its column handling
      and stated in the report)
- [ ] 5 new metric tests pass
- [ ] `PROGRESS.MD` note added
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `tools/webp-oracle.sh compare-encode-lossy` parses report columns
  positionally in a way an appended column still breaks — report the
  script's exact expectation instead of editing the script (it is not in
  scope).
- The report tool does not actually have width/height + both RGBA buffers
  in hand where PSNR is computed (the plan's premise) — report the tool's
  real data flow.
- You are tempted to transcribe libwebp's SSIM kernel for comparability —
  that violates the no-copy rule; the textbook metric is the deliverable.

## Maintenance notes

- Plan 016 (m5/m6 headroom measurement) should quote both PSNR and SSIM
  columns once this lands; if 016 runs first, its recommendation should be
  re-checked against SSIM afterward.
- Reviewer should scrutinize: window accounting at image edges (windows
  fully inside only — partial-window handling changes the number silently)
  and the stride-4 documentation (any future change to window/stride resets
  the comparability of recorded SSIM history).
- Deferred deliberately: gating any test on SSIM thresholds (needs history
  first), and RGB/whole-image SSIM variants.
