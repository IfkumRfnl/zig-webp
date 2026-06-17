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

Lossless encode has begun: `encodeLossless` turns a typed pixel buffer
(RGBA/BGRA/ARGB/RGB, honoring stride) into a valid simple `VP8L` WebP file.
This first slice emits ARGB literals only (no LZ77, transforms, or color cache
yet — see PLAN.MD step 7), so output is not size-optimized but round-trips
bit-exactly through this library's decoder for every still VP8L corpus image,
and `dwebp` decodes it back to the same pixels.

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
