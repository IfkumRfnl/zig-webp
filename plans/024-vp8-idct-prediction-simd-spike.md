# Plan 024: Attribution-gated spike — SIMD for VP8 inverse DCT and intra prediction

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- src/vp8/transform.zig src/vp8/prediction.zig PROGRESS.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3 (explicitly lower-confidence; gated on measurement)
- **Effort**: S for the gate, M if the build proceeds
- **Risk**: MED
- **Depends on**: plans/023-vp8-loop-filter-simd.md (hard — the profile must be taken *after* the filter is vectorized, or it will mis-attribute)
- **Category**: perf
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters — and why it is gated

libwebp vectorizes the 4×4 inverse DCT (two blocks per pass, `TransformTwo`)
and the intra predictors; this library runs them scalar. *However*, this
repo's own record cuts against assuming a win: the slice-10b entry in
`PROGRESS.MD` (2026-06-26) says scalar micro-restructuring of the inverse
transforms / IDCT DC fast-path was **prototyped and rejected as code-layout
noise ("those stages aren't the bottleneck")**, and the slice-10c entry
lists the remaining lossy levers as loop-filter SIMD, row-pipeline locality,
and threading — not the IDCT. So this plan is a measurement gate first: it
proceeds to SIMD work only if a profile taken after plan 023 shows the
inverse transform + prediction stages carrying a meaningful share of lossy
decode time. The most likely honest outcome is a recorded REJECTED verdict —
that is a success, not a failure.

## Current state

- `src/vp8/transform.zig` (276 lines) — `addInverseDct`
  (`:45-86`: two 4-row passes of exact-integer butterflies with `mulCos`/
  `mulSin` Q16 fixed-point, then add-to-prediction with clamp; wrapping i32
  ops by design for hostile streams, see `:9-13`) and `inverseWalshHadamard`
  (`:97-132`). The doc comment at `:43-44` records that always running the
  full transform is bit-identical to libwebp's DC-only fast paths — do not
  reintroduce dispatch for "correctness".
- `src/vp8/prediction.zig` — intra predictors (16×16 luma, 8×8 chroma, 4×4
  B_PRED).
- Callsites: `src/vp8/decoder.zig:473,565` (chroma/luma `addInverseDct`),
  `:197` (WHT); the encoder mirrors them (`src/vp8/encoder.zig:778,984,
  1000,1131`) — **encoder callsites are out of scope** (trusted-input,
  reconstruction must stay byte-identical to the decoder's by construction;
  if the shared function is vectorized both sides move together, which is
  fine — just don't restructure encoder code).

Key excerpt (`src/vp8/transform.zig:56-68`, pass 1):

```zig
for (0..4) |i| {
    const row_0: i32 = coefficients[i];
    const row_1: i32 = coefficients[4 + i];
    const row_2: i32 = coefficients[8 + i];
    const row_3: i32 = coefficients[12 + i];
    const a = row_0 +% row_2;
    const b = row_0 -% row_2;
    const c = mulSin(row_1) -% mulCos(row_3);
    const d = mulCos(row_1) +% mulSin(row_3);
    transposed[4 * i + 0] = a +% d;
    ...
}
```

Wrapping arithmetic (`+%`, `*%`) is part of the contract (hostile-stream
tolerance, `:267-275` test) — vector code must use wrapping vector ops.

Repo conventions: SIMD exemplar `src/color.zig:175-310`; scalar reference
kept; non-circular scalar-vs-SIMD equivalence test (slice-10b pattern);
32-bit portability (no hardcoded `u6` shifts on `usize`); byte-exactness
enforced by the SHA-256 corpus gate inside `zig build test`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 |
| Bench (ReleaseFast) | `zig build bench -Doptimize=ReleaseFast` | TSV to stdout |
| Profile | `perf record -F 999 --call-graph dwarf -o /tmp/plan024.perf -- zig build bench -Doptimize=ReleaseFast` then `perf report -i /tmp/plan024.perf --no-children` | symbol table incl. `addInverseDct`, prediction fns |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 |

If `perf` is unavailable and cannot be installed without sudo, STOP at
Step 1 and report — the operator must supply the profile (this plan must
not proceed on guesswork).

## Scope

**In scope** (files you may modify, ONLY if the gate passes):
- `src/vp8/transform.zig`
- `src/vp8/prediction.zig`
- `PROGRESS.MD` (dated findings row — written in BOTH outcomes)

**Out of scope** (do NOT touch):
- `src/vp8/decoder.zig`, `src/vp8/encoder.zig` — callsites unchanged.
- `src/vp8/loop_filter.zig` (plan 023), `src/color.zig` (done, 10b).
- Any "DC-only fast path" dispatch — explicitly rejected in 10b; full
  transform stays unconditional.

## Git workflow

- Branch: `vp8-idct-simd-spike`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Profile lossy decode (the gate)

With plan 023 merged into the branch point: run the `perf` command above.
In `perf report`, sum the self-time share of (a) `addInverseDct` +
`inverseWalshHadamard`, and (b) the `src/vp8/prediction.zig` functions,
restricted to the bench tool's lossy-decode phase (the bench also runs
encode; either filter by symbol or accept the dilution and note it — the
shares below are of *total* bench time in that case, so also record the
lossy-decode fraction of total to normalize).

