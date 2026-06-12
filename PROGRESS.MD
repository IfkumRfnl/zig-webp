# PROGRESS.MD

Status log for the roadmap in `PLAN.MD`. `PLAN.MD` stays forward-looking
(scope, ordering, acceptance gates); completed scope, dated oracle results,
and the current position are recorded here.

Last updated: 2026-06-12

## Current Position

Steps 0 through 4 are complete for their static scopes. Composing decoded
alpha planes over lossy VP8 color output is folded into step 5 because it
needs the VP8 decoder. Step 5 reconstruction has started: key-frame header
parsing is in place (see below). The near-term fuzzing and CI items listed
in `PLAN.MD` remain open and should land before reconstruction goes deeper.

## Cross-Cutting Practices

CI runs on every pull request and push to main
(`.github/workflows/ci.yml`): `zig fmt --check .` and `zig build test` on
Zig 0.16.0. The test suite includes a hash-based corpus regression
(`src/testing/corpus.zig`): decoded RGBA planes of all 43 still lossless
files and decoded alpha planes of all 18 ALPH-bearing files (61 rows) are
compared against committed SHA-256 hashes in `testdata/corpus-hashes.tsv`,
so CI needs no `dwebp`. The hashes lock the decoded planes that matched
`dwebp` byte-for-byte in the dated oracle runs below; regenerate with
`zig build corpus-hashes` only after a fresh corpus-wide oracle run.

Fuzz smoke targets are in place for every public decode entry point: strict
demux (`src/demux.zig`), VP8L still-image decode (`src/vp8l/decoder.zig`),
alpha plane decode (`src/alpha.zig`), VP8 key-frame header parsing
(`src/vp8/frame_header.zig`), VP8 macroblock prediction record parsing
(`src/vp8/modes.zig`), and the public static decode composition
(`src/decode.zig`). Each target uses `std.testing.fuzz` with a valid corpus
seed (framed via `src/testing/fuzz.zig` so seeds reach the parser
byte-for-byte) and runs under plain `zig build test` as a corpus +
empty-input smoke pass with leak detection. Coverage-guided runs via
`zig build test --fuzz` are currently blocked by an upstream Zig 0.16.0
bug: the bundled `lib/compiler/test_runner.zig` fails to compile under fuzz
instrumentation (`*builtin.StackTrace` vs `*debug.StackTrace` mismatch).
Revisit when the toolchain updates.

## In Progress

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
(`--nofilter` only until the loop filter lands) and the
`compare-yuv-nofilter` / `compare-yuv-nofilter-corpus` oracle modes mirror
the alpha tooling.

Not yet started: loop filtering (next), the plain `compare-yuv` gate,
YUV-to-RGB conversion, and alpha composition over lossy color.

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

Record new milestones here as dated rows: corpus, file counts, byte-exact or
gate metric, and skips.
