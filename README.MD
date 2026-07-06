# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Version `0.2.0` (preview; the public API is not yet frozen). See
[`CHANGELOG.MD`](CHANGELOG.MD) for the release scope and
[`RELEASING.MD`](RELEASING.MD) for the release gates and how each is checked.

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
is now feature-complete: `encodeAnimation` muxes already-encoded frame bitstreams
into a valid animated WebP (`VP8X` + `ANIM` + `ANMF`, with optional per-frame
`ALPH` and `ICCP`/`EXIF`/`XMP ` metadata) — the animated analogue of
`encodeStatic` — accepted by `webpinfo`/`webpmux`/`anim_dump`.
`encodeAnimationFromBuffers` builds on it to encode an ordered list of
pixel-buffer frames (each full-canvas or sub-rect, lossy or lossless, with alpha)
straight into an animated WebP, reusing the still encoders per frame; its output
composites back through this library's `decodeAnimation` and matches libwebp's
`anim_dump` byte-for-byte. `encodeAnimationMinimized` adds automatic frame
optimization: it takes full-canvas frames and derives a minimal `ANMF` layout
(sub-rectangle detection, inter-frame differencing with a blend-vs-replace
strategy, dispose selection, and keyframe insertion) that composites back to the
input canvases — byte-exact for lossless input, and within the codec's tolerance
for lossy — tracking the decoder's reconstructed canvas so lossy error never
accumulates. **Lossy frames are inter-frame optimized too:** the change rect is
detected against a source-quality carryover canvas with a quality-derived
content-change tolerance (`AnimationMinimizeOptions.tolerance`), so lossy
animations shrink to sub-rects instead of full-canvas keyframes (≈48% smaller
than a naive per-frame lossy encode on a moving-region sample, within ~0.1 dB of
its luma PSNR). The still pixel
encoders now also attach `ICCP`/`EXIF`/`XMP ` metadata (above). The only open
step-9 item is the manual ≥2-browser render confirmation (two sample animations
under `testdata/animation/`). The installed `zig-webp-encode` tool re-encodes a still WebP as
lossy `VP8 `.

Since `0.1.0`, the performance and hardening steps (10 and 11) are delivered:
lossy decode gained a vectorized YUV→RGB conversion and a table-driven VP8
boolean reader (≈1.3× aggregate, byte-exact), and every public entry point is
covered by a limits/malicious-input contract matrix, allocation-failure
injection (still and animated), encode-side fuzz targets, and deterministic
bounded mutation exploration of every fuzz seed. Untrusted input fails with
documented errors under caller-set `ResourceLimits`, never with panics or
unbounded allocation. Details and dated results live in `PROGRESS.MD`.

## Goals

- Decode and encode WebP lossy, lossless, alpha, metadata, and animation data.
- Keep the implementation portable and dependency-free: no C, no system
  libraries, and no vendored codecs.
- Favor explicit, bounded parsing paths suitable for fuzzing and audit.

Scope boundaries (no streaming decode, no inter-frame VP8, no ICC
application, no C ABI yet) and the full roadmap with acceptance gates live
in `PLAN.MD`; current status and dated oracle results live in `PROGRESS.MD`.

## Install

```sh
zig fetch --save git+https://github.com/IfkumRfnl/zig-webp
```

```zig
const webp_dep = b.dependency("zig_webp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("webp", webp_dep.module("webp"));
```

Then in your code:

```zig
const webp = @import("webp");
```

## Use

```sh
zig build
zig build test
tools/webp-oracle.sh check
tools/webp-oracle.sh compare-vp8l-corpus .zig-cache/vp8l-diff references/libwebp-test-data
tools/webp-oracle.sh compare-alpha-corpus .zig-cache/alpha-diff references/libwebp-test-data
zig build encode-lossy-report
tools/webp-oracle.sh compare-encode-lossy
zig build -Doptimize=ReleaseFast bench
tools/webp-bench.sh
```

The package exposes the `webp` module from `src/root.zig`.

`zig build -Doptimize=ReleaseFast bench` times the decode/encode entry points in
memory per asset class and prints a TSV (the PLAN.MD step-10 performance
baseline). It must be built `ReleaseFast` — a Debug build is instrumented and
several times slower, so its timings are not comparable to the committed
baseline (the tool warns when run in Debug). The optional `tools/webp-bench.sh`
times libwebp's `dwebp`/`cwebp` (and `anim_dump` for animations) over the same
files for a same-machine ratio. Both are local reports — timing is
environment-dependent and is not a CI gate.

`zig build test` includes a hash-based corpus regression: decoded RGBA and
alpha planes of the committed corpus in `testdata/libwebp-test-data`, and the
composited frames of the committed animations in `testdata/animation`, are
compared against SHA-256 hashes in `testdata/corpus-hashes.tsv` and
`testdata/animation/hashes.tsv`, so the check needs no `dwebp`/`anim_dump`. The
local `zig build ci` gate bundles the same three steps CI runs on every pull
request — `zig fmt --check .`, `zig build check`, and `zig build test` — into a
single command. Regenerate
the manifests with `zig build corpus-hashes` / `zig build anim-hashes` only
after a corpus-wide oracle run confirms the decoded planes and composited
frames (`tools/webp-oracle.sh compare-anim`).
