# Plan 011: Make VP8L palette detection O(pixels) instead of O(pixels × 256)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 5d6ed3c..HEAD -- src/vp8l/encoder.zig`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (output must be byte-identical; the committed corpus report proves it)
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `5d6ed3c`, 2026-07-04

## Why this matters

Every lossless encode starts by probing for a palette: `tryBuildPalette` walks
all source pixels and, for each one, linearly scans the palette collected so
far (up to 256 entries). High-color photos bail out early (as soon as the
257th distinct color appears), but low/medium-color images — icons, UI
screenshots, the exact images the palette path exists for — pay up to ~256
comparisons per pixel across the whole canvas. A 1000×1000 image with ~200
distinct colors performs on the order of 2×10⁸ pixel comparisons before
compression even begins. Replacing the linear scan with a fixed-size
open-addressing hash probe makes detection O(pixels) with zero allocation and
**identical output** (the palette set is the same; its order is normalized by
the existing sort).

## Current state

- `src/vp8l/encoder.zig:413-441` — `tryBuildPalette`, the function to change.
  The hot loop:

  ```zig
  // src/vp8l/encoder.zig:418-429
  var palette_buffer: [palette_size_max]pixel.Pixel = undefined;
  var palette_count: usize = 0;

  // Collect distinct colors, bailing out past the palette limit.
  outer: for (source) |value| {
      for (palette_buffer[0..palette_count]) |existing| {
          if (existing == value) continue :outer;
      }
      if (palette_count == palette_size_max) return null;
      palette_buffer[palette_count] = value;
      palette_count += 1;
  }
  ```

  Afterward (`:431-441`): `palette_count < 2` returns null; the palette is
  sorted (`std.mem.sort`) — **the sort is what fixes the output order, so
  insertion order does not affect the encoded bytes**; then it is heap-copied.
- `palette_size_max` is `transform.color_table_size_max`
  (`src/vp8l/encoder.zig:85`) — value 256.
- `pixel.Pixel` is `u32` (packed ARGB; `src/vp8l/pixel.zig:6`). Note `0` (fully
  transparent black) is a **legitimate pixel value** — a hash table of `u32`
  cannot use 0 as an empty-slot sentinel without an occupancy side-structure.
- The repo already has a multiplicative pixel hash you should reuse the
  constant from: `src/vp8l/color_cache.zig:10,49-55`:

  ```zig
  pub const multiplier: u32 = 0x1e35a7bd;
  // hash: (multiplier *% value) >> (32 - bits)
  ```
- Caller: `Plan.build` (`src/vp8l/encoder.zig:334`) — the palette probe is the
  first thing every lossless encode does. Its contract: return `null` when
  >256 distinct colors or <2 colors; otherwise a `BuiltPalette`.
- Existing tests covering this path (`src/vp8l/encoder.zig`): `"encodes and
  round-trips a low-color palette image"` (:1907), `"...two-color (1-bit
  packed) palette image"` (:1922), `"...cache-friendly repeated-palette
  image"` (:2040).
- Byte-identical-output oracle: `testdata/encode-corpus-sizes.tsv` is the
  committed lossless-encode size report over the whole encode corpus.
  `zig build encode-report -- OUTPUT.tsv` regenerates it (the tool runs from
  the repo root; see `tools/zig-webp-encode-report.zig:14-15`). If the encoder
  output is unchanged, the regenerated TSV is identical to the committed one.
- Repo conventions: Zig 0.16.0; TigerStyle-leaning — bounded loops, explicit
  asserts on invariants, no allocation where a fixed buffer suffices; `zig
  fmt .` before handing back.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tests | `zig build test` | exit 0 |
