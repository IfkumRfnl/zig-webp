# Plan 028: Measure Rust-informed VP8L decode experiments

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. Each candidate is an experiment, not a presumed win: keep only
> candidates that pass their correctness and performance gates. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise.
> When done, update this plan's status row in `plans/README.md` unless a
> reviewer dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 02f4e05..HEAD -- src/vp8l/entropy.zig src/vp8l/prefix_groups.zig src/vp8l/meta_prefix.zig src/vp8l/color_cache.zig src/vp8l/huffman.zig src/vp8l/inverse_transform.zig src/vp8l/decoder.zig src/decode.zig tools/webp-rust-bench.sh PROGRESS.MD`
> If any in-scope code changed, compare the "Current state" excerpts with the
> live code. Changed line numbers alone are harmless; changed invariants or
> loop structure are a STOP condition until the plan is reconciled.

## Status

- **Priority**: P1
- **Effort**: L (four independently gated experiments plus full A/B runs)
- **Risk**: MED (VP8L entropy and inverse-transform hot paths determine pixels)
- **Depends on**: plan 022 and the accepted packed-entry/scratch/predictor work
  through commit `02f4e05`
- **Category**: perf
- **Planned at**: commit `02f4e05`, 2026-07-15
- **Status**: REJECTED — all four candidates missed their gates; production
  source was reverted, with the reviewed decisive record at `30cc1ba`

## Why this matters

The local pure-Rust `image-webp` decoder is still faster on every measured
lossless still: Zig is **2.7621x** slower on the 24 opaque files and **2.8057x**
slower on the 23 alpha files by per-file geomean. Three full comparison runs
showed Zig winning **0/47** lossless files. The comparison is directionally
trustworthy: both sides time constructor/parser plus complete decode into a
reused RGB/RGBA destination, exclude file I/O and digest work, and validate the
same bytes before timing.

A source-level comparison found four remaining mechanisms worth measuring.
They are not invitations to copy Rust code. Reimplement from the VP8L
specification, preserve Zig's checked boundaries, and use the Rust source only
to understand why less work is possible.

The existing stage profile sets the priority: entropy is approximately
**66%–95%** of VP8L decode; predictor and color transforms are materially
smaller. Therefore the first two experiments target spatial-group and cached
copy work inside the entropy loop. Palette expansion is third and a possible
statistics-only specialization is fourth.

## Current state

### Finding A — Copies discard valid spatial-group run state

Rust retains the selected Huffman group until the decoded output index reaches
the next block boundary:

- `references/image-webp/src/lossless/decoder/mod.rs:468-480` computes
  `next_block_start` and selects a group only when `index >= next_block_start`.
- `references/image-webp/src/lossless/decoder/mod.rs:536-576` advances `index`
  after a backward copy without forcing a group refresh when the copy remains
  inside the current block.

Zig already hoists group selection to horizontal runs, but loses the remaining
run after every copy:

```zig
// src/vp8l/entropy.zig:185-198
if (spatial and run_remaining == 0) {
    const x: u32 = @intCast(output_index % @as(usize, width));
    const y: u32 = @intCast(output_index / @as(usize, width));
    prefix_codes = try spatial_selector.store.groupForPixel(...);
    ...
    run_remaining = @min(block_size - into_tile, width - x);
}
```

```zig
// src/vp8l/entropy.zig:209-221
output_index = try copyBackwardReference(...);
if (spatial) run_remaining = 0;
summary.copy_count += 1;
```

The forced refresh calls two checked, by-value layers:

- `src/vp8l/meta_prefix.zig:26-50` rechecks coordinates, image length, checked
  pixel count, entropy index, and group count.
- `src/vp8l/prefix_groups.zig:90-104` checks the initialized group count and
  returns the five-table `PrefixCodeGroup` by value.

This is most relevant to LZ77-heavy spatial-group images. Current examples:
`photo_foliage.webp` is **6.33x** slower than Rust and
`photo_signage.webp` is **4.73x** slower.

### Finding B — Cached copies stay scalar and rehash repeated pixels

Rust treats distance-one copies as a fill and does not reinsert the repeated
pixel into the color cache (`references/image-webp/src/lossless/decoder/mod.rs:
549-553`). This preserves cache state because the source pixel was already
inserted and reinserting the identical value at the identical hash changes
nothing. For other distances, Rust performs chunked copies first and updates
the cache in a separate pass (`:554-574`). It also peeks one additional
primary-table color-cache symbol and consumes it without another full outer
loop iteration (`:587-595`).

Zig's cache-specialized backward-copy path interleaves one copy and one hash /
cache insertion per output pixel:

```zig
// src/vp8l/entropy.zig:299-307
if (has_cache) {
    var output_index = output_index_start;
    var copied_count: usize = 0;
    while (copied_count < length_pixels) : (copied_count += 1) {
        const value = output[output_index - distance_pixels];
        output[output_index] = value;
        cache.insert(value);
        output_index += 1;
    }
    return output_index;
}
```

Zig also processes one cache reference per outer iteration
(`src/vp8l/entropy.zig:222-229`). `color_cache_bits_11.webp` remains **3.58x**
slower than Rust, making it the focused asset for this finding.

### Finding C — Palette expansion is per pixel rather than per packed byte

Rust has two palette paths in
`references/image-webp/src/lossless/decoder/reverse_transform.rs`:

- `:400-425` pads larger palettes to a fixed 256-entry table before the pixel
  loop, removing the per-pixel palette-length branch.
- `:430-573` dispatches 1/2/4-bit packed indices to const-specialized kernels,
  pre-expands all 256 possible packed bytes, and copies fixed-size expanded
  blocks per row.

Zig expands backward one output pixel at a time:

```zig
// src/vp8l/inverse_transform.zig:204-224
var output_index = @as(usize, @intCast(pixel_count));
while (output_index > 0) {
    output_index -= 1;
    const x = output_index % output_width;
    const y = output_index / output_width;
    const source_x = x >> width_bits;
    const source_index = y * source_width + source_x;
    ...
    const shift = ...;
    const color_index = (packed_index >> shift) & index_mask;
    pixels[output_index] = if (color_index < color_table_size)
        color_table[color_index]
    else
        pixel.fromChannels(0, 0, 0, 0);
}
```

`bad_palette_index.webp` remains **2.57x** slower than Rust. This finding is
high confidence for palette assets but cannot explain the large photographic
lossless gap by itself.

### Finding D — High-level decode may collect discarded entropy statistics

Zig initializes and updates a `DecodeSummary` counter for every literal, copy,
and cache operation (`src/vp8l/entropy.zig:172-177`, `:208`, `:221`, `:229`).
The public high-level lossless path discards the returned result at
`src/decode.zig:183`. Rust does not collect equivalent counters.

This is a measurement finding, not a proven cost: ReleaseFast may eliminate
some counters after inlining. Inspect generated code before changing the API
shape. Preserve the public low-level summary contract even if high-level decode
gets a `comptime collect_summary = false` specialization.

### Source differences already measured and rejected

Do not reopen these without new attribution evidence:

- **10-bit Huffman root.** Rust uses ten bits; Zig's measured ten-bit
  experiment slowed lossless opaque to **0.9620x** and lossless alpha to
  **0.9261x** versus the accepted eight-bit root. The larger table footprint
  outweighed fewer secondary lookups.
- **Bulk refill plus unchecked lookup.** Plan 021 implemented the Rust-like
  fill-once contract and measured only about **1.011x** aggregate lossless
  improvement, below its **1.05x** complexity gate.
- **Constant single-symbol group fill.** A prior isolated experiment helped
  selected constant images but regressed the aggregate. Do not add another
  unconditional outer-loop branch for it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Toolchain | `zig version` | `0.16.0` |
| Focused Zig benchmark | `zig build -Doptimize=ReleaseFast bench -- --decode-only --filter FILTER --iters 15 --warmup 2 --budget-ms 1500 OUT.tsv` | output TSV contains the target |
| Zig/Rust comparison | `tools/webp-rust-bench.sh --all -n 15 --warmup 2 --budget-ms 1500 -o OUT.tsv` | 135 validated, 0 skipped |
| Full gate | `zig build ci` | exit 0; all tests pass |
| wasm32 gate | `zig build wasm-check` | wasm32-wasi and wasm32-freestanding compile |
| Formatting | `zig fmt .` | exit 0 |

Use separate clean worktrees for baseline and candidate measurements. Run at
least three alternating baseline/candidate orderings. Compare the
median-of-three per-file medians; report both per-file geomean and summed time.
Never claim a general win from a tiny-file-heavy geomean.

## Suggested executor toolkit

- Read `skill://zig-0.16` before changing Zig code.
- Read `skill://zig-tiger-style`; preserve bounded loops, explicit integer
  conversions, compile-time invariants, and scalar equivalence authorities.
