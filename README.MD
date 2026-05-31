# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Status: scaffold. The current library exposes a small RIFF/WebP container parser
so future decoder and encoder work has a tested public surface to grow from.

## Goals

- Decode and encode WebP lossy, lossless, alpha, metadata, and animation data.
- Keep the implementation portable and dependency-free: no C, no system
  libraries, and no vendored codecs.
- Favor explicit, bounded parsing paths suitable for fuzzing and audit.

## Use

```sh
zig build
zig build test
```

The package exposes the `webp` module from `src/root.zig`.
