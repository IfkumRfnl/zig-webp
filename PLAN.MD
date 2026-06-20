# PLAN.MD

This project aims to become a production-ready, high-quality, pure Zig WebP
encoder and decoder with no runtime or package dependencies.

The practical path is not to port `libwebp` wholesale. `libwebp` remains the
behavior oracle, while smaller independent implementations and the specs guide
module shape, test strategy, and edge-case coverage.

This document is forward-looking: goals, scope boundaries, ordering, and
acceptance gates. Completed work, dated oracle results, and the current
position live in `PROGRESS.MD`.

## Goals and Non-Goals

Goals:

- Full static decode: VP8 lossy, VP8L lossless, and alpha.
- Animated decode with frame iteration and composited output.
- VP8L lossless encode, VP8 lossy encode, and animation/metadata encode.
- Safe-by-default handling of untrusted input with explicit resource limits.
- A Zig-native public API with caller-controlled allocation.

Non-goals, explicitly out of scope unless deliberately revisited:

- Streaming or incremental decode of partial files. The API takes complete
  input buffers.
- VP8 features WebP forbids or never uses: inter-frame prediction,
  golden/altref frames, and non-key-frame decode.
- Applying ICC color management. Profiles are exposed as raw chunks; color
  transformation is the caller's concern.
- A C ABI or bindings layer before the Zig API stabilizes.

Portability and threading stance: development and CI test little-endian
64-bit targets. Code must not assume host endianness, but big-endian targets
remain untested until CI covers one. The library is thread-compatible: no
global mutable state, so distinct decode/encode jobs may run on distinct
threads. Internal parallelism is deferred to step 10.

## Toolchain Policy

The package pins `minimum_zig_version` (currently 0.16.0) in `build.zig.zon`
and tracks the latest stable Zig release. Compiler upgrades land as dedicated
commits that pass `zig build test` plus a full local corpus run, so toolchain
churn never mixes with codec changes. Zig is the project's one moving
dependency; treat upgrades with the same care as code changes.

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
- Demand bit-exactness wherever the spec defines exact output: VP8L ARGB
  pixels, VP8 YUV reconstruction, and alpha planes are compared byte-for-byte
  against `libwebp`. Numeric tolerances are reserved for layers that are
  genuinely implementation-defined (such as YUV-to-RGB conversion variants),
  and each such layer must document why exactness does not apply.
- Avoid copying reference code. Use specs and independent tests to write Zig
  implementations.

## Cross-Cutting Practices

These run continuously from now on rather than as scheduled steps.

- Fuzzing starts now, not at the end. Demux, VP8L decode, and alpha decode
  are already public entry points and get fuzz smoke targets before VP8
  decoder work begins. Every new decode entry point lands with a fuzz target
  in the same change. Fuzz findings become committed regression tests.
- CI runs on every pull request: `zig fmt --check .`, `zig build test`, and a
  corpus regression mode that compares decoded output against committed
  SHA-256 hashes of known-good planes, so CI does not require `dwebp`. Full
  `dwebp`/`cwebp` differential runs remain available locally (and later in
  CI by building `libwebp` tools) via `tools/webp-oracle.sh`.
- Every decoder or encoder milestone records a dated, corpus-wide oracle
  result in `PROGRESS.MD`: corpus, file counts, byte-exact or gate metric,
  and skips.

## Proposed Module Layout

Files marked `(planned: …)` do not exist yet; every other path is on disk
today. Run `find src -name '*.zig' | sort` for the live tree.

