# Plan 022: Specialize the VP8L pixel decode loop — hoist group selection, comptime variants, chunked LZ77 copies

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- src/vp8l/entropy.zig PROGRESS.MD`
> If `src/vp8l/entropy.zig` changed since this plan was written (plan 021
> does NOT touch it, so only unrelated work would), compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (rewrites the hottest VP8L loop; mitigated by the byte-exact corpus gate and fuzz targets)
- **Depends on**: plans/021-vp8l-bitreader-bulk-refill-fast-path.md (soft — independent change, but land 021 first so each speedup is measured separately)
- **Category**: perf
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

The VP8L pixel loop pays three per-pixel taxes that libwebp does not:

1. **Meta-prefix group lookup per pixel.** `selector.group(dimensions,
   output_index)` runs for *every* pixel; in the spatial (meta-prefix) case
   it does a `%` and `/` by width plus a bounds-checked entropy-image read —
   but the group can only change every `block_size` (≥4) pixels
   horizontally, and most images use a single group where the lookup is pure
   waste.
2. **Runtime branching on cache/selector shape per pixel.** Whether a color
   cache exists and whether the selector is single/spatial is fixed for the
   whole image, yet checked per pixel (`if (cache) |...|` on every literal
   and every copied pixel).
3. **Pixel-at-a-time LZ77 copies.** `copyBackwardReference` copies one
   `u32` per iteration even when the ranges do not overlap and no cache
   insert is needed — where a `@memcpy` is legal and much faster.

Zig's comptime generics make libwebp's hand-written loop variants nearly free
to express: instantiate one loop body over `(has_cache, spatial)` and hoist
the group to tile boundaries. Decoded output must remain byte-for-byte
identical (the SHA-256 corpus gate enforces it). This is the second half of
closing the recorded 1.8×–5.6× lossless-decode gap (see plan 021).

## Current state

- `src/vp8l/entropy.zig` — VP8L entropy-coded image materialization; the
  file to change. 571 lines; the hot loop is `decodeImageWithSelector`.
- `src/vp8l/meta_prefix.zig` — `Info` (tile geometry) and `groupIndex`.
- `src/vp8l/prefix_groups.zig` — `Store.group(index)` /
  `Store.groupForPixel(info, entropy_image, x, y)`.
- `src/vp8l/color_cache.zig` — `Cache.insert(value)` / `Cache.lookup(index)`.

The hot loop today (`src/vp8l/entropy.zig:163-214`):

```zig
fn decodeImageWithSelector(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: ?*color_cache.Cache,
    selector: PrefixCodeSelector,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    ...
    var output_index: usize = 0;
    while (output_index < output.len) {
        const prefix_codes = try selector.group(dimensions, output_index);
        const green_symbol = try prefix_codes.green.decode(reader);
        if (green_symbol < huffman.literal_alphabet_size) {
            const value = try readLiteral(reader, prefix_codes, green_symbol);
            output[output_index] = value;
            if (cache) |color_cache_pointer| color_cache_pointer.insert(value);
            output_index += 1;
            summary.literal_count += 1;
        } else if (green_symbol < huffman.literal_alphabet_size + huffman.length_code_count) {
            output_index = try copyBackwardReference(...);
            summary.copy_count += 1;
        } else {
            const value = try readColorCachePixel(green_symbol, cache);
            output[output_index] = value;
            output_index += 1;
            summary.color_cache_count += 1;
        }
    }
    ...
}
```

The per-pixel group lookup (`src/vp8l/entropy.zig:128-155`):

```zig
const PrefixCodeSelector = union(enum) {
    single: image_data.PrefixCodeGroup,
    spatial: SpatialPrefixCodeSelector,

    fn group(self: PrefixCodeSelector, dimensions: image.Dimensions, output_index: usize) errors.Error!image_data.PrefixCodeGroup {
        ...
        .spatial => |spatial| {
            const width: usize = @intCast(dimensions.width);
            const x: u32 = @intCast(output_index % width);
            const y: u32 = @intCast(output_index / width);
            return spatial.store.groupForPixel(spatial.meta_prefix_info, spatial.entropy_image, x, y);
        },
    }
};
```

The copy loop (`src/vp8l/entropy.zig:272-281`):

```zig
var output_index = output_index_start;
var copied_count: u32 = 0;
while (copied_count < length) : (copied_count += 1) {
    const value = output[output_index - distance_pixels];
    output[output_index] = value;
    if (cache) |color_cache_pointer| color_cache_pointer.insert(value);
    output_index += 1;
}
```

Validation already done before this loop (`:254-270`): `length` fits the
remaining output, `distance > 0`, `distance <= output_index_start`. So inside
the loop, source and destination ranges are in-bounds by construction.

Tile geometry (`src/vp8l/meta_prefix.zig:19-52`): `Info.prefix_bits: u4`
(2..9), `block_size = 1 << prefix_bits`; `groupIndex(entropy_image, x, y)`
computes `entropy_x = x >> prefix_bits`, `entropy_y = y >> prefix_bits`, and
bounds-checks everything, returning `error.InvalidVP8LImageData` on a group
index ≥ `group_count`.

Callers of `decodeImageWithSelector` (all in this file): `decodeImage`
(single group; from `decodeWithPrefixCodes`, `:42-61`) and
`decodeWithGroupStore` (`:63-110`, spatial). Public signatures of
`decodeSingleGroup`, `decodeWithPrefixCodes`, `decodeWithGroupStore` must NOT
change — `src/vp8l/decoder.zig`, `src/alpha.zig`, and tests call them.

`DecodeSummary` (`:17-22`) counts literals/copies/cache hits — several tests
assert exact counts; the restructure must preserve them.

Repo conventions that apply:

- Assertions, bounded loops, explicit widths; keep the module's
  narrow-interface style (no new public API).
- **32-bit portability**: no hardcoded `u6` shift amounts on `usize` values
  (plan-014 lesson). `x >> prefix_bits` with `u4` amounts on `u32` is fine.
- The comptime-specialization precedent in this repo is
  `src/color.zig:175-310` (`upsampleLinePair(comptime format, ...)`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check, compile, 464+ tests incl. SHA-256 corpus gate) |
| Tests only | `zig build test` | exit 0 |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 |
| Bench (ReleaseFast) | `zig build bench -Doptimize=ReleaseFast` | TSV to stdout |
| Format | `zig fmt .` | run before `zig build ci` |

## Scope

**In scope** (the only files you should modify):
- `src/vp8l/entropy.zig`
- `PROGRESS.MD` (dated result row + short entry; append-only)

**Out of scope** (do NOT touch, even though they look related):
- `src/bit_reader.zig`, `src/vp8l/huffman.zig` — plan 021's territory.
- `src/vp8l/meta_prefix.zig`, `src/vp8l/prefix_groups.zig`,
  `src/vp8l/color_cache.zig` — read-only dependencies; their validation
  semantics are part of the contract you must reproduce.
- `src/vp8l/decoder.zig`, `src/alpha.zig` — callers; signatures unchanged.

## Git workflow

- Branch: `vp8l-specialized-decode-loop`
- Commit per step; message style: imperative summary line, e.g.
  `Specialize the VP8L pixel loop over cache and selector shape`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Record the baseline

`zig build bench -Doptimize=ReleaseFast` at the branch point (which should
include plan 021 if it landed) → `/tmp/plan022-bench-before.tsv`.

**Verify**: file exists with lossless decode rows.

### Step 2: Comptime-specialized loop with hoisted group state

Restructure `decodeImageWithSelector` into a thin dispatcher plus one
generic body:

```zig
fn decodeImageWithSelector(reader, dimensions, cache, selector, output) errors.Error!DecodeSummary {
    assert(output.len == try dimensions.pixelCount());
    return switch (selector) {
        .single => |codes| if (cache) |c|
            decodeLoop(true, false, reader, dimensions, c, .{ .single = codes }, output)
        else
            decodeLoop(false, false, reader, dimensions, undefined_cache_ok, .{ .single = codes }, output),
        .spatial => |spatial| if (cache) |c|
            decodeLoop(true, true, reader, dimensions, c, .{ .spatial = spatial }, output)
        else
            decodeLoop(false, true, reader, dimensions, ..., output),
    };
}

