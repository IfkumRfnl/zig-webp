# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While
the major version is `0`, the public API may still change between minor
releases.

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

[0.1.0]: https://github.com/IfkumRfnl/zig-webp/releases/tag/v0.1.0
