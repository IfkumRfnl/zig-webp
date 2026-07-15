# Plan 025: Per-tile predictor selection in the VP8L lossless encoder

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 7686a55..HEAD -- src/vp8l/encoder.zig src/vp8l/forward_transform.zig testdata/encode-corpus-sizes.tsv PROGRESS.MD plans/README.md`
> This plan was refreshed against `origin/main` after the decode-performance
> campaign. The encoder premise still holds; compare later in-scope changes
> against the contracts below and stop on a mismatch.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED (encoder output changes by design; round-trip exactness and size-regression gates protect it)
- **Depends on**: none (independent of the decode-perf plans)
- **Category**: perf (compression ratio)
- **Planned at**: commit `7686a55`, refreshed 2026-07-15 (originally authored
  at `29be0df`)

## Why this matters

The lossless encoder's known size gap vs `cwebp -lossless` is concentrated
in photographic content: the committed baseline records a 1.0368× corpus
median, `lossless2`/`lossless3` up to 1.59×, and photos around 1.05–1.18×
(`PROGRESS.MD`, step-7 rows). The leading working hypothesis is that choosing
one global predictor mode leaves local structure unmodeled while `cwebp` can
choose per tile. The decoder already supports per-tile predictor sub-images,
so this experiment can isolate the encoder change while preserving the
bit-exact round-trip gate. Its before/after size measurements decide whether
the hypothesis explains enough of the tail to retain the added machinery.

## Current state

All in `src/vp8l/encoder.zig` (2215 lines) unless noted.

**Global predictor choice** (`:574-608`):

```zig
/// Chooses a global predictor mode by minimizing the summed per-channel
/// absolute residual over a strided sample of the image. ...
fn choosePredictor(gpa: std.mem.Allocator, dimensions: image.Dimensions, source: []const pixel.Pixel) Error!?u8 {
    ...
    var mode: u8 = 0;
    while (mode < forward_transform.predictor_mode_count) : (mode += 1) {
        forward_transform.applyPredictor(mode, width, height, source, residual);
        const cost = residualCost(residual);
        if (cost < best_cost) { best_cost = cost; best_mode = mode; }
    }
    if (best_cost >= identity_cost) return null;
    return best_mode;
}
```

with the cost proxy `residualCost` (`:613-622`): sum of wrap-around channel
magnitudes ("a residual of 255 is distance 1 from zero").

**Plan wiring** (`:351-365`): if `choosePredictor` returns a mode, apply
`forward_transform.applyPredictor` over the working copy and
`plan.addTransform(.{ .predictor = .{ .mode = mode } })`.

**Bitstream emission** (`:1493-1499`): the predictor record writes a
*constant* block image:

```zig
.predictor => |predictor| {
    try writer.writeBits(@intFromEnum(transform.Kind.predictor), 2);
    try writeBlockTransformImage(writer, dimensions, pixel.fromChannels(255, 0, predictor.mode, 0));
},
```

`writeBlockTransformImage` (`:1523-1540`) hardcodes
`block_bits = transform.block_bits_max` (512-pixel blocks → 1×1 sub-image
for images ≤ 512²) and emits `sub_count` copies of the constant fill via
`writeConstantSubImage` (`:1545-1577`). The encoder also already has a
**real** sub-image writer: `writeLiteralSubImage` (`:1629`), used for the
delta-coded palette (`:1508-1514` — "The palette is a 1 x color_table_size
sub-image: encode its delta-coded entries as literals"), which builds
per-channel histograms and emits arbitrary pixels. The predictor sub-image
is exactly such a literal image with the mode in the **green** channel.

**Forward transform** (`src/vp8l/forward_transform.zig:126-152`):
`applyPredictor(mode, width, height, source, residual_out)` — single mode
for all pixels; per-pixel prediction from a `source` snapshot via
`predictForPosition` (`:156-182`; y==0 → left/black, x==0 → top, top-right
wraps at row end) and `predictPixel` (`:195-213`, modes 0–13). The
decoder's tiled inverse reads the mode for each pixel from the block image
at `(x >> block_bits, y >> block_bits)` — the block-image geometry is read
in `src/vp8l/transform.zig:120-138` (`readBlockTransform`:
`block_bits = readBits(3) + block_bits_min`, so the valid encode range is
`block_bits_min .. block_bits_min + 7`, i.e. 2..9).

**Verification harnesses that already exist** (do not rebuild them):

- Round-trip bit-exactness under `zig build test`:
  `src/testing/encode_corpus.zig` (synthetic matrix from
  `src/testing/synth.zig` + committed photos in `testdata/photos/`) plus
  the 43-file corpus re-encode round-trip.
- Size reporting: plain `zig build encode-report` covers the 34 committed
  synthetic/photo sources used by `testdata/encode-corpus-sizes.tsv`;
  `--with-corpus` adds 43 in-tree WebPs for a 77-source local oracle report.
- External size oracle (local only, not CI):
  `tools/webp-oracle.sh compare-encode-corpus REPORT.tsv` pairs sizes
  against `cwebp -lossless`.

Repo conventions: assertions/bounded loops/explicit widths; keep the
encoder's existing structure (this file already flags itself as large — do
NOT let this plan add a second concern; if your diff to `encoder.zig`
exceeds ~300 lines, put the tile-selection logic in the existing
`forward_transform.zig` or report). `AGENTS.MD`: never copy libwebp code —
reimplement from the spec; libwebp may only inform *what* to test.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt, compile, tests, and encode round-trips) |
| Committed-baseline report | `zig build encode-report -- /tmp/plan025-base.tsv` | TSV, 34 sources, 0 round-trip mismatches |
| Full local oracle report | `zig build encode-report -- --with-corpus /tmp/plan025-full.tsv` | TSV, 77 sources, 0 round-trip mismatches |
| Size oracle (optional, local) | `tools/webp-oracle.sh compare-encode-corpus /tmp/plan025-full.tsv` | per-file ratios vs `cwebp -lossless` |
| Decode validity (optional, local) | `dwebp <file> -o /dev/null` | exit 0 |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/vp8l/encoder.zig`
- `src/vp8l/forward_transform.zig`
- `testdata/encode-corpus-sizes.tsv` (regenerate — sizes change by design)
- `PROGRESS.MD` (dated result row + entry)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `src/vp8l/decoder.zig`, `src/vp8l/inverse_transform.zig`,
  `src/vp8l/transform.zig` — decode side already handles tiled predictors;
  it is the oracle, not a target.
