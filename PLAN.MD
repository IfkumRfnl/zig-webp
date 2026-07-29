# PLAN.MD

This project aims to become a production-ready, high-quality, pure Zig WebP
encoder and decoder with no runtime or package dependencies.

The practical path is not to port `libwebp` wholesale. `libwebp` remains the
behavior oracle, while smaller independent implementations and the specs guide
module shape, test strategy, and edge-case coverage.

This document is forward-looking: goals, scope boundaries, ordering, and
acceptance gates. Completed work, dated oracle results, and the current
position live in `PROGRESS.MD`.

## Goals and Non-Goals

Goals:

- Full static decode: VP8 lossy, VP8L lossless, and alpha.
- Animated decode with frame iteration and composited output.
- VP8L lossless encode, VP8 lossy encode, and animation/metadata encode.
- Safe-by-default handling of untrusted input with explicit resource limits.
- A Zig-native public API with caller-controlled allocation.

Non-goals, explicitly out of scope unless deliberately revisited:

- Streaming or incremental decode of partial files. The API takes complete
  input buffers.
- VP8 features WebP forbids or never uses: inter-frame prediction,
  golden/altref frames, and non-key-frame decode.
- Applying ICC color management. Profiles are exposed as raw chunks; color
  transformation is the caller's concern.
- A C ABI or bindings layer before the Zig API stabilizes. That sequencing
  guard was the 1.0 precondition; the post-1.0 C-ABI *design* lives in
  step 13 below and is not implemented yet (no shipped C header, exports,
  or compatibility promise).

Portability and threading stance: development and CI test little-endian
64-bit targets. Code must not assume host endianness; CI additionally runs
the full test suite on big-endian powerpc64 under user-mode QEMU
(`zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux
-Doptimize=ReleaseSafe -fqemu`; ReleaseSafe, sharded 4-way so the
emulated gate stays fast; native jobs keep Debug) and on 32-bit
wasm32-wasi under wasmtime (`zig build test -Dtarget=wasm32-wasi
-fwasmtime`); a `zig build wasm-check` gate additionally compiles the
library for wasm32-wasi and wasm32-freestanding plus the wasi unit tests.
The library is thread-compatible: no global mutable state, so
distinct decode/encode jobs may run on distinct threads. Internal
parallelism is a step 14 design decision (design recorded below; nothing
is implemented).

## Toolchain Policy

The package pins `minimum_zig_version` (currently 0.16.0) in `build.zig.zon`
and tracks the latest stable Zig release. Compiler upgrades land as dedicated
commits that pass `zig build test` plus a full local corpus run, so toolchain
churn never mixes with codec changes. Zig is the project's one moving
dependency; treat upgrades with the same care as code changes.

## References

Normative references:

- WebP container: https://developers.google.com/speed/webp/docs/riff_container
- WebP image format RFC: https://www.rfc-editor.org/rfc/rfc9649
- VP8 lossy bitstream: https://www.rfc-editor.org/rfc/rfc6386
- VP8L lossless bitstream:
  https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification

Reference implementations and corpora inspected:

| Local path | Upstream | Role | Notes |
|---|---|---|---|
| `references/libwebp` | `webmproject/libwebp` | Oracle | Official C implementation and tools. Use for differential testing, feature behavior, and encoding quality comparison. Do not copy architecture wholesale. |
| `references/libwebp-test-data` | `webm/libwebp-test-data` | Corpus | Official test vectors. Local clone had 131 `.webp` files and 184 files total. |
| `references/simplewebp` | `MikuAuahDark/simplewebp` | Compact decoder reference | Single-header C decoder, about 5.5k lines. Good for WebP decode flow and VP8L details. No encoder, animation, metadata extraction, or partial decode. |
| `references/image-webp` | `image-rs/image-webp` | Independent full decoder reference | Pure Rust decoder covers simple and extended formats, lossy, lossless, alpha, animation, ICC, EXIF, and XMP. Lossless encoder only. Useful for module boundaries. |
| `references/ffmpeg/libavcodec/webp.c` | `FFmpeg/FFmpeg` | Low-level C decoder reference | Compact C decoder file with mature edge-case handling. License is LGPL, so use only for behavior study and avoid copying code. |
| `references/deepteams-webp` | `deepteams/webp` | Encoder architecture reference | Pure Go implementation claiming lossy, lossless, animation, metadata, and presets. Treat as a recent idea source, not an oracle. |
| `references/skrashevich-go-webp` | `skrashevich/go-webp` | Encoder/test matrix reference | Pure Go implementation with a detailed feature/test matrix. Useful for checklist design and encode/decode coverage. |

The local reference clones live under `references/`. The clone directories are
ignored by git and excluded from the package; only `references/README.MD` is
tracked. Recreate them with:

```sh
mkdir -p references
git clone --depth 1 https://github.com/webmproject/libwebp.git references/libwebp
git clone --depth 1 https://chromium.googlesource.com/webm/libwebp-test-data references/libwebp-test-data
git clone --depth 1 https://github.com/MikuAuahDark/simplewebp.git references/simplewebp
git clone --depth 1 https://github.com/image-rs/image-webp.git references/image-webp
git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git references/ffmpeg
git clone --depth 1 https://github.com/deepteams/webp.git references/deepteams-webp
git clone --depth 1 https://github.com/skrashevich/go-webp.git references/skrashevich-go-webp
```

Do not vendor the reference clone contents into git or the Zig package.

## Design Principles

- Keep the library pure Zig and zero-dependency.
- Treat scalar correctness as the source of truth. SIMD and threading come
  after scalar code is correct and covered.
- Keep format layers separate. RIFF mux/demux, VP8, VP8L, alpha, animation,
  metadata, color conversion, and public API code should be independent modules.
- Prefer small, bounded parsers with explicit memory limits and clear error
  values.
- Use differential tests against `libwebp` for decoded pixels, metadata, muxed
  structure, and encoder output validity.
- Demand bit-exactness wherever the spec defines exact output: VP8L ARGB
  pixels, VP8 YUV reconstruction, and alpha planes are compared byte-for-byte
  against `libwebp`. Numeric tolerances are reserved for layers that are
  genuinely implementation-defined (such as YUV-to-RGB conversion variants),
  and each such layer must document why exactness does not apply.
- Avoid copying reference code. Use specs and independent tests to write Zig
  implementations.

## Cross-Cutting Practices

These run continuously rather than as scheduled steps.

- Fuzzing is continuous: every public decode and encode entry point carries
  a fuzz target that lands in the same change as the entry point. Fuzz
  findings become committed regression tests.
- CI runs on every pull request: `zig fmt --check .`, `zig build test`, and a
  corpus regression mode that compares decoded output against committed
  SHA-256 hashes of known-good planes, so CI does not require `dwebp`. Full
  `dwebp`/`cwebp` differential runs remain available locally (and later in
  CI by building `libwebp` tools) via `tools/webp-oracle.sh`.
- Every decoder or encoder milestone records a dated, corpus-wide oracle
  result in `PROGRESS.MD`: corpus, file counts, byte-exact or gate metric,
  and skips.

## Module Layout

Every path below is on disk today; run `find src -name '*.zig' | sort` for
the live tree. CLI, report, and oracle tools live under `tools/`.

```text
src/root.zig
src/container.zig
src/demux.zig
src/mux.zig
src/features.zig
src/image.zig
src/color.zig
src/bit_reader.zig
src/bit_writer.zig
src/alpha.zig
src/animation.zig
src/animation_decode.zig
src/animation_encode.zig
src/animation_optimize.zig
src/metadata.zig
src/options.zig
src/limits.zig
src/errors.zig
src/decode.zig
src/encode.zig
src/vp8/bool_reader.zig
src/vp8/bool_writer.zig
src/vp8/cost.zig
src/vp8/decoder.zig
src/vp8/encoder.zig
src/vp8/forward_transform.zig
src/vp8/frame_header.zig
src/vp8/header.zig
src/vp8/loop_filter.zig
src/vp8/modes.zig
src/vp8/prediction.zig
src/vp8/quant.zig
src/vp8/segment.zig
src/vp8/token_probs.zig
src/vp8/tokens.zig
src/vp8/transform.zig
src/vp8l/color_cache.zig
src/vp8l/decoder.zig
src/vp8l/encoder.zig
src/vp8l/entropy.zig
src/vp8l/forward_transform.zig
src/vp8l/header.zig
src/vp8l/huffman.zig
src/vp8l/huffman_writer.zig
src/vp8l/image_data.zig
src/vp8l/inverse_transform.zig
src/vp8l/lz77.zig
src/vp8l/meta_prefix.zig
src/vp8l/pixel.zig
src/vp8l/prefix_groups.zig
src/vp8l/transform.zig
src/testing.zig
src/testing/corpus.zig
src/testing/encode_corpus.zig
src/testing/fuzz.zig
src/testing/hardening.zig
src/testing/metrics.zig
src/testing/synth.zig
```

