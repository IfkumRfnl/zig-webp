# PROGRESS.MD

Status log for the roadmap in `PLAN.MD`. `PLAN.MD` stays forward-looking
(scope, ordering, acceptance gates); completed scope, dated oracle results,
and the current position are recorded here.

Last updated: 2026-06-12

## Current Position

Steps 0 through 4 are complete for their static scopes. Composing decoded
alpha planes over lossy VP8 color output is folded into step 5 because it
needs the VP8 decoder. Next up is step 5, the VP8 lossy decoder, preceded by
the near-term fuzzing and CI items listed in `PLAN.MD`.

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

Record new milestones here as dated rows: corpus, file counts, byte-exact or
gate metric, and skips.
