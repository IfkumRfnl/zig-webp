# Plan 023: Vectorize the VP8 loop filter with @Vector, byte-exact

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- src/vp8/loop_filter.zig PROGRESS.MD`
> If `src/vp8/loop_filter.zig` changed since this plan was written, compare
> the "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (bit-exactness of clamped fixed-point kernels; mitigated by the corpus gate and a scalar-vs-SIMD equivalence test)
- **Depends on**: plans/020-bench-libwebp-internal-decode-timing.md (soft — better ratios in the record)
- **Category**: perf
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

The in-loop deblocking filter is the largest remaining unvectorized stage of
lossy (VP8) decode — `PROGRESS.MD`'s slice-10c entry names "loop-filter
SIMD/lookup tables" first among the remaining lossy levers (YUV→RGB
conversion and bool-reader renormalization are already done, at 1.11× and
1.20× respectively). In libwebp this stage is a major SIMD win; here every
edge pixel runs scalar kernels where each of up to 8 taps does i64 index
arithmetic through function calls (`tap`/`store`). The filter runs over
every macroblock edge of every lossy still and every animation frame. The
target: `@Vector`-ize the per-edge kernels (16 luma / 8 chroma lanes),
byte-exact, keeping the scalar kernels as the reference implementation.

## Current state

- `src/vp8/loop_filter.zig` (517 lines) — the whole filter: strength
  precomputation (`computeStrengths`, `:49-109`), the per-frame macroblock
  walk (`applyFrame`, `:122-151`), per-macroblock edge dispatch
  (`filterMacroblock`, `:153-225`), edge loops (`simpleEdge` `:234-250`,
  `complexEdge` `:252-276`), and scalar kernels (`:285-405`).
- Called from `src/vp8/decoder.zig:220-221` and (encoder reconstruction)
  `src/vp8/encoder.zig:337-338` — both through `applyFrame`; **no signature
  changes needed or allowed**.

Edge geometry (`:227-233` comment): `across` steps across the edge (the
p[-k]/q[+k] tap delta), `along` walks the `count` pixels lying on the edge.
Two orientations per edge group in `filterMacroblock`:

- **Vertical edges** (left/inner-vertical): `across = 1`, `along = stride`
  — taps are horizontally adjacent, edge pixels are vertically strided.
- **Horizontal edges** (top/inner-horizontal): `across = stride`,
  `along = 1` — taps are vertically strided, the `count` (16 or 8) edge
  pixels are **contiguous in memory**. This is the easy SIMD case: each tap
  row `p3..q3` is one contiguous 16- or 8-byte load at `center + k*stride`.

The edge loops today (`:234-276`):

```zig
fn simpleEdge(plane: []u8, base: usize, across: i32, along: usize, count: usize, threshold: i32) void {
    const threshold2 = 2 * threshold + 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const center = base + i * along;
        if (needsFilter(plane, center, across, threshold2)) {
            doFilter2(plane, center, across);
        }
    }
}