fn decodeLoop(
    comptime has_cache: bool,
    comptime spatial: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: if (has_cache) *color_cache.Cache else void,
    ...
) errors.Error!DecodeSummary { ... }
```

(Exact parameter plumbing is yours; the load-bearing points are below.)

Inside `decodeLoop`:

1. **Group state, spatial variant only** (`comptime spatial`): maintain
   `x: u32`, `y: u32` alongside `output_index`, plus the current
   `prefix_codes` and the count of pixels remaining until the next tile
   boundary in this row (`run = min(block_size - (x & (block_size-1)),
   width - x)`). Refetch the group only when the run is exhausted or after a
   backward copy (which can jump rows): recompute `x = output_index % width`,
   `y = output_index / width` **only at those refetch points**. Fetch via
   the existing `spatial.store.groupForPixel(info, entropy_image, x, y)` so
   every validation error (`InvalidVP8LImageData` for a bad group index)
   still fires — just once per tile-run instead of once per pixel. The
   non-spatial variant binds `prefix_codes` once before the loop.
2. **Cache handling** (`comptime has_cache`): the literal-insert, the
   copy-insert, and the cache-symbol arm compile away entirely in the
   no-cache variant. In the no-cache variant a green symbol ≥
   `literal_alphabet_size + length_code_count` must still return
   `error.InvalidVP8LImageData` (today that comes from
   `readColorCachePixel`'s `orelse` — preserve it explicitly).
3. **Summary counts**: increment exactly as today; the four counters'
   values must be identical for identical input.

Keep `readLiteral`, `readChannel`, and the length/distance parsing in
`copyBackwardReference` as they are (they are correct and small); it is fine
to pass the comptime flags down or split `copyBackwardReference` into
cache/no-cache variants in the next step.

**Verify**: `zig build test` → exit 0 (corpus gate byte-exact; the
`decodeWithGroupStore` tests at `src/vp8l/entropy.zig:451+` cover the
spatial paths, including the invalid-group-index error).

### Step 3: Chunked copies in the no-cache variant

In the copy path, when `comptime has_cache == false` (cache inserts force
per-pixel work, so the cached variant keeps the existing loop):

- `distance_pixels == 1` → `@memset(output[output_index..][0..length], output[output_index - 1])`.
- `distance_pixels >= length` → non-overlapping:
  `@memcpy(output[output_index..][0..length], output[output_index - distance_pixels ..][0..length])`.
- Otherwise (overlapping, distance ≥ 2) → copy in chunks of
  `distance_pixels` (each chunk is non-overlapping with its source by
  construction), i.e. repeatedly `@memcpy` `min(distance_pixels, remaining)`
  pixels. Keep an `assert` that source and destination chunk ranges do not
  overlap before each `@memcpy` (UB otherwise — this assert is the safety
  net).

All three shapes produce exactly the sequence the scalar loop produces
(prove to yourself with the overlap argument; the corpus gate proves it in
bulk). `length` is already validated ≤ remaining output; `distance_pixels`
already validated in `1..=output_index_start`.

**Verify**: `zig build test` → exit 0; `zig build wasm-check` → exit 0.
Then `zig fmt .` and `zig build ci` → exit 0.

### Step 4: Measure and record

Interleaved A/B vs the branch point (ReleaseFast, single thread, ≥3 runs,
medians) on the bench lossless rows; append the dated row + entry to
`PROGRESS.MD` (format: the slice-10b/10c entries). State the dimension
honestly: scalar lossless decode, incremental over plan 021 if that landed.

**Verify**: aggregate lossless decode ≥ 1.10× vs the Step-1 baseline. Below
1.05× → STOP outcome (report numbers, leave unmerged).

## Test plan

New tests in `src/vp8l/entropy.zig` (model after the existing
`test "..."` blocks at `:340+` which hand-write bitstreams with
`bit_writer` + `writeSimplePrefixCode`):

1. **Overlapping-copy shapes**: distance 1 (run), distance < length
   (self-referencing), distance ≥ length (disjoint) — assert exact output
   pixels and `DecodeSummary` counts, no cache. These pin the Step-3 chunk
   logic against hand-computed expectations, independent of the corpus.
2. **Tile-boundary group switch**: a spatial stream whose entropy image maps
   two different groups within one row (the existing
   `decodeWithGroupStore` test at `:451+` is the structural pattern) and a
   copy that crosses a row boundary — asserts the hoisted refetch points are
   right.
3. Keep every existing test green unmodified — especially the
   invalid-group-index and no-cache-cache-symbol error tests.

The fuzz smoke target `test "fuzz VP8L still-image decode"`
(`src/vp8l/decoder.zig:607`) and the public-decode fuzz targets run under
`zig build test` and exercise the mutated/truncated paths of this loop —
they must stay green.

Verification: `zig build test` → all pass including ≥ 5 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0
- [ ] `zig build wasm-check` exits 0
- [ ] `grep -n "comptime has_cache" src/vp8l/entropy.zig` shows the
      specialized loop; `grep -c "selector.group(dimensions, output_index)"
      src/vp8l/entropy.zig` returns 0 (per-pixel lookup gone)
- [ ] New copy-shape and tile-boundary tests exist and pass
- [ ] Bench medians recorded in `PROGRESS.MD` with date, machine, build mode
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any corpus-hash test fails — never regenerate hashes to make it pass; the
  loop restructure changed decoded bytes somewhere. Bisect the step.
- `DecodeSummary` counts differ in any existing test — the summary is part
  of the observable contract.
- The overlap `assert` before a `@memcpy` would fire for any corpus file —
  the chunking math is wrong; do not remove the assert.
- Speedup < 1.05× aggregate lossless decode: report numbers, leave the
  branch unmerged for the maintainer's call.
- Code no longer matches the "Current state" excerpts.

## Maintenance notes

- If a future change adds new selector shapes (e.g. >1 meta-prefix bit
  semantics), the dispatcher in Step 2 is the single place to extend; the
  loop body stays shape-agnostic.
- Reviewer should scrutinize: the refetch points after backward copies
  (an off-by-one in `x`/`y` recomputation decodes with the *wrong group*
  and may still pass small tests — the corpus gate is the real net), and
  the no-cache cache-symbol error path.
- Deferred deliberately: fusing literal channel reads (green+red+blue+alpha)
  into one buffered refill — measure after this lands; and any SIMD in this
  loop (entropy decode is serial by nature).
