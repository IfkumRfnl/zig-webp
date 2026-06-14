# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Status: static lossless (VP8L) decode and ALPH alpha-plane decode are
complete and match `dwebp` byte-for-byte on the local `libwebp-test-data`
corpus (all four alpha filters, both uncompressed and VP8L-compressed alpha
streams). The VP8 lossy decoder reconstructs and deblocks full key frames,
byte-exact against plain `dwebp -yuv` for all 88 lossy corpus files plus
locally generated `cwebp` files (both the simple and normal in-loop
filters); YUV-to-RGB conversion, alpha composition over lossy color, and
animation decode are not available yet. The library also exposes bounded option and
limit types, image buffers, metadata, animation-frame and feature probing,
RIFF/WebP demux, static mux, and the VP8/VP8L bitstream infrastructure.

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
alpha planes of the committed corpus in `testdata/libwebp-test-data` are
compared against SHA-256 hashes in `testdata/corpus-hashes.tsv`, so the
check needs no `dwebp`. CI runs `zig fmt --check .` and `zig build test` on
every pull request. Regenerate the manifest with `zig build corpus-hashes`
only after a corpus-wide oracle run confirms the decoded planes.
