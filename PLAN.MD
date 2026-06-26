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
src/testing/metrics.zig
tools/zig-webp-bench.zig   (step 10 benchmark harness)
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

Status (delivered; see `PROGRESS.MD` for the dated rows). The benchmark harness
(`zig build bench` + `tools/webp-bench.sh`) and a scalar baseline are in place,
and the one large data-parallel decode hot loop — YUV→RGB fancy upsampling +
conversion — is vectorized (`@Vector`), lifting aggregate lossy decode ≈1.11×
byte-exactly. Recorded outcome against the working targets: scalar lossy decode
is **within ≈2.0–2.5× single-threaded `dwebp`** (and ≈2.3× after the SIMD win),
inside the ≤3× target; **lossless decode is the part outside it** (≈1.8× large,
up to ≈5.6× small), and is entropy-bound — its serial Huffman/LZ77 core is
already a fast multi-level table, so closing the gap is fundamentally a
SIMD/maturity difference vs `libwebp` rather than a missing scalar optimization.
The ≤1.5× "after vector work" target is therefore **revised**: it is realistic
for the conversion-dominated lossy path with further SIMD, not for the
serial-entropy lossless path, and is not a release gate. Honest negative results
worth keeping: scalar micro-restructuring of the inverse transforms and an IDCT
DC-only fast path were measured (thermal-controlled A/B) and **rejected** as
code-layout noise; SIMD subtract-green is likewise below the noise floor (small
post-pass vs entropy). Remaining levers, deferred as future work: SIMD loop
filter (the next-largest lossy lever, a high-effort `libwebp`-parity DSP item),
SIMD/restructured entropy decode, row/tile threading (the targets above are
single-threaded), and `image-webp`/pure-Go comparison runs. The `image.zig`
`metrics`/bench tooling and the byte-exact corpus gate make any future
optimization measurable and safe.

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

Steps 0 through 7 are complete and the VP8 lossy encoder (step 8) is now
feature-complete through step 8c.
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
3. **8b-3a (delivered).** Macroblock skip coding (`mb_skip_coeff` for all-zero
   residue, with `prob_skip_false` from the realized skip ratio) and in-loop
   loop-filter level selection from the quantizer (libwebp's default strength),
   the encoder filtering its own reconstruction in place so the self-consistency
   gate still holds. +0.34 dB on the photo corpus at neutral size; `dwebp`
   validity unchanged (0/135 invalid); see the 2026-06-21 oracle row.
4. **8b-3b (delivered).** Segmentation (adaptive per-segment quantization): a
   pre-pass (`src/vp8/segment.zig`) buckets macroblocks into up to four segments
   by luma complexity (1-D k-means) and gives each segment its own quantizer
   delta (finer for busier segments — the SSE-optimal direction), written via
   `frame_header.writeSegmentation` and the per-macroblock segment map. This
   slice carries the step-8b gate: at matched output size on the photo corpus the
   mean luma PSNR is within 1.0 dB of `cwebp -q 75 -m 4` (in fact +0.08 dB,
   beating it; see the 2026-06-21 oracle row). `dwebp` validity unchanged
   (0/135 invalid).
5. **8c (delivered).** Controls and parity features, completing the VP8 lossy
   encoder. An options scaffold (inert `EncoderOptions` knobs + an `EncodeConfig`
   struct, landed first so the slices could be built in parallel) then four
   slices: **8c-1** a `method` (0..6) effort knob scaling the rate-distortion
   search (method 4 byte-identical to 8b; 5–6 currently clamp to 4); **8c-2**
   lossy+alpha via the `ALPH` chunk (lossless alpha, byte-exact round-trip);
   **8c-3** target-size and target-PSNR modes (a bounded quantizer search — this
   slice carries the step-8c ≤5% target-size gate, landing 0.32–2.83% off on the
   photos); and **8c-4** sharp (iterative) RGB→YUV chroma. Each keeps its default
   path byte-identical to 8b and holds `dwebp` validity (0/135 invalid); the
   step-8c gate holds (the method-preset matrix has no validity regression and
   target-size lands within 5%). See the five 2026-06-22 oracle rows in
   `PROGRESS.MD`.

This order keeps early work testable and prevents the project from becoming
one large codec file that is difficult to audit or optimize.

With step 8c delivered, the VP8 lossy encoder is feature-complete, and with 9c
delivered, **step 9 (animation and metadata encode) is now feature-complete**
(9a container mux, 9b pixel-buffer encode, 9c frame optimization, 9d still
metadata), and **step 10 (performance) is now delivered**: a benchmark harness +
scalar baseline and a vectorized YUV→RGB color-conversion decode path (≈1.11×
lossy decode, byte-exact), with the honest findings and revised targets recorded
in the step-10 status above and in `PROGRESS.MD`. The remaining roadmap is step
11 (robustness hardening) and step 12 (public API and release criteria); the
only open step-9 item is the manual ≥2-browser render confirmation, which is set
up (see below) but intentionally not in CI.

Step 9 (animation and metadata encode) is broken into reviewable slices,
mirroring the `encodeStatic` → `encodeLossy` precedent (container layer first,
then pixels, then quality):

1. **9a (delivered).** The animation **container mux**: `mux.encodeAnimation`
   (public `encodeAnimation`) assembles already-encoded frame bitstreams into a
   valid `VP8X`+`ANIM`+`ANMF` animation (optional per-frame `ALPH`, optional
   `ICCP`/`EXIF`/`XMP `), validating every frame against the canvas and the
   container rules. It does not encode pixels. Output round-trips through this
   library's demux and is accepted by `webpinfo`/`webpmux`/`anim_dump` (see
   `PROGRESS.MD` and the 2026-06-23 oracle row).
