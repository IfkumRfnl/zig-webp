# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While
the major version is `0`, the public API may still change between minor
releases.

## [0.2.0] — 2026-07-07

Hardening and performance release (roadmap steps 10 and 11). The codec feature
set is unchanged from `0.1.0`: this release makes lossy decode measurably
faster, makes the untrusted-input resource-limit contract enforced end to end,
and completes the fuzz / allocation-failure test surface. The public API is
still not frozen (`0.x`); API stabilization is step 12.

### Performance

- Vectorized (Zig `@Vector`) YUV→RGB fancy-upsampling conversion for the
  4-channel output formats on little-endian: ≈1.11× aggregate lossy decode
  (up to 1.31× on conversion-heavy files), byte-exact — verified by the
  corpus-hash gate plus a non-circular scalar/SIMD equivalence test.
- Table-driven VP8 boolean-reader renormalization: ≈1.20× aggregate lossy
  decode on the local corpus with unchanged bitstream semantics.
- VP8L encoder palette detection now probes a fixed open-addressing hash set
  (O(pixels) instead of O(pixels × palette size)); encoded output is
  byte-identical.
- New in-memory benchmark harness: `zig build -Doptimize=ReleaseFast bench`
  times the public decode/encode entry points per asset class, and the
  optional `tools/webp-bench.sh` times libwebp's tools over the same files
  for a same-machine ratio. Dated baselines, A/B results, and rejected
  experiments are recorded in `PROGRESS.MD`.

### Hardening

- Limits and malicious-input contract matrix (`src/testing/hardening.zig`):
  every public decode/parse/encode entry point is exercised with
  caller-tightened `ResourceLimits` and must fail with its documented error —
  including `parseFeatures` non-input limits and the bitstream-reachable
  `VP8X` 24-bit canvas dimension overflow.
- Allocation budgeting now covers the lossy decode paths: VP8 frame
  reconstruction validates its allocation plan (macroblocks, context rows,
  padded YUV planes) against `ResourceLimits.allocation_bytes_max` before
  allocating, and VP8L-compressed `ALPH` decode charges its scratch against
  the same cumulative `decodeStatic` budget.
- Allocation-failure injection extended to animated decode: both
  `decodeAnimation` and the streaming `AnimationDecoder` survive injected
  failure at every allocation site with a clean error and no leak.
- Fuzz smoke targets extended to the encode side: still lossless/lossy encode
  from pixels, pixel-buffer animation encode, and static/animation mux over
  untrusted bitstreams — whenever the encoder accepts an input, its output
  must decode back cleanly.
- Deterministic bounded mutation exploration for all nine public fuzz targets
  (`runMutations` in `src/testing/fuzz.zig`): each target's valid seed is
  replayed under fixed-seed PRNG byte substitutions and truncations on every
  `zig build test` run, exploring the seeds' input neighborhoods with zero
  flake risk while coverage-guided `--fuzz` remains blocked by an upstream
  Zig 0.16.0 bug (watched by the weekly Zig-master canary).

### Tooling and docs

- `zig build ci` bundles the full CI gate set (format check, library + tool
  compile, tests) into one local command.
- Docs truth-up: encoder option docs, root module docs, and the install flow
  now match the code exactly.

### Notes

- Verified at the release commit: `zig build ci` green (452/452 tests);
  `zig build encode-report` 77 sources, 0 round-trip mismatches (step-7
  validity); `compare-encode-corpus` median 1.0368× vs `cwebp -lossless`
  (step-7 size gate ≤1.10×); `compare-anim-corpus` 10/10 committed animations
  byte-exact against `anim_dump`.
- Out of scope, unchanged from `0.1.0`: streaming/incremental decode,
  non-key-frame VP8, ICC color application, and a C ABI.

## [0.1.0] — 2026-06-26

First tagged release: a zero-dependency, pure-Zig WebP codec targeting Zig
`0.16.0`. This is a preview (`0.x`) release — the feature set below is complete
and tested, but the public API is not yet frozen.

The release gate for `0.1.0` (see `RELEASING.MD`) is the static decode gate
(step 5) plus the lossless-encode validity and size gates (step 7); both held in
CI / local oracle at the tagged commit. Features beyond those gates (lossy
encode, animation/metadata encode) are included and tested, with their
acceptance results recorded in `PROGRESS.MD`.

### Decode

- Static decode for VP8L (lossless), VP8 (lossy), and `ALPH` alpha, byte-exact
  against `dwebp` on the `libwebp-test-data` corpus — all four alpha filters,
  both uncompressed and VP8L-compressed alpha streams.
- VP8 lossy reconstruction with both the simple and normal in-loop deblocking
  filters, byte-exact against `dwebp -yuv`; fancy chroma upsampling to RGB,
  byte-exact against `dwebp -pam`, including lossy+alpha.
- Public `decodeStatic` to packed RGBA / BGRA / ARGB / RGB.
- Animated decode: `decodeAnimation` returns every composited frame, and
  `AnimationDecoder` streams frames over a reused canvas — byte-exact against
  `anim_dump` across lossless/lossy/mixed frames, alpha, and every dispose/blend
  combination.
- Feature and animation-frame probing, RIFF/WebP demux, and metadata
  (`ICCP` / `EXIF` / `XMP `) extraction.

### Encode

- `encodeLossless`: typed pixel buffer (RGBA / BGRA / ARGB / RGB, honoring
  stride) → valid `VP8L` WebP. Round-trips bit-exactly through this library's
  decoder; median compressed size 1.04× `cwebp -lossless` on the encode corpus.
- `encodeLossy`: → valid `VP8 ` (or `VP8X` + `ALPH` + `VP8 `) WebP, with
  rate-distortion intra mode decision (16x16 / 8x8 modes and 4x4 B_PRED),
  macroblock skip coding, a quantizer-derived in-loop filter, and adaptive
  per-segment quantization. At matched size, photo-corpus luma PSNR is within
  1.0 dB of `cwebp -q 75 -m 4` (in fact +0.08 dB). Includes a `method` (0..6)
  effort knob, lossy+alpha via `ALPH`, target-size and target-PSNR modes, and
  optional sharp (iterative) RGB→YUV chroma.
- Still encoders accept optional raw `ICCP` / `EXIF` / `XMP ` metadata,
  emitting an extended (`VP8X`) container in spec-canonical chunk order.
- Animation encode: `encodeAnimation` muxes already-encoded frame bitstreams
  into a valid animated WebP; `encodeAnimationFromBuffers` encodes pixel-buffer
  frames directly; `encodeAnimationMinimized` adds sub-rectangle detection,
  inter-frame differencing, dispose selection, and keyframe insertion (for both
  lossless and lossy frames). Output is accepted by `webpinfo` / `webpmux` and
  matches `anim_dump` byte-for-byte for lossless input.

### Notes

- Out of scope for this release: streaming/incremental decode, non-key-frame
  VP8, ICC color application, a C ABI, and SIMD/threaded performance work
  (deferred to later steps; see `PLAN.MD`).
- The cross-browser render confirmation for animation encode is set up but not
  automated; see the browser-render check in `PROGRESS.MD`.

[0.2.0]: https://github.com/IfkumRfnl/zig-webp/releases/tag/v0.2.0
[0.1.0]: https://github.com/IfkumRfnl/zig-webp/releases/tag/v0.1.0
