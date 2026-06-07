# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Status: foundation. The current library exposes bounded public option, limit,
image-buffer, metadata, animation-frame, feature-probing, RIFF/WebP demux, and
static mux APIs. Pixel decode and codec internals are still future work.

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
```

The package exposes the `webp` module from `src/root.zig`.