2. **9b (delivered).** Public `encodeAnimationFromBuffers` from pixel buffers:
   `src/animation_encode.zig` encodes each caller-supplied frame (lossy or
   lossless, with alpha) into a `VP8 `/`VP8L` bitstream — reusing the still
   encode machinery — and muxes them via 9a. The caller dictates each frame's
   rectangle (full-canvas or sub-rect), blend, and dispose. Carries the step-9
   gate that `anim_dump` of the output matches this library's own
   `decodeAnimation` composition byte-for-byte (see `PROGRESS.MD` and the
   2026-06-23 9b oracle row).
3. **9c (delivered).** Frame optimization: public `encodeAnimationMinimized`
   (in `src/animation_optimize.zig`) takes full-canvas frames + timing and
   automatically derives a minimal `ANMF` layout — sub-rectangle detection
   (minimal bounding box of the changed region), inter-frame differencing with a
   blend-vs-replace strategy (lossless: equal-to-prev pixels made transparent
   under `alpha_blend` when the result provably reconstructs exactly, else
   verbatim `replace`; lossy: always verbatim `replace`), a one-frame-lookahead
   dispose-to-background choice, and keyframe insertion (frame 0, full-canvas
   changes, and a bounded interval) — then reuses the 9b per-frame encoder and
   the 9a mux. The optimizer tracks the decoder's *reconstructed* canvas
   (re-decoding each frame it emits and compositing with the exact
   `animation_decode` rules), so lossy error never accumulates and the 9b gate
   is preserved. **Slice 9c-2 extended this to lossy frames:** the change rect is
   detected against a *source-quality carryover* canvas (not the noisy
   reconstruction) using a per-channel content-change tolerance `T`
   (`Options.tolerance`, defaulting to a quality-derived value — libwebp's
   `QualityToMaxDiff`, ~5 at q=75), so lossy frames now shrink to a sub-rect
   instead of staying full-canvas keyframes; bounded drift is capped by the
   keyframe interval. Lossless frames use `T = 0` (exact) and an
   identical-to-reconstruction carryover, so the byte-exact lossless gate is
   unchanged. Gate (CI): all-lossless minimized round-trips are byte-exact;
   a lossy moving-region animation shrinks ≥1 ANMF rect and decodes valid; the
   optimized lossy mean luma PSNR stays within 0.5 dB of the naive full-canvas
   encode; `anim_dump` parity holds for lossless and lossy samples; `webpinfo`
   clean. Measured lossy result: ≈48% smaller than the naive full-canvas lossy
   encode on the moving-sub-region sample, PSNR +0.14 dB (not a loss; the
   inherited gradient is quantized once at the keyframe rather than re-noised
   each frame) — see the 2026-06-23 9c-2 oracle row. Step 9 is now
   feature-complete.
4. **9d (delivered, still encode).** Metadata-from-pixels for **still** encode:
   `EncoderOptions.metadata` (a `metadata.RawPayloads`) threads raw
   `ICCP`/`EXIF`/`XMP ` into the `encodeLossless`/`encodeLossy` mux calls, so the
   still encoders now emit an extended (`VP8X`) container with those chunks in
   spec-canonical order (and coexisting with a lossy `ALPH`). They round-trip
   byte-exactly through `demux`; with empty metadata the output is byte-identical
   to the pre-9d path (asserted by test). Chunk-order honesty: the from-pixels
   path emits spec-canonical order (there is no caller order to preserve there);
   the `mux.encodeStaticFromDemux` remux path is what preserves unknown-chunk
   order. Animation-level metadata is already handled by 9a's
   `AnimationImage.metadata` (and 9b's `AnimationEncodeOptions.metadata`), so 9d
   does not duplicate it.

**Browser-render check (step-9 completion gate):** set up, not closed. 9c
generates two minimized sample animations under `testdata/animation/`
(`anim_minimized_lossless.webp`, `anim_minimized_lossy.webp` — a textured
background with a moving sub-region) for manual inspection. Both pass `anim_dump`
parity and `webpinfo` cleanly. The full "renders in ≥2 major browsers" gate is
manual and intentionally **not** wired into CI: open the two samples in two
browsers and confirm the moving region animates correctly. Everything that can
be automated (byte-exact lossless round-trip, `anim_dump` parity, `webpinfo`) is
gated; the cross-browser confirmation is the only remaining manual step.