Fuzz targets live alongside the tests of the module they exercise, using
Zig's built-in fuzzer, so fuzz coverage moves with the code it protects.

The exact names can change, but the ownership boundaries should remain. A
container parser must not know how VP8 macroblocks work. A VP8L Huffman builder
must not know how RIFF chunks are ordered. Animation compositing must not own
single-frame codec internals.

## Implementation Order

### 0–9. Completed Foundations

Steps 0 through 9 are complete. The delivered scope, acceptance-gate
results, and dated corpus/oracle rows live in `PROGRESS.MD`; the summary
below is the roadmap record:

- **Step 0** — project foundation; **step 1** — RIFF/WebP container;
  **step 2** — core bitstream infrastructure.
- **Step 3** — VP8L lossless decoder and **step 4** — alpha chunk decode,
  byte-exact against `dwebp` on the corpus.
- **Step 5** — VP8 lossy decoder: bit-exact key-frame reconstruction and
  loop filtering (`dwebp -yuv` byte-exact), a separately tested
  fancy-upsampling YUV→RGB conversion layer (`dwebp -pam` byte-exact), and
  alpha composition over lossy color.
- **Step 6** — extended decode and animation: VP8X flag/ordering rules,
  `decodeAnimation` / `AnimationDecoder`, and metadata extraction;
  composited frames byte-exact against `anim_dump`.
- **Step 7** — VP8L lossless encoder: subtract-green, color, predictor, and
  palette transforms, LZ77, color cache, and meta-prefix groups; bit-exact
  round-trips with median size 1.04× `cwebp -lossless` (gate ≤ 1.10×).
  On the six primary low-color sources of the pinned eight-source UI/alpha
  corpus, the default path measures **0.7293×** libwebp lossless preset 0
  time, wins both real-asset rows, and emits **0.8029×** aggregate bytes. It
  uses bounded palette-specific tokenization without a separate public effort
  mode; dated evidence and the formal plan-030 disposition live in
  `PROGRESS.MD`.
  Optional near-lossless preprocessing was not implemented — a quality
  refinement, never a gate — and remains available future work.
- **Step 8** — VP8 lossy encoder in three gated phases (8a valid bitstream,
  8b quality, 8c controls): rate-distortion intra mode decision with
  B_PRED, skip coding, loop-filter selection, adaptive segmentation, a
  `method` (0..6) effort knob, lossy+alpha via `ALPH`, target-size /
  target-PSNR modes, and sharp YUV. Gates: matched-size photo-corpus luma
  PSNR within 1.0 dB of `cwebp -q 75 -m 4` (measured +0.08 dB); target-size
  within 5%; no validity regressions across the preset matrix.
- **Step 9** — animation and metadata encode: `encodeAnimation` (container
  mux), `encodeAnimationFromBuffers` (pixel frames),
  `encodeAnimationMinimized` (sub-rect detection, inter-frame differencing,
  dispose/keyframe strategy, quality-derived lossy tolerance), and
  still-encode metadata. Output is accepted by `webpinfo`/`webpmux`,
  `anim_dump` matches this library's own composition byte-for-byte, and the
  manual two-browser render check passed.

### 10. Performance Work

- Establish scalar baselines before optimizing.
- Benchmark decode and encode separately for small icons, photos, alpha-heavy
  UI assets, large images, and animations.
- Working targets, revised only with recorded data: scalar decode within 3x
  single-threaded `libwebp` on the benchmark set. The original "within 1.5x
  after Zig vector work" target is **revised** with recorded data (see
  `PROGRESS.MD`): it holds as a direction for the conversion-dominated lossy
  path with further SIMD/cache-aware work, but not for the lossless path, whose
  cost is the serial entropy decoder (an already-optimized multi-level
  Huffman/LZ77 table) where the remaining gap is a SIMD/maturity difference vs
  `libwebp` rather than a missing scalar optimization; it is a direction, not a
  release gate. Encode targets are set once 8b lands and quality/speed tradeoffs
  are measurable.
- Add cache-aware hot loops for transforms, prediction, color conversion, and
  filters.
- Add optional Zig vectorized implementations behind clean module boundaries.
- Consider row or tile parallelism only after deterministic scalar behavior
  is locked down.

Deliverable: dated performance reports following the honest-benchmarking rules
in `AGENTS.md`. The gating comparison is against `libwebp` (the conformance
oracle and the same-lineage SIMD baseline this library is measured against),
recorded same-machine via `tools/webp-bench.sh`. Comparisons against
`image-webp` (Rust) and the pure-Go references remain **supplementary reports**:
they are independent implementations, not conformance oracles. The optional
`tools/webp-rust-bench.sh` harness now provides digest-gated, same-machine
decode-into comparisons when the local Rust toolchain/reference checkout is
available; neither is a package or CI dependency.

Step 10 is delivered. Dated baselines, the vectorized color conversion and
inverse DCT, full-edge SIMD loop filtering, VP8 boolean-reader renormalization,
VP8L entropy/transform/output work, rejected experiments, and future levers are
recorded in `PROGRESS.MD` (this section stays forward-looking per `AGENTS.md`).

### 11. Robustness Hardening

Fuzzing and limits checks run continuously (see Cross-Cutting Practices);
this step deepens them to release depth.

- Grow fuzz corpora from corpus seeds and accumulated findings; give CI a
  fixed fuzz time budget per target: demux, VP8L decode, VP8 decode, alpha
  decode, animation composition, and encoder round trips.
- Add allocation-failure injection tests around every public entry point.
- Add limits tests for huge dimensions, oversized chunks, invalid distances,
  invalid Huffman trees, recursive VP8L transforms, and animation frame
  counts.
- Keep all loops bounded by parsed dimensions, chunk sizes, or explicit
  limits.
- Ensure malicious inputs fail with errors, not panics or unbounded
  allocation.

Deliverable: fuzzed, bounded decode and encode paths suitable for untrusted
input.

### 12. Public API and Release Criteria

- Stabilize APIs for:
  - feature probing without full decode (delivered: `parseFeatures` audited,
    contract final, see `PROGRESS.MD`);
  - static decode to caller-owned buffers (delivered: `decodeStaticInto`,
    see `PROGRESS.MD`);
  - static encode from typed pixel buffers (delivered: `encodeLossless`/
    `encodeLossy` audited, see `PROGRESS.MD`);
  - animation iteration and composition (delivered: `decodeAnimation`/
    `AnimationDecoder` audited, see `PROGRESS.MD`);
  - metadata extraction and muxing (delivered: `MetadataPayloads` contract
    audited both directions, see `PROGRESS.MD`);
  - memory and security limits (delivered: `ResourceLimits` and per-entry
    budget docs audited, see `PROGRESS.MD`).
- Document pixel formats, ownership, allocation behavior, and error
  semantics (delivered: 2026-07-08 Tier-1 audit checked all four across the
  surface, see `PROGRESS.MD`).
- Require `zig build test`, hash-based corpus regression, encoder validity
  gates, and fuzz smoke budgets in CI.
- Release `0.1.0` only after the step 5 decode gate and the step 7 validity
  and size gates hold in CI.
- Release `1.0.0` only after the 8b and 8c gates, animation encode, metadata,
  hardening, docs, and the compatibility matrix in `RELEASING.MD`
  ("Compatibility matrix (1.0 gate)") are all met.

### 13. C ABI (post-1.0)

Forward-looking design only. This step records the C export contracts a later
implementation plan must execute. Nothing here authorizes `src/capi.zig`, an
installed header, shared library scaffolding, or CI wiring today.

#### 1. Scope of the exported surface (v1)

**Decision.** C ABI v1 exports the still-image Tier-1 core only:
`isWebP` / `parseHeader` / `parseChunkHeader` / `parseFeatures` analogues,
`decodeStaticInto` (caller-owned writable `zwebp_buffer` pixels only),
`encodeLossless` / `encodeLossy` (read-only `zwebp_image_view` input;
library-owned output bytes + paired free), and C-only helpers:
`zwebp_error_category` / `zwebp_error_name`, `zwebp_free(ptr, len)` (paired
free for library-owned encode output; see decision 4), plus
`zwebp_abi_version(void)` (runtime ABI version matching `ZWEBP_ABI_VERSION`;
see decision 8). No library-allocated pixel decode in v1.