- `src/alpha.zig` — the ALPH encoder reuses plane encoding; it inherits any
  benefit through the shared path automatically. Do not special-case it.
- The color transform's constant block image (`:1501-1504`) — per-tile
  *color* transform is a separate, later decision.
- `EncoderOptions` — no new public knobs in this plan; tile bits are an
  internal constant.

## Git workflow

- Branch: `vp8l-per-tile-predictor`
- Commit per step; message style: imperative summary line, e.g.
  `Select VP8L predictor modes per 16x16 tile`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Record the size baseline

Generate both baselines:

1. `zig build encode-report -- /tmp/plan025-before-base.tsv` — 34 committed
   synthetic/photo sources, 0 mismatches.
2. `zig build encode-report -- --with-corpus /tmp/plan025-before-full.tsv` —
   77 sources, 0 mismatches. If `cwebp` is available, run
   `tools/webp-oracle.sh compare-encode-corpus /tmp/plan025-before-full.tsv`;
   `lossless2`/`lossless3` should read about 1.59×.

**Verify**: both reports exist and every mismatch field is `0`.

### Step 2: Tiled forward transform

In `src/vp8l/forward_transform.zig`, add:

```zig
/// Applies a per-tile predictor transform forward: the mode for pixel (x, y)
/// is `modes[(y >> tile_bits) * tiles_wide + (x >> tile_bits)]`. Inverse of
/// the decoder's tiled predictor application. Neighbors always read from the
/// `source` snapshot (identical to `applyPredictor`'s contract).
pub fn applyPredictorTiled(
    modes: []const u8,
    tile_bits: u4,
    width: usize,
    height: usize,
    source: []const pixel.Pixel,
    residual_out: []pixel.Pixel,
) void
```

