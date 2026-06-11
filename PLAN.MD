# PLAN.MD

This project aims to become a production-ready, high-quality, pure Zig WebP
encoder and decoder with no runtime or package dependencies.

The practical path is not to port `libwebp` wholesale. `libwebp` remains the
behavior oracle, while smaller independent implementations and the specs guide
module shape, test strategy, and edge-case coverage.

## Progress

Last updated: 2026-06-11

- Step 0, Project Foundation: done.
  Package-level API types, resource limits, corpus helpers, current
  `zig build test` coverage, and optional local oracle tooling are in place.
- Step 1, RIFF/WebP Container: done for static container scope.
  Strict demux covers RIFF sizing, padding, chunk order, duplicate chunks,
  unknown chunks, trailing data, simple `VP8 `/`VP8L`, `VP8X` feature probing,
  raw metadata exposure, and chunk locations. Static mux/remux writes valid
  canonical chunk ordering and preserves metadata payloads.
- Step 2, Core Bitstream Infrastructure: done.
  Bounded little-endian byte readers/writers, LSB-first bit readers/writers,
  VP8L canonical Huffman table construction/lookup, and VP8 boolean arithmetic
  reader/writer are implemented with unit, invalid-input, round-trip, and
  compile-time capacity tests.
- Step 3, VP8L Lossless Decoder: in progress.
  VP8L image header parsing, transform-list parsing and dimension bookkeeping,
  single-prefix-group image-data Huffman parsing, code-length repeat handling,
  color-cache metadata validation, distance mapping, bounded entropy-stream
  scanning, and no-transform single-prefix-group ARGB materialization for
  literals, LZ77 copies, color-cache references, and meta-prefix entropy image
  parsing are implemented with focused tests. Multiple Huffman group storage and
  meta-prefix selection helpers are also in place. Remaining work includes
  wiring multi-group selection into main-image decode, inverse transforms, public
  static decode composition, and differential corpus checks against `dwebp`.

## References

Normative references:

- WebP container: https://developers.google.com/speed/webp/docs/riff_container
- WebP image format RFC: https://www.rfc-editor.org/rfc/rfc9649
- VP8 lossy bitstream: https://www.rfc-editor.org/rfc/rfc6386
- VP8L lossless bitstream:
  https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification

Reference implementations and corpora inspected:

| Local path | Upstream | Role | Notes |
|---|---|---|---|
| `references/libwebp` | `webmproject/libwebp` | Oracle | Official C implementation and tools. Use for differential testing, feature behavior, and encoding quality comparison. Do not copy architecture wholesale. |
| `references/libwebp-test-data` | `webm/libwebp-test-data` | Corpus | Official test vectors. Local clone had 131 `.webp` files and 184 files total. |
| `references/simplewebp` | `MikuAuahDark/simplewebp` | Compact decoder reference | Single-header C decoder, about 5.5k lines. Good for WebP decode flow and VP8L details. No encoder, animation, metadata extraction, or partial decode. |
| `references/image-webp` | `image-rs/image-webp` | Independent full decoder reference | Pure Rust decoder covers simple and extended formats, lossy, lossless, alpha, animation, ICC, EXIF, and XMP. Lossless encoder only. Useful for module boundaries. |
| `references/ffmpeg/libavcodec/webp.c` | `FFmpeg/FFmpeg` | Low-level C decoder reference | Compact C decoder file with mature edge-case handling. License is LGPL, so use only for behavior study and avoid copying code. |
| `references/deepteams-webp` | `deepteams/webp` | Encoder architecture reference | Pure Go implementation claiming lossy, lossless, animation, metadata, and presets. Treat as a recent idea source, not an oracle. |
| `references/skrashevich-go-webp` | `skrashevich/go-webp` | Encoder/test matrix reference | Pure Go implementation with a detailed feature/test matrix. Useful for checklist design and encode/decode coverage. |

The local reference clones live under `references/`. The clone directories are
ignored by git and excluded from the package; only `references/README.MD` is
tracked. Recreate them with:

```sh
mkdir -p references
git clone --depth 1 https://github.com/webmproject/libwebp.git references/libwebp
git clone --depth 1 https://chromium.googlesource.com/webm/libwebp-test-data references/libwebp-test-data
git clone --depth 1 https://github.com/MikuAuahDark/simplewebp.git references/simplewebp
git clone --depth 1 https://github.com/image-rs/image-webp.git references/image-webp
git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git references/ffmpeg
git clone --depth 1 https://github.com/deepteams/webp.git references/deepteams-webp
git clone --depth 1 https://github.com/skrashevich/go-webp.git references/skrashevich-go-webp
```

Do not vendor the reference clone contents into git or the Zig package.

## Design Principles

- Keep the library pure Zig and zero-dependency.
- Treat scalar correctness as the source of truth. SIMD and threading come
  after scalar code is correct and covered.
- Keep format layers separate. RIFF mux/demux, VP8, VP8L, alpha, animation,
  metadata, color conversion, and public API code should be independent modules.