| Encode report | `zig build encode-report -- /tmp/claude-encode-report.tsv` | exit 0, writes the TSV |
| Report diff | `diff /tmp/claude-encode-report.tsv testdata/encode-corpus-sizes.tsv` | no output (identical) |
| Format | `zig fmt .` / `zig fmt --check .` | exit 0 |
| Tool compile | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/vp8l/encoder.zig` — the `tryBuildPalette` collection loop and any new
  private helper + tests beside it

**Out of scope** (do NOT touch, even though they look related):
- `src/vp8l/color_cache.zig` — you may *reference* `color_cache.multiplier`
  via import (check how `encoder.zig` already imports sibling modules), but do
  not modify it.
- `src/vp8l/transform.zig` — `color_table_size_max` stays as is.
- The rest of `tryBuildPalette` (the `< 2` check, the sort, the delta-table
  building) and everything downstream — the change is strictly the
  distinct-color collection.
- `testdata/encode-corpus-sizes.tsv` — must NOT be regenerated/committed; it
  is the oracle proving output is unchanged.

## Git workflow

- Branch: `claude/vp8l-palette-hash-probe` (repo convention: `claude/` prefix).
- Commit style: short imperative summary, e.g. `Probe palette colors through a fixed hash set`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the linear scan with a fixed open-addressing probe

Design (allocation-free, stack-only, bounded):

- A 1024-slot table (`4 × palette_size_max`, load factor ≤ 0.25 at the 256
  bail-out point) of `u16` indices into `palette_buffer`, plus a sentinel for
  "empty". Storing **indices** (with e.g. `std.math.maxInt(u16)` as empty)
  sidesteps the pixel-value-0 sentinel problem cleanly and keeps the table
  4× smaller than storing pixels.
- Hash: `(color_cache.multiplier *% value) >> (32 - 10)` for a 10-bit table
  index (same shape as `color_cache.hash`).
- Linear probing with wraparound (`index = (index + 1) & (table_len - 1)`);
  the probe loop is bounded by table_len — assert the table can never be full
  (256 entries max in a 1024-slot table).
- Loop body per pixel: probe; if an occupied slot's palette entry equals the
  pixel, continue the outer loop; if empty slot found, bail to `return null`
  when `palette_count == palette_size_max`, else insert (write palette_buffer,
  store the index in the slot).

Behavioral invariants that must hold (they are what keeps output identical):
- The *set* of collected colors is unchanged (dedup is dedup).
- The >256-colors bail-out still triggers on the 257th **distinct** color.
- `palette_buffer` still receives colors in first-seen order (irrelevant to
  output because of the sort, but keeps the diff reviewable).
- Everything after the collection loop is untouched.

**Verify**: `zig build test` → exit 0, in particular the three palette
round-trip tests listed above.

### Step 2: Add a targeted unit test for the probe's edge cases

Beside the existing palette tests, add one test covering the cases the old
linear scan handled implicitly:
- an image whose colors include pixel value `0x00000000` (transparent black)
  AND `0xFF000000` (opaque black) — both must be collected as distinct;
- an image with exactly 256 distinct colors (palette succeeds, count == 256);
- an image with 257 distinct colors (returns null).
  Generating N distinct u32s: e.g. `fromChannels(255, i % 256, i / 256, 0)`
  over an incrementing i — deterministic, no PRNG needed.
  Route through the public `encodeAlloc` + decode round-trip OR call
  `tryBuildPalette` directly (it's file-private; the test lives in the same
  file, so direct calls work — match how the existing palette tests exercise
  things and keep the style consistent).

**Verify**: `zig build test` → exit 0, new test passes.

### Step 3: Prove byte-identical output over the corpus

```
zig build encode-report -- /tmp/claude-encode-report.tsv
diff /tmp/claude-encode-report.tsv testdata/encode-corpus-sizes.tsv
```

The diff must be empty. (The TSV records per-source encoded size and
round-trip status; identical sizes across the whole encode corpus plus
bit-exact round-trips is the repo's standard evidence that encoder output is
unchanged.)

**Verify**: `diff` → no output, exit 0.

### Step 4: Format and final gates

**Verify**: `zig fmt --check .` → exit 0; `zig build test` → exit 0;
`zig build check` → exit 0.

## Test plan

- New test (Step 2) in `src/vp8l/encoder.zig`: zero-pixel-value vs opaque
  black distinctness; exactly-256 succeeds; 257 returns null. Model after
  `"encodes and round-trips a low-color palette image"` (:1907).
- Existing regression net: the three palette round-trip tests, the full
  encode-corpus round-trip suite under `zig build test`, and the byte-identical
  corpus report diff (Step 3).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] The inner `for (palette_buffer[0..palette_count])` scan is gone from
      `tryBuildPalette` (`grep -A3 "outer: for" src/vp8l/encoder.zig` shows a
      probe, not a linear rescan)
- [ ] `zig build test` exits 0 (all existing + new tests)
- [ ] `zig build encode-report -- /tmp/claude-encode-report.tsv && diff /tmp/claude-encode-report.tsv testdata/encode-corpus-sizes.tsv` → empty diff
- [ ] `zig fmt --check .` exits 0; `zig build check` exits 0
- [ ] `git status` shows only `src/vp8l/encoder.zig` modified (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `tryBuildPalette` changed since `5d6ed3c`.
- Step 3's diff is non-empty (output changed — the change is NOT
  behavior-preserving; report the differing rows, revert, do not "fix" by
  regenerating the TSV).
- Any existing palette/round-trip test fails and the cause isn't an obvious
  bug in your probe.
- You find yourself wanting to change the bail-out semantics, the sort, or
  `palette_size_max` — out of scope.

## Maintenance notes

- The probe table size (1024) is coupled to `palette_size_max` (256) by the
  load-factor argument; if `color_table_size_max` ever changes, the table and
  its never-full assert must scale with it — encode that relationship as a
  comptime assert (`table_len >= 4 * palette_size_max`).
- Reviewers should scrutinize: the empty-slot sentinel logic (u16 index
  sentinel, NOT pixel value 0), and the probe-loop bound.
- Measured payoff was reasoned statically, not benchmarked; if the maintainer
  wants a number, `zig build -Doptimize=ReleaseFast bench` before/after on the
  lossless-encode rows gives it. Not a gate.