**Rationale.** Still probe/decode/encode covers the common FFI adoption path
without opaque streaming handles or nested animation ownership.

**Rejected.** Mirroring all of Tier 1 in v1 (animation + mux + demux detail)
would freeze hard-to-version nested ownership before any C caller exists.
Also rejected: a `decodeStatic`-style library-allocated pixel API in v1 —
that forces cross-language pixel ownership the Into path was added to avoid.

**Tier-1 entry-point partition** (complete; silence is not a decision):

| Zig Tier-1 entry point | C ABI |
|---|---|
| `isWebP` | **v1** |
| `parseHeader` | **v1** |
| `parseChunkHeader` | **v1** |
| `parseFeatures` | **v1** |
| `decodeStaticInto` | **v1** |
| `encodeLossless` | **v1** |
| `encodeLossy` | **v1** |
| `errorCategory` | **v1** (as `zwebp_error_category` / `zwebp_error_name`) |
| *(no Zig Tier-1 analogue)* | **v1** C-only: `zwebp_free(ptr, len)` → free library-owned encode output (decision 4); `zwebp_abi_version(void)` → runtime C ABI version (`ZWEBP_ABI_VERSION`; decision 8); size-aware `int32_t zwebp_*_init(void* s, uint32_t struct_size)` defaulting helpers for every v1 **option/config** struct (decision 5 — return `0` on success or a published error such as `ZWEBP_ERROR_BAD_STRUCT_SIZE`; zero-fill is not sufficient, so these are required v1 support symbols); fixed-layout `int32_t zwebp_limits_init(zwebp_limits* s)` (no `struct_size`; returns `0` or `ZWEBP_ERROR_INVALID_ARGUMENT` on NULL; decision 5) |
| `decodeStatic` | **non-goal** for C (Into is the C decode shape; no parallel owning-pixel export) |
| `decodeAnimation` | **deferred v2** (batch owning frames; prefer streaming handle) |
| `AnimationDecoder` | **deferred v2** (opaque `zwebp_anim_decoder*` handle: create / next / reset / destroy) |
| `parseWebP` | **deferred** pending decision 10 (chunk-location demux vs probe-only) |
| `encodeStatic` | **deferred v2** (pre-encoded bitstream mux; niche for C) |
| `encodeAnimation` | **deferred v2** (nested frame bitstream + metadata ownership) |
| `encodeAnimationFromBuffers` | **deferred v2** |
| `encodeAnimationMinimized` | **deferred v2** |

Supporting Tier-1 *types* appear in C only as the extern structs / enums
needed by the classified entry points above (limits, mutable decode
buffers, const encode image views, `parseHeader` / `parseChunkHeader`
result carriers `zwebp_container_header` / `zwebp_chunk_header`, options,
feature summary scalars, error codes). Tier-2 Zig exports are C non-goals.

#### 2. Naming and header

**Decision.** Prefix `zwebp_`. One hand-written installed header
`include/zwebp.h`. The header is a maintained artifact, not auto-emitted.

**Rationale.** Short, and it does not collide with libwebp's `WebP*` /
`webp/` namespace — a C program may link both. Zig has no reliable
auto-header emit for this surface.

**Rejected.** `webp_zig_` (longer, still WebP-adjacent) and generating the
header from Zig `@export` metadata (fragile across toolchain versions).

**Implementation gate (future).** CI must compile the header against the
exports — e.g. build a tiny C smoke program that `#include`s `zwebp.h` and
links **every shipped C artifact** (the static archive always; and
`libzwebp.so` / the platform shared library whenever the optional shared
build is enabled, exercising dynamic-symbol visibility, export list, and
soname packaging) — so header/export drift or an unusable shared ABI fails
the build.

#### 3. Error model

**Decision.** Fallible C functions return `int32_t` status: `0` success;
negative stable codes for the **subset of `errors.Error` reachable from the
exported C surface** (today: the v1 wrappers around `isWebP` /
`parseHeader` / `parseChunkHeader` / `parseFeatures` / `decodeStaticInto` /
`encodeLossless` / `encodeLossy`, plus the error helpers). Codes are
numbered explicitly in `include/zwebp.h` / the future `src/capi.zig` map
and are **appended-only**: new reachable Zig errors get new negative
codes; never reuse or renumber. Provide `int32_t zwebp_error_category(int32_t code)` returning a
**stable integer category** (not a string, not a Zig enum ordinal) for
known codes, and `const char* zwebp_error_name(int32_t code)` returning a
static NUL-terminated string. Category return values are the explicit
header constants — fixed in `zwebp.h`, never derived from Zig
`errors.Category` ordinals (a Zig enum reorder/insertion must not change
C category numbers); a unit test pins the C-constant → Zig `Category`
mapping:

- `ZWEBP_ERROR_CATEGORY_CONTAINER = 0`
- `ZWEBP_ERROR_CATEGORY_RESOURCE_LIMIT = 1`
- `ZWEBP_ERROR_CATEGORY_UNSUPPORTED = 2`
- `ZWEBP_ERROR_CATEGORY_BITSTREAM = 3`
- `ZWEBP_ERROR_CATEGORY_ALLOCATION = 4`

Unknown / unmapped status codes (including the reserved
`ZWEBP_ERROR_INTERNAL` fallback when its documented category is
`unsupported`) must still return one of these published constants — never
an ad-hoc number. `zwebp_error_name` remains the string helper; category
branching uses the integer constants above.

Do **not** stabilize corpus/testing-only or other Zig errors that no
exported C entry point can return (e.g. `CorpusUnavailable`,
`InvalidCorpusPath`). If a wrapper ever observes an unmapped Zig error,
translate it to a single reserved deterministic fallback code (e.g.
`ZWEBP_ERROR_INTERNAL`) whose `zwebp_error_category` is
`ZWEBP_ERROR_CATEGORY_UNSUPPORTED` (or another single documented published
category constant) and whose `zwebp_error_name` is a static string — never
invent ad-hoc status or category numbers at runtime. C-surface validation that never becomes a Zig
`errors.Error` also uses published stable codes: at least
`ZWEBP_ERROR_BAD_STRUCT_SIZE` (unknown/too-small option/config
`struct_size` on size-aware init or callees) and
`ZWEBP_ERROR_INVALID_ARGUMENT` (FFI required-pointer NULLs,
pointer/length violations, and invalid enum discriminants in
decision 4) — numbered in the header, appended-only like the Zig-mapped
codes, and covered by `zwebp_error_category` / `zwebp_error_name`.

Each C wrapper must keep a mapping that is
exhaustive for the Zig errors that wrapper can produce; a future
implementation gate requires compile-time or unit-test exhaustiveness
checks over every exported wrapper's reachable set (and a regression
asserting the fallback path for an intentionally unmapped sentinel).

**Rationale.** Plan 013's "additions to `errors.Error` are not breaking"
still holds on the Zig side; the C ABI freezes only the FFI-visible code
list, so internal/test taxonomy churn does not widen the C surface.

**Rejected.** One C code per every `errors.Error` member (would freeze
unreachable testing/internal errors into the ABI); returning Zig
error-set integer values (not a stable ABI); POSIX `errno`-style
thread-local detail; out-parameters for the code while returning `bool`.

#### 4. Memory model

**Decision.** No allocator object crosses the C boundary in v1. Internal
scratch and encoder output are owned by a process-wide thread-safe Zig
allocator chosen at implementation time (must be thread-safe and introduce
no global mutable codec state, matching the library threading stance).
Decode pixels are always caller-owned via the Into contract into a mutable
`zwebp_buffer`. Encode inputs are a read-only `zwebp_image_view`
(`const uint8_t* pixels`). Live Zig `ImageBuffer.pixels` is a mutable `[]u8`,
so the C wrapper **must not** `@constCast` (or equivalent) into today's
`encodeLossless` / `encodeLossy`, and **must not** silently copy the whole
image to obtain mutable pixels. Before the C ABI ships, Zig 1.x must gain an
additive, non-breaking const-input encode path (a read-only pixel-view entry,
or an internal encoder entry that accepts const pixels) that the C wrappers
call; any whole-image copy would need an explicit documented decision with
its allocation budgeted against `allocation_bytes_max` and is **not** the
chosen design. Encoder success fills an owning result
(`uint8_t* data; uint64_t len;`) freed with `zwebp_free(ptr, len)` — both
pointer and length, so size-aware allocators remain possible.
`ResourceLimits.allocation_bytes_max` remains the caller's bound on internal
scratch/output exactly as in Zig.