- Prefer small, bounded parsers with explicit memory limits and clear error
  values.
- Use differential tests against `libwebp` for decoded pixels, metadata, muxed
  structure, and encoder output validity.
- Avoid copying reference code. Use specs and independent tests to write Zig
  implementations.

## Proposed Module Layout

```text
src/root.zig
src/container.zig
src/demux.zig
src/mux.zig
src/features.zig
src/image.zig
src/pixel.zig
src/color.zig
src/bit_reader.zig
src/bit_writer.zig
src/alpha.zig
src/animation.zig
src/metadata.zig
src/vp8/bool_reader.zig
src/vp8/bool_writer.zig
src/vp8/decoder.zig
src/vp8/encoder.zig
src/vp8/frame.zig
src/vp8/prediction.zig
src/vp8/transform.zig
src/vp8/loop_filter.zig
src/vp8/quant.zig
src/vp8l/decoder.zig
src/vp8l/encoder.zig
src/vp8l/huffman.zig
src/vp8l/lz77.zig
src/vp8l/transform.zig
src/vp8l/color_cache.zig
src/testing/corpus.zig
src/testing/metrics.zig
```

The exact names can change, but the ownership boundaries should remain. A
container parser must not know how VP8 macroblocks work. A VP8L Huffman builder
must not know how RIFF chunks are ordered. Animation compositing must not own
single-frame codec internals.

## Implementation Order

### 0. Project Foundation

- Add package-level types for decoder options, encoder options, image buffers,
  metadata, animation frames, and error categories.
- Add explicit resource limits: input bytes, output pixels, allocation bytes,
  frame count, animation canvas size, and chunk count.
- Add test helpers for reading corpus files without making the package depend on
  external references.
- Add a local differential-test script that can call `dwebp`, `cwebp`, and
  `webpinfo` when those tools are installed.

Deliverable: `zig build test` covers current container code and a local optional
oracle workflow exists.

### 1. RIFF/WebP Container

- Finish strict RIFF parsing: size fields, padding bytes, chunk order, duplicate
  chunks, unknown chunks, trailing data, and 4 GiB limits.
- Parse simple files containing only `VP8 ` or `VP8L`.
- Parse extended `VP8X` flags and canvas dimensions.
- Parse and expose raw `ICCP`, `EXIF`, and `XMP ` metadata chunks.
- Add a `Features` API for dimensions, format kind, alpha, animation, metadata,
  and chunk locations without full pixel decode.
- Add muxing support for valid chunk ordering and padding.

Deliverable: lossless metadata-preserving demux/mux round trips for static files.

### 2. Core Bitstream Infrastructure

- Implement bounded little-endian byte readers and bit readers.
- Implement canonical Huffman table construction and lookup for VP8L.
- Implement VP8 boolean arithmetic reader and writer as an isolated module.
- Add table-size proofs and compile-time assertions for all static tables.
- Test bit readers/writers independently before using them in codecs.

Deliverable: reusable bitstream modules with unit tests and invalid-input tests.

### 3. VP8L Lossless Decoder

Implement the lossless decoder first because it outputs exact ARGB pixels and is
easier to validate bit-for-bit than lossy reconstruction.

- Parse VP8L signature, dimensions, alpha flag, version, and transform list.
- Decode Huffman groups, meta prefix images, literals, LZ77 backward references,
  distance mapping, and optional color cache references.
- Implement inverse transforms: predictor, color transform, subtract-green, and
  color indexing.
- Validate all dimensions, distances, copy ranges, Huffman code lengths, and
  color-cache sizes before writing output.
- Compare decoded pixels against `dwebp -pam` or `dwebp -ppm` for every VP8L
  file in `libwebp-test-data`.

Deliverable: still-image VP8L decode to RGBA/ARGB with corpus coverage.

### 4. Alpha Chunk Decode

- Parse `ALPH` chunk headers for compression, filtering, and preprocessing.
- Decode raw alpha streams.
- Decode VP8L-compressed alpha streams through the VP8L decoder core.
- Implement alpha filters: none, horizontal, vertical, and gradient.
- Compose alpha with lossy VP8 color output and validate VP8X alpha flag rules.

Deliverable: lossy+alpha and lossless-alpha test vectors decode correctly.

### 5. VP8 Lossy Decoder

- Parse WebP's VP8 key-frame payloads and reject unsupported non-key-frame
  states where WebP forbids them.
- Implement frame header parsing, segmentation, quantization, coefficient
  probability updates, token partitions, macroblock modes, and skip flags.
- Implement intra prediction for luma and chroma modes.
- Implement inverse DCT and WHT using exact integer rules.
- Implement normal and simple loop filters.
- Implement YUV420 to RGB conversion and chroma upsampling with explicit options
  for compatibility and quality.
- Validate against `libwebp-test-data` lossy files and a generated corpus from
  `cwebp`.

Deliverable: static lossy decode with differential pixel tolerances defined.

### 6. Extended Decode and Animation