fn complexEdge(plane: []u8, base: usize, across: i32, along: usize, count: usize,
    threshold: i32, inner_limit: i32, hev_threshold: i32, comptime macroblock_edge: bool) void {
    const threshold2 = 2 * threshold + 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const center = base + i * along;
        if (!needsFilter2(plane, center, across, threshold2, inner_limit)) continue;
        if (hev(plane, center, across, hev_threshold)) {
            doFilter2(plane, center, across);
        } else if (macroblock_edge) {
            doFilter6(plane, center, across);
        } else {
            doFilter4(plane, center, across);
        }
    }
}
```

The kernels are pure i32 fixed-point with clamps — all lane-parallel
(`:340-405`, key excerpts):

```zig
fn doFilter2(plane: []u8, center: usize, across: i32) void {
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    const a = 3 * (q0 - p0) + sclip1(p1 - q1);
    const a1 = sclip2(@divFloor(a + 4, 8));
    const a2 = sclip2(@divFloor(a + 3, 8));
    store(plane, center, across, -1, p0 + a2);
    store(plane, center, across, 0, q0 - a1);
}
// doFilter4 (:354-367): same 4 taps, writes p1..q1 with a3 = @divFloor(a1 + 1, 2)
// doFilter6 (:370-387): 6 taps, weights 27/18/9 with +63, >>7 via @divFloor(...,128)
// needsFilter (:298-304), needsFilter2 (:307-329), hev (:332-338): tap-wise abs/compare
// sclip1 = clamp(-128,127); sclip2 = clamp(-16,15); clip255 = clamp(0,255)
```

Per-lane decision structure: each edge pixel independently picks
{skip, filter2, filter4, filter6} from `needsFilter2`/`hev`. In SIMD this
becomes: compute **all** candidate outputs per lane, then `@select` with the
decision masks. That is bit-exact because every kernel is a pure function of
its taps.

`@divFloor(x, 8)` on possibly-negative i32 = arithmetic shift `x >> 3`
**only for floor semantics** — Zig's `>>` on signed ints is an arithmetic
shift with floor behavior, so `@divFloor(a + 4, 8)` ≡ `(a + 4) >> 3`.
Same for `/128` ≡ `>> 7`. Use shifts in vector code (`@divFloor` is also
fine on vectors; either way, do NOT use `@divTrunc`).

Repo conventions that apply — the house SIMD pattern is
`src/color.zig:175-310` (slice 10b):

- A comptime-gated SIMD path with the scalar path kept as the reference and
  used for tails/other configs (`upsampleInteriorSimd` returns where the
  scalar loop resumes).
- A **non-circular equivalence test**: 10b added a test asserting the
  scalar-only output equals the SIMD path's output on the same input,
  independent of the corpus hashes. Replicate that idea here.
- u8 lane data has no endianness, so unlike 10b you do NOT need a
  little-endian gate; the vector path can be unconditional.
- **32-bit portability**: no hardcoded `u6` shift amounts on `usize`
  (plan-014 lesson); `zig build wasm-check` compiles the tests for wasm32.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check, compile, 464+ tests incl. SHA-256 corpus gate over 88 lossy stills) |
| Tests only | `zig build test` | exit 0 |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 |
| Bench (ReleaseFast) | `zig build bench -Doptimize=ReleaseFast` | TSV to stdout |
| Format | `zig fmt .` | run before `zig build ci` |

## Scope

**In scope** (the only files you should modify):
- `src/vp8/loop_filter.zig`
- `PROGRESS.MD` (dated result row + short entry; append-only)

**Out of scope** (do NOT touch, even though they look related):
- `src/vp8/decoder.zig`, `src/vp8/encoder.zig` — callers; `applyFrame`'s
  signature and the deferred-single-pass filtering model (file-top comment,
  `:1-11`) are fixed.
- `src/color.zig` — the exemplar, not a target.
- `src/vp8/transform.zig`, `src/vp8/prediction.zig` — plan 024's
  (conditional) territory.

## Git workflow

- Branch: `vp8-loop-filter-simd`
- Commit per step; message style: imperative summary line, e.g.
  `Vectorize horizontal loop-filter edges`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Record the baseline

`zig build bench -Doptimize=ReleaseFast` at the branch point →
`/tmp/plan023-bench-before.tsv`. Note the lossy rows (`bryce`,
`lossy_extreme*`, `vp80-*` classes).

**Verify**: file exists with lossy decode rows.

### Step 2: Vectorize horizontal edges (contiguous lanes)

Add SIMD variants used only for the `along == 1` orientation (top and
inner-horizontal edges), dispatched from `filterMacroblock` — pass a
comptime orientation or add `simpleEdgeH`/`complexEdgeH` entry points; keep
the existing scalar functions untouched as the reference.

Implementation shape (luma `count=16`; chroma `count=8` — use a comptime
`Lanes` parameter):

1. Load rows as vectors: `q_k = plane[base + k*stride ..][0..Lanes].*` for
   k in -4..3 (`@Vector(Lanes, u8)`), widen to `@Vector(Lanes, i16)`.
   i16 is sufficient headroom: taps are 0..255, `a = 3*(q0-p0)+sclip1(p1-q1)`
   ∈ [-893, 892], the 27/18/9-weighted doFilter6 intermediate
   `27*a_clamped + 63` with `a_clamped ∈ [-128,127]` ∈ [-3393, 3492] — all
   fit i16. Keep a comptime assert documenting these bounds.
2. Compute masks lane-wise: `needs2` (edge + interior smoothness),
   `hev_mask` — straight transcriptions of `needsFilter2`/`hev` with
   `@abs`/comparisons on vectors (`@select` composes the boolean vectors).
3. Compute all three filter results (f2, f4, f6 for macroblock edges; f2,
   f4 for inner) for every lane, then select per output row:
   `result = @select(needs2, @select(hev_mask, f2_row, f46_row), original_row)`.
4. Store each affected row back with one contiguous vector store.
5. `simpleEdge` horizontal variant: same pattern with `needsFilter` and f2
   only.

Fixed-point care: use `>>` (arithmetic) or `@divFloor` on the i16 vectors —
never `@divTrunc`; clamp helpers become `@min`/`@max` splat pairs mirroring
`sclip1`/`sclip2`/`clip255` exactly.

**Verify**: `zig build test` → exit 0. The corpus gate (88 lossy stills,
filter on, byte-for-byte) is the primary oracle for this step.

### Step 3: Vectorize vertical edges via transpose

For `across == 1` edges (left/inner-vertical): load the 8×`Lanes` pixel
block around the edge (8 strided contiguous-row loads of 8 bytes... note
here the 8 taps are contiguous per edge pixel and the Lanes edge pixels are
strided). Transpose to tap-major vectors with `@shuffle`, run the exact
Step-2 lane math, transpose back, store rows.

If the transpose cost eats the win (measure!), an acceptable fallback is to
keep vertical edges scalar and record that in `PROGRESS.MD` — half the
edges vectorized is still a real win. Decide by measurement, not vibes: run
the bench with Step 2 only, then with Step 3, and keep Step 3 only if it
improves the aggregate.

**Verify**: `zig build test` → exit 0 after whichever variant you keep;
`zig build wasm-check` → exit 0; `zig fmt .`; `zig build ci` → exit 0.

### Step 4: Measure and record

Interleaved A/B vs branch point (ReleaseFast, single thread, ≥3 runs,
medians) over the lossy bench rows. Append the dated `PROGRESS.MD` row +
entry (slice-10b entry is the format template: headline aggregate, best
file, what stayed unchanged, rejected alternatives). If dwebp is present,
refresh the `bryce` ratio via `tools/webp-bench.sh` (`decode_int_ms` column
if plan 020 landed).

**Verify**: aggregate lossy decode ≥ 1.05× (filter share varies by corpus;
`lossy_extreme_probabilities`-class files with high filter levels should
show the largest wins). Below 1.03× → STOP outcome.

## Test plan

New tests in `src/vp8/loop_filter.zig`, modeled on the existing test style
in the file (`:411+`) and 10b's non-circular equivalence idea:

1. **Scalar/SIMD equivalence, randomized**: build a deterministic
   pseudo-random padded frame (fixed `std.Random.DefaultPrng` seed — never
   entropy, matching `src/testing/fuzz.zig`'s determinism convention), run
   `applyFrame` twice — once forced down the scalar edge functions, once
   through the SIMD dispatch — over several strength settings
   (level ∈ {10, 25, 63}, sharpness ∈ {0, 4, 7}, simple and complex,
   `inner` on/off) and assert plane equality byte-for-byte. To force the
   scalar path, keep the scalar edge functions callable and give the test a
   thin harness that mirrors `filterMacroblock`'s dispatch with scalar
   functions — do not add a runtime "disable SIMD" knob to production code.
2. **Boundary macroblocks**: 1-macroblock and 2×1-macroblock frames (no
   left/top neighbors) through both paths — pins the `has_left`/`has_top`
   guards against out-of-bounds vector loads (vectors read 4 taps across
   the edge; the guards must keep them inside the padded plane exactly as
   the scalar taps are).
3. Existing tests stay green unmodified.

Verification: `zig build test` → all pass including the new equivalence
tests; corpus hashes unchanged.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0
- [ ] `zig build wasm-check` exits 0
- [ ] `grep -n "@Vector" src/vp8/loop_filter.zig` shows the vector kernels;
      scalar `doFilter2/4/6` still present (reference + tails)
- [ ] New scalar-vs-SIMD equivalence tests exist and pass
- [ ] Bench medians recorded in `PROGRESS.MD` with date, machine, build
      mode, and the Step-3 keep/drop decision recorded
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any corpus-hash test fails — a lane-math difference (likely a
  `@divTrunc`-vs-floor or clamp-order slip); never regenerate hashes.
- The equivalence test passes but the corpus gate fails — the dispatch
  differs between test harness and production path; report the discrepancy.
- Vector loads would read outside the padded plane for edge macroblocks
  (check the padding guarantees in `src/vp8/decoder.zig`'s plane allocation
  before assuming; if padding is insufficient for 4-tap reads at frame
  borders, STOP and report rather than growing the padding).
- Speedup < 1.03× aggregate lossy decode: report numbers, leave unmerged.

## Maintenance notes

- Plan 024 (IDCT/prediction SIMD spike) measures what is left of lossy
  decode after this lands — execute 023 first.
- Reviewer should scrutinize: signed-shift floor semantics in the vector
  kernels, the i16 headroom comptime assert, and the transpose index maps
  in Step 3 (an incorrect shuffle that still round-trips symmetric test
  content is the classic trap — the randomized equivalence test exists for
  exactly this).
- Deferred deliberately: threading the filter (plan 027 design doc), and
  fusing filter into the reconstruction row pipeline ("row-pipeline
  locality" lever from 10c — a separate, larger restructure).