- Specifications remain authoritative:
  - RFC 9649 for WebP image format behavior.
  - The WebP lossless bitstream specification for cache, copy, transform, and
    palette semantics.

## Scope

**In scope** (only as required by the accepted experiments):

- `src/vp8l/entropy.zig`
- `src/vp8l/prefix_groups.zig`
- `src/vp8l/meta_prefix.zig`
- `src/vp8l/color_cache.zig`
- `src/vp8l/huffman.zig`
- `src/vp8l/inverse_transform.zig`
- `src/vp8l/decoder.zig`
- `src/decode.zig`
- `PROGRESS.MD` (dated accepted/rejected measurements)
- `plans/README.md` (status only)

**Out of scope**:

- `src/bit_reader.zig` and Huffman root width — measured and rejected above.
- VP8 lossy modules, encoders, RIFF/container parsing, public API renames, or
  new package dependencies.
- Any modification to `references/image-webp`; it is a read-only oracle.
- `README.MD` and `PLAN.MD`; no user-facing behavior or roadmap scope changes.
- SIMD, threading, or architecture-specific assembly.

## Git workflow

- Branch: `perf/vp8l-rust-informed-loops`
- Use one commit per candidate so rejected work can be dropped cleanly.
- Commit messages should describe the mechanism, for example
  `Preserve VP8L prefix group across local copies`.