Structure it as the existing `applyPredictor` (`:126-152`) with the mode
lookup swapped in; assert `modes.len == tiles_wide * tiles_high` and every
`mode < predictor_mode_count`. Keep `applyPredictor` (other callers and the
global fallback still use it). The boundary rules (`predictForPosition`)
are position-based, not tile-based — reuse the function unchanged.

Also add the small helper the encoder will share:
`pub fn tileCount(extent: u32, tile_bits: u4) u32` (ceil-div by
`1 << tile_bits`).

**Verify**: `zig build test` → exit 0 (existing forward/inverse round-trip
tests still pass; new tests come in Step 5).

### Step 3: Per-tile mode selection in the encoder

In `src/vp8l/encoder.zig`:

1. Add a module constant `const predictor_tile_bits: u4 = 4;` (16×16 tiles —
   the compression/side-information sweet spot cwebp defaults to; valid
   range is 2..9 per `transform.zig:124`). Add a comptime assert that it
   lies in `[transform.block_bits_min, transform.block_bits_max]`.
2. Add `choosePredictorTiled(gpa, dimensions, source) Error!?TiledPredictor`
   where `TiledPredictor = struct { modes: []u8, tile_bits: u4 }`:
   - For each tile, evaluate all 14 modes **on that tile's pixels only**,
     scoring with the existing `channelMagnitude` proxy (extract the
     per-pixel scoring from `residualCost` so tiles don't allocate; predict
     from the `source` snapshot exactly as `applyPredictorTiled` will).
   - Track total tiled cost; compare against the best *global* cost (the
     existing `choosePredictor` loop already computes it — refactor so both
     share one scan, or call both and compare) **plus** a side-information
     estimate for the mode image: a reasonable, honest proxy is
     `tile_count` bytes (mode literals are ≤ 14 symbols; do not overfit —
     the real arbiter is Step 4's measured sizes). Selection rule:
     - tiled cost + side estimate < min(global cost, identity cost) → tiled;
     - else fall back to the existing global/None decision unchanged.
   - Single-tile images (both extents ≤ 16) must take the global path
     (byte-identical output to today for those inputs — cheap invariant to
     test).
3. Wire into `Plan.build` (`:351-365`): tiled result → allocate residual,
   `forward_transform.applyPredictorTiled(...)`, store
   `.{ .predictor = .{ .tiled = ... } }`. Extend `PredictorRecord`
   (`:280-283` region) to a tagged form: `.global: u8` / `.tiled:
   TiledPredictor`; free `modes` in `Plan.deinit` (`:391-400`).
4. Emission (`:1493-1499`): global arm unchanged (still
   `writeBlockTransformImage`). Tiled arm: write the 2-bit kind, then
   `writer.writeBits(tile_bits - transform.block_bits_min, 3)`, then build
   the mode sub-image (`tiles_wide × tiles_high` pixels of
   `pixel.fromChannels(255, 0, mode, 0)`) and emit via the existing
   `writeLiteralSubImage` (`:1629`) — mirroring exactly how the decoder
   reads it back (`transform.zig:120-138` + the inverse transform's per-tile
   lookup). The sub-image buffer is a short-lived allocation charged like
   the palette path's.

**Verify**: `zig build test` → exit 0. This is the big one: the encode
corpus round-trip (synthetic + photos + 43 corpus files) proves every tiled
encode decodes bit-exactly through this library's own decoder.

### Step 4: Measure sizes, regenerate the committed baseline

1. Run `zig build encode-report -- /tmp/plan025-after-base.tsv`; compare its
   34 rows against `/tmp/plan025-before-base.tsv`. Aggregate must not grow.
2. Run `zig build encode-report -- --with-corpus
   /tmp/plan025-after-full.tsv`; compare all 77 rows against
   `/tmp/plan025-before-full.tsv`. Photographic sources should shrink. If any
   file grows more than 2%, investigate the selection rule before proceeding
   (the side-information estimate may be too optimistic for that class).
3. If `cwebp` is available: `tools/webp-oracle.sh compare-encode-corpus
   /tmp/plan025-after-full.tsv`. Success target: `lossless2`/`lossless3`
   materially below 1.59× and corpus median no worse than 1.0368×. Also
   spot-check three encoded files with `dwebp -o /dev/null`.
4. Regenerate the committed 34-source baseline with
   `zig build encode-report -- testdata/encode-corpus-sizes.tsv`. Do not
   commit the 77-source `--with-corpus` report.
5. Append the dated `PROGRESS.MD` row + entry: per-file median/aggregate
   ratios, the `lossless2`/`lossless3` before/after, and the honest note
   that encode *speed* changed too (report the `zig build bench` lossless
   encode row delta; the 14-modes-per-tile scan costs time — record it,
   whatever it is).

**Verify**: the four bullets above, in order; `zig fmt .`;
`zig build ci` → exit 0.

## Test plan

New tests (place next to the code they pin, matching existing test style):

- `src/vp8l/forward_transform.zig`: `applyPredictorTiled` round-trips
  through the decoder's inverse on a hand-built 40×24 image (≥ 2×2 tiles at
  tile_bits=4) with per-tile modes chosen adversarially (different mode
  per tile, including modes 11–13); model after the existing
  "forward ... inverts decoder ..." tests (`:288+`).
