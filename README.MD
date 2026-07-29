# zig-webp

`zig-webp` is a zero-dependency, Zig-only WebP implementation targeting Zig
0.16.0.

Version `1.0.1` (Tier-1 public API frozen and semver-governed). See
[`CHANGELOG.MD`](CHANGELOG.MD) for the release scope and
[`RELEASING.MD`](RELEASING.MD) for the release gates and how each is checked.

API stability is two-tiered: the named entry points (`decodeStatic`,
`decodeStaticInto`, `decodeAnimation`, `AnimationDecoder`, the `encode*`
functions except the bitstream-level `encodeVP8LBitstream`/`encodeVP8Bitstream`
tooling, `parseFeatures`, `parseWebP`, `isWebP`, `parseHeader`,
`parseChunkHeader`, `errorCategory`) and their parameter/result types are
**Tier 1** — stable at 1.0 and semver-governed. The `vp8_*`/`vp8l_*` module
exports, the two bitstream-level encoders, `bit_reader`/`bit_writer`,
`testing`, and other module re-exports
are **Tier 2** internals with no stability promise. Additions to
`errors.Error` are not breaking; removals or renames of Tier 1 names are.
See the module doc comment in `src/root.zig` for the full Tier 1 list.

Status: the full 1.0 roadmap is delivered — static and animated decode,
static and animated encode, metadata, performance work, and hardening.
Post-1.0, the C ABI (step 13) and internal threading (step 14) are
design-complete in `PLAN.MD` but not implemented. Details and dated oracle
results live in `PROGRESS.MD`.

**Decode.** `decodeStatic` decodes lossless (VP8L), lossy (VP8), and
lossy+alpha (`ALPH`) stills to packed RGBA/BGRA/ARGB/RGB, and
`decodeStaticInto` performs the same decode into a caller-owned buffer,
honoring its stride and format — byte-exact against `dwebp` on the full
`libwebp-test-data` corpus (bit-exact YUV reconstruction with both loop
filters, fancy chroma upsampling, alpha composition; for aligned, tightly
packed four-byte lossless output, VP8L reconstructs directly in the final
storage). `decodeAnimation` returns every composited frame and
`AnimationDecoder` streams them one at a time over a reused canvas, both
byte-exact against libwebp's `anim_dump` across lossless/lossy/mixed
frames, alpha, and every dispose/blend combination. `parseFeatures` probes
dimensions/format/alpha/animation/metadata without decoding pixels;
`parseWebP` is a strict RIFF demux to chunk locations.

**Encode.** `encodeLossless` turns a typed pixel buffer into a valid VP8L
WebP that round-trips bit-exactly through this library's decoder (median
size 1.04× `cwebp -lossless` on the encode corpus). `encodeLossy` emits a
valid `VP8 ` (or `VP8X` + `ALPH` + `VP8 `) file with rate-distortion intra
mode decision (16x16/8x8 modes and per-subblock 4x4 B_PRED), macroblock
skip coding, in-loop deblocking at a quantizer-derived level, adaptive
per-segment quantization, a `method` (0..6) effort knob, lossless
byte-exact `ALPH` alpha, target-size / target-PSNR modes, and optional
sharp (iterative) RGB→YUV chroma — at matched output size the photo-corpus
luma PSNR is within the 1.0 dB gate of `cwebp -q 75 -m 4` (in fact
+0.08 dB). Both still encoders attach optional raw `ICCP`/`EXIF`/`XMP `
metadata in spec-canonical order. For animation, `encodeAnimation` muxes
already-encoded frame bitstreams, `encodeAnimationFromBuffers` encodes an
ordered list of pixel-buffer frames (full-canvas or sub-rect, lossy or
lossless, with alpha), and `encodeAnimationMinimized` derives a minimal
`ANMF` layout automatically (sub-rectangle detection, inter-frame
differencing with a blend-vs-replace strategy, dispose selection, keyframe
insertion; lossy frames use a quality-derived change tolerance, ≈48%
smaller than a naive per-frame encode on a moving-region sample). Output is
accepted by `webpinfo`/`webpmux`, matches `anim_dump` byte-for-byte, and
rendered correctly in Firefox and Chromium.