```text
src/root.zig
src/container.zig
src/demux.zig
src/mux.zig
src/features.zig
src/image.zig
src/vp8l/pixel.zig
src/color.zig
src/bit_reader.zig
src/bit_writer.zig
src/alpha.zig
src/animation.zig
src/animation_decode.zig
src/metadata.zig
src/options.zig
src/limits.zig
src/errors.zig
src/decode.zig
src/vp8/bool_reader.zig
src/vp8/bool_writer.zig
src/vp8/decoder.zig
src/vp8/encoder.zig        (planned: step 8)
src/vp8/frame_header.zig
src/vp8/modes.zig
src/vp8/prediction.zig
src/vp8/transform.zig
src/vp8/loop_filter.zig
src/vp8/quant.zig
src/vp8/tokens.zig
src/vp8/token_probs.zig
src/vp8l/decoder.zig
src/vp8l/encoder.zig       (planned: step 7)
src/vp8l/huffman.zig
src/vp8l/lz77.zig          (planned: step 7)
src/vp8l/transform.zig
src/vp8l/inverse_transform.zig
src/vp8l/color_cache.zig
src/vp8l/entropy.zig
src/vp8l/header.zig
src/vp8l/image_data.zig
src/vp8l/meta_prefix.zig
src/vp8l/prefix_groups.zig
src/testing.zig
src/testing/corpus.zig
src/testing/fuzz.zig
src/testing/metrics.zig    (planned: step 10)
```

Fuzz targets live alongside the tests of the module they exercise, using
Zig's built-in fuzzer, so fuzz coverage moves with the code it protects.

The exact names can change, but the ownership boundaries should remain. A
container parser must not know how VP8 macroblocks work. A VP8L Huffman builder
must not know how RIFF chunks are ordered. Animation compositing must not own
single-frame codec internals.

## Implementation Order

### 0–5. Completed Foundations

Step 0 (project foundation), step 1 (RIFF/WebP container), step 2 (core
bitstream infrastructure), step 3 (VP8L lossless decoder), step 4 (alpha
chunk decode), and step 5 (VP8 lossy decoder, including alpha composition over
lossy color and the lossy path through the public `decodeStatic`) are complete
for their static scopes. See `PROGRESS.MD` for what each delivered, the dated
corpus results, and the step 5 acceptance gate. The step 5 spec below is
retained as the record of that gate.

### 5. VP8 Lossy Decoder

VP8 reconstruction is exactly specified: RFC 6386 fixes the boolean decoder,
dequantization, intra prediction, inverse DCT/WHT, and loop filter to the
bit. Only YUV-to-RGB conversion is implementation-defined. Build and validate
the decoder in two layers so exactness is never blurred by conversion
choices.

Reconstruction layer (bit-exact, no tolerances):

- Parse WebP's VP8 key-frame payloads and reject non-key-frame states WebP
  forbids.
- Implement frame header parsing, segmentation, quantization, coefficient
  probability updates, token partitions, macroblock modes, and skip flags.
- Implement intra prediction for luma and chroma modes.
- Implement inverse DCT and WHT using exact integer rules.
- Implement normal and simple loop filters.
- Add a `compare-yuv` oracle mode (mirroring the alpha tooling) that diffs
  decoded YUV420 planes byte-for-byte against `dwebp -yuv` for every lossy
  corpus file. Any mismatch is a bug, never a tolerance.

Conversion layer (separately tested):

- Implement YUV420-to-RGB conversion and chroma upsampling as its own module
  with explicit mode options; the mode mirroring `libwebp`'s default fancy
  upsampling is validated against `dwebp -pam` output for that mode.
- Compose decoded alpha planes over lossy color and validate VP8X alpha flag
  rules (the remainder of step 4).

Acceptance gate: byte-exact YUV planes against `dwebp -yuv` for all lossy
files in `libwebp-test-data` plus a generated `cwebp` corpus, and byte-exact
RGBA against `dwebp -pam` in the matching upsampling mode, including
lossy+alpha files.

### 6. Extended Decode and Animation

- Enforce `VP8X` feature flags and extended chunk ordering rules.
- Decode animated WebP: `ANIM`, `ANMF`, frame rectangles, frame durations,
  dispose methods, blend methods, background color, and loop count.
- Reuse the static VP8/VP8L/alpha decoders per frame.
- Provide both frame iteration and fully composited output APIs.
- Preserve metadata extraction for still and animated files.

