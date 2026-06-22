# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Status: static decode is complete for lossless (VP8L), lossy (VP8), and ALPH
alpha, all matching `dwebp` byte-for-byte on the local `libwebp-test-data`
corpus (all four alpha filters, both uncompressed and VP8L-compressed alpha
streams). The VP8 lossy decoder reconstructs and deblocks full key frames
(byte-exact against plain `dwebp -yuv` for all 88 lossy corpus files plus
locally generated `cwebp` files, both the simple and normal in-loop filters),
converts to RGB with fancy chroma upsampling, and composes the decoded ALPH
plane over lossy color — byte-exact against `dwebp -pam` for every lossy file,
including lossy+alpha. The public `decodeStatic` entry point decodes both
lossless and lossy stills to packed RGBA/BGRA/ARGB/RGB. Animated WebP decode
is available too: `decodeAnimation` returns every composited frame, and
`AnimationDecoder` streams them one at a time over a reused canvas — both
byte-exact against libwebp's `anim_dump` across a generated corpus spanning
lossless/lossy/mixed frames, alpha, and every dispose/blend combination. The
library also exposes bounded option and limit types, image buffers, metadata,
animation-frame and feature probing, RIFF/WebP demux, static mux, and the
VP8/VP8L bitstream infrastructure.

Static encode is implemented for both formats. `encodeLossless` turns a typed
pixel buffer (RGBA/BGRA/ARGB/RGB, honoring stride) into a valid simple `VP8L`
WebP file; the lossless encoder uses the step-7 transform/cache/group machinery
and round-trips bit-exactly through this library's decoder. Both still encoders
also take optional raw `ICCP`/`EXIF`/`XMP ` metadata
(`EncoderOptions.metadata`); when present the output is an extended (`VP8X`)
container with those chunks in spec-canonical order, round-tripping byte-exactly
through `parseWebP` (with empty metadata the output is byte-identical to before).
`encodeLossy` emits a valid `VP8 ` (or `VP8X` + `ALPH` + `VP8 `) WebP file with rate-distortion
intra mode decision (the 16x16/8x8 modes and per-subblock 4x4 B_PRED), macroblock
skip coding, the in-loop deblocking filter at a quantizer-derived level, and
adaptive per-segment quantization (coefficient probabilities stay at the RFC
defaults, one token partition). Step 8b met its quality gate — at matched output
size the photo-corpus luma PSNR is within 1.0 dB of `cwebp -q 75 -m 4` (in fact
+0.08 dB). Step 8c then completed the lossy encoder: a `method` (0..6) effort
knob that scales the rate-distortion search, lossy+alpha via the `ALPH` chunk
(lossless, byte-exact alpha), target-size and target-PSNR encode modes, and
optional sharp (iterative) RGB→YUV chroma. Animation and metadata encode (step 9)
is now underway: `encodeAnimation` muxes already-encoded frame bitstreams into a
valid animated WebP (`VP8X` + `ANIM` + `ANMF`, with optional per-frame `ALPH` and
`ICCP`/`EXIF`/`XMP ` metadata) — the animated analogue of `encodeStatic` —
accepted by `webpinfo`/`webpmux`/`anim_dump`, and the still pixel encoders now
attach metadata (above). Encoding animation frames straight from pixel buffers,
and frame optimization, are the remaining step-9 slices. The installed
`zig-webp-encode` tool re-encodes a still WebP as lossy `VP8 `.

## Goals

- Decode and encode WebP lossy, lossless, alpha, metadata, and animation data.
- Keep the implementation portable and dependency-free: no C, no system
  libraries, and no vendored codecs.
- Favor explicit, bounded parsing paths suitable for fuzzing and audit.

Scope boundaries (no streaming decode, no inter-frame VP8, no ICC
application, no C ABI yet) and the full roadmap with acceptance gates live
in `PLAN.MD`; current status and dated oracle results live in `PROGRESS.MD`.

## Use

```sh
zig build
zig build test
tools/webp-oracle.sh check
tools/webp-oracle.sh compare-vp8l-corpus .zig-cache/vp8l-diff references/libwebp-test-data
tools/webp-oracle.sh compare-alpha-corpus .zig-cache/alpha-diff references/libwebp-test-data
zig build encode-lossy-report
tools/webp-oracle.sh compare-encode-lossy
```

The package exposes the `webp` module from `src/root.zig`.

`zig build test` includes a hash-based corpus regression: decoded RGBA and
alpha planes of the committed corpus in `testdata/libwebp-test-data`, and the
composited frames of the committed animations in `testdata/animation`, are
compared against SHA-256 hashes in `testdata/corpus-hashes.tsv` and
`testdata/animation/hashes.tsv`, so the check needs no `dwebp`/`anim_dump`. CI
runs `zig fmt --check .` and `zig build test` on every pull request. Regenerate
the manifests with `zig build corpus-hashes` / `zig build anim-hashes` only
after a corpus-wide oracle run confirms the decoded planes and composited
frames (`tools/webp-oracle.sh compare-anim`).
