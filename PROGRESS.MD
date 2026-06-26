# PROGRESS.MD

Status log for the roadmap in `PLAN.MD`. `PLAN.MD` stays forward-looking
(scope, ordering, acceptance gates); completed scope, dated oracle results,
and the current position are recorded here.

Last updated: 2026-06-23

## Current Position

Steps 0 through 6 are complete for their decode scopes. The VP8 lossy decoder
runs end-to-end through the public `decodeStatic`: full key-frame decode
(header through the in-loop deblocking filter, byte-exact against plain
`dwebp -yuv`), YUV-to-RGB with fancy chroma upsampling, and composition of the
decoded ALPH plane over lossy color — all byte-exact against `dwebp -pam` for
every lossy file in the corpus, including lossy+alpha (see Oracle Results).
Animated WebP now decodes through `decodeAnimation` (all composited frames) and
the streaming `AnimationDecoder`, byte-exact against libwebp's `anim_dump` on a
generated animation corpus. Step 7 (VP8L lossless encoder) is now in progress:
its first slice — valid VP8L still output from ARGB literals — is delivered and
round-trips bit-exactly (see "Step 7 — VP8L Lossless Encoder (slice 1)" and the
2026-06-16 oracle row). Its second slice — LZ77 back-references plus the
subtract-green, color, predictor, and palette/color-indexing transforms (each
decision-gated) — is also delivered and round-trips bit-exactly (see "Step 7 —
VP8L Lossless Encoder (slice 2)" and the second 2026-06-16 oracle row). Its third
slice — an optional color cache and an optional entropy image / multiple Huffman
groups (meta-prefix), each chosen by measuring the real encoded size — is now
delivered, still round-trips bit-exactly, and lowers the median size-vs-`cwebp`
ratio to 1.04x (see "Step 7 — VP8L Lossless Encoder (slice 3)" and the third
2026-06-16 oracle row).

Ahead of the VP8 lossy encoder (step 8), an encode **test corpus** now backs the
encoder side, since step 8's gates are measured on source images: a generated
synthetic source matrix (macroblock-edge dimensions × content × alpha), four
committed CC0 photographs under `testdata/photos/`, and the in-tree lossless
WebP files. Every synthetic source and photo round-trips bit-exactly through
`encodeStaticLossless` and back under `zig build test`, and a committed oracle
mode measures lossless size against `cwebp -lossless` (median 1.04x; see
"Encode Test Corpus (pre-step-8 harness)" and the 2026-06-18 oracle row).

The VP8 lossy encoder (step 8) is now underway, with its first slice — step 8a,
a valid-bitstream baseline — delivered. `src/vp8/encoder.zig` emits a `VP8 ` key
frame with a deliberately fixed all-DC mode decision (16x16 DC luma, 8x8 DC
chroma, loop filter off, default coefficient probabilities, one token
partition), built on a forward RGB→YUV420 converter (`color.zig`), forward
DCT/WHT (`vp8/forward_transform.zig`), forward quantization (`vp8/quant.zig`),
and coefficient token coding (`vp8/tokens.zig`). The encoder reconstructs each
macroblock through the same inverse routines the decoder uses, so a conforming
decoder reproduces its reconstruction bit-for-bit at the YUV layer — the step 8a
gate, enforced under `zig build test` across the synthetic matrix (including the
transparent-RGB case) and the photos. Locally `dwebp` decodes all 135 encoded
still files without error (see "Step 8 — VP8 Lossy Encoder (slice 8a)" and the
2026-06-19 oracle row). Quality (real mode decision and the PSNR gate) is step
8b; alpha and presets are step 8c.

Step 8b (quality) is now delivered through slice 8b-3b: per-macroblock intra mode
decision (8b-1), a token bit-cost rate model and B_PRED 4x4 luma intra (8b-2),
macroblock skip coding plus quantizer-derived loop-filter selection (8b-3a), and
adaptive per-segment quantization (8b-3b). Slice 8b-3b carries the step-8b
acceptance gate, and it holds: at matched output size on the photo corpus the
mean BT.601 luma PSNR is 40.79 dB versus 40.70 dB for `cwebp -q 75 -m 4` (+0.08
dB, inside the 1.0 dB target with room to spare; see the second 2026-06-21 oracle
row).

Step 8c (controls and parity features) is now also delivered, **completing the
VP8 lossy encoder**. It landed as an options scaffold (inert `EncoderOptions`
knobs + an `EncodeConfig` struct, so the slices could be built in parallel
without colliding on the public surface) followed by four slices: **8c-1** a
`method` (0..6) effort knob that scales the rate-distortion search (method 4, the
default, is byte-identical to the 8b encoder; methods 5–6 currently clamp to 4),
**8c-2** lossy+alpha via the `ALPH` chunk (lossless alpha, byte-exact round-trip),
**8c-3** target-size and target-PSNR modes (a bounded quantizer search), and
**8c-4** sharp (iterative) RGB→YUV chroma. Every slice keeps its default path
byte-identical to 8b and holds `dwebp` validity (0/135 invalid); the step-8c gate
holds (the method-preset matrix encodes the corpus with no validity regression,
and target-size lands within 5% — 0.32–2.83% on the photos). See the five
2026-06-22 oracle rows. With step 8c done the lossy encoder is feature-complete;
the remaining lossy work is performance (step 10) and release hardening
(step 11).

Step 9 (animation and metadata encode) is now **feature-complete** (9a container
mux, 9b pixel-buffer encode, 9c frame optimization, 9d still metadata); the only
open step-9 item is the manual ≥2-browser render confirmation, which is set up
(two minimized animations under `testdata/animation/`) but intentionally not in CI. Its first slice — 9a, the
animation **container mux** — is delivered: `mux.encodeAnimation` (public
`encodeAnimation`) assembles already-encoded frame bitstreams into a valid
animated WebP (`VP8X`+`ANIM`+`ANMF`, optional per-frame `ALPH`, optional
`ICCP`/`EXIF`/`XMP `), the animated analogue of `encodeStatic`. It validates every
frame against the canvas and the container rules and round-trips through this
library's demux; `webpinfo`/`webpmux`/`anim_dump` accept output built from real
encoded frames (see "Step 9 — Animation and Metadata Encode (slice 9a)" and the
first 2026-06-23 oracle row). Its second slice — 9b, the pixel-level
`encodeAnimationFromBuffers` — is now also delivered: `src/animation_encode.zig`
encodes a caller-supplied ordered list of pixel-buffer frames (each a full-canvas
or sub-rect `image.Buffer` with its offset, duration, blend/dispose, and lossy or
lossless codec), reusing the still VP8/VP8L/alpha encode machinery, and muxes them
via 9a. It carries the step-9 pixel-path gate, which holds: `anim_dump` of four
generated animations (lossless full-canvas, lossless sub-rect with
background-dispose, lossy full-canvas, mixed lossless + lossy-alpha) matches this
library's own composition byte-for-byte across every frame, and all four are
accepted by `webpinfo` (see "Step 9 — Animation and Metadata Encode (slice 9b)"
and the second 2026-06-23 oracle row).

Slice 9d — **metadata-from-pixels for still encode** — is also delivered.
`EncoderOptions` gained a `metadata: metadata.RawPayloads = .{}` field, threaded
into the `mux.encodeStatic` calls in `encodeStaticLossless`/`encodeStaticLossy`,
so the public still encoders (`encodeLossless`/`encodeLossy`) can now attach raw
`ICCP`/`EXIF`/`XMP ` (the mux already wrote them; this closes the from-pixels
API gap). Present metadata forces the extended (`VP8X`) container and the chunks
emit in spec-canonical order — `VP8X` → `ICCP` → (`ALPH`) → `VP8(L)` → `EXIF` →
`XMP ` — round-tripping byte-exactly through `demux`; with empty metadata (the
default) the output is byte-identical to the pre-9d path (asserted by test
against a direct mux call). Metadata coexists with a lossy `ALPH` chunk and rides
through the target-size/PSNR searches unchanged. Chunk-order honesty: the
from-pixels path emits canonical order (there is no caller-specified order to
preserve there); the `mux.encodeStaticFromDemux` remux path is what preserves
unknown-chunk order. Animation-level metadata stays owned by 9a's
`AnimationImage.metadata` (and 9b's `AnimationEncodeOptions.metadata`), not
duplicated here (see "Step 9 — Animation and Metadata Encode (slice 9d)" and the
second 2026-06-23 oracle row).

Slice 9c — **automatic frame optimization** — closes the step-9 pixel path. New
`animation_optimize.encodeAnimationMinimized` (public `encodeAnimationMinimized`,
in `src/animation_optimize.zig`) takes full-canvas frames + timing + per-frame
codec and automatically derives a minimal `ANMF` layout: sub-rectangle detection
(minimal bounding box of the changed region), inter-frame differencing with a
blend-vs-replace strategy (lossless: equal-to-prev pixels made transparent under
`alpha_blend` when that provably reconstructs exactly, else a verbatim `replace`;
lossy: always verbatim `replace`), a one-frame-lookahead dispose-to-background
choice, and keyframe insertion (frame 0, any full-canvas change, and a bounded
interval). It reuses the 9b per-frame encoder and the 9a mux. The correctness key:
the optimizer tracks the decoder's *reconstructed* canvas — it re-decodes each
frame it emits and composites with the exact `animation_decode` rules
(transparent-RGB zeroing, source-over non-premultiplied blend, the previous
background-disposed-rect skip) — so lossy reconstruction error never accumulates
and the 9b parity gate is preserved.

**Slice 9c-2 extended the optimizer to lossy frames.** 9c diffed against the
reconstructed previous canvas with an exact compare, so VP8 noise (which differs
almost everywhere) inflated every lossy frame's diff rect to the full canvas and
lossy animations got 0% inter-frame shrink. 9c-2 detects the change rect against a
*source-quality carryover* canvas (the original input pixels carried frame to
frame, mirroring libwebp's `canvas_carryover`) using a per-channel content-change
tolerance `T` (`AnimationMinimizeOptions.tolerance`, defaulting to a
quality-derived value — libwebp's `QualityToMaxDiff`, ≈5 at q=75): a pixel counts
as unchanged when its alpha matches and every RGB channel differs by at most `T`
(alpha-weighted). Pixels within tolerance are inherited from the previous decoded
frame; the keyframe interval bounds drift. Lossless frames use `T = 0` and a
carryover that equals the reconstruction bit-for-bit, so the byte-exact lossless
gate is **unchanged**.

CI gates hold: all-lossless minimized animations decode byte-for-byte back to
their input canvases (a moving sub-region that shrinks below the canvas, a
degenerate identical frame, a full-canvas change that forces a keyframe, a
transparency-reveal that falls back to replace, a blend+dispose multi-frame
sequence, and a forced-interval keyframe run); a lossy moving-region animation
shrinks ≥1 `ANMF` rect and decodes valid; and the optimized lossy mean luma PSNR
stays within 0.5 dB of the naive full-canvas encode. Local `anim_dump` parity
holds for both a lossless and a lossy minimized sample, and `webpinfo` is clean.
Reported compression: lossless ≈8% smaller than the naive full-canvas encode on
the moving-sub-region sample; **lossy ≈48% smaller** on a 96×64 8-frame moving-
square sample (2680→1390 B), at PSNR **+0.14 dB** vs naive (not a loss — the
inherited gradient is quantized once at the keyframe instead of re-noised every
frame). See "Step 9 — Animation and Metadata Encode (slice 9c)" and the third and
the 9c-2 2026-06-23 oracle rows. The ≥2-browser render check is set up via two
`testdata/animation/` animations and remains the only open (manual, non-CI) step-9 item.

**Step 10 (performance work) is delivered.** It comprises the benchmark harness
+ scalar baseline (slice 10a) and one vectorized hot loop — the YUV→RGB color
conversion (slice 10b, ≈1.11× lossy decode, byte-exact). The honest summary:
scalar lossy decode is within the ≤3× single-threaded `dwebp` target (≈2.3×
after the SIMD win); lossless decode is the part outside it and is entropy-bound
(a serial, already-table-optimized Huffman/LZ77 core), so the gap is a
SIMD/maturity difference vs `libwebp` rather than a missing scalar optimization,
and the ≤1.5× "after vector work" target is revised accordingly (realistic for
the conversion-dominated lossy path with more SIMD, not for serial-entropy
lossless; not a gate). Measured-and-rejected as code-layout noise (thermal-
controlled A/B): scalar micro-restructuring of the inverse transforms, an IDCT
DC-only fast path, and SIMD subtract-green — all small/serial relative to the
bottleneck. Future levers (deferred): SIMD loop filter (the next-largest lossy
lever), SIMD/restructured entropy decode, row/tile threading, and
`image-webp`/pure-Go comparison runs. The harness + byte-exact corpus gate keep
all of it measurable and safe. Detail follows.

A new in-memory benchmark tool (`tools/zig-webp-bench.zig`, `zig build
bench`) times the public decode and encode entry points per asset class — codec
time only, no file I/O — reporting the median of repeated timed runs. It
establishes the scalar baseline that the optimization work measures against; an
optional `tools/webp-bench.sh` times libwebp's `dwebp`/`cwebp` over the same
files for a same-machine ratio. The
dated 2026-06-26 baseline (see "Step 10 — Performance Work (slice 10a)" and the
2026-06-26 oracle row) shows lossy decode at ≈2.0–2.5× single-threaded `dwebp`
(inside the ≤3× scalar target) but small/medium VP8L lossless decode at
≈2.8–5.6× (outside it). Timing is environment-dependent and stays a local
report, not a CI gate. Threading is **not** in scope here (it remains future
work; the targets are single-threaded).

**Slice 10b vectorizes the YUV→RGB color conversion** — the largest genuinely
data-parallel hot loop in the lossy decode path. `color.upsampleLinePair`'s
interior is a stencil over the chroma rows (no dependency on previously produced
output), so the diamond upsample *and* the BT.601 matrix vectorize cleanly; an
`@Vector` path (8 chroma columns → 16 pixels/chunk) now handles the 4-channel
formats on little-endian, with the scalar path unchanged as the reference
(boundaries, odd-width tail, 3-channel `rgb`, and big-endian). It is byte-exact
(the corpus-hash gate plus a non-circular `.rgb`-scalar vs `.rgba`-SIMD
equivalence test) and lifts aggregate lossy decode **1.11×** (763.6→690.2 ms on
the corpus; up to 1.31× on conversion-heavy files), lossless unchanged (VP8L
never calls it). See "Step 10 — Performance Work (slice 10b)" and the 2026-06-26
oracle row.

Honest scope note: scalar *micro-restructuring* of the inverse transforms (VP8L
predictor/color, the IDCT DC-only fast path) was prototyped and **rejected** —
under thermal-controlled A/B it only produced code-layout noise (≤±5%), because
those stages are not the bottleneck (VP8L decode is entropy-bound and the
Huffman path is already a fast multi-level table; lossy decode work is spread
across boolean decode, reconstruction, the loop filter, and conversion). The
SIMD conversion win above is real because it targets a loop that is both hot and
parallel. The remaining lossless-decode gap vs `dwebp` is the serial entropy
decoder, where libwebp's lead is SIMD/maturity that scalar Zig cannot match
cleanly; that is documented as future work, not forced.

## Cross-Cutting Practices

CI runs on every pull request and push to main
(`.github/workflows/ci.yml`): `zig fmt --check .` and `zig build test` on
Zig 0.16.0. The test suite includes a hash-based corpus regression
(`src/testing/corpus.zig`): decoded RGBA planes of all 131 still images (43
lossless and 88 lossy, the latter with composed ALPH alpha) and decoded alpha
planes of all 18 ALPH-bearing files (149 rows) are compared against committed
SHA-256 hashes in `testdata/corpus-hashes.tsv`, so CI needs no `dwebp`. The hashes lock the decoded planes that matched
`dwebp` byte-for-byte in the dated oracle runs below; regenerate with
`zig build corpus-hashes` only after a fresh corpus-wide oracle run. A parallel
manifest `testdata/animation/hashes.tsv` locks the composited frames of the 8
committed animations (29 frames total) against `anim_dump`; regenerate with
`zig build anim-hashes` after a fresh `compare-anim` run.

The encoder has a parallel corpus harness. `src/testing/encode_corpus.zig`
round-trips a defined set of *source* images through the lossless encoder and
back through the decoder, asserting bit-exact recovery under `zig build test`:
the synthetic matrix from `src/testing/synth.zig` (edge dimensions, content,
and alpha cases, generated at test time) and the committed CC0 photographs in
`testdata/photos/` (decoded to pristine pixels). No hashes are needed — for
lossless the source pixels are the oracle. `src/testing/metrics.zig` adds
MSE/PSNR (overall and BT.601 luma) for the lossy PSNR gate to come. The
`zig build encode-report` tool prints encoded size, bits-per-pixel, and the
round-trip verdict per source (committed baseline
`testdata/encode-corpus-sizes.tsv`), and `tools/webp-oracle.sh
compare-encode-corpus REPORT.tsv` pairs those sizes against `cwebp -lossless`.

Fuzz smoke targets are in place for every public decode entry point: strict
demux (`src/demux.zig`), VP8L still-image decode (`src/vp8l/decoder.zig`),
alpha plane decode (`src/alpha.zig`), VP8 key-frame header parsing
(`src/vp8/frame_header.zig`), VP8 macroblock prediction record parsing
(`src/vp8/modes.zig`), the public static decode composition
(`src/decode.zig`), and animated decode composition
(`src/animation_decode.zig`). Each target uses `std.testing.fuzz` with a valid corpus
seed (framed via `src/testing/fuzz.zig` so seeds reach the parser
byte-for-byte) and runs under plain `zig build test` as a corpus +
empty-input smoke pass with leak detection. Coverage-guided runs via
`zig build test --fuzz` are currently blocked by an upstream Zig 0.16.0
bug: the bundled `lib/compiler/test_runner.zig` fails to compile under fuzz
instrumentation (`*builtin.StackTrace` vs `*debug.StackTrace` mismatch).
Revisit when the toolchain updates.

## Recently Completed

### Step 10 — Performance Work (slice 10b: SIMD color conversion)

Slice 10b is the first optimization slice: an `@Vector` implementation of the
YUV→RGB **fancy upsampling + BT.601 conversion** (`src/color.zig`), the largest
data-parallel hot loop in lossy decode. The key enabler: `upsampleLinePair`'s
interior output pair at columns `(2x-1, 2x)` is a pure stencil over chroma
columns `(x-1, x)` and never reads previously produced output, so it has no
serial dependency. The interior was first made stateless (`upsampleInteriorPair`
reads `chroma[x-1]` directly instead of carrying it), then a SIMD path
(`upsampleInteriorSimd`/`upsampleChunk`, 8 chroma columns → 16 output pixels per
chunk) computes the diamond filter and the conversion in `@Vector(16, i32)`
lanes and stores a packed-`u32`-per-pixel vector. It runs for the 4-channel
formats on little-endian; the scalar path (unchanged, the reference) handles the
first/last/odd-width-tail pixels, `rgb`, and big-endian.

Bit-exactness: the BT.601 lanes use the same fixed-point `mulHi` (`>>8`) and the
identity `clip8(v) == clamp(v >> 6, 0, 255)` (since `yuv_fix2 == 6`), and the
diamond keeps `u`/`v` in separate i32 lanes (the scalar packed-`u32` trick was
only a scalar-ALU convenience). Verified by the committed corpus-hash gate (88
lossy stills decode byte-for-byte vs the libwebp-correct hashes, most at
SIMD-triggering widths) plus a new non-circular unit test: a wide image's `.rgb`
output (forced scalar — SIMD is 4-channel only) equals the `.rgba` SIMD path's
R/G/B, catching any diamond/interleave/store-layout bug independent of the
formula.

Measured (ReleaseFast, i5-13450HX, single thread, thermal-controlled interleaved
A/B vs `main`): **aggregate lossy decode 1.11×** (763.6→690.2 ms over the lossy
corpus), up to **1.31×** on conversion-heavy files (`vp80-00-comprehensive-008`)
and **1.2×** on lossy+alpha; lossless decode unchanged (1.02×, noise — VP8L emits
ARGB directly and never calls this path). `zig build test` green; `zig fmt`
clean. See the 2026-06-26 (slice 10b) oracle row.

### Step 10 — Performance Work (slice 10a: baseline harness)

Slice 10a is the **measurement foundation** for the performance step: it adds a
benchmark harness and records the scalar baseline, with no codec changes (the
hot loops are optimized in 10b/10c). New `tools/zig-webp-bench.zig` (`zig build
bench`) times the public entry points — `decodeStatic`, `decodeAnimation`,
`encodeLossless`, `encodeLossy` — entirely **in memory** (no PAM/file writes, so
the numbers are codec time, not disk I/O). For each input it runs untimed warmup
iterations then repeated timed iterations and reports the **median** wall-clock
time (via the `std.Io` monotonic clock), with a per-measurement time budget so a
single multi-second image cannot blow up the run. It enumerates `testdata/`
into asset classes (icon / photo / large / alpha / animation for decode; the
synthetic matrix + photos for encode) and emits a TSV with throughput in
megapixels/second. Correctness is **not** re-checked here — that stays with `zig
build test` (the committed-hash corpus regression and the encoder
self-consistency gates); the harness only measures the speed of a build that
already passes them. An optional `tools/webp-bench.sh` times libwebp's
`dwebp`/`cwebp` over the same files (skipping gracefully when absent, never a
build dependency) for a same-machine ratio.

**Baseline (2026-06-26, ReleaseFast, 13th Gen Intel Core i5-13450HX, single
thread; libwebp 1.5.0):**

- *Decode* (pixel-weighted aggregate MP/s): lossy ≈39, lossless ≈28. Per class:
  large ≈40, alpha ≈34, photo ≈28, with icon/animation dominated by per-decode
  overhead rather than throughput (tiny canvases), so MP/s understates them.
- *Decode vs single-threaded `dwebp`* (our min ÷ `dwebp` min; `dwebp` also
  formats PAM output, so the ratio mildly favors us and is indicative, not
  exact): lossy `bryce` 11158×2156 **2.5×**, `lossy_extreme` 800×534 **2.0×**;
  lossless `lossless_big_random_alpha` 2048² **1.8×**, `lossless_color_transform`
  512² **2.8×**, `photo_foliage` 512×342 (lossless) **5.6×**. Lossy decode and
  large lossless are inside the ≤3× scalar target; small/medium lossless decode
  is the clear miss.
- *Encode* (MP/s): lossless ≈1.3 (photos), lossy q75 ≈8.8 (photos). vs `cwebp`
  on `photo_foliage`: lossless 125 ms vs 88 ms (**1.4×**), lossy 22 ms vs 12 ms
  (**1.8×**) — already competitive, so decode is the optimization priority.

`zig build test` unchanged (all gates pass); `zig build check` compiles the new
tool. See the 2026-06-26 oracle row.

### Step 9 — Animation and Metadata Encode (slice 9c: frame optimization)

Slice 9c delivers **automatic frame optimization**, the inter-frame half of the
animation encoder, and completes step 9's feature set. New
`animation_optimize.encodeAnimationMinimized` (public `encodeAnimationMinimized`)
takes full-canvas frames (the desired display at each timestamp) + timing +
per-frame codec and derives a minimal `ANMF` layout that composites back to
exactly those frames; the explicit-rect `encodeAnimationFromBuffers` (9b) stays
the manual API. All four PLAN.MD §9 optimization features live in the new module:

- **Sub-rectangle detection.** `changeRect` computes the minimal bounding box of
  pixels that differ from the decoder's reconstructed previous canvas (an exact
  pixel compare, mirroring libwebp's `MinimizeChangeRectangle`), snapped to even
  offsets (the container stores offsets in 2-pixel units).
- **Inter-frame differencing + blend strategy.** Inside the diff rect, pixels
  equal to the previous canvas are made transparent and the frame is emitted as
  `alpha_blend` so the previous canvas shows through — but only when that
  reconstructs exactly (`blendCandidateExact`: every changed pixel must be fully
  opaque, a sound subset of libwebp's `IsLosslessBlendingPossible`). Otherwise
  the frame is a verbatim `replace` of the cropped target. Both stay byte-exact.
- **Dispose strategy.** A one-frame lookahead picks dispose-to-background when
  clearing this frame's rect gives the next frame a strictly smaller change rect.
  Correct regardless of the choice, because the optimizer re-tracks the canvas
  with whatever dispose it picked.
- **Keyframe insertion.** Frame 0 is a full-canvas `replace` keyframe; further
  keyframes are forced on any full-canvas change and on a bounded
  `keyframe_interval` (clamped to `[1, 4096]`).

The correctness invariant is enforced by tracking the decoder's *reconstructed*
canvas, not the source: after encoding each frame, the optimizer re-decodes the
bitstream it just produced and composites it into `prev_canvas` with the exact
`animation_decode` rules (`zeroTransparentPixels`, `blendPixelNonPremult`, the
previous background-disposed-rect skip, keyframe clear). For lossy frames this is
what keeps the round-trip valid — diffing the next frame against the source
canvas instead would accumulate error. `animation_encode` exposes one narrow hook
(`encodeFrameForOptimizer`) so both encode APIs share a single per-frame codec;
the heavy optimization logic is isolated in `src/animation_optimize.zig` (no
monolith). Canvas-sized scratch (`prev_canvas` + a target buffer) is bounded
against the allocation budget up front, and every loop is bounded by the canvas
or the clamped keyframe interval.

**CI gate (byte-exact lossless round-trip), `zig build test`, 394/394 pass, +11
new:** the gate builds several all-lossless full-canvas input sequences, encodes
via `encodeAnimationMinimized`, decodes via `decodeAnimationAlloc`, and asserts
each composited frame equals the input canvas **byte-for-byte** — covering a
static background with a small moving opaque sub-region (and asserting, via
`demux`, that at least one `ANMF` rect is smaller than the canvas, i.e. the
optimizer actually shrinks), a frame identical to the previous (degenerate 1×1
rect), a full-canvas change (forces a keyframe — full-canvas `replace`), a
transparency-reveal over an opaque background (falls back to a `replace`
sub-rect), a blend+dispose multi-frame sequence, and a forced keyframe interval
(frames 0/2/4 full-canvas at interval 2). A lossy minimized animation decodes at
the canvas dimensions without error, and the whole path survives allocation
failure at every site over a mixed lossless + lossy two-frame encode.

**Local `anim_dump` gate (libwebp 1.5.0):** two minimized 96×64 6-frame samples
(`testdata/animation/anim_minimized_lossless.webp`, `testdata/animation/anim_minimized_lossy.webp`, a
textured background with a moving 16×16 sub-region) pass
`tools/webp-oracle.sh compare-anim` — `anim_dump` matches this library's own
composition byte-for-byte across all 6 frames each (compared=2, failed=0) — and
`webpinfo` reports no errors for both. The lossless sample's frames after frame 0
are 28×28/28×40 sub-rects (the dot's bounding box); the lossy sample's are
full-canvas (see the size note below). See the third 2026-06-23 oracle row.

**Compression payoff (reported, not gated):** on the 6-frame moving-sub-region
sample the minimized lossless encode is 3840 bytes vs the naive full-canvas
`encodeAnimationFromBuffers` 4174 bytes — an 8.0% reduction. The lossy minimized
encode is byte-identical to naive (7942 bytes, 0% reduction): VP8 reconstruction
differs from the source almost everywhere, so the exact diff rect against the
reconstructed canvas is the whole canvas and every frame stays a full-canvas
keyframe. This is a deliberate correctness-first choice — libwebp shrinks lossy
frames by treating near-equal pixels as unchanged (a quality tolerance), which
trades exactness for size and is left as future work.

**Browser-render check (step-9 completion gate):** set up, not closed. The two
`testdata/animation/` animations validate cleanly under `webpinfo` and match `anim_dump`;
the manual ≥2-browser confirmation is intentionally not wired into CI (it is the
only remaining manual step-9 item).

### Step 9 — Animation and Metadata Encode (slice 9d: still-encode metadata)

Slice 9d closes the still pixel-encode metadata gap. The mux already wrote
`ICCP`/`EXIF`/`XMP ` (and `StaticImage.metadata` supported them), but the public
still encoders called it with empty metadata, silently dropping any profile/EXIF/
XMP. 9d threads metadata through.

- **API.** `EncoderOptions` (the shared options bag for both still encoders)
  gained `metadata: metadata.RawPayloads = .{}` (raw `?[]const u8`
  `color_profile`/`exif`/`xmp`, caller-owned, written verbatim). It is forwarded
  into the `mux.encodeStatic` calls in `encodeStaticLossless` and
  `encodeStaticLossy` (the latter in `encodeLossyPass`, so it also rides every
  probe of the target-size/PSNR searches). `options.zig` imports `metadata.zig`;
  `metadata.zig` imports only `container.zig`, so there is no import cycle.
- **Output.** Present metadata forces the extended (`VP8X`) container and emits
  the chunks in spec-canonical order — `VP8X` → `ICCP` → (`ALPH`) → `VP8(L)` →
  `EXIF` → `XMP `. Metadata and a lossy `ALPH` chunk coexist correctly. With
  empty metadata (the default) the output is byte-identical to the pre-9d path.
- **Allocation accounting.** The lossy pass charges the live metadata payload
  bytes against the mux allocation budget alongside the borrowed `ALPH` payload
  (`metadataByteCount`); the mux's own `validateAllocationBytes(file_size)`
  remains the authoritative gate.
- **Chunk-order honesty.** The from-pixels encoders emit canonical order (there
  is no caller-specified order to preserve on that path). Caller chunk-order
  preservation is the `mux.encodeStaticFromDemux` remux path's job (unchanged
  here, already covered by its round-trip test). Animation-level metadata stays
  owned by 9a's `AnimationImage.metadata`; 9d does not duplicate it.

Round-trip (CI gate, `zig build test`, 370/370 pass): 5 new encode tests assert
(a) `encodeLossless`/`encodeLossy` with ICCP+EXIF+XMP recover each payload
byte-exactly through `demux` with the chunks in spec order and the file an
extended (`VP8X`) container; (b) a lossy+alpha+metadata case keeps `ALPH` and the
metadata chunks in canonical order and round-trips alpha exactly; (c) the
empty-metadata lossless path is byte-identical to a direct simple-`VP8L` mux; and
(d) allocation-failure-at-every-site for both encoders with metadata present. The
existing lossy "byte-identical with target modes inert" test continues to assert
the empty-metadata lossy path is unchanged.

Browser-render check (step-9 completion gate): **set up, not closed.** Three
samples were generated via the new API and the in-main `mux.encodeAnimation` (a
metadata-bearing lossless still, a metadata-bearing lossy still, and a two-frame
lossless animation with XMP) and validated with `webpinfo` — all "No error
detected", with the ICCP/EXIF/XMP/Animation flags and chunk offsets in
spec-canonical order. The full "renders in ≥2 major browsers" gate is a manual
step best run once 9c lands frame-optimized animations; it is **not** treated as a
hard gate for this slice and **not** added to CI. See the second 2026-06-23
oracle row.

### Step 9 — Animation and Metadata Encode (slice 9b: pixel-level encode)

Slice 9b delivers the **pixel-level** animation encoder — the animated analogue
of the still `encodeLossy`/`encodeLossless`. `animation_encode.encodeAnimationFromBuffers`
(public `encodeAnimationFromBuffers`) takes a caller-supplied ordered list of
pixel-buffer frames, encodes each to a bitstream, and muxes them via slice 9a.

- **Inputs.** A `FrameSource` carries the frame's `image.Buffer` (any supported
  pixel format), its even canvas offset (`x`/`y`), duration, blend/dispose
  methods, and per-frame codec (`.lossy`/`.lossless`). The buffer's own
  dimensions are the frame rectangle. An `Options` struct carries the canvas,
  loop count, background, animation-level metadata, resource limits, and the
  shared per-frame `quality`/`method`/`alpha_quality` knobs.
- **Per-frame encode reuses the still machinery** rather than reimplementing
  codecs: `encode.gatherArgbAlloc` gathers the frame's ARGB, then a lossless
  frame runs `vp8l_encoder.encodeAlloc` (VP8L carries its own alpha) and a lossy
  frame runs `color.rgbaToYuv420Alloc` + `vp8_encoder.encodeAlloc`, plus
  `alpha.encodePlaneAlloc` into an `ALPH` payload when the plane carries
  transparency (a fully-opaque lossy frame is a plain `VP8 `). Each frame's
  scratch is freed before the next; the per-frame allocation budgets mirror
  `encode.zig`'s. The caller dictates the rectangle/blend/dispose; inter-frame
  optimization is slice 9c.
- **Mux and validation.** The encoded frames go straight into
  `mux.encodeAnimation`, which re-validates every rectangle (inside the canvas,
  even offsets), bitstream dimensions, alpha placement, and the frame/chunk
  limits — so this layer leans on the mux for the container rules and adds only
  the canvas/frame-count fast-fail and per-buffer `validate()`.

Round-trip (CI gate, `zig build test`, 378/378 pass, +13 new): an all-lossless
full-canvas-keyframe animation composites back **byte-for-byte** to its source
frames through `decodeAnimationAlloc` (the full pixel round-trip); further tests
cover a lossy frame (decodes at the right dimensions), a lossless sub-rect over a
keyframe, a lossless alpha frame and a lossy+alpha frame (alpha recovered
exactly), per-frame blend/dispose (a background-disposed sub-rect clears for the
next frame), loop count + background round-trip, metadata pass-through, the input
errors (empty list, odd offset, rect outside canvas) and the frame-count limit,
and survive allocation failure at every site (`checkAllAllocationFailures` over a
mixed lossless + lossy-alpha animation). Validity (local, libwebp 1.5.0):
`tools/webp-oracle.sh compare-anim` confirms `anim_dump` of four generated
animations (lossless full-canvas, lossless sub-rect with background-dispose,
lossy full-canvas, mixed lossless + lossy-alpha with alpha-blend) matches this
library's own composition byte-for-byte across all 8 frames, and `webpinfo`
reports "No error detected" for all four. See the second 2026-06-23 oracle row.
Inter-frame sub-rectangle/differencing optimization (9c) remains.

### Step 9 — Animation and Metadata Encode (slice 9a: container mux)

Slice 9a delivers the animation **container muxer** — the step-9 analogue of
`encodeStatic`. `mux.encodeAnimation` (public `encodeAnimation`) assembles
already-encoded frame bitstreams into a valid animated WebP; it does not encode
pixels (that is slice 9b).

- **Inputs.** `AnimationImage` carries the canvas, loop count, background color,
  optional metadata, and an ordered list of `AnimationFrameImage` frames. Each
  frame supplies its rectangle, duration, blend/dispose methods, codec
  (`.lossy`/`.lossless`), the raw `VP8 `/`VP8L` bitstream, and an optional lossy
  `ALPH` payload — the bitstream-carrying analogue of `StaticImage`.
- **Output layout.** `VP8X` (animation flag + canvas) → optional `ICCP` → `ANIM`
  (background + loop count) → one `ANMF` per frame (16-byte frame header +
  optional `ALPH` + image) → optional `EXIF`/`XMP `. The `VP8X` alpha flag is set
  iff any frame carries alpha.
- **Validation.** Every frame's rectangle must lie inside the canvas with even
  offsets (the container stores them in 2-pixel units), its bitstream dimensions
  must equal the rectangle, `ALPH` is rejected on `.lossless` frames, and the
  duration fits the 24-bit field — the same constraints `demux` enforces on read,
  so a muxed animation always round-trips. Resource limits bound frame count,
  chunk count, and the single output allocation.

Round-trip (CI gate, `zig build test`, 365/365 pass): 12 new tests mux
multi-frame lossy+lossless animations and parse them back through `demux`
(rects, durations, blend/dispose, loop count, background, metadata), cover the
validation errors (odd offset, lossless+`ALPH`, rect outside canvas, dimension
mismatch, empty list) and the frame-count limit, and survive allocation failure
at every site. Validity (local, libwebp 1.5.0): a 32×32 two-frame animation
built from real library-encoded frames (lossless full-canvas + lossy 16×16
sub-rect with background dispose) is accepted by `webpinfo` ("No error
detected"), listed correctly by `webpmux -info`, and decoded to per-frame images
by `anim_dump`. See the 2026-06-23 oracle row. Pixel-level `encodeAnimation`
from buffers (and the `anim_dump`-matches-our-composition gate), inter-frame
optimization, and metadata-from-pixels are slices 9b–9d.

### Step 8 — VP8 Lossy Encoder (step 8c: controls and parity)

Step 8c completes the VP8 lossy encoder with its controls and parity features,
landed as an options scaffold plus four reviewable slices. Every piece keeps its
default path byte-identical to the 8b encoder and holds `dwebp` validity at
0/135 invalid:

- **Scaffold.** Inert `EncoderOptions` knobs (`method`, `target_size`,
  `target_psnr`, `alpha_quality`, `use_sharp_yuv`) and an `EncodeConfig` struct
  on `vp8.encoder.encodeAlloc`, landed first so the four slices could be built
  in parallel without colliding on the public surface.
- **8c-1 — method/effort knob.** `method` (0..6, `cwebp -m` compatible) scales
  the rate-distortion search via an `Effort` tier (DC-only at 0–1, all 16x16 /
  chroma modes at 2–3, full B_PRED + segmentation at 4–6). Method 4 (the
  default) is byte-identical to the 8b encoder; methods 5–6 currently clamp to 4
  (no extra search above the 8b baseline yet — the knob's present value is the
  faster low end: m2 ≈ 2.2x and m0 ≈ 3.4x faster than m4).
- **8c-2 — lossy+alpha (`ALPH`).** The straight (non-premultiplied) alpha plane
  is row-filtered and stored as the cheaper of uncompressed or a headerless VP8L
  stream (reusing the step-7 encoder), emitted as a `VP8X`+`ALPH`+`VP8 `
  container; `alpha_quality` selects 0 = uncompressed / 1..100 = lossless VP8L.
  Fully-opaque inputs stay byte-identical to the color-only path. Alpha
  round-trips byte-exactly through `decodeStatic` and `dwebp -pam`.
- **8c-3 — target-size / target-PSNR.** A bounded (≤8-probe) binary search over
  the quantizer index hits a requested byte size or BT.601 luma PSNR; both
  unset → byte-identical to the single-pass quality path, both set →
  `error.InvalidEncodeOptions`. The `ALPH` payload is encoded once and reused
  across probes (it is independent of the color quantizer).
- **8c-4 — sharp-YUV.** Optional iterative (bounded 4-pass Gauss–Seidel) chroma
  downsampling (`use_sharp_yuv`) that minimizes the residual against the
  decoder's fancy upsampler; the default box-average path is unchanged.

The step-8c acceptance gate holds: the method-preset matrix encodes the corpus
with no validity regression (0/135 across methods) and target-size lands within
5% (0.32–2.83% on the photos). See the five 2026-06-22 oracle rows. With step 8c
done the VP8 lossy encoder is feature-complete; remaining lossy work is
performance (step 10) and release hardening (step 11).

### Step 8 — VP8 Lossy Encoder (slice 8a)

The first VP8 lossy encoder slice emits a valid `VP8 ` key-frame bitstream with
a deliberately fixed mode decision; real mode decision and quality are step 8b.
The correctness rule is self-consistency: the encoder reconstructs every
macroblock through the same inverse routines the decoder uses, so a conforming
decoder reproduces the stored reconstruction bit-for-bit. New and changed code:

- `src/color.zig` gains the forward RGB→YUV420 conversion (BT.601 with libwebp's
  `VP8RGBToY/U/V` coefficients, a 2x2 chroma box-average, and edge-replicated
  macroblock padding). Color comes from raw RGB regardless of alpha, so a fully
  transparent pixel keeps its hidden color — the transparent-RGB case 8a must
  handle exactly.
- `src/vp8/forward_transform.zig` is the encode pair of `transform.zig`: a
  forward 4x4 DCT and forward WHT, locked by round-trip unit tests against the
  inverse routines before anything depends on them.
- `src/vp8/quant.zig` gains forward quantization (a bias-toward-zero quantizer
  reusing the existing dequant tables, with a matching dequantize helper) and a
  monotone quality→quantizer-index map.
- `src/vp8/tokens.zig`, `src/vp8/modes.zig`, and `src/vp8/frame_header.zig`
  promote their previously test-only encode mirrors to production: coefficient
  token emission (`writeBlock` / `writeMacroblock`), key-frame mode writing
  (`encodeKeyFrameModes`), and the compressed first-partition header writer —
  each the exact inverse of the corresponding parser, sharing its tables so the
  halves cannot drift.
- `src/vp8/encoder.zig` orchestrates the per-macroblock raster loop: DC-predict
  from reconstructed neighbors, forward-transform the residual, quantize,
  reconstruct through the shared inverse routines, and emit the quantized levels
  as tokens. It writes partition 0 (compressed header + all-DC mode records) and
  the single token partition, then assembles the frame with the back-patched
  first-partition size.
- The public API gains `encodeLossy` / `encodeStaticLossy` (typed pixel buffer →
  muxed `VP8 ` WebP file; alpha is dropped until 8c) and `encodeVP8Bitstream`
  (raw VP8 payload), wired through `src/encode.zig` and `src/root.zig`.
- `encodeStaticLossy` now accounts for its ARGB copy, YUV source/reconstruction
  planes, VP8 partition/token scratch, raw VP8 bitstream, and final mux output
  against `EncoderOptions.limits.allocation_bytes_max` before large scratch
  buffers are allocated.

Validity and the self-consistency gate run under `zig build test`:
`src/testing/encode_corpus.zig` encodes every synthetic source and committed
photo through the low-level encoder, decodes the result, and asserts the
decoder's YUV planes equal the encoder's reconstruction byte-for-byte; the
smooth photos and a flat fully-transparent field additionally clear an RGB PSNR
floor, and the public `encodeStaticLossy`+`decodeStatic` path round-trips at the
source dimensions. New tooling: `zig build encode-lossy-report` reports size,
bits-per-pixel, and luma PSNR per source, `zig build encode-lossy` re-encodes a
WebP as lossy, and `tools/webp-oracle.sh compare-encode-lossy` feeds every
encoded file to `dwebp` for the external validity check and pairs sizes against
`cwebp -q -noalpha` (matching step 8a's alpha-dropping behavior). Deep encoder
fuzzing and allocation-failure depth stay deferred to step 11, though the public
path already passes `checkAllAllocationFailures`.
The lossy oracle fails on still-image encode errors, reference-tool failures,
and empty validation sets; only animated files are skipped after `webpinfo`
classification.

### Encode Test Corpus (pre-step-8 harness)

Before the VP8 lossy encoder (step 8), the encode side gained a defined source
corpus and measurement harness, because step 8's gates are measured on source
images rather than on decoded WebP files:

- `src/testing/synth.zig` generates a deterministic matrix of 30 synthetic
  sources crossing VP8 macroblock geometry (1x1; 15/16/17 luma-block edges;
  asymmetric partials; primes; 1xN/Nx1 strips; larger canvases), content (flat,
  gradient, high-frequency checker, saturated bars, noise, radial,
  neutral-chroma ramp, two-tone), and alpha (opaque, ramp, binary, and
  fully-transparent pixels carrying non-zero RGB — the case step 8a must handle
  exactly). Nothing is committed; the images are rebuilt at test time.
- `testdata/photos/` holds four committed CC0 photographs (a face, a foliage
  macro, signage with text, and a sunset gradient) downscaled to a 512 px
  longest side and stored as `cwebp -lossless` WebP, so they decode to pristine
  pixels. Licenses and provenance are in `testdata/photos/PROVENANCE.md`.
- `src/testing/encode_corpus.zig` round-trips every synthetic source and every
  committed photo through `encodeStaticLossless` and back through the decoder,
  asserting bit-exact recovery under `zig build test` (the in-tree lossless
  corpus is already round-tripped by `corpus.zig`). All 30 synthetic sources and
  4 photos round-trip with zero mismatches.
- `src/testing/metrics.zig` provides MSE and PSNR (overall plus BT.601 luma,
  using libwebp's `VP8RGBToY` weights so step-8 figures line up with `cwebp`).
- Tooling: `zig build encode-report [-- --with-corpus] [OUT.tsv]` reports
  encoded size, bits-per-pixel, and round-trip per source (committed baseline
  `testdata/encode-corpus-sizes.tsv`); `tools/webp-oracle.sh
  compare-encode-corpus REPORT.tsv` pairs our sizes against `cwebp -lossless`.

This concretely realizes step 7's "encode corpus", which previously named the
unversioned "libwebp gallery images": a committed CC0 photo set plus the
synthetic matrix and the in-tree lossless files. Re-measured against
`cwebp -lossless` (libwebp 1.5.0) over the 43 in-tree lossless files plus the 4
photos, the per-file median size ratio is 1.0368x (aggregate 1.046x), so the
step-7 1.10x median gate still holds; the photographic files (1.05x–1.18x on the
photos, up to 1.59x on `lossless2`/`lossless3`) remain the known gap that
per-block predictor selection will close.

### Step 7 — VP8L Lossless Encoder (slice 3)

The third encoder slice adds entropy-coding depth on top of slice 2's
transforms, all in `src/vp8l/encoder.zig` (mirroring the decode side's
`color_cache.zig`, `meta_prefix.zig`, `prefix_groups.zig`, and the group-store
entropy path in `entropy.zig`):

- An optional color cache. The LZ77 token stream is lowered to an "op stream"
  while simulating the decoder's cache exactly: lowering reads the materialized
  main-image pixels so every copied pixel is inserted into the cache just as the
  decoder inserts it, and a literal whose pixel already sits at its hashed slot
  is emitted as a cache-index green symbol (`green_base + index`), the exact
  inverse of `color_cache.zig` + the cache path in `entropy.zig`. A guard gives
  any empty channel histogram a single symbol so the prefix code stays a valid
  single-leaf tree — this matters for a solid all-zero image whose first pixel
  hits the zero-initialized cache and emits no literals at all.
- An optional entropy image / multiple Huffman groups (meta-prefix). The image
  is tiled into prefix blocks (block-size log2 in [3,5]); per-block green
  histograms are clustered greedily (L1 distance, bounded at 16 groups); the
  entropy image (group index per block, red high byte / green low byte) is
  emitted as a transform-role single-group literal stream, followed by the
  per-group prefix codes and a symbol stream that selects each op's group by its
  starting block. This inverts `meta_prefix.zig` + `prefix_groups.zig`.
- Both choices are gated by *measuring the real encoded size*: each candidate
  (single group with each candidate cache size, and the multi-group plan) is
  fully encoded into a scratch buffer and the smallest is re-emitted into the
  output. Because the comparison is exact, a candidate is never kept when it
  would enlarge the output, so slice 3 is never larger than slice 2 on any file.

Validity and round-trip stay gated by `zig build test`: the slice-1 corpus
round-trip test still passes with the richer encoder, and new tests cover a
cache-friendly repeated-palette image, the cache-hit/copy-insert lowering rules
(white-box on `lowerOps`), the empty-cache solid-image edge case, and a
two-region image whose `planMultiGroup` is asserted to open at least two groups
and which round-trips through the multi-group emission path.

### Step 7 — VP8L Lossless Encoder (slice 2)

The second encoder slice adds compression transforms on top of slice 1's
literal output, each the exact inverse of the corresponding decode routine so
every combination still round-trips bit-exactly through this library's decoder:

- LZ77 back-reference matching (`src/vp8l/lz77.zig`): a hash-chain greedy
  matcher over packed ARGB pixels emits literal/copy tokens. `prefixForValue`
  inverts the decoder's `image_data.readPrefixValue` (length and distance
  prefix symbols + extra bits), and `distanceCodeForPixels` inverts
  `distanceFromCode` by emitting the direct `distance + 120` code form
  (matches are capped at `(1 << 20) - 120` pixels so the code is always
  representable). Copies extend the green channel's alphabet with length
  symbols and use the distance prefix code, exactly as the decoder reads them.
- Forward transforms (`src/vp8l/forward_transform.zig`): subtract-green, the
  per-block color transform (signed 3.5 fixed-point green→red / green→blue /
  red→blue multipliers), the per-block predictor transform (all 14 modes), and
  the color-table delta coding for palettes. Each is the bit-exact inverse of
  `inverse_transform.zig` (proven by per-mode round-trip unit tests).
- The encoder (`src/vp8l/encoder.zig`) now plans a transform stack: a
  palette / color-indexing transform for images with at most 256 distinct
  colors (with the decoder's index bit-packing for 2/4/16/256-color tables and
  a delta-coded color table), or, for higher-color images, a single global
  predictor mode (chosen by minimizing a residual-magnitude proxy) followed by
  the cheaper of a color transform or subtract-green (mutually exclusive so
  red/blue are not adjusted twice). Each transform is applied only when its
  estimated gain is positive. The main image is then LZ77-tokenized and
  entropy-coded. Prefix-code descriptors now pick the cheapest of the simple
  form (1–2 length-1 symbols) and the normal form with run-length packing
  (code-length repeat codes 16/17/18), which slashed the per-file overhead on
  small images (e.g. the 1x1 `lossless_vec_1_*` files dropped from 382 to 48
  bytes).

Validity and round-trip stay gated by `zig build test`: the slice-1 corpus
round-trip test (decode every still VP8L corpus file to RGBA, re-encode, decode,
assert bit-identical) still passes with the richer encoder, and new synthetic
cases cover low-color palettes (including odd-width 1-bit-packed indices),
LZ77-friendly repetition, and a chroma-correlated image whose transform plan is
asserted to include the color transform.

### Step 7 — VP8L Lossless Encoder (slice 1)

The first encoder slice emits valid still VP8L bitstreams from ARGB literals
only — no LZ77 backward references, no transforms, and no color cache yet. A
canonical Huffman writer (`src/vp8l/huffman_writer.zig`) is the exact inverse
of the decoder's reader (`src/vp8l/huffman.zig`): it assigns length-limited
canonical code lengths from a histogram, then emits codes in the reader's
canonical (length, symbol) order with the same bit-reversal, including the
single-leaf zero-bit exception and a length-limited build for the 7-bit
code-length-code. The encoder (`src/vp8l/encoder.zig`) writes the VP8L image
header, a "no transform" terminator, the no-color-cache / single-prefix-group
flags, the five prefix-code descriptors (green/red/blue/alpha/distance) in
normal form, and the per-pixel literal symbol stream, all through the existing
LSB-first `BitWriter`. The public API gains `encodeLossless` (typed pixel
buffer → muxed simple `VP8L` WebP file, any RGBA/BGRA/ARGB/RGB input honoring
stride) and `encodeVP8LBitstream` (ARGB → raw VP8L payload), wired in
`src/encode.zig` and `src/root.zig` and muxed via the existing
`mux.encodeStatic`.

Validity and round-trip are gated by committed tests under `zig build test`:
synthetic edge cases (1x1, solid color, two-axis gradient, full-range alpha,
single-row, single-column) plus a corpus test that decodes every still VP8L
file in `testdata/libwebp-test-data` to RGBA, re-encodes it, decodes the
re-encoded bytes, and asserts the pixels are bit-identical to the source.
Size is not gated for this slice (LZ77/transforms come next).

### Step 6 — Extended Decode and Animation

Animated WebP decode is implemented in `src/animation_decode.zig`, composing
frames onto a canvas to match libwebp's `anim_dump` byte-for-byte. The
container layer (`src/demux.zig`) already enforced the `VP8X` feature flags and
extended chunk-ordering rules and parsed `ANIM`/`ANMF` (frame rectangles,
durations, dispose/blend methods, background color, loop count) into
`animation.Info`/`animation.Frame`; step 6 adds the pixel decode and
compositing on top.

Each frame is reconstructed through the shared still decoder
(`decode.decodeImage`, extracted in the first step-6 slice so VP8/VP8L/alpha is
reused rather than duplicated). Compositing replicates libwebp exactly: a
transparent-canvas start (the `ANIM` background color is informational only),
keyframe detection that clears the canvas, source-over non-premultiplied alpha
blend (blend method 0) or verbatim copy (method 1), the skip of blending inside
a previous frame's background-disposed rectangle, dispose-to-background between
frames, and the zeroing of fully transparent pixels' RGB (libwebp's animation
decoder, unlike `-exact` static decode, does not preserve it). The blend math
is the integer `BlendPixelNonPremult` approximation libwebp uses for
`MODE_RGBA`.

Two public entry points share the compositor: `decodeAnimation` returns every
composited frame as its own buffer, and the streaming `AnimationDecoder`
(`init`/`next`/`reset`/`info`/`deinit`) yields one frame at a time over a reused
canvas for bounded memory. A new `error.NotAnimated` rejects still inputs;
animation requires a 4-channel output format. The `zig build anim` tool and the
`compare-anim` / `compare-anim-corpus` oracle modes mirror the still tooling,
and `tools/zig-webp-anim-hashes.zig` (`zig build anim-hashes`) regenerates the
committed frame-hash manifest. A fuzz smoke target covers the animation entry
point.

### Step 5 — VP8 Lossy Decoder

Key-frame header parsing is implemented in `src/vp8/frame_header.zig` on top
of the existing boolean reader: frame tag (key-frame/version/show-frame
validation), picture header (start code, dimensions, scale codes), and the
compressed first-partition header through color space, segmentation, loop
filter, token partition layout, quantizer indices, `refresh_entropy_probs`,
DCT coefficient probability updates, and the skip probability. The RFC 6386
default and update token probability tables live in
`src/vp8/token_probs.zig`, transcribed from the normative tables and
cross-checked value-for-value between `references/libwebp` and
`references/ffmpeg` before committing. All 88 lossy still files in the
committed corpus parse with dimensions matching demux features.

Macroblock prediction record parsing is implemented in `src/vp8/modes.zig`
on top of a generic RFC 6386 treed read added to the boolean reader:
per-macroblock segment ids, coefficient-skip flags, key-frame 16x16 luma and
chroma intra modes, and B_PRED subblock modes with above/left contexts
(including the derived contexts that 16x16 modes contribute). The key-frame
mode trees and the 10x10x9 `kf_bmode_prob` table are transcribed from RFC
6386 and were cross-checked value-for-value against `references/libwebp` and
`references/ffmpeg` under their permuted mode enumerations. Prediction
records for all 88 lossy still files in the committed corpus parse without
error, and a fuzz smoke target covers the record parser.

Dequantization factor resolution is implemented in `src/vp8/quant.zig`: the
RFC 6386 section 14.1 dc/ac lookup tables (cross-checked value-for-value
against `references/libwebp` and `references/ffmpeg`), index clamping,
per-segment quantizer resolution (absolute and relative), the y2_dc doubling,
the y2_ac 155/100 scaling with its floor of 8 (comptime-verified equivalent
to libwebp's fixed-point form), and the uv_dc saturation at 132.

Coefficient token decode is implemented in `src/vp8/tokens.zig`: the RFC
6386 section 13 token tree as explicit branches, coefficient bands with the
position-16 sentinel, zigzag scatter, extra-bit categories with MSB-first
probabilities (cat6 reaching 2114; the RFC's "67 - 2048" comment is wrong),
sign bits, dequantize-at-store with wrapping i16 semantics, per-plane
first-coefficient handling (Y-after-Y2 starts at 1), left/above nonzero
contexts at subblock granularity, the skipped-macroblock rule that preserves
Y2 context for B_PRED macroblocks, and implicit-skip reporting for the loop
filter. The boolean reader now zero-pads short initial loads (tiny final
token partitions are valid; `vp80-05-sharpness-1430.webp` splits 4 bytes
across partitions) and `BoolReader.init` no longer fails. A corpus test
decodes every coefficient of all 88 lossy still files end-to-end (modes,
per-row partition selection, contexts) without error.

The inverse transforms are implemented in `src/vp8/transform.zig`: the
exact-integer inverse 4x4 DCT (columns then rows, lone `(x+4)>>3` rounder,
Q16 constants 20091/35468 with the K-1 split) fused with add-to-prediction
and unconditional [0,255] clamping, and the inverse Walsh-Hadamard transform
for Y2 with its distinct (0,3)/(1,2) butterfly pairing and `(x+3)>>3`
rounder. Arithmetic uses wrapping i32 ops so hostile wrapped-i16
coefficients cannot panic. Unit vectors were generated independently from
the RFC pseudocode (twice) rather than from reference C code.

Intra prediction kernels are implemented in `src/vp8/prediction.zig` as
pure functions over explicit neighbor values: 16x16 luma and 8x8 chroma
DC (with the edge-variant denominators and the 128 no-neighbor case),
V/H/TM, and all ten 4x4 B_PRED modes including the B_VL final-pixel
exceptions and the RFC's `svg2p` typo resolution. Unit vectors were
computed independently from the RFC formula tables; synthetic-border
identities (127/129) are covered. Neighbor gathering (frame edges, the
fixed top-right rule for subblocks 3/7/11/15) belongs to the
reconstruction slice.

Full-frame reconstruction is implemented in `src/vp8/decoder.zig`: the
whole-frame decode loop (persistent per-partition token readers selected by
row, nonzero contexts, Y2 WHT scatter before luma IDCTs), a bordered
scratch macroblock with the synthetic 127/129 edges, left-sample rotation
including the above-left corner, top-sample snapshots taken from the
unfiltered reconstruction, the fixed top-right rule for right-edge
subblocks, B_PRED predict/add interleaving, and macroblock-padded plane
output with ceil-rounded chroma crop dimensions. The `zig build yuv` tool
and the `compare-yuv` / `compare-yuv-corpus` oracle modes (plus their
`-nofilter` variants) mirror the alpha tooling.

The in-loop deblocking filter is implemented in `src/vp8/loop_filter.zig`
(RFC 6386 section 15) and runs as a final pass over the reconstructed,
macroblock-padded planes — deferring every edge to after whole-frame
reconstruction is bit-identical to libwebp's row pipeline because intra
prediction only ever reads the unfiltered above-row snapshot. The simple
(2-tap) and normal (4/6-tap) kernels, the high-edge-variance and
interior-smoothness tests, and the per-segment / per-prediction-size
strength derivation (sharpness narrowing, loop-filter ref/mode deltas, and
the `f_inner |= has-nonzero-coefficients` rule, where the nonzero flag is
`decodeMacroblock`'s return) are transcribed from `references/libwebp` and
cross-checked against the normative text. Macroblocks are filtered in raster
order, each applying left / inner-vertical / top / inner-horizontal edge
groups in libwebp's exact sequence. Decoding exposes
`DecodeOptions{ .apply_loop_filter }` so the tool can still emit
`dwebp -nofilter`-equivalent output for regression isolation.

The YUV-to-RGB conversion layer is implemented in `src/color.zig` as a pure
function over borrowed planes: the BT.601 fixed-point conversion and the
"fancy" bilinear chroma upsampler (with its mirror-at-the-boundary first/last
row handling) are transcribed from `references/libwebp` (`src/dsp/yuv.h`,
`src/dsp/upsampling.c`, `src/dec/io_dec.c`) and produce bit-identical output
to libwebp's scalar path. Because conversion is implementation-defined rather
than RFC-fixed, correctness is pinned to `dwebp -pam` (which defaults to
fancy upsampling) instead of to a spec formula. The `zig build rgb` tool and
the `compare-rgb` / `compare-rgb-corpus` oracle modes (plus their
`-nofilter` variants) mirror the YUV tooling; alpha-bearing lossy files are
handled by the alpha-composition stage described next.

The public `decodeStatic` decodes lossy stills end-to-end: it reconstructs the
YUV frame, converts with fancy upsampling, and composes the decoded ALPH plane
(when present and the output format carries alpha) verbatim over the result —
lossy WebP uses straight, non-premultiplied alpha, so RGB is left untouched.
The `compare-rgb` oracle and the `zig-webp-rgb` tool no longer skip
alpha-bearing files. Lossless and lossy stills are byte-exact against the
committed plane hashes, closing the step 5 decode gate.

## Completed Steps

### Step 0 — Project Foundation

Package-level API types, resource limits, corpus helpers, current
`zig build test` coverage, and optional local oracle tooling are in place.

### Step 1 — RIFF/WebP Container

Done for static container scope. Strict demux covers RIFF sizing, padding,
chunk order, duplicate chunks, unknown chunks, trailing data, simple
`VP8 `/`VP8L`, `VP8X` feature probing, raw metadata exposure, and chunk
locations. Static mux/remux writes valid canonical chunk ordering and
preserves metadata payloads.

### Step 2 — Core Bitstream Infrastructure

Bounded little-endian byte readers/writers, LSB-first bit readers/writers,
VP8L canonical Huffman table construction/lookup, and VP8 boolean arithmetic
reader/writer are implemented with unit, invalid-input, round-trip, and
compile-time capacity tests.

### Step 3 — VP8L Lossless Decoder

Done for still-image lossless corpus scope. VP8L image header parsing,
transform-list parsing and dimension bookkeeping, single-prefix-group
image-data Huffman parsing, code-length repeat handling, color-cache
metadata validation, distance mapping, bounded entropy-stream scanning, and
no-transform single-prefix-group ARGB materialization for literals, LZ77
copies, color-cache references, and meta-prefix entropy image parsing are
implemented with focused tests. Multiple Huffman group storage and
meta-prefix selection during main-image entropy decode are also in place.
Subtract-green, predictor, color, and color-indexing inverse transform
support are wired into the limited raw VP8L decoder. Main-image
meta-prefix/group-store entropy decoding is available through the
allocator-backed raw decoder path. Public static lossless decode composition
is available for still VP8L images.

### Step 4 — Alpha Chunk Decode

Alpha-plane decode is done; composition with lossy VP8 color output is
tracked under step 5. ALPH header parsing (compression, filter,
preprocessing, reserved-bit validation), uncompressed alpha stream decode,
the none/horizontal/vertical/gradient unfilters, and VP8L-compressed alpha
decode through the headerless VP8L image-stream entry point are implemented
in `src/alpha.zig` with unit, invalid-input, filter round-trip, and corpus
decode tests. The committed oracle workflow (`compare-alpha`/
`compare-alpha-corpus` modes backed by the `zig build alpha` plane-dump
tool) compares decoded ALPH planes against the alpha region of
`dwebp -alpha -pgm`.

Note: strict demux keeps its lenient ALPH policy (reserved bits tolerated
and canonicalized on remux); the decode path rejects them like `dwebp`.

## Oracle Results

| Date | Scope | Result |
|---|---|---|
| 2026-06-11 | VP8L still-image decode vs `dwebp` PAM output | Matched all 43 VP8L files in `references/libwebp-test-data`; 88 non-lossless files skipped. |
| 2026-06-12 | ALPH plane decode vs `dwebp -alpha -pgm` | Matched all 18 ALPH-bearing files byte-for-byte (both compression methods, all four filters, color cache); 113 non-ALPH files skipped. |
| 2026-06-12 | Pre-loop-filter VP8 reconstruction vs `dwebp -nofilter -yuv` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (Y, U, and V planes), plus 43 locally generated `cwebp` files (qualities 10-95, segments, filter/sharpness settings, odd dimensions down to 1x1); 43 non-lossy corpus files skipped. |
| 2026-06-13 | Filtered VP8 decode vs plain `dwebp -yuv` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (Y, U, and V planes), plus 31 locally generated `cwebp` files exercising both the simple (`-nostrong`) and normal (`-strong`) filters, filter strengths 0/20/60, qualities 8-92, sharpness 0/4/7, and odd dimensions down to 1x1; 43 non-lossy corpus files skipped. The `-nofilter` oracle still matches. |
| 2026-06-14 | VP8 YUV-to-RGB + fancy upsampling vs `dwebp -pam` | Matched all 70 lossy-without-alpha still files in `libwebp-test-data` byte-for-byte (full RGBA PAM), plus 84 locally generated `cwebp` files (two-axis gradients at odd dimensions 1x1 through 64x48, qualities 5-95, simple and normal filters, segments + sharpness 7); 61 non-lossy / lossy+alpha corpus files skipped. The `-nofilter` oracle matches all 154 too. |
| 2026-06-14 | Composited lossy RGBA (with ALPH alpha) vs `dwebp -pam` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (full RGBA PAM), now including all 18 lossy+alpha files via ALPH composition, plus 18 locally generated `cwebp` lossy+alpha files (RGBA gradients at odd dimensions 1x1 through 64x48, qualities 30-95, alpha quality 60-100, full-range alpha); 43 non-lossy corpus files skipped. Both the filtered and `-nofilter` oracle modes match. |
| 2026-06-14 | Composited animation frames vs `anim_dump -pam` (libwebp 1.5.0) | Matched 14 locally generated animations byte-for-byte across all composited frames (`img2webp` lossless/lossy/mixed plus `webpmux`-assembled frames): every dispose×blend combination, full-canvas and sub-rect frames, binary and gradient alpha, background-dispose with overlapping and disjoint rectangles, and canvases from 2x1 to 100x80. The 8 most representative (29 frames) are committed under `testdata/animation` with SHA-256 frame hashes in `testdata/animation/hashes.tsv`. |
| 2026-06-16 | VP8L literal encoder round-trip (own decoder + `dwebp`) | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode (ARGB literals only) and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus test). Locally, `dwebp -pam` also decodes the encoder's output bit-exactly to the source on `lossless_vec_2_0.webp` (128x128); `dwebp` is not on CI, so CI relies on the own-decoder round-trip. Encoded size is ~1.28x the original corpus bytes (literals only; size is not gated this slice). |
| 2026-06-16 | VP8L transform encoder (slice 2) round-trip + size vs `cwebp -lossless` | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode with LZ77 + the decision-gated subtract-green/color/predictor/palette transforms and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus test, runs under `zig build test`). Locally `dwebp` (libwebp 1.5.0) also decodes all 43 re-encoded files to pixels byte-identical to the originals (full corpus cross-check, 0 mismatches). Size vs `cwebp -lossless` (cwebp 1.5.0, default settings, same decoded source pixels): per-file median ratio 1.0986x (37/43 files at or below 1.10x; range 0.92x–1.63x), aggregate-bytes ratio 1.044x. Size is reported, not yet hard-gated; the worst cases are small/synthetic vector images where cwebp's entropy-image and color-cache machinery (slice 3) wins. |
| 2026-06-16 | VP8L entropy encoder (slice 3) round-trip + size vs `cwebp -lossless` | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode with the slice-2 transforms plus the optional color cache and optional entropy-image/multiple-Huffman-groups, each chosen by measuring the real encoded size, and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus round-trip test, runs under `zig build test`). Locally `dwebp` (libwebp 1.5.0) decodes all 43 re-encoded files to pixels byte-identical to the originals (full corpus cross-check, 0 mismatches). Size vs `cwebp -lossless` (cwebp 1.5.0, default settings, same decoded source pixels): per-file median ratio 1.0368x (37/43 files at or below 1.10x; range 0.92x–1.59x), and no file is larger than the slice-2 encoding (the measure-by-encoding selection only keeps genuine wins). The remaining files above 1.10x are the photographic `lossless1`–`lossless4` / `lossless_color_transform` / `near_lossless_75`, which need per-block predictor selection (a later refinement) to close the gap. The 1.10x median size gate for step 7 holds against `cwebp` on this corpus; the PNG comparison is not yet recorded. |
| 2026-06-18 | Encode test corpus round-trip + lossless size vs `cwebp -lossless` | New pre-step-8 harness. Round-trip (CI gate, runs under `zig build test`): all 30 synthetic sources (macroblock-edge dimensions × content × alpha) and the 4 committed CC0 photos (512px) re-encode through `encodeStaticLossless` and decode back bit-exactly, 0 mismatches; the 43 in-tree lossless files stay covered by the existing corpus round-trip test. Size (reported, via `tools/webp-oracle.sh compare-encode-corpus`) over 47 real-image files (43 in-tree lossless + 4 photos), `cwebp -lossless` (libwebp 1.5.0), identical decoded source pixels: per-file median ratio 1.0368x, aggregate 1.046x (range 0.92x–1.59x; the 4 photos 1.05x–1.18x). Confirms the step-7 1.10x median gate on the now-defined encode corpus. |

| 2026-06-19 | VP8 lossy encoder (slice 8a) round-trip + validity vs `dwebp`/`cwebp` | New baseline encoder. Self-consistency (CI gate, runs under `zig build test`): the decoder reproduces the encoder's reconstruction byte-for-byte at the YUV layer for all 30 synthetic sources (every macroblock geometry × content × alpha, including the transparent-RGB case) and the 4 committed photos; the public `encodeStaticLossy`+`decodeStatic` path round-trips at the source dimensions. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 encoded still files (4 photos + 131 in-tree corpus stills, lossless and lossy sources re-encoded) without error — 0 failures. Quality (reported, not gated): mean BT.601 luma PSNR 37.1 dB over the 34-source report at q75 (photos 34.7–40.8 dB); encoded size median 1.17x and aggregate 1.464x vs `cwebp -q 75 -noalpha` — a DC-only baseline with no rate-distortion, to be closed by step 8b. |
| 2026-06-20 | VP8 lossy encoder (slice 8b-1) intra mode decision: self-consistency + validity + quality vs 8a | Replaces the fixed all-DC decision with a per-macroblock intra mode choice: each macroblock picks its 16x16 luma mode and its shared 8x8 chroma mode among DC/V/H/TM by a rate-distortion score (reconstruction SSE plus a quantizer-scaled penalty on coded coefficients, weight 1 chosen by measurement). B_PRED (4x4 luma intra) stays deferred to slice 8b-2. Self-consistency (CI gate, `zig build test`): the decoder still reproduces the encoder's reconstruction byte-for-byte at the YUV layer across every macroblock geometry × content × alpha and the 4 photos — now exercising TrueMotion at the left frame edge via a single-column geometry, and a neighbor-gather unit test pins the decoder-mirroring above-left corner (synthetic 129 at column 0 / row > 0) that all-DC never read. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 encoded stills without error — 0 failures (the 8a validity gate holds). Quality (reported, not gated, q75): on the 4-photo corpus mean BT.601 luma PSNR 37.97 → 38.07 dB (+0.10) while total photo bytes drop 72,496 → 69,124 (−4.7%) — every photo improves on both PSNR and size; over the 30 synthetic+photo sources with finite PSNR in both baselines, +0.11 dB at −4.4% bytes. (The 34-source report mean reads lower than 8a only because `alpha_gradient_32x32` now reconstructs losslessly — PSNR ∞ — and the report excludes ∞ from its mean; it is an improvement, not a regression.) |
| 2026-06-20 | VP8 lossy encoder (slice 8b-2a) token bit-cost rate model | Replaces slice 8b-1's nonzero-coefficient rate proxy with an accurate VP8 token bit-cost model: `src/vp8/cost.zig` holds `VP8EntropyCost` (transcribed value-for-value from `references/libwebp` `src/dsp/cost.c`; index 128 = 256 fixes the 1/256-bit unit), and `tokens.blockCost` mirrors `writeBlock`/`writeBlockTokens`/`writeLargeValue` boolean-for-boolean to return the exact ideal coding cost. The 16x16-luma and chroma rate-distortion decisions now weigh reconstruction SSE against real coded bits via a quantizer-scaled Lagrange multiplier (λ ∝ AC-step², tuned by measurement). Self-consistency (CI gate, `zig build test`) and `dwebp` validity (0/135 invalid) hold unchanged. Quality (reported, q75): on the 4-photo corpus the mean luma PSNR is unchanged (38.065 dB) at 1.1% fewer bytes (69,124 → 68,386); over the 30 finite-PSNR synthetic+photo sources, −0.025 dB at −2.0% bytes; the per-file median size vs `cwebp -q 75 -noalpha` improves from 1.169x to 1.124x over the 135-file corpus. The standalone gain is small by design — the model's purpose is the rate-accurate 16x16-vs-B_PRED comparison slice 8b-2b needs. |
| 2026-06-20 | VP8 lossy encoder (slice 8b-2b) B_PRED intra mode | Adds B_PRED (per-subblock 4x4 luma intra) to the mode decision. Each macroblock now also evaluates B_PRED — choosing one of the ten 4x4 intra modes per luma subblock by rate-distortion (subblock SSE + the slice-8b-2a token bit cost + the submode-tree signaling cost via `modes.treeCost`) — and the 16x16-vs-B_PRED choice compares full luma RD costs including each mode's signaling. The encoder mirrors the decoder's bordered scratch (synthetic borders plus the fixed macroblock-row top-right for right-edge subblocks), so the self-consistency gate holds for B_PRED too: a new test confirms B_PRED is selected on detailed content and the decoder reproduces the reconstruction byte-for-byte. `has_y2` is now per-macroblock (B_PRED codes its luma DC per subblock, with no Y2 block). Because B_PRED codes far more mode data, very large detail-rich frames can overflow VP8's 19-bit first-partition size; the encoder detects this and re-encodes the frame with B_PRED disabled (a rare second pass), so every corpus file still encodes. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid (including the 11158x2156 `bryce` via the fallback). Quality (reported, q75): on the 4-photo corpus mean BT.601 luma PSNR 38.07 → 39.57 dB (+1.51) at 6.6% fewer bytes (68,386 → 63,862) — every photo gains ~1.1–2.1 dB; over the 30 finite-PSNR synthetic+photo sources, +1.04 dB at −7.8% bytes; the per-file median size vs `cwebp -q 75 -noalpha` improves from 1.124x to 1.088x over the 135-file corpus. |
| 2026-06-21 | VP8 lossy encoder (slice 8b-3a) skip decisions + loop-filter selection | Adds two header-level quality features. A macroblock whose residue quantizes entirely to zero is now coded as `mb_skip_coeff` (no residual tokens emitted), with the frame's `prob_skip_false` derived from the realized skip ratio (libwebp `CalcSkipProba`); skip coding is always enabled, which is valid for any ratio and avoids a buffering pass. The RFC 6386 §15 in-loop deblocking filter runs at a level chosen from the AC quantizer (libwebp `SetupFilterStrength`, single segment, default `-f 60`, sharpness 0, normal filter; e.g. q75 → level 10), and the encoder filters its finished reconstruction in place via the decoder's own `loop_filter.applyFrame`. Self-consistency (CI gate, `zig build test`): intra prediction reads only unfiltered pixels during the pass, so filtering the whole frame afterward leaves the decoder's filtered output byte-identical to the encoder's stored reconstruction; the gate now exercises both skip and filtering (q75 → level 10), with new tests that flat content is skipped, that filtering actually changes pixels (and unfiltered decode does not match), and that the level / skip-probability heuristics hold. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid. Quality (reported, q75): on the 4-photo corpus mean BT.601 luma PSNR 39.65 → 39.99 dB (+0.34) at +0.08% bytes (63,614 → 63,668; every photo flat-or-better in PSNR, foliage also smaller); over the 34-source report +0.48 dB (36.82 → 37.30); per-file median size vs `cwebp -q 75 -noalpha` unchanged at 1.088x. The PSNR gain is entirely the deblocking filter (skip never alters the reconstruction); skip coding is byte-neutral on this textured corpus — it shrinks low-detail content but the per-frame skip overhead offsets that on busy photos — and pays off more on flat content. Segmentation (adaptive quant) and the matched-size PSNR gate close in slice 8b-3b. |

| 2026-06-21 | VP8 lossy encoder (slice 8b-3b) segmentation: matched-size luma-PSNR gate vs `cwebp -q 75 -m 4` | Adds adaptive per-segment quantization — the step-8b gate slice. A pre-pass (`src/vp8/segment.zig`) buckets macroblocks into up to four segments by luma complexity (summed \|AC\| of the source luma subblocks, integer 1-D k-means, ≤6 iterations) and assigns each segment a quantizer delta on the frame base — finer for busier segments, the SSE-optimal direction, spread ±4 indices — emitted through the new `frame_header.writeSegmentation` and the per-macroblock segment map (`modes.encodeKeyFrameModes`). Flat/uniform or low-variation frames keep segmentation off, byte-identical to 8b-3a. The encoder reconstructs each macroblock with its segment's factors — exactly what the decoder resolves from the header via `quant.segmentFactors` — so the self-consistency gate holds. Self-consistency (CI gate, `zig build test`): the decoder reproduces the encoder's reconstruction byte-for-byte across every macroblock geometry × content × alpha and the 4 photos, plus a new mixed flat/textured case that exercises ≥2 segments; `frame_header.writeSegmentation` round-trips through `parseSegmentation` and `segment.zig` unit tests cover the k-means split, the uniform-collapse fallback, and the tree-probability derivation. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid; the per-file median size vs `cwebp -q 75 -noalpha` is unchanged at 1.088x (the symmetric spread is bit-neutral at a fixed base quantizer). **Gate (matched output size, photo corpus, BT.601 luma PSNR vs `cwebp -q 75 -m 4`):** mean 40.79 dB vs cwebp 40.70 dB, **+0.08 dB** — inside the 1.0 dB target and ahead of `cwebp`; per photo: foliage +0.42, sky +0.31, portrait +0.04, signage −0.44 (sizes matched within 0.2–4.2%). Against the 8b-3a uniform-quant baseline at matched size (−0.02 dB vs cwebp), segmentation adds +0.10 dB. The spread magnitude was tuned by measurement: the matched-size gain plateaus across spreads 2..5 (≈+0.1 dB), is neutral by spread 6, and goes negative by spread 12 (coarsened segments then lose more than refined ones gain). |

| 2026-06-22 | VP8 lossy encoder (slice 8c-1) method/quality effort knob | Honors `EncodeConfig.method` (0..6, `cwebp -m` compatible) to scale the rate-distortion search via an `Effort` tier (`src/vp8/encoder.zig`), threaded `encodeAlloc` → `encodeFramePass` → `encodeMacroblock` → `selectLuma`/`selectChroma`: methods 0–1 code DC-only (no B_PRED, no segmentation), 2–3 evaluate all four 16x16/chroma intra modes, 4–6 run the full search (B_PRED + segmentation). **Method 4 — the default, matching the 8b gate's `-m 4` — is byte-identical to the 8b encoder** (asserted by test); methods 5–6 clamp to 4, i.e. no extra search above the 8b baseline yet, so the knob's present value is the faster low end. Self-consistency (CI gate, `zig build test`) and `dwebp` validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0: 0/135 invalid) hold. Quality/speed (reported, 4 photos, q75): m4 and m6 identical in size and PSNR; m2 ≈ 2.2x faster than m4 (~10 vs ~22 ms) at −0.9 to −1.4 dB luma; m0 ≈ 3.4x faster (DC-only). |
| 2026-06-22 | VP8 lossy encoder (slice 8c-2) lossy+alpha via the `ALPH` chunk | `encodeStaticLossy` encodes the straight (non-premultiplied) alpha plane into an `ALPH` chunk and emits a `VP8X`+`ALPH`+`VP8 ` container; a fully-opaque input still emits a plain `VP8 ` file byte-identical to the color-only path. Alpha is lossless: the plane is row-filtered (best of none/H/V/gradient) and stored as the cheaper of uncompressed or a headerless VP8L stream (`src/alpha.zig` `encodePlaneAlloc`, reusing the step-7 encoder's new `encodeImageStreamAlloc`), the exact inverse of `alpha.zig` decode; `encode_options.alpha_quality` selects 0 = uncompressed / 1..100 = lossless VP8L. Round-trip (CI gate, `zig build test`): the synth RGBA alpha cases (ramp, binary checker, transparent-over-nonzero-RGB) recover the alpha plane byte-exactly through `decodeStatic`; fully-opaque output is asserted byte-identical to the `VP8 `-only path. Validity: locally `dwebp -pam` recovers alpha byte-for-byte on the re-encoded libwebp alpha fixtures (all four filters + the color-cache fixture), and `compare-encode-lossy` is 0/135 invalid. Note: the `compare-encode-lossy` *size* ratio is now skewed (aggregate ~1.98x) because our output carries `ALPH` alpha while its `cwebp -q -noalpha` baseline strips it — validity is the gate; a fair alpha-vs-alpha size comparison needs an alpha-carrying `cwebp` baseline (a tooling follow-up). |
| 2026-06-22 | VP8 lossy encoder (slice 8c-3) target-size / target-PSNR modes | `EncoderOptions.target_size` (bytes) and `target_psnr` (dB) drive a bounded (≤8-probe, `search_passes_max`) binary search over the quantizer index, re-encoding each probe and keeping the closest-to-target candidate; both unset → byte-identical to the single-pass quality path (asserted at q0/25/50/75/100), both set → `error.InvalidEncodeOptions`. target-PSNR measures full-range BT.601 luma PSNR of the reconstruction (the metric `cwebp` reports). Alpha rides through the search unchanged: the `ALPH` payload is encoded once and reused across probes. Gates (CI `zig build test`, 345/345 pass; `dwebp` `compare-encode-lossy` 0/135 invalid): on the 4 photos target-size lands 0.32–2.83% off (step-8c gate ≤5%), target-PSNR 38.0 dB → 38.01–38.08 dB achieved; a new test confirms target-size on an alpha source still recovers alpha byte-exactly. **This slice carries the step-8c target-size gate and completes the VP8 lossy encoder.** |
| 2026-06-22 | VP8 lossy encoder (slice 8c-4) sharp (iterative) RGB→YUV chroma | Adds `color.rgbaToYuv420SharpAlloc`, selected by `encodeStaticLossy` when `encode_options.use_sharp_yuv` is set; the default (false) box-average path is byte-identical to before (asserted). Sharp starts from the box grid and runs a bounded 4-pass integer Gauss–Seidel refinement that minimizes, per chroma cell, the residual between the full-resolution chroma target (`rgbToU`/`rgbToV`) and what the decoder's fancy upsampler reconstructs over that cell (a closed-form 9:3:3:1 diamond matching `upsampleFancy`, gated by test); luma is left at full resolution. Self-consistency holds (sharp changes only the source chroma, not the encoder-vs-decoder equivalence). Validity: locally `dwebp` 1.5.0 decodes all 4 sharp photo outputs; `compare-encode-lossy` 0/135 invalid. Quality (reported): on an isolated saturated red/blue color edge the converter gains +2.20 dB RGB PSNR at matched size (13.89 → 16.09); end-to-end (encode q75 → decode, sharp vs box) RGB PSNR +0.55–1.36 dB on signage/foliage/sky and −0.03 dB on portrait — but at matched *quality*, so sharp preserves more chroma detail and the outputs run slightly larger (a matched-size comparison would narrow the gain to roughly the isolated-converter figure). Merged, briefly reverted (#66), and re-applied (#67) during integration; net result is in `main`. |
| 2026-06-23 | Animation container mux (slice 9a) accepted by `webpinfo`/`webpmux`/`anim_dump` | New `mux.encodeAnimation` (public `encodeAnimation`) assembles already-encoded frame bitstreams into an animated WebP: `VP8X` (animation flag + canvas) → optional `ICCP` → `ANIM` (background + loop count) → one `ANMF` per frame (16-byte frame header + optional lossy `ALPH` + `VP8 `/`VP8L`) → optional `EXIF`/`XMP `. It does not encode pixels — `AnimationImage`/`AnimationFrameImage` carry the bitstreams, the animated analogue of `StaticImage`/`encodeStatic`. Every frame's rectangle (inside the canvas, even offsets), codec, bitstream dimensions, and alpha are validated, and the `VP8X` alpha flag is set iff any frame carries alpha — the same constraints `demux` enforces on read, so a muxed animation always round-trips. Round-trip (CI gate, `zig build test`, 365/365 pass): 12 new tests mux multi-frame lossy+lossless animations and parse them back through `demux` (rects, durations, blend/dispose, loop count, background, metadata), cover the validation errors (odd offset, lossless+`ALPH`, rect outside canvas, dimension mismatch, empty list) and the frame-count limit, and survive allocation failure at every site. Validity (local, libwebp 1.5.0): a 32×32 two-frame animation built from real library-encoded frames (lossless full-canvas + lossy 16×16 sub-rect with background dispose) is accepted by `webpinfo` ("No error detected"), listed correctly by `webpmux -info`, and decoded to per-frame PNGs by `anim_dump`. This is the step-9 container layer; pixel-level `encodeAnimation` from buffers (and the `anim_dump`-matches-our-composition gate) is slice 9b. |
| 2026-06-23 | Still-encode metadata (slice 9d) round-trips through `demux`; samples validate under `webpinfo` | `EncoderOptions` gained `metadata: metadata.RawPayloads = .{}`, threaded into the `mux.encodeStatic` calls in `encodeStaticLossless`/`encodeStaticLossy` (the latter via `encodeLossyPass`, so it rides every target-size/PSNR probe). The public still encoders (`encodeLossless`/`encodeLossy`) can now attach raw `ICCP`/`EXIF`/`XMP ` (the mux already wrote them; this closes the from-pixels API gap). Present metadata forces the extended (`VP8X`) container; the chunks emit in spec-canonical order (`VP8X` → `ICCP` → (`ALPH`) → `VP8(L)` → `EXIF` → `XMP `) and coexist with a lossy `ALPH`. `options.zig` imports `metadata.zig`, which imports only `container.zig` — no import cycle. Round-trip (CI gate, `zig build test`, 370/370 pass): 5 new tests assert lossless and lossy both recover ICCP+EXIF+XMP byte-exactly through `demux` with chunks in spec order; a lossy+alpha+metadata case keeps `ALPH`+metadata in canonical order and round-trips alpha exactly; the empty-metadata lossless path is byte-identical to a direct simple-`VP8L` mux (the lossy empty-metadata path stays covered by the existing 8c-3 byte-identical test); and allocation-failure-at-every-site holds for both encoders with metadata present. Chunk-order honesty: the from-pixels path emits canonical order (no caller-specified order to preserve); the `mux.encodeStaticFromDemux` remux path preserves unknown-chunk order. Browser-render gate set up, not closed: three samples (metadata-bearing lossless still, lossy still, and a 2-frame lossless animation with XMP via in-main `mux.encodeAnimation`) validate under `webpinfo` ("No error detected", ICCP/EXIF/XMP/Animation flags set, chunks in spec order); the ≥2-browser manual check is deferred to once 9c lands frame-optimized animations and is not in CI. |
| 2026-06-23 | Pixel-level animation encode (slice 9b) `anim_dump` matches our composition | New `animation_encode.encodeAnimationFromBuffers` (public `encodeAnimationFromBuffers`) encodes a caller-supplied ordered list of pixel-buffer frames into an animated WebP — the animated analogue of `encodeLossy`/`encodeLossless`. Each `FrameSource` (an `image.Buffer` + even canvas offset + duration + blend/dispose + lossy/lossless codec) is encoded by reusing the still machinery (`encode.gatherArgbAlloc`, then `vp8l_encoder.encodeAlloc` for lossless, or `color.rgbaToYuv420Alloc` + `vp8_encoder.encodeAlloc` + `alpha.encodePlaneAlloc` for lossy+alpha) and muxed via slice 9a; the caller dictates each frame's rectangle/blend/dispose (inter-frame optimization is 9c). Round-trip (**CI gate, `zig build test`, 378/378 pass, +13 new**): an all-lossless full-canvas-keyframe animation composites back **byte-for-byte** to its source frames via `decodeAnimationAlloc`; further tests cover a lossy frame (right dims), a lossless sub-rect over a keyframe, a lossless and a lossy+alpha frame (alpha recovered exactly), per-frame blend/dispose (background-dispose clears a sub-rect for the next frame), loop count + background + metadata round-trip, the input errors (empty list, odd offset, rect outside canvas) and the frame-count limit, and survive allocation failure at every site over a mixed lossless + lossy-alpha animation. **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim` — `anim_dump` of four generated animations (lossless full-canvas, lossless sub-rect with background-dispose, lossy full-canvas, mixed lossless + lossy-alpha with alpha-blend) matches this library's own composition byte-for-byte across all 8 frames (compared=4, failed=0), and `webpinfo` reports "No error detected" for all four.** This carries the step-9 pixel-path gate; sub-rectangle/differencing optimization (9c) remains. |
| 2026-06-23 | Animation frame optimization (slice 9c) byte-exact lossless round-trip + `anim_dump` parity; ≈8% lossless reduction vs naive | New `animation_optimize.encodeAnimationMinimized` (public `encodeAnimationMinimized`, module `src/animation_optimize.zig`) takes full-canvas frames + timing + per-frame codec and auto-derives a minimal `ANMF` layout that composites back to exactly those frames: **sub-rectangle detection** (minimal bounding box vs the decoder's reconstructed previous canvas, even-snapped), **inter-frame differencing + blend strategy** (equal-to-prev pixels made transparent under `alpha_blend` when it provably reconstructs exactly — every changed pixel fully opaque — else verbatim `replace`), **dispose** (one-frame lookahead picks background when it shrinks the next diff rect), and **keyframe insertion** (frame 0, any full-canvas change, bounded `keyframe_interval`). Reuses the 9b per-frame encoder via one narrow hook (`encodeFrameForOptimizer`) and the 9a mux. Correctness key: the optimizer tracks the decoder's **reconstructed** canvas — re-decoding each frame it emits and compositing with the exact `animation_decode` rules (transparent-RGB zeroing, source-over non-premultiplied blend, previous background-disposed-rect skip) — so lossy error never accumulates. **CI hard gate (byte-exact lossless round-trip), `zig build test`, 394/394 pass, +11 new:** all-lossless minimized animations decode byte-for-byte back to the input canvases across a static-background-with-moving-sub-region (asserted via `demux` to actually shrink at least one `ANMF` rect below the canvas), a degenerate identical frame (1×1 rect), a full-canvas change (forced keyframe), a transparency-reveal (replace fallback), a blend+dispose multi-frame sequence, and a forced keyframe interval (frames 0/2/4 full-canvas at interval 2); a lossy minimized animation decodes at the right dims; allocation failure survived at every site. **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim`** on two minimized 96×64 6-frame samples (`testdata/animation/anim_minimized_lossless.webp`, `testdata/animation/anim_minimized_lossy.webp`) — `anim_dump` matches this library's composition byte-for-byte across all 6 frames each (compared=2, failed=0), and `webpinfo` reports "No error detected" for both. **Compression (reported, not gated):** minimized lossless 3840 B vs naive `encodeAnimationFromBuffers` 4174 B (8.0% smaller, sub-rect frames 28×28/28×40); minimized lossy byte-identical to naive (7942 B, 0%) — VP8 reconstruction differs almost everywhere so the exact diff rect is full-canvas every frame, a deliberate correctness-first choice (libwebp's quality-tolerance lossy shrink is future work). Step 9 is now feature-complete; the ≥2-browser render check is set up (the two `testdata/animation/`) but manual and not in CI. |
| 2026-06-23 | Lossy animation frame optimization (slice 9c-2) shrinks lossy sub-rects, PSNR within tolerance of naive, ≈48% smaller | Extends `animation_optimize.encodeAnimationMinimized` so **lossy** frames are inter-frame optimized instead of emitted as full-canvas keyframes. The change rect is now detected against a **source-quality carryover** canvas (the original input pixels carried frame to frame, dispose clears applied — mirroring libwebp's `canvas_carryover`), not the noisy reconstruction, so VP8 noise (which 9c's exact diff flagged almost everywhere → full-canvas every frame) no longer inflates the rect. A pixel counts as unchanged via a per-channel content-change tolerance `T` (libwebp's `PixelsAreSimilar`: alpha must match, each RGB channel diff alpha-weighted ≤ `T·255`). New `AnimationMinimizeOptions.tolerance: ?u8 = null` defaults to a quality-derived value (`qualityToMaxDiff`, libwebp's `QualityToMaxDiff`: 31 at q=0, ≈5 at q=75, 1 at q=100); lossless frames force `T = 0` (exact) with a carryover equal to the reconstruction, so the byte-exact lossless path is **unchanged**. The blend/transparent path stays lossless-only (lossy sub-rects are always verbatim `replace`); inherited regions come from the previous decoded frame and drift is bounded by `keyframe_interval`. **CI gates, `zig build test`, 398/398 pass, +4 new:** the 9c all-lossless byte-exact round-trips still pass unchanged (hard lossless gate); a lossy 64×48 5-frame moving-region animation shrinks ≥1 `ANMF` rect below the canvas (asserted via `demux`) and decodes valid; the optimized lossy mean luma PSNR (`src/testing/metrics.zig`, vs the source) stays within **0.5 dB** of the naive `encodeAnimationFromBuffers` full-canvas encode and the optimized stream is strictly smaller; `qualityToMaxDiff`/`pixelsSimilar` unit-checked at reference points; allocation failure survived at every site (now three carryover buffers). **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim`** on a generated 96×64 8-frame lossy minimized sample — `anim_dump` matches this library's composition byte-for-byte across all 8 frames (compared=1, failed=0), and `webpinfo` reports "No error detected" (frame 0 a full-canvas keyframe, frames 1–7 shrunk to 22×22 sub-rects). **Compression (reported):** lossy minimized **1390 B vs naive 2680 B (48.1% smaller)** at q=75, mean luma PSNR **45.96 vs 45.82 dB (+0.14 dB, not a loss** — the inherited gradient is quantized once at the keyframe rather than re-noised each frame). Tolerance chosen: ≤0.5 dB below naive, justified because the only quality difference is inherited (non-rect) regions carrying the previous frame's lossy values; the measured delta is comfortably positive. Closes 9c's "lossy = full-canvas keyframes, future work" caveat. |
| 2026-06-26 | Performance baseline (slice 10a) via new `zig build bench`; scalar decode/encode throughput + same-machine libwebp ratio | New `tools/zig-webp-bench.zig` (`zig build bench`) times the public `decodeStatic`/`decodeAnimation`/`encodeLossless`/`encodeLossy` entry points **in memory** (no file I/O), reporting the median of repeated timed runs (via the `std.Io` monotonic clock) with a per-measurement time budget, over `testdata/` asset classes (decode: icon/photo/large/alpha/animation; encode: synthetic matrix + 4 CC0 photos). No codec change — pure measurement; correctness stays with `zig build test` (committed-hash regression + encoder self-consistency), which the harness assumes. An optional `tools/webp-bench.sh` times `dwebp`/`cwebp` over the same files (graceful SKIP when absent, never a build dependency). **Baseline (ReleaseFast, 13th Gen Intel Core i5-13450HX, single thread, libwebp 1.5.0; 213 rows):** decode pixel-weighted aggregate ≈39 MP/s lossy, ≈28 MP/s lossless. Same-machine vs single-threaded `dwebp` (our min ÷ `dwebp` min; `dwebp` also formats PAM output, so indicative not exact): lossy `bryce` 11158×2156 **2.5×**, `lossy_extreme` 800×534 **2.0×**; lossless `lossless_big_random_alpha` 2048² **1.8×**, `lossless_color_transform` 512² **2.8×**, `photo_foliage` 512×342 (lossless) **5.6×**. Encode vs `cwebp` on `photo_foliage`: lossless 125 ms vs 88 ms (**1.4×**), lossy q75 22 ms vs 12 ms (**1.8×**). Read honestly: lossy decode and large lossless are inside the ≤3× single-threaded scalar target; small/medium VP8L lossless decode (2.8–5.6×) is the miss and the priority for 10b/10c; the encoder is already competitive. Timing is environment-dependent and **not** a CI gate. `zig build test` unchanged; `zig build check` compiles the tool. |

| 2026-06-26 | SIMD YUV→RGB color conversion (slice 10b): 1.11× lossy decode, byte-exact | `@Vector` rewrite of `color.upsampleLinePair`'s interior (fancy chroma upsample + BT.601 conversion), the largest data-parallel hot loop in lossy decode. Each output pair is a stencil over chroma columns `(x-1, x)` with no dependency on prior output, so it vectorizes; an 8-chroma-column (16-pixel) chunk computes the diamond and conversion in `@Vector(16, i32)` lanes and stores a packed-`u32`-per-pixel vector, for the 4-channel formats on little-endian. The scalar path is unchanged and remains the reference for boundaries, odd-width tail, `rgb`, and big-endian. **Bit-exact (CI gate, `zig build test`):** the committed corpus-hash regression (88 lossy stills → byte-for-byte vs libwebp-correct hashes, most at SIMD widths) still passes, plus a new non-circular equivalence test (wide-image `.rgb` scalar output == `.rgba` SIMD output for R/G/B). **Speed (local, thermal-controlled interleaved A/B vs `main`, ReleaseFast, i5-13450HX, single thread):** aggregate lossy decode **1.11×** (763.6→690.2 ms over the lossy corpus), up to **1.31×** on conversion-heavy files and ~1.2× on lossy+alpha; lossless decode unchanged (1.02×, noise — VP8L never calls this path). Reduces the `bryce` lossy-decode ratio vs single-threaded `dwebp` from ≈2.5× to ≈2.3×. Honest note: scalar micro-restructuring of the inverse transforms / IDCT DC fast-path was prototyped and rejected as code-layout noise (those stages aren't the bottleneck); the remaining lossless gap is the serial entropy decoder (already a fast multi-level Huffman table), documented as future work. |

Record new milestones here as dated rows: corpus, file counts, byte-exact or
gate metric, and skips.