- Enforce `VP8X` feature flags and extended chunk ordering rules.
- Decode animated WebP: `ANIM`, `ANMF`, frame rectangles, frame durations,
  dispose methods, blend methods, background color, and loop count.
- Reuse the static VP8/VP8L/alpha decoders per frame.
- Provide both frame iteration and fully composited output APIs.
- Preserve metadata extraction for still and animated files.

Deliverable: all static and animated decode features are usable from public API.

### 7. VP8L Lossless Encoder

Start with correctness and valid output, then improve compression.

- Implement RIFF/VP8L muxing for still images.
- Implement VP8L bit writer, canonical Huffman writer, and basic literal output.
- Add simple LZ77 matches and distance mapping.
- Add subtract-green transform.
- Add palette/color-indexing transform for low-color images.
- Add predictor and color transforms.
- Add entropy image / multiple Huffman groups after the single-group encoder is
  stable.
- Add optional color cache and near-lossless preprocessing.
- Differentially validate by decoding produced files with both `zig-webp` and
  `dwebp`.

Deliverable: lossless encoder that beats PNG on common inputs and produces
libwebp-compatible files.

### 8. VP8 Lossy Encoder

This is the hardest part of the project and should not start until the decoder,
bit writers, muxer, and lossless encoder are solid.

- Implement RGB/RGBA to YUV420 conversion, including exact transparent-RGB
  handling.
- Implement DCT/WHT forward transforms, quantization, coefficient coding, and
  boolean arithmetic output.
- Implement baseline macroblock mode decision.
- Implement rate-distortion scoring, segmentation, skip decisions, and loop
  filter selection.
- Add method/quality presets compatible with `cwebp` concepts.
- Add target size and target PSNR modes after regular quality mode is stable.
- Add sharp-YUV or equivalent high-quality chroma conversion.
- Add alpha encoding via `ALPH` for lossy+alpha output.

Deliverable: lossy still-image encoder with acceptable visual quality and
configurable speed/quality tradeoffs.

### 9. Animation and Metadata Encode

- Encode `VP8X`, `ANIM`, and `ANMF`.
- Support lossless and lossy frame codecs.
- Implement sub-rectangle detection, frame differencing, blend/dispose strategy,
  keyframe insertion, loop count, and background color.
- Encode raw metadata chunks and preserve user-specified chunk order where the
  spec permits it.

Deliverable: animated WebP encoding that browsers and `webpmux` accept.

### 10. Performance Work

- Establish scalar baselines before optimizing.
- Benchmark decode and encode separately for small icons, photos, alpha-heavy
  UI assets, large images, and animations.
- Add cache-aware hot loops for transforms, prediction, color conversion, and
  filters.
- Add optional Zig vectorized implementations behind clean module boundaries.
- Consider row or tile parallelism only after deterministic scalar behavior is
  locked down.

Deliverable: performance reports against `libwebp`, `image-webp`, and selected
pure-Go references.

### 11. Robustness and Security

- Add fuzz targets for demux, VP8L decode, VP8 decode, alpha decode, animation
  composition, and encoder round trips.
- Add allocation-failure tests around every public entry point.
- Add limits tests for huge dimensions, oversized chunks, invalid distances,
  invalid Huffman trees, recursive VP8L transforms, and animation frame counts.
- Keep all loops bounded by parsed dimensions, chunk sizes, or explicit limits.
- Ensure malicious inputs fail with errors, not panics or unbounded allocation.

Deliverable: fuzzed, bounded decode and encode paths suitable for untrusted
input.

### 12. Public API and Release Criteria

- Stabilize APIs for:
  - feature probing without full decode;
  - static decode to caller-owned buffers;
  - static encode from typed pixel buffers;
  - animation iteration and composition;
  - metadata extraction and muxing;
  - memory and security limits.
- Document pixel formats, ownership, allocation behavior, and error semantics.
- Require `zig build test`, corpus decode tests, encoder validity tests, and
  fuzz smoke tests in CI.
- Release `0.1.0` only after static VP8/VP8L decode and VP8L encode are stable.
- Release `1.0.0` only after lossy encode, alpha, animation, metadata, fuzzing,
  docs, and compatibility testing are all production-ready.

## Near-Term Work Items

1. Done: start VP8L decode modules against the official lossless-vector scope.
2. Done: parse VP8L signature, dimensions, alpha flag, version, and transform
   list.
3. Done for single-prefix-group scope: decode VP8L code-length and image
   Huffman groups using the shared table builder.
4. Done for single-prefix-group scope: materialize pixels from literals, LZ77
   backward references, distance mapping, and optional color-cache references.
5. In progress: support meta-prefix images and multiple Huffman groups.
   Entropy-image parsing, group-count derivation, and prefix-code group
   storage/selection helpers are done; main-image multi-group decode remains.
6. Next: implement inverse transforms and differential pixel checks against
   `dwebp`.

This order keeps early work testable and prevents the project from becoming one
large codec file that is difficult to audit or optimize.