**FFI invalid-argument validation (before Zig slices / enums).** Every C
wrapper **must** validate FFI arguments at the boundary **before**
constructing a Zig slice, dereferencing a caller pointer, or converting an
integer discriminant into a Zig enum. On violation, return the published
`ZWEBP_ERROR_INVALID_ARGUMENT` (decision 3) — never trap, never silently
truncate, never `@enumFromInt` an unchecked value.

- **Required pointers (plain and nested).** `NULL` for any required pointer
  argument returns `ZWEBP_ERROR_INVALID_ARGUMENT`. This covers option/init
  struct pointers (`zwebp_decoder_options*`, `zwebp_encoder_options*`,
  `zwebp_demux_options*`, `zwebp_limits*` on `zwebp_limits_init`, and the
  `void* s` of every size-aware `zwebp_*_init`), destination / view
  pointers (`zwebp_buffer*`, `zwebp_image_view*` / `const zwebp_image_view*`),
  and parse-result out-params (`zwebp_container_header*`,
  `zwebp_chunk_header*`, feature-summary outs, and any other required
  out-pointer). Optional pointers remain nullable only where the contract
  explicitly says so (e.g. metadata payload pointers when the matching
  `has_*` flag is clear).
- **Pointer/length pairs.** Every raw C pointer/length pair must be
  validated before a Zig slice is built. Required nonempty buffers reject
  `NULL` pointers (`pixels` / `data` / input byte streams / metadata
  payload pointers when the corresponding length is nonzero or the buffer
  is required). Lengths are `uint64_t` on the C side; on targets where
  `usize` is narrower (wasm32 / 32-bit), reject `len > SIZE_MAX` /
  `len > std.math.maxInt(usize)` rather than truncating or trapping. This
  applies to decode output `zwebp_buffer` pixel pairs, encode input
  `zwebp_image_view` pairs, input WebP byte streams
  `(const uint8_t* data, uint64_t len)`, and metadata payload
  `*_data`/`*_len` pairs on encode options.
- **Enum discriminants.** Every integer enum field the wrappers convert
  into a Zig enum — including `ZWEBP_FORMAT_*` pixel formats on
  `zwebp_buffer` / `zwebp_image_view`, and any other published enum
  constants — **must** be range-checked against the published constant set
  **before** `@enumFromInt` (or equivalent). Unknown values return
  `ZWEBP_ERROR_INVALID_ARGUMENT`; wrappers must not trap on an invalid
  discriminant or pass one into Zig.

**Rationale.** Process-wide ownership keeps the C call shape close to
"buffer in, status out" without a context handle on every call; Into
already solved decode-side cross-language ownership.

**Rejected.** Passing a caller allocator vtable across the ABI in v1
(large surface, hard to version, conflicts with the Zig-side
caller-controlled allocator story). Also rejected for v1: a mandatory
opaque `zwebp_context*` on every call (better for WASM freestanding and
allocator-failure injection from C, but heavier than host C needs; revisit
under decision 10 if freestanding shares this surface). Also rejected:
bridging `const zwebp_image_view` / `const uint8_t*` encode inputs via
`@constCast` onto Zig `ImageBuffer` (`pixels: []u8`), or a silent
whole-image copy to manufacture mutable pixels (see the const-input Zig
path requirement above).

#### 5. Struct strategy

**Decision.** Extensible **option/config** extern structs carry a leading
`uint32_t struct_size`. `zwebp_limits` is a **fixed-layout**, non-extensible
value type in C v1 — it has **no** `struct_size` and is **not** in the
struct_size-bearing extensible set (see Mirror below). Fixed-layout data
carriers likewise do **not** carry `struct_size`:
`zwebp_limits`, `zwebp_buffer`, `zwebp_image_view`, `zwebp_container_header`,
`zwebp_chunk_header`, and the owning encode-result
(`uint8_t* data; uint64_t len;`) are not versioned via the size mechanism
(layout changes there are C-breaking). `zwebp_features` is likewise a fixed
by-value result (see decision 6).

**Nested-limits evolution rule (C v1).** Nesting `zwebp_limits` by value
before later option fields is safe **only because** `zwebp_limits` is
fixed/non-extensible. Any future new limit knob is appended to the
**embedding** option/config struct's tail (or delivered via a new option
field), **never** by growing nested `zwebp_limits`. Growing an embedded
extensible struct in the middle would shift every subsequent option field
and break the old-prefix `struct_size` promise.

Callers **must** initialize every option/config struct before use by one of:

1. calling the matching size-aware `zwebp_*_init` (preferred) — the exported
   form is `int32_t zwebp_*_init(void* s, uint32_t struct_size)` (callers pass
   `sizeof(*s)`). On success the helper returns `0`, writes documented
   defaults only within the recognized prefix of the caller-provided
   `struct_size`, sets `s->struct_size = struct_size`, and **never writes
   past the caller's allocation**. Unknown or too-small sizes return a
   published error (e.g. `ZWEBP_ERROR_BAD_STRUCT_SIZE`; same rejection rule
   as callees: below `min_prefix`, or not an exact supported historical
   prefix) and **must not** write through `s`. The header provides a
   convenience macro `ZWEBP_*_INIT(s)` that expands to
   `zwebp_*_init((s), sizeof(*(s)))` and **yields that `int32_t` status**;
   callers **must** check it; or