- Do not push or open a PR unless the operator instructs you.

## Steps

### Step 1: Establish the paired baseline

From clean commit `02f4e05`, run three full Zig/Rust comparisons and targeted
long-budget Zig runs for:

- `photo_foliage.webp`
- `photo_signage.webp`
- `color_cache_bits_11.webp`
- `bad_palette_index.webp`
- `lossless_big_random_alpha.webp`

Record per-file medians and the four codec/alpha bucket summaries. Confirm
**135 validated, 0 skipped** on every full comparison.

**Verify**: three complete TSV files exist under `.zig-cache/`; each has 135
paired `decode-into` files and no digest mismatch.

### Step 2: Preserve spatial group state across copies

Change `src/vp8l/entropy.zig` so a backward copy consumes only the applicable
part of `run_remaining`. If the copy ends before the current block boundary,
retain the existing prefix group. If it reaches or crosses the boundary, set
`run_remaining = 0` so the next symbol selects the group for its new output
position.

Measure that change alone first. Only after it wins, separately change the
spatial selector to validate invariant dimensions/counts once before the loop
and retain a pointer/reference to the selected `PrefixCodeGroup`. Runtime
errors for malformed entropy images and out-of-range group IDs must remain
reachable before any unchecked indexing.

Add focused tests for copies that:

- end one pixel before a tile boundary;
- end exactly on a boundary;
- cross one and multiple boundaries;
- land in a tile with a different Huffman group;
- end at a partial right-edge tile.

**Verify**: focused entropy tests pass; `zig build ci` and
`zig build wasm-check` pass; 135/135 Rust differential validation passes.
Keep each subchange only if targeted lossless geomean improves at least
**1.03x**, full-lossless summed time improves at least **1.01x**, and neither
lossless alpha/opaque bucket regresses by more than **1%** across the three
alternating orderings.

### Step 3: Specialize cached backward copies

In the `has_cache` comptime variant of `copyBackwardReference`:

1. Special-case `distance_pixels == 1` with `@memset`; do not reinsert the
   repeated source value because its identical cache slot is already current.
2. For other distances, use the existing bounded no-cache copy geometry to
   materialize output first, then scan exactly the copied pixels in order to
   update the cache. Preserve collision order.
3. Measure before considering a consecutive-cache-symbol peek. If a peek is
   attempted, it must accept only a validated primary-table cache symbol,
   consume exactly its bit count, remain bounded at end-of-stream, and never
   add a general unchecked bit-reader API.

Add tests with a deliberately colliding small cache, distance-one runs,
overlapping distances 2/3/4, lengths shorter/equal/longer than distance, and a
copy that ends at output capacity. Compare every result and final cache state
against the current scalar reference behavior.

**Verify**: focused cache/entropy tests, full CI, wasm, and 135/135 differential
validation pass. Keep each subchange only under the same **1.03x targeted**,
**1.01x full-lossless summed-time**, and **<1% bucket-regression** gates, with
`color_cache_bits_11.webp` included in the targeted set.

### Step 4: Expand palette indices per packed byte

Keep the current `applyColorIndexingTransform` implementation as the scalar
reference. Add compile-time-specialized kernels for 1-, 2-, and 4-bit indices.
Each kernel may precompute a bounded 256-entry mapping from one packed byte to
the corresponding 8/4/2 pixels, then expand rows from bottom to top so in-place
source indices are not overwritten before use.

For eight-bit indices, use a padded fixed 256-entry local table or an equally
bounded representation that makes out-of-range indices resolve to transparent
black without a per-pixel conditional. Account for all temporary storage with
a fixed upper bound; no allocator dependency is permitted in this transform.