**Performance and hardening.** Lossy decode combines vector YUV→RGB
conversion, table-driven VP8 boolean renormalization, vector inverse DCT,
compact residual metadata, and SIMD loop filtering; VP8L decode adds buffered
entropy reads, vector/run inverse transforms, compact Huffman setup, and direct
reconstruction into eligible output storage. Default VP8L encoding uses
hash-probed palette indexing, direct one-group palette emission, a
constant-image run shortcut, and bounded previous-row/recent-index matching for
palettes up to 96 colors. On the pinned six-source low-color UI/alpha corpus,
this default path measured **0.7293×** libwebp lossless preset 0 time while
emitting **0.8029×** its bytes; this is a class-specific, single-threaded
result, not a general encoder claim.
A pinned 135-file comparison against pure-Rust `image-webp` measured summed
decode-into
ratios of **0.9315×** (lossy opaque) and **0.9324×** (lossy+alpha), with
Rust still ahead on the lossless classes (**1.0874×** opaque, **1.0492×**
alpha) — per-class results, not a universal claim; the protocol and
rejected experiments are recorded in `PROGRESS.MD`. Every public entry
point is covered by a limits/malicious-input contract matrix,
allocation-failure injection, fuzz targets with deterministic bounded
mutation exploration, and caller-set `ResourceLimits`; untrusted input
fails with documented errors, never panics or unbounded allocation.

The installed `zig-webp-encode` tool re-encodes a still WebP as lossy
`VP8 `; `zig-webp-info` prints container structure and features without
decoding pixels.

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
tools/webp-rust-bench.sh
tools/webp-fast-lossless-bench.sh --output .zig-cache/fast-lossless.tsv
```

The package exposes the `webp` module from `src/root.zig`.

`zig build -Doptimize=ReleaseFast bench` times the decode/encode entry points in
memory per asset class and prints a TSV (the PLAN.MD step-10 performance
baseline), including still `decode-into` rows via `decodeStaticInto`. It must be
built `ReleaseFast` — a Debug build is instrumented and several times slower, so
its timings are not comparable to the committed baseline (the tool warns when
run in Debug). The optional `tools/webp-bench.sh` times libwebp's `dwebp`/`cwebp`
(and `anim_dump` for animations) over the same files for a same-machine ratio.
The optional `tools/webp-rust-bench.sh` pairs still `decode-into` rows with a
local `references/image-webp` Cargo adapter materialized only under
`.zig-cache/` (skipped when Cargo or the reference clone is absent; never a
package/CI dependency). It invokes Zig only via
`zig build -Doptimize=ReleaseFast bench -- ...`, defaults to a two-file smoke
set, and supports `--all` over `testdata/photos` plus the committed static
corpus (skipping files without a validated Zig decode-into digest). These are
local reports — timing is environment-dependent and is not a CI gate.

`zig build test` includes a hash-based corpus regression: decoded RGBA and
alpha planes of the committed corpus in `testdata/libwebp-test-data`, and the
composited frames of the committed animations in `testdata/animation`, are
compared against SHA-256 hashes in `testdata/corpus-hashes.tsv` and
`testdata/animation/hashes.tsv`, so the check needs no `dwebp`/`anim_dump`. The
local `zig build ci` gate bundles the same three steps CI runs on every pull
request — `zig fmt --check .`, `zig build check`, and `zig build test` — into a
single command. CI also runs the full suite on wasm32-wasi under wasmtime
(`zig build test -Dtarget=wasm32-wasi -fwasmtime`) and a `zig build wasm-check`
compile gate for wasm32-wasi/freestanding. Regenerate
the manifests with `zig build corpus-hashes` / `zig build anim-hashes` only
after a corpus-wide oracle run confirms the decoded planes and composited
frames (`tools/webp-oracle.sh compare-anim`).
