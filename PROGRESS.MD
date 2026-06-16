# PROGRESS.MD

Status log for the roadmap in `PLAN.MD`. `PLAN.MD` stays forward-looking
(scope, ordering, acceptance gates); completed scope, dated oracle results,
and the current position are recorded here.

Last updated: 2026-06-16

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

Record new milestones here as dated rows: corpus, file counts, byte-exact or
gate metric, and skips.