- `src/vp8l/encoder.zig`:
  1. An image built from two content regions favoring different predictors
     (e.g. horizontal gradient left half → mode 1, vertical gradient right
     half → mode 2) encodes with a tiled predictor record, round-trips
     bit-exactly via `decoder.decodeARGBAlloc`, and is **smaller** than the
     same image encoded with the global path (force-compare by size).
  2. A ≤16×16 image produces output byte-identical to the pre-change
     encoder (global path preserved — regression-pin with a committed
     expected size or by structural assertion on the transform record).
  3. Allocation-failure injection: the tiled path survives
     `checkAllAllocationFailures` (mirror how the existing encode tests do
     it — see the step-9 entries' pattern).
- The existing corpus round-trip tests are the bulk oracle; they need no
  changes.

Verification: `zig build test` → all pass including the new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0; `zig build wasm-check` exits 0
- [ ] Plain `zig build encode-report`: 34 sources, 0 round-trip mismatches
- [ ] `zig build encode-report -- --with-corpus /tmp/plan025-after-full.tsv`:
      77 sources, 0 round-trip mismatches
- [ ] Aggregate corpus size ≤ before; no single file > +2% without a
      recorded justification
- [ ] If cwebp present: `lossless2`/`lossless3` ratio < 1.40× (from 1.59×)
      and median ≤ 1.0368× — recorded in `PROGRESS.MD`; if absent, recorded
      as pending-oracle in the plan status
- [ ] `testdata/encode-corpus-sizes.tsv` regenerated and committed
- [ ] New tiled round-trip + size + allocation-failure tests exist and pass
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any round-trip mismatch appears in `zig build test` or `encode-report` —
  the forward/inverse tile geometry disagrees; fix the geometry, never the
  expectation.
- Aggregate corpus size *grows*: the selection rule is miscalibrated;
  report the per-file deltas rather than shipping a size regression.
- The diff to `src/vp8l/encoder.zig` balloons past ~300 lines — the 2026-07-04
  audit already flagged this file's size as a maintainer judgment call;
  report with a proposed split instead of compounding it.
- `writeLiteralSubImage` turns out to reject the mode-image alphabet or
  dimensions (it was built for 1×N palettes) — report its actual contract
  rather than force-fitting.

## Maintenance notes

- Follow-ups deliberately deferred: entropy-based tile scoring (histogram
  cost instead of |residual| proxy), per-tile *color* transform (same
  emission machinery once this lands), and exposing effort/tile-bits via
  `EncoderOptions.method` (plan 016's measurement should inform whether
  m5/6 wants a finer tile grid).
- Reviewer should scrutinize: tile-boundary prediction (neighbors legally
  cross tile boundaries — the mode changes, the neighbor pixels do not),
  the single-tile fallback invariant, and the side-information estimate
  (must be a conservative, commented heuristic, not a magic number).