Acceptance gate: composited animation frames match `libwebp`'s `anim_dump`
output byte-for-byte on the animated corpus files, and all static and
animated decode features are usable from the public API.

### 7. VP8L Lossless Encoder

Start with correctness and valid output, then improve compression.

- Implement RIFF/VP8L muxing for still images.
- Implement VP8L bit writer, canonical Huffman writer, and basic literal
  output.
- Add simple LZ77 matches and distance mapping.
- Add subtract-green transform.
- Add palette/color-indexing transform for low-color images.
- Add predictor and color transforms.
- Add entropy image / multiple Huffman groups after the single-group encoder
  is stable.
- Add optional color cache and near-lossless preprocessing.

Acceptance gates, measured on a defined encode corpus (the decoded ARGB of
all VP8L files in `libwebp-test-data` plus the `libwebp` gallery images):

- Validity: 100% of encoded files decode without error by both `dwebp` and
  this library, and round-trip bit-exactly to the source pixels.
- Size: median compressed size at most 1.10x `cwebp -lossless` at default
  settings, recorded per file. The PNG comparison is reported, not gated:
  measure against a named PNG encoder at stated settings (stock `libpng`
  defaults, plus `oxipng -o 2` where available) on the same pixels.

### 8. VP8 Lossy Encoder

This is the largest single work item in the project: expect it to cost
roughly as much as steps 0 through 7 combined. It must not start until the
VP8 decoder, bit writers, muxer, and lossless encoder are solid, and it is
planned, built, and reviewed as three separately gated phases.

#### 8a. Valid-bitstream baseline

- Implement RGB/RGBA to YUV420 conversion, including exact transparent-RGB
  handling.
- Implement forward DCT/WHT, quantization, coefficient coding, and boolean
  arithmetic output, with a deliberately simple fixed mode decision.
- Gate: every encoded corpus image decodes without error by both `dwebp` and
  this library, and this library's decoder reproduces the encoder's own
  reconstruction bit-for-bit at the YUV layer.

#### 8b. Quality

- Implement real macroblock mode decision with rate-distortion scoring,
  segmentation, skip decisions, token cost estimation, and loop filter
  selection.
- Gate: at matched output size on the photo corpus, mean luma PSNR within
  1.0 dB of `cwebp -q 75 -m 4`. This threshold is an initial target; revise
  it only with recorded data and rationale, per the honest-benchmarking
  rules in `AGENTS.md`.

#### 8c. Controls and parity features

- Add method/quality presets compatible with `cwebp` concepts.
- Add target-size and target-PSNR modes after regular quality mode is stable.
- Add sharp-YUV or equivalent high-quality chroma conversion.
- Add alpha encoding via `ALPH` for lossy+alpha output.
- Gate: the preset matrix encodes the corpus without validity regressions,
  and target-size mode lands within 5% of the requested size.

### 9. Animation and Metadata Encode

- Encode `VP8X`, `ANIM`, and `ANMF`.
- Support lossless and lossy frame codecs.
- Implement sub-rectangle detection, frame differencing, blend/dispose
  strategy, keyframe insertion, loop count, and background color.
- Encode raw metadata chunks and preserve user-specified chunk order where
  the spec permits it.

Acceptance gate: encoded animations are accepted by `webpmux` and
`webpinfo`, decode through `libwebp`'s `anim_dump` to frames matching this
library's own composition, and render in at least two major browsers.

### 10. Performance Work

- Establish scalar baselines before optimizing.
- Benchmark decode and encode separately for small icons, photos, alpha-heavy
  UI assets, large images, and animations.
- Working targets, revised only with recorded data: scalar decode within 3x
  single-threaded `libwebp` on the benchmark set, within 1.5x after Zig
  vector work. Encode targets are set once 8b lands and quality/speed
  tradeoffs are measurable.
- Add cache-aware hot loops for transforms, prediction, color conversion, and
  filters.