**Gate**: if (a) + (b) normalized to lossy-decode time is **< 8%**, the
plan's outcome is REJECTED. Write the dated `PROGRESS.MD` row recording the
measured shares (so nobody re-litigates without new evidence), update
`plans/README.md` status to `REJECTED (measured: <shares>)`, and finish —
Steps 2+ do not run.

**Verify**: a written percentage for (a) and (b) with the normalization
stated, either in your report (gate failed) or carried into Step 2.

### Step 2 (gate passed): Vectorize `addInverseDct`

`@Vector(4, i32)` per row/column pass (the natural width; two-blocks-at-once
`TransformTwo` shape is optional and only if callsite batching is free —
callers hand blocks one at a time, so start with single-block lanes):

- Each pass processes the 4 columns (then rows) as one vector per line:
  `a`, `b`, `c`, `d` become vector expressions with wrapping ops (`+%` on
  vectors) and `mulCos`/`mulSin` as vector helpers
  (`(v *% @as(V, @splat(20091))) >> @splat(16)` etc. — signed arithmetic
  shift on i32 vectors preserves the scalar semantics).
- The add-clamp store widens the 4 destination bytes, adds, clamps 0..255
  (`@min`/`@max`), narrows, stores 4 bytes.
- Keep the scalar version compiled (rename `addInverseDctScalar`) as the
  test reference; production dispatch is unconditional vector (no
  endianness concern — lane types are explicit).

**Verify**: `zig build test` → exit 0 (unit vectors at `:140-275` and the
corpus gate); `zig build wasm-check` → exit 0.

### Step 3 (gate passed): Vectorize the hottest predictors

From the Step-1 profile, vectorize only predictors above ~2% self time
(typically TM/DC 16×16). Contiguous row writes vectorize trivially; do not
touch B_PRED's 4×4 unless the profile says so.

**Verify**: `zig build test` → exit 0; `zig fmt .`; `zig build ci` → exit 0.

### Step 4: Measure and record

Interleaved A/B bench (ReleaseFast, single thread, ≥3 runs, medians), lossy
rows. Append the dated `PROGRESS.MD` row + entry. If the end-to-end win is
< 1.03× aggregate lossy decode, record the numbers and mark the branch for
the maintainer's judgment rather than merging by default — consistency with
how 10b/10c recorded rejected experiments.

## Test plan

(Gate-passed path only.)

- `src/vp8/transform.zig`: keep every existing test green against the
  vector implementation (they call `addInverseDct` directly — the vectors
  at `:140-275` are independent, RFC-derived, and are the primary unit
  oracle). Add one scalar-vs-vector equivalence test over deterministic
  pseudo-random coefficient blocks (fixed PRNG seed) including i16-extreme
  values (the `:267-275` wrap tolerance case), asserting byte-equal output
  planes.
- `src/vp8/prediction.zig`: scalar-vs-vector equivalence per vectorized
  predictor, random contexts, fixed seed.

Verification: `zig build test` → all pass.

## Done criteria

EITHER (rejected):
- [ ] Dated `PROGRESS.MD` row with the measured stage shares and the
      REJECTED verdict; `plans/README.md` row says
      `REJECTED (measured: ...)`; no `src/` changes committed

OR (built):
- [ ] `zig build ci` exits 0; `zig build wasm-check` exits 0
- [ ] Scalar reference functions still present; equivalence tests pass
- [ ] Bench medians + profile shares recorded in `PROGRESS.MD`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `perf` is unavailable and cannot be obtained — the gate cannot run.
- Any corpus-hash test fails (wrapping-op or shift-semantics slip; never
  regenerate hashes).
- You are tempted to add a DC-only dispatch "while in there" — recorded as
  rejected in 10b; do not.
- The profile contradicts the plan's premise in the other direction (e.g.
  shows an unexpected stage > 20%): report the finding instead of chasing
  it — that is new-plan material.

## Maintenance notes

- This plan is deliberately structured so a REJECTED outcome produces a
  permanent, dated record — the third such record for this stage (after
  10b's scalar prototype note) would settle the question durably.
- Reviewer (built path): scrutinize wrapping vector ops (`+%`/`*%` must not
  become trapping `+`/`*`), and that `inverseWalshHadamard` was only
  touched if the profile named it.