2. explicitly assigning **every** field, including
   `struct_size = sizeof(...)` (the caller's own `sizeof`, not the
   library's).

Fixed `zwebp_limits` is initialized by `int32_t zwebp_limits_init(zwebp_limits* s)` /
`ZWEBP_LIMITS_INIT(s)` (fills the six documented defaults; not size-aware).
On success the helper returns `0` and writes the defaults; a NULL `s`
returns `ZWEBP_ERROR_INVALID_ARGUMENT` and must not write (decision 4).
The header macro `ZWEBP_LIMITS_INIT(s)` expands to `zwebp_limits_init(s)`
and **yields that `int32_t` status**; callers **must** check it. Full field
assignment remains allowed — including when nested inside an option/config
struct whose size-aware init fills the nested limits with those same
defaults.

Setting only `struct_size` on an otherwise indeterminate stack (or heap)
object is **not** supported: remaining fields (limits, `has_*` flags,
optionals) would be garbage. Zero-filling alone is also **not**
sufficient unless the caller then follows (1) or (2), because documented
init defaults are not all zero-bit patterns. A size-unaware
`zwebp_*_init(struct*)` that applies the library's current `sizeof` is
**rejected** for option/config structs — a newer shared library must not
write past an older, smaller caller allocation.

Mirror:

- `zwebp_limits` — fixed-layout mirror of Zig `ResourceLimits`
  (`src/limits.zig`): the **six** integer fields only (`file_size_max` is
  the default for `input_bytes_max`, not a separate C field). **No**
  `struct_size`; not size-extensible in C v1. Init via status-returning
  `int32_t zwebp_limits_init(zwebp_limits* s)` / `ZWEBP_LIMITS_INIT(s)`
  (status-yielding; callers must check; or full assignment). Fields, in
  order (defaults match `ResourceLimits{}`):
  `uint64_t input_bytes_max` (default `0xfffffffe` / `container.file_size_max`);
  `uint64_t output_pixels_max` (default `16777216`);
  `uint64_t allocation_bytes_max` (default `268435456` / `256 * 1024 * 1024`);
  `uint32_t frame_count_max` (default `4096`);
  `uint64_t animation_canvas_pixels_max` (default `16777216`);
  `uint32_t chunk_count_max` (default `65536`).
  Future limit knobs do **not** append here — they append to the embedding
  option/config struct's tail (or arrive as a new field); see the
  nested-limits evolution rule above.
- `zwebp_decoder_options` — v1 options for `decodeStaticInto` (Zig
  `DecoderOptions` in `src/options.zig`). Leading `struct_size`; init via
  size-aware `int32_t zwebp_decoder_options_init(void* s, uint32_t struct_size)` /
  `ZWEBP_DECODER_OPTIONS_INIT(s)` (status-yielding; callers must check) (or
  full assignment). Fields, in order:
  - `zwebp_limits limits;` — nested by value (Zig `limits: ResourceLimits =
    .{}`); `*_init` fills it with the same defaults as `zwebp_limits_init`
    (no nested `struct_size` — limits is fixed);
  - **no** `output_format` field in C v1 — Zig's `DecoderOptions.output_format`
    exists for owning `decodeStatic`, but C v1 decode is Into-only and
    `decodeStaticInto` ignores `DecoderOptions.output_format` (`dest.format`
    is authoritative; see `src/root.zig` / `src/decode.zig`). The destination
    `zwebp_buffer.format` (`ZWEBP_FORMAT_*`) is the single source of truth;
  - `bool preserve_metadata;` — Zig `preserve_metadata: bool = true`
    (reserved/no-effect today; default `true`);
  - `bool decode_animation;` — Zig `decode_animation: bool = true`
    (reserved/no-effect on still decode; default `true`).
- `zwebp_encoder_options` — v1 options for `encodeLossless` / `encodeLossy`
  (Zig `EncoderOptions` in `src/options.zig`). Leading `struct_size`; init
  via size-aware `int32_t zwebp_encoder_options_init(void* s, uint32_t struct_size)` /
  `ZWEBP_ENCODER_OPTIONS_INIT(s)` (status-yielding; callers must check) (or
  full assignment). Fields, in order:
  - `zwebp_limits limits;` — nested by value (Zig `limits: ResourceLimits =
    .{}`); same nested-init rule as decoder options (fixed nested limits,
    no nested `struct_size`);
  - **no** codec/format discriminator field — Zig `EncoderOptions.format`
    (`features.FormatKind`, default `.lossless` in `src/options.zig`) is
    **not** mirrored on the C struct. Each C entry point sets the Zig-side
    `format` from the wrapper invoked: `zwebp_encode_lossless` →
    `.lossless`, `zwebp_encode_lossy` → `.lossy` (matching
    `encodeStaticLossless` / `encodeStaticLossy` in `src/encode.zig` /
    `encodeLossless` / `encodeLossy` in `src/root.zig`, which reject a
    mismatched `format` with `error.UnsupportedImageFormat`). There are no
    `ZWEBP_CODEC_*` constants; pixel byte-order uses `ZWEBP_FORMAT_*` on
    `zwebp_buffer` / `zwebp_image_view` only;
  - `uint8_t quality;` — Zig `quality: u8 = 75`; default `75`;
  - `bool preserve_metadata;` — Zig `preserve_metadata: bool = true`
    (reserved/no-effect; default `true`);
  - `uint8_t method;` — Zig `method: u8 = 4`; default `4`;
  - `bool has_target_size;` + `uint32_t target_size;` — Zig
    `target_size: ?u32 = null`; init clears the flag (unset); never treat
    `0` as unset;
  - `bool has_target_psnr;` + `float target_psnr;` — Zig
    `target_psnr: ?f32 = null`; init clears the flag (unset); `float` is
    IEEE-754 binary32; mutually exclusive with `has_target_size` when both
    set (same `InvalidEncodeOptions` rule);
  - `uint8_t alpha_quality;` — Zig `alpha_quality: u8 = 100`; default
    `100`;
  - `bool use_sharp_yuv;` — Zig `use_sharp_yuv: bool = false`; default
    `false`;
  - metadata payloads (Zig `metadata: RawPayloads = .{}`) as three optional
    slices, each `bool has_*` + `const uint8_t* *_data` + `uint64_t *_len`:
    `has_color_profile` / `color_profile_data` / `color_profile_len`,
    `has_exif` / `exif_data` / `exif_len`, `has_xmp` / `xmp_data` / `xmp_len`.
    Init clears every `has_*` and nulls every pointer/length (Zig default
    all-null). Caller owns the pointed-to bytes; they must outlive the
    encode call.
- `zwebp_demux_options` — v1 options for `parseFeatures` (Zig `DemuxOptions`
  / `demux.Options` in `src/demux.zig`). Leading `struct_size`; init via
  size-aware `int32_t zwebp_demux_options_init(void* s, uint32_t struct_size)` /
  `ZWEBP_DEMUX_OPTIONS_INIT(s)` (status-yielding; callers must check) (or
  full assignment). Fields, in order:
  - `zwebp_limits limits;` — nested by value (Zig `limits: ResourceLimits =
    .{}`); same nested-init rule as decoder options (fixed nested limits,
    no nested `struct_size`);
  - `bool allow_trailing_data;` — Zig `allow_trailing_data: bool = false`;
    default `false`;
  - `bool strict_padding;` — Zig `strict_padding: bool = true`; default
    `true`.
  A fuller demux-result options bag beyond this probe surface is deferred
  with `parseWebP` (decision 1 / decision 10); v1 does not invent extra
  demux knobs.
- `zwebp_buffer` — mutable pixel storage for decode-Into outputs (**no**
  `struct_size`; fixed layout):
  `uint8_t* pixels; uint64_t len; uint32_t width, height, stride;
  int32_t format;` (pointer+len, not a Zig slice). `format` values are
  the explicit header constants `ZWEBP_FORMAT_RGB = 0`,
  `ZWEBP_FORMAT_RGBA = 1`, `ZWEBP_FORMAT_BGRA = 2`, `ZWEBP_FORMAT_ARGB = 3`
  — fixed in `zwebp.h`, never derived from Zig `PixelFormat` enum
  ordinals (a Zig enum reorder/insertion must not change C byte-order
  semantics); a unit test pins the C-constant → Zig `PixelFormat`
  mapping;
- `zwebp_image_view` — read-only pixel input for encode entry points (**no**
  `struct_size`; fixed layout):
  `const uint8_t* pixels; uint64_t len; uint32_t width, height, stride;
  int32_t format;` (same layout and `ZWEBP_FORMAT_*` constants as
  `zwebp_buffer` except `pixels` is
  const). The C wrappers call the Zig const-input encode path required in
  decision 4 — never `@constCast` onto `ImageBuffer.pixels: []u8`, never a
  silent whole-image copy.
- `zwebp_container_header` — by-value / out-param result of the
  `parseHeader` analogue (**no** `struct_size`; fixed layout), field-for-field
  from Zig `ContainerHeader`: `uint32_t riff_payload_size;` (Zig
  `riff_payload_size: u32`). Methods such as `fileSizeBytes` are not
  exported; callers that need the implied file size compute
  `riff_payload_size + 8`.
- `zwebp_chunk_header` — by-value / out-param result of the
  `parseChunkHeader` analogue (**no** `struct_size`; fixed layout),
  field-for-field from Zig `ChunkHeader`: `uint8_t tag[4];` (Zig
  `tag: FourCC` / `bytes: [4]u8` — four raw FourCC bytes, not an enum) and
  `uint32_t payload_size;` (Zig `payload_size: u32`). Padding /
  `chunkSizeBytes` helpers are not exported as struct fields.

Decode-Into takes a `zwebp_buffer*` (writable). `encodeLossless` /
`encodeLossy` take a `const zwebp_image_view*` (or the view by value).
Do not share a single mutable `uint8_t* pixels` type for both directions —
that would force encode callers with read-only image memory to cast away
const, and fixing it later would be an ABI break.

Zig optionals (`target_size: ?u32`, `target_psnr: ?f32`, metadata slices)
become value + `bool has_*` (and pointer+length for payloads). Never treat
`0` as unset.

**Directional `struct_size` compatibility** (precise; this is how appended
fields stay non-breaking on **option/config** structs only — **not**
`zwebp_limits`, which is fixed):

- Each option/config struct defines a **minimum recognized prefix**
  (the v1 field layout including `struct_size` itself). Callees **never
  read beyond `min(caller.struct_size, library_sizeof)`** bytes. Size-aware
  `int32_t zwebp_*_init` likewise **never writes beyond the caller-provided
  `struct_size`** (and never beyond the recognized prefix of that size);
  rejection returns `ZWEBP_ERROR_BAD_STRUCT_SIZE` (or the published
  equivalent) without writing.
- A **newer library** accepting an **older/smaller** caller struct must
  accept `struct_size` values that equal a **supported historical prefix**
  (including the current `library_sizeof`), treat absent trailing fields as
  init-defaults, and must not read or write past the caller-provided size.
  The same rule applies to size-aware init: an older/smaller caller size is
  accepted when it is an exact supported prefix; init fills only that
  prefix, sets `s->struct_size` to the caller-provided size, and returns
  `0`. Sizes below `min_prefix`, or sizes that are not an exact supported
  prefix, are rejected (by both callees and init) via the published status.
- An **older library** receiving a **newer/larger** caller struct may
  **reject** sizes above the version it understands (it must not guess at
  trailing fields, and still must not read or write past
  `caller.struct_size`). Forward progress for callers is to rebuild against
  a newer header/soname, not to require old binaries to accept unknown
  tails.
- Shrinking or reordering fields inside the recognized prefix is
  C-breaking; appending fields (and bumping the library `sizeof`) is
  non-breaking for callers that keep initializing via size-aware
  `zwebp_*_init` / `ZWEBP_*_INIT` (or fully assigning every field) with
  `struct_size` equal to their own `sizeof`, and for libraries that default
  the absent tail as above. New limit knobs append on these option/config
  tails (or as new fields), never by extending nested `zwebp_limits`.
- Fixed-layout carriers (`zwebp_limits`, `zwebp_buffer`, `zwebp_image_view`,
  `zwebp_container_header`, `zwebp_chunk_header`, owning encode result,
  `zwebp_features`) do not participate in these rules.

**Rationale.** Explicit presence flags avoid sentinel rot (`0` is a legal
PSNR target). Directional size rules give libwebp-style extensibility for
options without pretending pixel buffers and encode results are extensible
the same way. That avoids the contradiction of requiring `struct_size` on
layouts that start at `pixels` / `data`.

**Rejected.** Requiring `struct_size` on every extern struct (including
fixed data carriers and `zwebp_limits`); making nested `zwebp_limits`
size-extensible (or nesting any extensible struct before later option
fields — appending inside the nested type would shift subsequent fields and
break the old-prefix promise); growing nested `zwebp_limits` after v1
instead of appending new limit knobs on the embedding option/config tail;
exposing a codec/format discriminator (`int32_t format` /
`ZWEBP_CODEC_*`) on `zwebp_encoder_options` when the C entry-point name
already selects the codec (Zig defaults `EncoderOptions.format` to
`.lossless`, so default-initialized options would make `encodeLossy` fail
with `UnsupportedImageFormat`); duplicating decode format on
`zwebp_decoder_options.output_format` when C v1 is Into-only and
`zwebp_buffer.format` is already authoritative;
`0`-as-unset sentinels; omitting `zwebp_*_init` and forcing callers to
hand-reconstruct Zig defaults with no helper; treating
`struct_size = sizeof(...)` alone as initialization; a size-unaware
option/config `zwebp_*_init(struct*)` that writes defaults using the
library's current `sizeof` (would overrun an older, smaller caller
allocation when a newer shared library is loaded — init must take the
caller's `struct_size` explicitly and return status); a void/status-less
size-aware init that cannot report bad `struct_size`; a void/status-less
`zwebp_limits_init` / `ZWEBP_LIMITS_INIT` that cannot report NULL via
`ZWEBP_ERROR_INVALID_ARGUMENT`; a single mutable
`zwebp_buffer` / `uint8_t* pixels` type for both decode outputs and encode
inputs; `@constCast` (or equivalent) from `zwebp_image_view`'s
`const uint8_t* pixels` onto Zig `ImageBuffer` / `[]u8`, or a silent
whole-image copy to obtain mutable encode input (primary requirement: the
Zig const-input encode path in decision 4); packing Zig slices as fat
pointers without the decision-4 FFI required-pointer / pointer-length /
enum-discriminant checks; leaving required option/buffer/out-param
pointers unchecked (NULL dereference/trap); converting unchecked
`int32_t` enum fields with `@enumFromInt`; bidirectional
"accept any `sizeof`" (old libraries must not silently ignore unknown
trailing semantics); rejecting every smaller-than-current option/config
struct (would make appended fields a breaking change for old callers).

#### 6. Feature probe result

**Decision.** `zwebp_features` is a by-value extern struct of Summary
*scalars* only (**no** `struct_size`; fixed layout). No pointers, no
`ChunkLocation` fields, nothing to free. Frame count is not part of
`features.Summary` today and is not invented here — animation frame counts
arrive with deferred animation/demux APIs. Fields, in order:

- `int32_t file_kind;` — Zig `file_kind: FileKind`. Values are the explicit
  header constants `ZWEBP_FILE_KIND_SIMPLE = 0`,
  `ZWEBP_FILE_KIND_EXTENDED = 1` — fixed in `zwebp.h`, never derived from
  Zig `FileKind` ordinals; a unit test pins the C-constant → Zig mapping;
- `bool has_format;` + `int32_t format_kind;` — Zig `format: ?FormatKind`.
  When `has_format` is clear, `format_kind` is ignored. When set, values are
  `ZWEBP_FORMAT_KIND_LOSSY = 0`, `ZWEBP_FORMAT_KIND_LOSSLESS = 1` — fixed
  in `zwebp.h`, never derived from Zig `FormatKind` ordinals; a unit test
  pins the mapping. These are **bitstream** kind constants, distinct from
  the pixel-order `ZWEBP_FORMAT_*` constants on `zwebp_buffer` /
  `zwebp_image_view` (no shared namespace / no `ZWEBP_CODEC_*` alias);
- `uint32_t width; uint32_t height;` — Zig `canvas` dimensions;
- `bool has_alpha;` / `bool is_animation;` — Zig flags;
- `bool has_color_profile;` / `bool has_exif;` / `bool has_xmp;` — fixed
  individual presence flags mirroring `metadata.Presence` field-for-field
  (`color_profile`, `exif`, `xmp` in that order). Clear means absent; set
  means present. Same naming as the encoder-options `has_*` payload flags;
  **not** a packed bitset / flags word. New metadata kinds, if ever needed,
  append additional `bool has_*` fields (layout-breaking for this fixed
  result — C major bump per decision 8), never reuse or repack these three;
- `uint32_t chunk_count;` — Zig `chunk_count: u32`.

Invalid `file_kind` / `format_kind` discriminants on **inputs** that accept
these enums follow decision 4's enum-validation rule
(`ZWEBP_ERROR_INVALID_ARGUMENT`). As a probe **result**, the library only
writes published constants.

**Rationale.** Matches the Zig probe's "by value, nothing to free"
contract and stays honest about what `parseFeatures` actually returns.
Pinning `ZWEBP_FILE_KIND_*` / `ZWEBP_FORMAT_KIND_*` separately from pixel
`ZWEBP_FORMAT_*` keeps C callers stable across Zig enum churn without
colliding byte-order constants. Individual `bool has_*` metadata flags
mirror Zig `metadata.Presence` and the encoder-options presence style
without inventing a parallel bit-numbering ABI.

**Rejected.** Exporting chunk offsets in the probe result (that is demux
detail; see decision 10). Deriving feature file/format kind numbers from
Zig enum ordinals. Reusing pixel `ZWEBP_FORMAT_*` or encoder
`ZWEBP_CODEC_*` names for bitstream format kind. Leaving metadata presence
as an implementation choice between `bool` fields and a bitset; packing
presence into a `uint32_t` bitset / flags word with `ZWEBP_METADATA_*`
masks (would fork from the `bool has_*` style used elsewhere and still
need a frozen layout — pick the bools once).

#### 7. Artifact and build

**Decision.** Future `build.zig` grows a Tier-2 `capi` module rooted at
`src/capi.zig`, linked into the existing static library plus an optional
shared-library step; `include/zwebp.h` installed via `b.installFile` (or
equivalent). The Zig module remains the package's primary artifact; C is
an adoption layer.

**Future implementation acceptance gates** (must all hold before claiming
the C ABI ships):

1. **Header/export consistency** — a C translation unit that includes
   `zwebp.h` compiles and links against **every shipped C artifact** (the
   static archive always; and `libzwebp.so` / the platform shared library
   whenever the optional shared build is enabled), and **calls every
   exported v1 function** with minimal valid (or deliberately trivial)
   inputs — not address-only references — so parameter/return ABI drift
   fails at compile or run time (probes, decode, both encoders, error
   helpers, `zwebp_free`, `zwebp_abi_version`, every size-aware
   `zwebp_*_init` helper, and status-returning `zwebp_limits_init`).
   Address-of-only smoke is
   insufficient. An equivalent `dlsym`-style presence check for the shared
   artifact remains **additional**, not a substitute for the call smoke,
   catching missing exports, hidden dynamic symbols, export-list mistakes,
   and soname packaging errors. An entry point the smoke never calls must
   not be able to ship missing, mistyped, or hidden. CI must not pass with a
   working archive but an unusable dynamic C ABI.
2. **Behavioral decode gate** — a C smoke program decodes a committed
   corpus still into a caller-owned buffer via the Into analogue and
   byte-compares against Zig `decodeStatic` / corpus hash expectations.
   Behavioral coverage also includes decision 4's FFI invalid-argument
   rule: at least one NULL and one oversized-`len` rejection case on a
   decode output buffer and/or input byte stream; at least one NULL
   required-pointer case (options struct, `zwebp_buffer*`, a
   parse-result out-param, or `zwebp_limits_init(NULL)` /
   `ZWEBP_LIMITS_INIT` with a null operand — each must observe
   `ZWEBP_ERROR_INVALID_ARGUMENT` via the returned `int32_t` status);
   and at least one invalid enum-discriminant
   case (e.g. unknown `ZWEBP_FORMAT_*` on a `zwebp_buffer`), each
   returning `ZWEBP_ERROR_INVALID_ARGUMENT` (no trap / no truncate / no
   unchecked `@enumFromInt`).
3. **Behavioral encode gate** — presupposes the Zig const-input encode
   path from decision 4. C smoke programs encode from a
   `const zwebp_image_view` through **each encoder exported in v1** —
   separate coverage for `encodeLossless` and `encodeLossy` analogues,
   since they drive different codec paths and option handling — validate
   the returned
   library-owned bytes (e.g. decode them / byte-check, or at minimum confirm
   a parseable WebP with the expected dimensions), and free the output via
   `zwebp_free`. This gate must catch const-input mishandling (writing through
   or casting away const on caller pixels; `@constCast` bridges are out of
   policy), wrong result lengths, and missing or mismatched paired freeing
   in **either** encoder. Include at least one NULL / oversized-`len`
   rejection case on an encode input view and on a metadata payload pair;
   at least one NULL required-pointer case (`zwebp_encoder_options*` or
   `const zwebp_image_view*`); and at least one invalid enum-discriminant
   case (e.g. unknown `ZWEBP_FORMAT_*` on a `zwebp_image_view`)
   (decision 4).
4. **Error-map exhaustiveness** — for each exported C wrapper, a test
   (comptime preference, else unit) proves the Zig→C status map covers that
   wrapper's reachable `errors.Error` set, and a separate case proves the
   reserved unmapped-error fallback code/category/name. The same gate (or a
   sibling unit test) pins the published C-constant → Zig mappings for
   `ZWEBP_ERROR_CATEGORY_*`, `ZWEBP_FORMAT_*` (pixel), `ZWEBP_FILE_KIND_*`,
   and `ZWEBP_FORMAT_KIND_*` (bitstream) so Zig enum reorder cannot silently
   change C numbers. The same gate (or sibling) also pins
   `zwebp_features.has_color_profile` / `has_exif` / `has_xmp` →
   `metadata.Presence.color_profile` / `.exif` / `.xmp` (field order and
   meaning; not a bitset).
5. **`struct_size` directionality** (option/config only; `zwebp_limits` is
   fixed and out of scope for size rules) — tests cover (a) older/smaller
   prefix accepted with defaulted tail fields, (b) oversized/unknown size
   rejected without reading past the caller-provided bytes, and (c)
   size-aware `int32_t zwebp_*_init(void*, uint32_t)` / `ZWEBP_*_INIT`:
   writes defaults only within the recognized prefix of the caller-provided
   size, sets `s->struct_size` to that size, never writes past the caller's
   allocation, and **rejects bad sizes via the returned status**
   (`ZWEBP_ERROR_BAD_STRUCT_SIZE` or the published equivalent; a test proves
   callers observe that status). Separately, `int32_t zwebp_limits_init` /
   `ZWEBP_LIMITS_INIT` status is covered by gate 2's NULL required-pointer
   case (and the call smoke in gate 1): success returns `0`, NULL returns
   `ZWEBP_ERROR_INVALID_ARGUMENT` without writing.
6. Wire those checks into `zig build check` or a dedicated step invoked by
   CI.

**Rejected.** Shipping a shared library without linking/`dlsym`-style
smoke coverage of that shared artifact (or without the header-drift,
decode- and encode-behavior, error-map exhaustiveness, and `struct_size`
directionality gates); treating header install as documentation-only;
gating only the static archive while an optional `libzwebp.so` ships
untested; claiming the C ABI complete with decode-only behavioral coverage
while `encodeLossless` / `encodeLossy` (and their C ownership/`zwebp_free`
contract) remain unexercised from C.

#### 8. ABI stability policy

**Decision.** The C ABI versions independently of the already-stable Zig
1.x package API. The header defines `ZWEBP_ABI_VERSION`, and v1 exports
`uint32_t zwebp_abi_version(void)` returning that same runtime C ABI
version (in scope with the other C-only helpers; see decision 1).
Shared-library soname follows the C major (e.g. `libzwebp.so.1`);
soname / C major bumps only on C-breaking changes (removed entry points,
changed signatures, reused or renumbered published error codes, changing
`zwebp_error_category` or `zwebp_error_name` for a published code,
shrinking/reordering a recognized option/config `struct_size`
prefix, changing the fixed `zwebp_limits` or `zwebp_features` layout, or changing the
directional size / nested-limits rules in decision 5). Published error metadata is ABI-stable: reclassifying a code into a
different `ZWEBP_ERROR_CATEGORY_*` value, or renaming its stable
`zwebp_error_name` string, under the same numeric status code is
C-breaking (callers may switch on category/name, not only on the status
number). Likewise, renumbering or reusing `ZWEBP_ERROR_CATEGORY_*`,
`ZWEBP_FORMAT_*`, `ZWEBP_FILE_KIND_*`, or `ZWEBP_FORMAT_KIND_*` constants
is C-breaking. Non-breaking: appending C error codes for newly reachable
Zig errors (with category/name entries for those new codes only);
appending new category or enum constants only when paired with new
codes/fields that need them; appending struct fields under decision 5's
newer-library-defaults-absent-tail / older-library-may-reject-larger rules.
Implementing or evolving the C layer does not silently extend the Zig 1.x
compatibility promise to an unimplemented surface — C stability starts
when the C ABI is released.

**Rationale.** Zig 1.x can keep improving internals and additive Tier-1 APIs
while C callers pin a narrower, explicitly versioned FFI contract.

**Rejected.** Coupling C soname 1:1 to Zig package minor tags, or claiming
C ABI stability before any C artifact exists.

#### 9. Explicit non-goals for C ABI v1

- No callbacks into user code.
- No streaming or incremental decode of partial files (mirrors the Zig
  library non-goal).
- No caller-allocator ABI.
- No thread-pool / internal-parallelism knobs.
- No animation encode (`encodeAnimation` /
  `encodeAnimationFromBuffers` / `encodeAnimationMinimized`) — still Tier 1
  in Zig, deferred from the first C surface because nested frame and
  metadata ownership need a separate design review.
- No language-specific bindings (Python/Rust/etc.); those consume this C
  ABI downstream.
- No claim that this design is already implemented.

#### 10. Open questions left open

- **WASM freestanding exports:** whether wasm32-freestanding shares this
  exact host C surface or a slimmed one (possibly with an explicit context /
  arena inject — see decision 4's rejected alternative). Plan 014 follow-ups
  must consume this answer rather than inventing a third surface.
- **`parseWebP`:** whether chunk-location demux detail is worth a C export
  at all versus keeping C on `parseFeatures` + still decode/encode. Deferred
  until a concrete FFI caller needs remux/chunk surgery.

### 14. Threading (post-1.0 design)

Forward-looking design only, like step 13. This step records the opt-in
concurrency model a later implementation plan must execute. Nothing here
authorizes worker code, `std.Io` plumbing, or CI matrix changes today.

#### 1. Goals and non-goals

**Goal.** Where the recorded profile supports it, beat default
single-threaded `dwebp` wall-clock on large lossy stills (the `bryce`
class) and scale animation encode across frames. **Non-goals**: threading
as default behavior; wasm threads; threading VP8L lossless decode — the
profiled bottleneck is the serial entropy loop at roughly 66%–95% of VP8L
decode (`PROGRESS.MD`, 2026-07-11 tile-run attribution), which workers
cannot split, and the 2026-07-18 scalar campaign record stands.

#### 2. API shape and concurrency provider

**Decision.** New sibling entry points taking a caller-supplied `std.Io`
first parameter (e.g. `decodeStaticIo(io, gpa, bytes, options)`,
`encodeAnimationFromBuffersIo(...)`), plus one additive defaulted options
field `worker_count_max: u8 = 1` (1 = scalar path; ignored by the non-Io
entry points). The application constructs, owns, and deinitializes the
provider (typically `std.Io.Threaded`); the library never constructs,
caches, or hides one. Zig 0.16's own guidance: "the application is
responsible for choosing the `Io` implementation and library code should
accept an `Io` parameter" (`std/Io/Threaded.zig:1695-1704`). Existing
entry points keep their exact signatures and single-threaded semantics.
Tier: the new surface lands **Tier 2** and is promoted to Tier 1 only
after the first implementation slice survives its gates. Tier-1 rule
quoted from `src/root.zig`: "additions to `errors.Error` are not
breaking; removals or renames of Tier 1 names are" — new names and a
defaulted options field are additive, so nothing here breaks Tier 1.

**Rejected.** An options-only `thread_count_max` on the existing entry
points: it names no provider, forcing a hidden internal scheduler behind
frozen signatures — exactly what the stdlib guidance warns against.

#### 3. Determinism contract

Output is byte-identical for every worker count (as libwebp's `-mt` is).
Normative rules: workers write disjoint, pre-assigned output and scratch
regions; merge/reduction order is fixed by shard index, never completion
order; no dependence on time, RNG, or pointer order. CI runs the SHA-256
corpus gates through the threaded path at ≥ 2 workers via a test-only
option matrix: the corpus tests iterate `worker_count_max` over {1, 2, 4}
on the Io entry points with a test-constructed `std.Io.Threaded`.

#### 4. Budget accounting

`ResourceLimits.allocation_bytes_max` (`src/limits.zig`) stays one global
per-call budget. Per-worker scratch is reserved from it before any worker
starts (reserve-before-spawn); if reserving worker K's scratch would
exceed the budget, the call proceeds with K−1 workers, degrading to the
scalar path at 1. A call that succeeds single-threaded MUST never fail
with `error.AllocationLimitExceeded` because threading was requested.

#### 5. Failure and lifetime semantics

Normative rules, not open questions:

- **Deterministic error precedence.** Each worker records its error in
  its own shard slot; after all workers are joined, the entry point scans
  slots in shard order and returns the lowest-index error. The result
  never depends on scheduling races.
- **Cancellation.** The first fatal error (or an explicit cancel) sets a
  shared atomic flag; workers poll it at bounded intervals (row/frame
  boundaries) and exit early. Cancel is cooperative and keeps the
  byte-exact and budget contracts: a canceled call returns the
  shard-ordered error, never partial success.
- **Join-before-return.** Every started worker is awaited (or canceled
  and awaited) before the entry point returns success or error; no thread
  or reference into caller-owned buffers outlives the call.
- **Scratch cleanup.** Per-worker scratch is freed on success, error, and
  mid-flight cancel, and is charged/uncharged against
  `allocation_bytes_max` symmetrically on every path.
- **Partial-spawn failure.** If starting worker N fails
  (`Io.Group.concurrent` → `error.ConcurrencyUnavailable`, or allocation
  failure), the started workers keep their shards and are joined normally,
  unspawned shards run inline on the calling thread, and their reserved
  scratch is freed or reused — spawn failure degrades, it never leaks
  threads or budget charges, and never fails a call that would succeed
  single-threaded.

#### 6. Concurrency primitive

**Decision.** Caller-supplied `std.Io` plus a per-call `std.Io.Group`
using `Group.concurrent`/`await`/`cancel` (`std/Io.zig`). The library
owns each call's group and always awaits or cancels it before returning
(decision 5); the application owns the provider's lifetime. **Rejected:**
internal raw `std.Thread.spawn` — the library would own thread creation,
join bookkeeping, and partial-spawn cleanup itself, duplicating what
`Io.Group` guarantees, and callers could not bound or share the pool with
the rest of their application. Also rejected:
`std.Io.Threaded.global_single_threaded` as a scheduler — it "does not
support concurrency or cancelation" (`std/Io/Threaded.zig:1703`).
wasm and single-threaded targets stay on the scalar path either way.

#### 7. Structure per codec path

1. **Lossy decode pipeline split.** Entropy/token decode
   (`src/vp8/tokens.zig` + bool reader) feeding reconstruction and loop
   filter (`src/vp8/decoder.zig`, `src/vp8/loop_filter.zig`) over a
   bounded row queue — the libwebp `-mt` shape. Token decode is serial
   per partition and reconstruction consumes rows in order, so the
   ceiling is ≈ 2× (two stages). Workload: `bryce.webp` at 796.6 ms after
   the accepted plan-022 SIMD work (`PROGRESS.MD`, 2026-07-15 entry).
2. **Animation encode frame parallelism.**
   `encodeAnimationFromBuffers` (`src/animation_encode.zig`) encodes each
   frame's bitstream independently (the caller fixes rect/blend/dispose),
   so per-frame encode parallelizes with a serial 9a mux barrier.
   **Caveat (binding):** `encodeAnimationMinimized`
   (`src/animation_optimize.zig`) re-decodes each frame it just encoded
   to track the reconstructed canvas (`PROGRESS.MD` step-9c entry; the
   2026-07-04 unplanned finding in `plans/README.md`), so its rect and
   dispose decisions are frame-serial. The parallel slice targets the
   buffers path only; the minimized path stays serial until a later plan
   restructures that optimizer barrier explicitly.
3. **Lossy encode wavefront.** RD decisions in `src/vp8/encoder.zig` are
   row-causal through reconstructed neighbors; macroblock-row wavefront
   parallelism needs a deterministic reduction and is the most complex
   candidate. Deferred to its own plan.
4. **ALPH/color overlap.** `src/alpha.zig` decode is independent of VP8
   reconstruction until composition, so the planes can overlap; the
   ceiling is max(color, alpha) wall-clock. Small and cheap.

**Build order.** (2) on the buffers path first, then (1), then (4);
(3) only with a dedicated plan. VP8L decode is excluded (decision 1).

#### 8. Platform matrix

linux/macos native: threads available. wasm32-wasi, wasm32-freestanding,
and `builtin.single_threaded` builds: a compile-time capability check
keeps the scalar path as the only path (the Io entry points still
compile; the worker count clamps to 1 and no `concurrent` call is made);
`zig build wasm-check` and the wasmtime suite stay green. Big-endian is
unaffected, but CI must run one threaded configuration (the native matrix
at 2 workers, decision 3).

#### 9. Acceptance gates for the implementation plans

- Byte-exact SHA-256 corpus output at 1/2/4 workers.
- No allocation outside the budget: `checkAllAllocationFailures` extended
  over the reservation and spawn path.
- A dated bench row showing wall-clock below single-threaded `dwebp` on
  at least the `bryce` class.
- `zig build wasm-check` green; big-endian suite unchanged.
- Tests exercising partial-spawn degrade, cancel plus join-before-return,
  and scratch cleanup on every error path.

#### 10. Open questions left open

- Whether the Io-taking entry points later subsume the non-Io ones or
  stay siblings permanently — decide at Tier-1 promotion time.
- Shard granularity for the pipeline split (row vs macroblock-row batch)
  and queue depth — measure, do not guess.

## Near-Term Work Items

Steps 0 through 12 are complete and `1.0.x` is released; completed step
status, gate results, and the release history live in `PROGRESS.MD`.

The remaining roadmap is post-1.0 **step 13** (C ABI) and **step 14**
(threading): both designs are recorded above; implementing either remains
future work — no C artifact and no threading code exist today. Each
implementation slice gets its own plan executed against the recorded
design decisions and acceptance gates.

Separately from the feature steps, the next post-1.0 VP8L performance plan
must start from codegen/profile evidence for a whole-stream entropy-state
redesign with a local bit-buffer/table cursor and checked tail. The
2026-07-18 campaign closed local output packing, transform fusion, scratch
probing, Huffman root width, pair-table, fixed-green, unchecked lookup, and
meta-prefix representation variants without producing an every-class Rust
win. A replacement kernel must make both lossless class sums lower than
Rust on the pinned 135-file harness, improve full-lossless summed time by
at least 5%, preserve 135/135 digest identity, and keep every unaffected
codec control within 1%. It must not reopen plan 021's unsafe
bulk-refill/unchecked lookup. The completed direct final-output
reconstruction and exact residual ratios are recorded in `PROGRESS.MD`.

Smaller open refinements, in no required order: VP8L near-lossless
preprocessing (the step-7 leftover; quality refinement, never gated) and
real method 5–6 search depth in the lossy encoder (currently a documented
clamp to method 4).
