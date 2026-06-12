# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Status: VP8L decoder groundwork in progress. The current library exposes
bounded public option, limit, image-buffer, metadata, animation-frame,
feature-probing, RIFF/WebP demux, static mux, bitstream, VP8 boolean coder, and
VP8L header/transform/Huffman image-data APIs. A limited raw VP8L path can
materialize no-transform, single-prefix-group ARGB payloads and parse
meta-prefix entropy images, prefix-code group storage, and multi-group entropy
streams. Raw VP8L payload decode supports subtract-green, predictor, color, and
color-indexing transforms, plus allocator-backed main-image meta-prefix/group
stores. Static lossless WebP decode is available for still VP8L images and
matches `dwebp -pam` on the local `libwebp-test-data` VP8L corpus. ALPH chunk
alpha-plane decode is available for both uncompressed and VP8L-compressed
streams with all four alpha filters, matching `dwebp` alpha output on the
local corpus; lossy decode and animation are not available yet.

## Goals

- Decode and encode WebP lossy, lossless, alpha, metadata, and animation data.
- Keep the implementation portable and dependency-free: no C, no system
  libraries, and no vendored codecs.
- Favor explicit, bounded parsing paths suitable for fuzzing and audit.

## Use

```sh
zig build
zig build test
tools/webp-oracle.sh check
tools/webp-oracle.sh compare-vp8l-corpus .zig-cache/vp8l-diff references/libwebp-test-data
```

The package exposes the `webp` module from `src/root.zig`.