Add equivalence tests for palette sizes 1, 2, 3, 4, 5, 16, 17, and 256; widths
1, 2, 7, 8, 9, and a multi-row partial block; invalid indices; and randomized
scalar-versus-specialized comparison.

**Verify**: focused transform equivalence, full CI, wasm, and 135/135
differential validation pass. Keep only if palette-target geomean improves at
least **1.05x**, full-lossless summed time does not regress beyond **1%**, and
stack usage stays bounded for wasm32.

### Step 5: Determine whether summary counters survive optimization

Inspect the ReleaseFast call path from `decodeLossless` through
`decodeARGBAlloc` and the four `decodeLoop` specializations. If generated code
contains no per-operation summary increments when `src/decode.zig` discards the
result, record **no change needed** and stop this experiment.

If increments remain, add a comptime collection mode internal to the VP8L
decoder. The public low-level entry points and `VP8LEntropyDecodeSummary` must
retain existing values; only high-level `decodeStatic` / `decodeStaticInto`
should select the statistics-free path. Do not add a public option.

Add a test decoding the same literal/copy/cache stream through both modes:
pixels and errors must match, while the collecting mode retains the exact
existing counts.

**Verify**: generated ReleaseFast code or a focused A/B demonstrates the
increments were removed. Keep only if full-lossless summed time improves at
least **1.01x** with no bucket regression beyond **1%**; then run full CI, wasm,
and differential validation.

### Step 6: Integrate winners and record honest results

Rebase the individually accepted commits onto current `main` in the measured
order. Repeat three alternating full comparisons against a clean baseline.
Record in `PROGRESS.MD`:

- accepted and rejected candidate commits;
- machine, Zig/Rust versions, ReleaseFast/release modes, iterations, warmups,
  and budget;
- 135/135 digest validation;
- per-bucket geomean and summed-time ratios;
- representative targeted files and large-file variance;
- remaining Zig / `image-webp` ratios.

Do not claim Zig beats Rust unless the cumulative paired results actually show
that for the named bucket and metric.

**Verify**: `zig build ci` and `zig build wasm-check` pass on the final
cumulative branch; its worktree is clean except for the intended plan-status
update.

## Test plan

Every accepted candidate must add an observable equivalence test that would
fail on a plausible implementation bug:

- spatial copies: group changes at exact/crossed block boundaries;
- cached copies: cache collisions and overlap order;
- palette expansion: odd widths, final partial packed byte, invalid index;
- summary specialization: identical pixels/errors with exact collecting counts.

The committed 135-file digest comparison is the end-to-end oracle. Tests must
remain deterministic, allocation-bounded, and valid under wasm32 compilation.

## Done criteria

- [ ] Every candidate has an isolated baseline/candidate measurement and a
      recorded accept/reject decision.
- [ ] No rejected candidate remains in the final source diff.
- [ ] Final `zig build ci` exits 0 with all tests passing.
- [ ] Final `zig build wasm-check` exits 0.
- [ ] Three final comparisons each validate 135/135 files with zero skips.
- [ ] `PROGRESS.MD` records both geomean and summed-time results honestly.
- [ ] No dependency, Rust source modification, public API change, SIMD, or
      threading was added.
- [ ] `plans/README.md` records DONE or REJECTED with the final commit(s).

## STOP conditions

Stop and report rather than improvising if:

- Drift changed the spatial-group, copy, cache, palette, or public summary
  invariants described above.
- A candidate changes decoded bytes, accepted/rejected error behavior, final
  color-cache state, or wasm32 compilation.
- Correct spatial-group preservation requires decoding symbols with a group
  chosen from any position other than the symbol's starting output position.
- A cache optimization cannot prove identical collision/update order.
- Palette specialization needs unbounded or allocator-backed temporary memory.
- A candidate misses its gate after three alternating measurements.
- The work appears to require reopening the rejected bit-reader or 10-bit-root
  experiments without new attribution evidence.

## Maintenance notes

- Keep the scalar palette and cache/copy logic as equivalence authorities even
  when production dispatches to specialized kernels.
- Review group-boundary arithmetic and cache-collision order before reviewing
  micro-optimization details; those are the byte-exactness risks.
- `image-webp` is a comparison oracle, not a source to copy. Comments and code
  must explain the VP8L invariant independently of Rust's implementation.
- If the first two entropy experiments do not materially improve
  `photo_foliage.webp` and `photo_signage.webp`, the next action is attribution
  profiling, not more speculative Huffman-table geometry.