- Add optional Zig vectorized implementations behind clean module boundaries.
- Consider row or tile parallelism only after deterministic scalar behavior
  is locked down.

Deliverable: dated performance reports against `libwebp`, `image-webp`, and
selected pure-Go references, following the honest-benchmarking rules in
`AGENTS.md`.

### 11. Robustness Hardening

Fuzzing and limits checks run continuously (see Cross-Cutting Practices);
this step deepens them to release depth.

- Grow fuzz corpora from corpus seeds and accumulated findings; give CI a
  fixed fuzz time budget per target: demux, VP8L decode, VP8 decode, alpha
  decode, animation composition, and encoder round trips.
- Add allocation-failure injection tests around every public entry point.
- Add limits tests for huge dimensions, oversized chunks, invalid distances,
  invalid Huffman trees, recursive VP8L transforms, and animation frame
  counts.
- Keep all loops bounded by parsed dimensions, chunk sizes, or explicit
  limits.
- Ensure malicious inputs fail with errors, not panics or unbounded
  allocation.

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
- Document pixel formats, ownership, allocation behavior, and error
  semantics.
- Require `zig build test`, hash-based corpus regression, encoder validity
  gates, and fuzz smoke budgets in CI.
- Release `0.1.0` only after the step 5 decode gate and the step 7 validity
  and size gates hold in CI.
- Release `1.0.0` only after the 8b and 8c gates, animation encode, metadata,
  hardening, docs, and compatibility testing are all met.

## Near-Term Work Items

Steps 0 through 7 are complete and the VP8 lossy encoder (step 8) is underway.
Step 7 (VP8L lossless encoder) met both gates: every encode-corpus image
round-trips bit-exactly and the median compressed size is 1.04x
`cwebp -lossless` (see `PROGRESS.MD`). Its optional near-lossless preprocessing
was not implemented — it is a quality refinement, not a gate — and remains
available as future work.

Step 8a (the valid-bitstream baseline) is delivered: `src/vp8/encoder.zig` emits
a `VP8 ` key frame with a fixed all-DC mode decision on top of forward RGB→YUV420
conversion, forward DCT/WHT, forward quantization, and coefficient token coding.
Every encode-corpus image decodes without error through both this library's
decoder and `dwebp`, and the decoder reproduces the encoder's own reconstruction
bit-for-bit at the YUV layer (the step 8a gate; see `PROGRESS.MD` and the
2026-06-19 oracle row).

Step 8b (quality) is broken into reviewable slices so the encoder stays
auditable:

1. **8b-1 (delivered).** Real per-macroblock intra mode selection for the 16x16
   luma modes and the shared 8x8 chroma mode (DC/V/H/TM), scored by a
   rate-distortion metric (reconstruction SSE plus a quantizer-scaled
   coded-coefficient penalty). The self-consistency and `dwebp` validity gates
   still hold and every photo improves in both PSNR and size over 8a; see the
   2026-06-20 oracle row.
2. **8b-2 (delivered).** B_PRED (per-subblock 4x4 luma intra) with proper VP8
   token-cost estimation so the 16x16-vs-B_PRED choice is rate-accurate.
   Delivered in two slices: **8b-2a** — a token bit-cost model (`src/vp8/cost.zig`,
   `tokens.blockCost`) replacing the nonzero-count rate proxy; and **8b-2b** —
   B_PRED itself, scored against the 16x16 modes with that cost model
   (+1.5 dB at −6.6% bytes on the photo corpus; 2026-06-20 oracle rows).
3. **8b-3 (next).** Add segmentation, skip decisions, and loop-filter level
   selection, gating on the matched-size luma-PSNR target in step 8b above.
4. Then step 8c: method/quality presets, target-size and target-PSNR modes,
   sharp-YUV chroma, and alpha (`ALPH`) encoding for lossy+alpha output.

This order keeps early work testable and prevents the project from becoming
one large codec file that is difficult to audit or optimize.
