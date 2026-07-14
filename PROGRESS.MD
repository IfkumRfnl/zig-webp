# PROGRESS.MD

Status log for the roadmap in `PLAN.MD`. `PLAN.MD` stays forward-looking
(scope, ordering, acceptance gates); completed scope, dated oracle results,
and the current position are recorded here.

Last updated: 2026-07-14

## Current Position

Steps 0 through 6 are complete for their decode scopes. Static WebP decode runs
through the public `decodeStatic` for VP8L lossless, VP8 lossy, and lossy+ALPH
inputs; the lossy path includes key-frame reconstruction, in-loop deblocking,
fancy YUV-to-RGB upsampling, and alpha composition, with committed corpus hashes
locking the `dwebp`-matched output. Animated WebP decodes through both
`decodeAnimation` (all composited frames) and the streaming `AnimationDecoder`,
with committed frame hashes locking the `anim_dump`-matched output.

Step 7 (VP8L lossless encode) is complete. The encoder emits valid still VP8L
from typed pixel buffers, applies LZ77 plus the decision-gated subtract-green,
color, predictor, palette/color-indexing, optional color-cache, and optional
meta-prefix paths, and round-trips the encode corpus bit-exactly. The committed
lossless encode report remains the size baseline (median 1.04x vs
`cwebp -lossless` at the recorded gate).

Step 8 (VP8 lossy encode) is complete through 8c. The encoder emits valid VP8
key frames, implements rate-distortion mode decision, B_PRED, skip coding,
loop-filter selection, adaptive segmentation, lossy+alpha via `ALPH`,
method/quality controls, target-size and target-PSNR searches, and sharp YUV
chroma. The step-8b and 8c gates hold in the dated oracle rows: matched-size
photo-corpus luma PSNR is within the 1.0 dB target, and target-size mode lands
within 5% on the photo corpus.

Step 9 (animation and metadata encode) is feature-complete: container mux
(`encodeAnimation`), pixel-buffer animation encode (`encodeAnimationFromBuffers`),
automatic frame minimization (`encodeAnimationMinimized`), lossy-frame
optimization, and still metadata from `EncoderOptions.metadata` are delivered.
Automated gates hold for demux validity, `webpinfo` cleanliness, `anim_dump`
parity, lossless byte-exact minimized round-trips, and lossy minimized validity
and PSNR. The last step-9 gate, the manual ≥2-browser render check, passed on
2026-07-08: `testdata/animation/anim_minimized_lossless.webp` and
`testdata/animation/anim_minimized_lossy.webp` both animate correctly in
Firefox and Chromium (operator-run; versions not recorded). Step 9 is complete.

Step 10 (performance) is delivered. The benchmark harness, scalar baseline,
vectorized YUV-to-RGB conversion, and table-driven VP8 boolean-reader
renormalization are recorded below with their dated measurements. The honest
summary is unchanged: scalar lossy decode is within the ≤3x single-threaded
`dwebp` target and materially closer on large VP8 stills after the recorded
optimizations; lossless decode remains entropy-bound and outside that narrow
speed target.

Step 11 (robustness hardening) is delivered through the planned slices. The
limits/malicious-input matrix, allocation-failure injection for public decode and
encode entry points, encode fuzz smoke targets, and deterministic bounded
mutation exploration are all merged. A review follow-up also closed real
allocation-budget enforcement gaps in VP8 lossy frame reconstruction and
VP8L-compressed `ALPH` decode. Coverage-guided `zig build test --fuzz` remains
blocked by the Zig 0.16.0 test-runner instrumentation bug, but the weekly Zig
master canary watches for that upstream blocker to clear.

Step 12's remaining stabilization work is done. A 2026-07-08 audit of the
Tier-1 surface walked all 16 stable entry points and every contract-listed
type against a
fixed checklist (ownership, allocation bounds, error semantics, naming and
parameter order, pixel-format/stride contracts); the findings table lives under
Recently Completed. Every finding was doc-class — no behavior changes and no
Tier-1 renames. The contract list in `src/root.zig` now also names the six
parameter/result types it had omitted, and the two bitstream-level encoders
(`encodeVP8LBitstream`/`encodeVP8Bitstream`) are explicitly Tier 2. With the
compatibility matrix closed, `1.0.0` shipped per `RELEASING.MD`'s release
procedure (Tier-1 frozen; see `README.MD` / `CHANGELOG.MD`).

Step 13 (C ABI) is design-complete only: plan 015 recorded the post-1.0 C
export contracts in `PLAN.MD` (v1 still-image scope, naming/header, error
model, memory ownership, size-aware struct init, acceptance gates, independent
C ABI versioning). No C header, exports, or shared library ships yet.

## Cross-Cutting Practices

CI runs on every pull request and push to main
(`.github/workflows/ci.yml`) as four jobs on Zig 0.16.0: `test`
(ubuntu-latest: `zig fmt --check .`, `zig build check`, `zig build test`),
`big-endian` (ubuntu-latest:
`zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux
-Doptimize=ReleaseSafe -fqemu` under `qemu-user-static`), `macos`
(macos-latest aarch64:
`zig build check`, `zig build test`), and `wasm` (ubuntu-latest:
`zig build wasm-check` compile gate for wasm32-wasi and wasm32-freestanding
plus the full suite under wasmtime via
`zig build test -Dtarget=wasm32-wasi -fwasmtime`). The local
`zig build ci` step bundles the Linux-job gate set (not the wasm job). The
test suite includes a hash-based corpus regression
(`src/testing/corpus.zig`): decoded RGBA planes of all 131 still images (43
lossless and 88 lossy, the latter with composed ALPH alpha) and decoded alpha
planes of all 18 ALPH-bearing files (149 rows) are compared against committed
SHA-256 hashes in `testdata/corpus-hashes.tsv`, so CI needs no `dwebp`. The
hashes lock the decoded planes that matched `dwebp` byte-for-byte in the dated
oracle runs below; regenerate with `zig build corpus-hashes` only after a fresh
corpus-wide oracle run. A parallel manifest `testdata/animation/hashes.tsv`
locks the composited frames of the 8 committed animations (29 frames total)
against `anim_dump`; regenerate with `zig build anim-hashes` after a fresh
`compare-anim` run.

The encoder has a parallel corpus harness. `src/testing/encode_corpus.zig`
round-trips a defined set of *source* images through the lossless encoder and
back through the decoder, asserting bit-exact recovery under `zig build test`:
the synthetic matrix from `src/testing/synth.zig` (edge dimensions, content,
and alpha cases, generated at test time) and the committed CC0 photographs in
`testdata/photos/` (decoded to pristine pixels). No hashes are needed — for
lossless the source pixels are the oracle. `src/testing/metrics.zig` provides
MSE/PSNR helpers for the lossy quality gates. The `zig build encode-report` tool
prints encoded size, bits-per-pixel, and the round-trip verdict per source
(committed baseline `testdata/encode-corpus-sizes.tsv`), and
`tools/webp-oracle.sh compare-encode-corpus REPORT.tsv` pairs those sizes against
`cwebp -lossless`.

Fuzz smoke targets are in place for the public decode and encode surfaces:
strict demux, VP8L still decode, alpha-plane decode, VP8 header/mode/token
parsing, public static decode composition, animated decode composition,
lossless/lossy still encode, static mux, animation mux, and pixel-buffer
animation encode. Each target uses `std.testing.fuzz` with a valid corpus seed
(framed via `src/testing/fuzz.zig` so seeds reach the parser byte-for-byte) and
runs under plain `zig build test` as a corpus + empty-input smoke pass with leak
detection. Public targets also run deterministic bounded mutation exploration
through `testing.fuzz.runMutations`, using fixed seeds and stack-only scratch so
failures are reproducible and CI-stable. Coverage-guided runs via
`zig build test --fuzz` are still blocked by an upstream Zig 0.16.0 bug: the
bundled `lib/compiler/test_runner.zig` fails to compile under fuzz
instrumentation (`*builtin.StackTrace` vs `*debug.StackTrace` mismatch). Revisit
when the toolchain updates.

Future decode-speed ratios vs libwebp should be recorded against `decode_int_ms` (dwebp's internal decode time via `-v`), which removes the recorded PAM-formatting caveat from the 10a baseline rows.

## Recently Completed

### 2026-07-13 — Plan 017: `zig-webp-info` container-probe CLI

Delivered `tools/zig-webp-info.zig` (`zig build info`, installed as
`zig-webp-info`): a webpinfo-style container probe built on the public
`parseWebP` API with no codec or public-API changes. It reports container
kind, bitstream format, canvas size, alpha/animation/metadata flags, the
ordered chunk list, unknown chunks, and (for animations) loop count,
background color, and per-frame rect/duration/dispose/blend details.
Animated files summarize per-frame bitstream formats as
`lossy (animated)` / `lossless (animated)` / `mixed (animated)` when
`features.format` is null by design. The probe relaxes demux canvas
limits (`output_pixels_max` / `animation_canvas_pixels_max` =
`maxInt(u32)`, matching other inspection tools) so large-but-valid
stills and animations can be inspected without decoding pixels.

Validation: exercised against lossless, lossy, alpha, and animation
fixtures under `testdata/`; `zig build info` with no args exits 2 with
the usage line. `zig build check` compiles the tool; README lists it
alongside the other installed CLIs.
### 2026-07-13 — Plan 015: C-ABI export layer design (PLAN.MD step 13)

Plan 015 is complete as design-only work, reviewer-verified and delivered via
PR #102 (branch `c-abi-design`). `PLAN.MD` step 13 now records the post-1.0 C ABI
contracts a later implementation plan must execute. Nothing authorizes
`src/capi.zig`, an installed header, shared-library scaffolding, or CI wiring
today — no C header, exports, or compatibility promise ships with this entry.

Recorded decisions (summary; full text in `PLAN.MD`):

- **v1 still-image scope** — probe/decode-Into/encode core only
  (`isWebP` / `parseHeader` / `parseChunkHeader` / `parseFeatures`,
  `decodeStaticInto`, `encodeLossless` / `encodeLossy`), plus C-only helpers
  `zwebp_error_category` / `zwebp_error_name`, `zwebp_free`,
  `zwebp_abi_version`, and the size-aware / limits init helpers.
  Animation, owning-pixel decode, and mux detail are deferred or non-goals
  for C v1.
- **Naming/header** — `zwebp_` prefix; one hand-written installed
  `include/zwebp.h` (not auto-emitted); CI must compile/link a C smoke
  against every shipped C artifact.
- **Error model** — `int32_t` status (`0` / negative appended-only codes for
  the FFI-reachable subset); `int32_t zwebp_error_category` returning
  `ZWEBP_ERROR_CATEGORY_*`; `zwebp_error_name` static strings; reserved
  unmapped-error fallback.
- **Memory ownership** — no allocator object across the boundary; caller-owned
  decode-Into pixels; read-only encode `zwebp_image_view`; library-owned
  encode bytes freed via `zwebp_free(ptr, len)`; Zig must gain a const-input
  encode path before C ships.
- **Struct strategy** — `struct_size` + status-returning size-aware init for
  option/config structs only; `zwebp_limits` is fixed-layout (no
  `struct_size`; status-returning `int32_t zwebp_limits_init` /
  `ZWEBP_LIMITS_INIT`, NULL → `ZWEBP_ERROR_INVALID_ARGUMENT`); nested
  limits stay fixed so option field offsets never shift; size-aware
  `int32_t zwebp_*_init(void* s, uint32_t struct_size)` (optional
  `ZWEBP_*_INIT(s)` macro) never writes past the caller's allocation;
  directional older-prefix / newer-tail rules; fixed carriers unversioned;
  fixed `zwebp_features` metadata presence is three `bool` fields
  (`has_color_profile` / `has_exif` / `has_xmp`), not a bitset.
- **FFI validation / constants** — required-pointer NULL checks, pointer/length
  `SIZE_MAX` checks, and enum-discriminant checks return
  `ZWEBP_ERROR_INVALID_ARGUMENT`; stable `ZWEBP_FORMAT_*` (pixel),
  `ZWEBP_FILE_KIND_*`, `ZWEBP_FORMAT_KIND_*` (bitstream), and
  `ZWEBP_ERROR_CATEGORY_*` (`int32_t zwebp_error_category`) constants;
  encoder codec selected by entry point (no C `ZWEBP_CODEC_*` options field);
  Into decode has no duplicate `output_format` knob.
- **Acceptance gates** — call-based header/export smoke on static and shared
  artifacts (every v1 symbol, including status-returning init helpers);
  decode-from-C and both-encoder encode-from-C smokes (encode frees via
  `zwebp_free`; NULL `zwebp_limits_init` covered); error-map /
  constant-mapping exhaustiveness (including `zwebp_features` metadata
  `has_*` → `Presence` pins); `struct_size` / init directionality.
- **Independent C ABI versioning** — `ZWEBP_ABI_VERSION` /
  `zwebp_abi_version()` and soname follow the C major, not Zig package
  minors; C stability starts when the C ABI is released.

### 2026-07-09 — Plan 019: fast big-endian CI (ReleaseSafe + 4-way shards)

The `big-endian` CI job was the slow outlier (12m49s–16m40s on 2026-07-08
runs) because the full 464-test suite ran Debug under QEMU TCG. Same-machine
baselines at `29be0df` (qemu 10.0.8): Debug 18m24s vs ReleaseSafe 4m23s
(all 464 pass). Sharding across 4 parallel simple-mode qemu processes cut
local wall time further to **215s (~3m35s)** for
`zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux
-Doptimize=ReleaseSafe -fqemu` (exit 0; four `ran 116 of 464` lines sum to
464; zero failed/leaked).

Delivered: `tools/shard_test_runner.zig` (mirrors Zig 0.16.0 default-runner
terminal + non-fuzz `fuzz` path), `-Dtest-shards` wiring in `build.zig`
(default path and `zig build ci` stay unsharded/default-runner), CI job +
docs updated. Native probes: fail/leak/misconfig all exit 1; `zig build ci`
exit 0. PR #97's `Big-endian tests (powerpc64, QEMU)` job passed in **3m9s**
(GitHub Actions run `28993818050`, job `86039146902`), completing the CI
observation gate.

Local quirk (not a regression): the sharded `.simple`-runner `.check` path
can still print a benign `failed command: …` trailer on a successful
(exit 0) run — the simple-mode runner writes its normal per-shard output
(`ran 116 of 464`, pass counts) to stderr, which the build runner surfaces
alongside the command line. The exit code is 0 and the build succeeds, so
the trailer is not a failure; read the exit code and the shard-count lines,
not the `failed command:` line. This is independent of the earlier
unsharded default-runner quirk on hosts without binfmt_misc
(`failed command: … --listen=-` under direct qemu); the sharded path does
not use the `--listen` IPC protocol.

### 2026-07-09 — 32-bit `usize` shift fix and wasm32 test gate

Follow-up to the plan 014 spike findings below (same branch). Fixed the five
`@as(usize, 1) << @as(u6, …)` sites in `src/vp8l/huffman.zig` (lines 180,
312, 339, 341, 361) by dropping the explicit `u6` and letting `@intCast`
infer `Log2Int(usize)` — `u5` on 32-bit targets, `u6` on 64-bit. A sweep of
all shift sites confirmed these were the only `usize` shifts with a
hardcoded `u6` amount; the rest shift fixed-width `u32`/`u64`/`i64` or use
`u2`/`u3`/`u5` amounts that coerce on both register widths.

Gates strengthened to cover the class: `zig build wasm-check` now also
compiles (without running) the unit tests for wasm32-wasi, forcing full
semantic analysis on a 32-bit `usize` target — the exportless static
libraries alone stayed green with the bug present. The CI `wasm` job
additionally runs the full suite under wasmtime
(`zig build test -Dtarget=wasm32-wasi -fwasmtime`). Verified locally:
464/464 tests pass on wasm32-wasi under wasmtime, including the SHA-256
corpus regression (file reads work via the `--dir=.` preopen), and
`zig build ci` stays green on the 64-bit host.

### 2026-07-09 — Plan 014: wasm32 build spike

Spike on branch `wasm32-spike` (Zig 0.16.0, wasmtime 46.0.1). No `src/` or
`tools/` changes — findings only, plus the smallest CI gate that proved true.

**Compile (step 1):**

| Target | Command | Result |
|---|---|---|
| `wasm32-wasi` | `zig build-lib src/root.zig -target wasm32-wasi -O ReleaseSmall --name zig-webp-wasm -femit-bin=…` | exit 0 |
| `wasm32-freestanding` | same with `-target wasm32-freestanding` | exit 0 |

(`-femit-bin=/dev/null` fails with LLD `UnableToWriteArchive`; use a real
path.) Both targets also succeed via the new `zig build wasm-check` step
(ReleaseSmall static libraries for wasi and freestanding, independent of
`-Dtarget`). Caveat: a static archive with no forced exports is a weak
analysis gate — full semantic analysis of Huffman table construction only
fires when tests or tools reference that path (see below).

**Test under wasmtime (step 3):**

```sh
zig build test -Dtarget=wasm32-wasi -fwasmtime
```

Failed at **compile** time (never reached the runtime / preopen question):

```
src/vp8l/huffman.zig:180:63: error: expected type 'u5', found 'u6'
    const subtable_entry_count = @as(usize, 1) << @as(u6, @intCast(extra_bits));
```

Same error on `zig test src/root.zig -target x86-linux --test-no-exec` and
on `zig build check -Dtarget=wasm32-wasi` (every tool that pulls in VP8L
Huffman). Root cause: on 32-bit targets `Log2Int(usize)` is `u5`, so a `u6`
shift amount is a type error; on 64-bit hosts `Log2Int(usize)` is `u6` and
the cast is accepted. Additional `@as(usize, 1) << @as(u6, …)` sites in the
same file (lines 312, 339, 341, 361) will need the same treatment. This is
exactly the 32-bit portability bug the spike was meant to surface — fixing
it is a follow-up plan (out of scope here).

**CI deliverable:** `.github/workflows/ci.yml` gains a `wasm` job that runs
`zig build wasm-check` only. No wasm test step until the shift-type fix
lands. README unchanged (suite does not pass on wasm). Binary size of a
useful wasm artifact was not measured — empty archives / shared-lib stubs
with no exports are not marketable numbers.

**Follow-ups:**

1. Fix `src/vp8l/huffman.zig` (and sibling `usize` shift sites) for 32-bit
   `usize`, then add a wasm32-wasi unit-test step under wasmtime
   (`--dir .` for corpus file reads). *Landed 2026-07-09 — see the entry
   above.*
2. `wasm32-freestanding` export surface + caller-owned allocator handoff
   (pairs with plan 015 / plan 012).
3. npm-publishable browser demo; ReleaseSmall size reporting once exports
   exist.

### Step 12 — Tier-1 API audit and 1.0 readiness

Plan 018 (branch `step-12-tier1-audit`, 2026-07-08) closes step 12's remaining
"stabilize APIs" and "document pixel formats, ownership, allocation behavior,
and error semantics" bullets with a recorded audit of the full Tier-1 surface:
all 16 entry points and every contract-listed type were scored against a fixed
checklist — (a) ownership/free obligations, (b) allocation bounded and stated
where budgeted against `ResourceLimits.allocation_bytes_max`, (c) notable
failure modes named and `errorCategory` coverage, (d) naming and parameter
order (`gpa` first, options bag last, `*_options`), (e) pixel-format/stride
contract wherever an `ImageBuffer` crosses the API. Both known leads from the
plan were confirmed: six parameter/result types were missing from the Tier-1
list (now added — `OwnedBuffer` via `image`, `DemuxOptions`, `MuxOptions`,
`StaticImage`, `ContainerHeader`, `ChunkHeader`; each is a new conscious freeze
commitment), and the two root-level bitstream encoders were in neither tier
(now explicitly Tier 2 in `src/root.zig` and `README.MD` — they are tooling
entry points, so freezing them would buy nothing and cost flexibility). Every
finding was doc-class; nothing moved behavior, and no Tier-1 rename was
recommended or applied. `zig build ci` passed after the fixes (2026-07-08,
464/464 tests, corpus hashes unchanged).

Findings table (fix class `doc` = documentation corrected in this pass,
`none` = checked with no action needed; `n/a` marks checklist items that do
not apply to the row):

| Name | Checklist item | Finding | Fix class |
|---|---|---|---|
| `decodeStatic` | e (a–d ok) | output stride contract was implicit ("packed"); now states stride == width × channels | doc |
| `decodeStaticInto` | a–e | checked, no finding: dest ownership, stride/format authority, scratch budget, `InvalidCanvasSize`/`UnsupportedAnimationDecode` all stated | none |
| `decodeAnimation` | b, c (a, d, e ok) | (b) allocation budget (canvas + owned frames vs `allocation_bytes_max`) undocumented; (c) `error.UnsupportedImageFormat` for 3-channel output unnamed | doc |
| `AnimationDecoder` (`init`/`next`/`reset`/`info`/`deinit`) | a, b, c (d, e ok) | root alias omitted: input bytes must outlive the decoder; demux/canvas allocation budget; `init` failure modes (`NotAnimated`, `UnsupportedImageFormat`) | doc |
| `encodeLossless` | b, c (a, d, e ok) | (b) allocation honesty unstated (canvas bounded by `output_pixels_max`, which also bounds pixel-proportional scratch; muxed file charged to `allocation_bytes_max`); (c) wrong-format error and VP8L 14-bit cap (>16384 → `InvalidVP8LHeader`) unnamed | doc |
| `encodeLossy` | b, c (a, d, e ok) | (b) enforced scratch+mux budgets unstated; (c) VP8 14-bit cap (>16383 → `InvalidCanvasSize`) and wrong-format error unnamed | doc |
| `encodeStatic` | b, c (a, d ok; e n/a) | (b) limits/budget unstated; (c) `InvalidMuxChunk` for bitstream/canvas mismatch unnamed | doc |
| `encodeAnimation` | b, c (a ok; d note; e n/a) | (b) limits/budget unstated; (c) frame-validation errors unnamed; (d) param `anim` abbreviated — cosmetic, parameter names are not API | doc |
| `encodeAnimationFromBuffers` | b, c (a, d, e ok) | (b) budget unstated; (c) empty-list `MissingImageData` unnamed; stale "optimization is a later step" (9c shipped) | doc |
| `encodeAnimationMinimized` | b, c (a, d, e ok) | (b) budget unstated; (c) `InvalidCanvasSize` for non-canvas-sized input and empty-list `MissingImageData` unnamed | doc |
| `parseFeatures` | a–d (e n/a) | checked, no finding: by-value result, budget stated, strict validation described | none |
| `parseWebP` | b (a, c, d ok; e n/a) | allocation bound unstated (parity with `parseFeatures`); doc now also states locations are offsets into `bytes` | doc |
| `isWebP` | a, d (b, c, e n/a) | checked, no finding: allocation-free stated; no errors by design | none |
| `parseHeader` | c (d ok; a, b, e n/a) | failure modes unnamed (`InputTooSmall`/`InvalidRiffSignature`/`InvalidWebPSignature`/`InvalidRiffSize`/`FileTooLarge`) | doc |
| `parseChunkHeader` | c (d ok; a, b, e n/a) | `TruncatedChunkHeader` unnamed | doc |
| `errorCategory` | c, d (a, b, e n/a) | checked, no finding: total function, exhaustive switch over `Error` (compile-enforced) | none |
| `DecoderOptions` | b–e (a n/a) | checked, no finding: `preserve_metadata`/`decode_animation` no-ops are honestly documented, recorded tradeoffs | none |
| `EncoderOptions` | c (b, d ok; a, e n/a) | `preserve_metadata` was an undocumented, never-read knob (a fourth no-op beyond the three recorded ones); now documented as reserved/no effect | doc |
| `ResourceLimits` | c (b, d ok; a, e n/a) | per-field docs absent — which limit produces which error was only readable from code; added, including that `allocation_bytes_max` meters only the paths that document it | doc |
| `ImageBuffer` | a, e (c, d ok; b n/a) | root alias said "decoded pixel plane" though it is also encoder input and `decodeStaticInto` dest; stride/row-major semantics and `validate` errors undocumented on the type | doc |
| `Dimensions` | c, d (a, b, e n/a) | checked, no finding: `init` validates via `pixelCount` (`InvalidCanvasSize`/`DimensionsOverflow`) | none |
| `PixelFormat` (via `image`) | e (d ok; a–c n/a) | per-variant byte order was stated nowhere; added (`rgba` = R,G,B,A etc.; `rgb` 3-byte, no alpha) | doc |
| `Error` | c, d (a, b, e n/a) | checked, no finding: one shared set stays (decided); additions-not-breaking rule recorded in the contract | none |
| `ErrorCategory` | c, d (a, b, e n/a) | checked, no finding: five self-describing classes; `errorCategory` exhaustive | none |
| `FeatureSummary` | a, d (b, c, e n/a) | checked, no finding: by-value, nothing to free. Note: embeds optional `container.ChunkLocation` fields — transitive field types freeze with their parent but are enumerated only at signature level | none |
| `DemuxResult` | a, d (b ok; c, e n/a) | (a) ok (`deinit` stated). (d) note: `animation_info` is module-level `animation.Info`, a distinct type from Tier-1 `AnimationInfo` (`animation_decode.Info`); same short name, reachable only via Tier-2 module exports — no action | none |
| `AnimationImage` | a–d (e n/a) | checked, no finding: root + mux docs cover placement, validation, metadata | none |
| `AnimationFrameImage` | a–e | checked, no finding: rect/duration/blend/dispose/alpha constraints documented at the type | none |
| `AnimationInfo` | a, d (b, c, e n/a) | checked, no finding: by-value; background documented as informational | none |
| `CompositedFrame` | a (d, e ok; b, c n/a) | alias claimed frames "from `decodeAnimation` are owned" — that entry point returns `DecodedAnimationFrame`, never this type; borrow window (valid until next `next`/`reset`/`deinit`) now stated at root | doc |
| `DecodedAnimation` | a, d (b, c, e n/a) | checked, no finding: `deinit` ownership stated | none |
| `DecodedAnimationFrame` | a (d, e ok; b, c n/a) | root alias had no doc; added (owned by `DecodedAnimation`, packed buffer, duration/timestamp) | doc |
| `AnimationFrameSource` | a–e | checked, no finding: stride/format, even-offset rule, per-frame codec documented | none |
| `AnimationEncodeOptions` | b–e (a n/a) | checked, no finding: limits plus shared lossy quality/method/alpha knobs documented | none |
| `AnimationFrameInput` | a–e | checked, no finding: full-canvas requirement and transparent-RGB canonicalization documented | none |
| `AnimationMinimizeOptions` | b–e (a n/a) | checked, no finding: `keyframe_interval` clamp (`keyframe_interval_max` = 4096) and `tolerance` documented | none |
| `MetadataPayloads` | a (d ok; b, c, e n/a) | alias described only the demux direction ("carried by a file"); it is also encoder input (caller-owned, must outlive the encode) — root alias now states both | doc |
| `OwnedBuffer` (via `image`, added to list) | a (d, e ok; b, c n/a) | result type of `decodeStatic` was absent from the Tier-1 list; the type had no doc (owner, `deinit`, packed stride) — both fixed | doc |
| `DemuxOptions` (added to list) | a, c, d (b ok; e n/a) | parameter type of `parseFeatures`/`parseWebP` absent from the list; `allow_trailing_data`/`strict_padding` documented nowhere public — root alias now documents them | doc |
| `MuxOptions` (added to list) | a, d (b ok; c, e n/a) | parameter type of `encodeStatic`/`encodeAnimation` absent from the list; `force_extended` undocumented — root alias now documents it | doc |
| `StaticImage` (added to list) | a–d (e n/a) | parameter type of `encodeStatic` absent from the list; existing alias doc adequate, list membership fixed | doc |
| `ContainerHeader` (added to list) | a, d (b, c, e n/a) | result type of `parseHeader` absent from the list; alias undocumented — added | doc |
| `ChunkHeader` (added to list) | a, d (b, c, e n/a) | result type of `parseChunkHeader` absent from the list; alias undocumented — added | doc |
| Known lead 1 — missing parameter/result types | contract completeness | CONFIRMED: `OwnedBuffer`, `DemuxOptions`, `MuxOptions`, `StaticImage`, `ContainerHeader`, `ChunkHeader` all appear in Tier-1 signatures but were missing from the enumerated list; all six added to the `src/root.zig` contract (truth-up, not scope expansion) | doc |
| Known lead 2 — `encodeVP8LBitstream`/`encodeVP8Bitstream` | tier classification; d | CONFIRMED unclassified; audit concludes Tier 2 (docs say "for tooling"; raw bitstream layer, no limits plumbing) — now explicit in contract and README. (d) noted: `encodeVP8Bitstream` takes `[]const VP8LARGBPixel` (a VP8L-named packed-ARGB type in a VP8 signature) and a bare `quality: u8` instead of an options bag; both are Tier-2 after classification, renameable in any release — no action for 1.0 | doc |

Applied fixes (all doc-class, commit `432dcb1`): `src/root.zig` — Tier-1 list
gains the six missing types, Tier-2 bullet names the two bitstream encoders,
and the forwarding/alias docs listed above gained ownership, budget, error,
and stride clauses; `src/options.zig` — `EncoderOptions.preserve_metadata`
documented as reserved/no-effect; `src/image.zig` — `PixelFormat` byte order,
`Buffer` row-major/stride semantics, `validate` errors, `OwnedBuffer`
ownership; `src/limits.zig` — per-field `ResourceLimits` docs; `README.MD` —
tier statement now excludes the two bitstream-level encoders from the Tier-1
`encode*` grouping (and names them Tier 2), and the stale "only open step-9
item" sentence now records the passed browser check.

**1.0.0 readiness** (2026-07-08, verified at `step-12-tier1-audit` HEAD).
Every `RELEASING.MD` gate holds:

- *CI-covered gates* (fmt, build, step-5 corpus hashes, lossless round-trip
  units): local `zig build ci` exit 0 at HEAD (464 tests), and the CI record
  for the planning commit `6d62f55` — run 28878252291, all three jobs green
  (`Format, tests, and corpus regression`; `Big-endian tests (powerpc64,
  QEMU)`; `macOS tests (aarch64)`); verified via `gh run view` (a bare
  `gh run list --commit 6d62f55` returns empty — query quirk, not a missing
  run).
- *Local-oracle gates* (all four tools resolved; every mode re-run this
  session): step-7 validity — `zig build encode-report`, 77 sources,
  **0 round-trip mismatches** (= 0.2.0 record); step-7 size —
  `compare-encode-corpus`, **median 1.0368×**, aggregate 1.0460× (≤ 1.10×
  gate, = 0.2.0 record); step-8b — `compare-encode-lossy` **0/135
  `dwebp`-invalid** (= record; the size aggregate ~1.98× is the recorded
  8c-2 `-noalpha`-baseline skew) and `encode-lossy-report` clean (34
  sources, mean luma 37.13 dB); the matched-size +0.08 dB PSNR gate result
  stands as recorded 2026-06-21 (method-4 output has been asserted
  byte-identical since); step-8c target-size — reproduced in this session's
  `zig build ci` metrics output, **0.32–2.83% off** (≤ 5% gate) and
  target-PSNR 38.01–38.08 dB achieved, digit-for-digit the recorded 8c-3
  row; animation parity — `compare-anim-corpus` over `testdata/animation`,
  **10/10 byte-exact** (= 0.2.0 record).
- *Compatibility matrix*: Linux x86_64, macOS aarch64, and big-endian
  powerpc64 rows green in the `6d62f55` CI run above; browsers row recorded
  2026-07-08 (Firefox + Chromium, both minimized samples animate correctly);
  Windows recorded-deferred with reason.

The operator chose to ship: `1.0.0` was tagged on 2026-07-08 per
`RELEASING.MD`'s release procedure (version bump in `build.zig.zon`, dated
`CHANGELOG.MD` entry, release PR, tag after merge). Plans 014 (WASM spike),
016 (m5/6 measurement), and 017 (info CLI) remain additive post-1.0
follow-ups — they were not release blockers.

### Step 12 — Release criteria (1.0 stability contract + compatibility matrix)

Plan 013 (branch `one-oh-compat-matrix`, 2026-07-07) makes the 1.0 gate's
"compatibility testing" checkable. The API stability contract is now written:
`src/root.zig`'s module doc defines two tiers (Tier 1 — the named entry
points and their parameter/result types, semver-governed at 1.0; Tier 2 —
`vp8_*`/`vp8l_*` and other module internals, no stability promise; additions
to `errors.Error` are not breaking, removals/renames of Tier 1 names are),
mirrored in `README.MD`. `RELEASING.MD` gained a "Compatibility matrix
(1.0 gate)" section defining exactly what compatibility testing means (Linux
x86_64, macOS aarch64, big-endian powerpc64 under QEMU, ≥2-browser manual
render, Windows deferred), plus the written browser-check procedure;
`PLAN.MD`'s 1.0.0 criterion now references that matrix by name. CI gained two
jobs: `big-endian` (`zig build test -Dtarget=powerpc64-linux -fqemu` on
ubuntu-latest with `qemu-user-static`) and `macos` (`zig build check` +
`zig build test` on macos-latest aarch64). The local qemu proof was skipped
by operator decision (no sudo available to install `qemu-user-static`);
powerpc64 cross-compilation was verified locally
(`zig build check -Dtarget=powerpc64-linux`, exit 0, 2026-07-07). **The
first CI run of the `big-endian` job passed (PR #92, 2026-07-07, 16m18s):
the full 464-test suite — including the byte-exact SHA-256 corpus
regression — is green on a big-endian host under QEMU; no endianness bugs
found.** The first `macos` job run failed in the `setup-zig` composite
action: macOS runners report `uname -m`/`uname -s` as `arm64`/`Darwin`,
but ziglang.org's index keys the build `aarch64-macos` (the plan's claim
that the action "works as-is on macOS" was wrong). Fixed on the same branch
with operator authorization (an out-of-plan-scope deviation): the action now
normalizes `arm64`→`aarch64` and `darwin`→`macos`, and the SHA-256 check
falls back to `shasum -a 256` where GNU `sha256sum` is absent.
Windows remains deferred: the `setup-zig` composite
action resolves `uname -m`/`uname -s` keys against `.tar.xz` archives, while
`x86_64-windows` ships as `.zip` and Git-bash `uname -s` reports
`MINGW64_NT-...`; whoever picks it up should extend the composite action, not
add a third-party action. The ≥2-browser render check (the last open step-9
item) has its procedure recorded in `RELEASING.MD`; it passed on 2026-07-08 in
Firefox and Chromium (see the step-9 paragraph in Current Position), closing
the browsers row of the compatibility matrix.

### Step 12 — Public API (caller-owned decode buffers: `decodeStaticInto`)

Plan 012 (branch `decode-static-into`, 2026-07-07) delivers the step-12
"static decode to caller-owned buffers" API. `decodeStaticInto(gpa, bytes,
dest, options)` decodes a still WebP into a caller-owned `ImageBuffer`,
row-major, honoring `dest.stride`; `dest.format` is authoritative and
`DecoderOptions.output_format` is ignored on that path. The contract:
`dest.validate()` must pass and `dest.dimensions` must exactly equal the
file's canvas (`error.InvalidCanvasSize` otherwise), both checked before any
pixel is decoded; bytes outside the written rows (stride padding, tail slack)
are left untouched; animated inputs fail with
`error.UnsupportedAnimationDecode`. The v1 implementation decodes through the
shared `decodeImage` primitive into a packed internal buffer (allocated from
`gpa` and budgeted against `limits.allocation_bytes_max` exactly like
`decodeStatic`) and row-copies into `dest`; threading the caller's stride
through the codec output stages is a recorded follow-up optimization.
`decodeStatic` itself is unchanged — it now shares a `parseStaticSource`
demux prologue with the new entry point, and the SHA-256 corpus gate pins its
output byte-for-byte.

Test evidence (2026-07-07, 464/464 passing, was 452): `src/decode.zig` adds
seven tests — byte-equality with `decodeStatic` on a lossless
(`lossless1.webp`) and a lossy (`test.webp`) corpus file, stride-padding
sentinel survival, `dest.format` overriding `output_format`,
larger-and-smaller dimension mismatches, undersized pixel slices, and
animated-input rejection. `src/testing/hardening.zig` adds five matrix rows —
`input_bytes_max`, `output_pixels_max`, `allocation_bytes_max`, clean errors
at every input truncation point, and `checkAllAllocationFailures` injection
over the internal scratch (the dest buffer is caller-provided).

### Step 11 — Robustness Hardening (slice 11d: bounded mutation exploration)

Plan 009 (branch `claude/step-11d-bounded-random-fuzz`, PR #84) adds a
deterministic, bounded mutation-exploration helper to the test fuzz harness and
wires it into every public fuzz target. `src/testing/fuzz.zig` exposes
`pub fn runMutations(body, payload, options)` which runs `variant_count`
(default 128) reproducible mutations of a known-good seed payload, each framed
like a corpus entry so the existing fuzz body's `smith.slice` read sees the
mutated bytes. Each variant applies 1–8 random byte substitutions at random
offsets and, with probability 1/8, is first truncated to a random length in
[0, payload.len] (empty included, the key parser boundary). The PRNG is a
fixed-seed `std.Random.DefaultPrng` seeded per call site from
`MutationOptions.prng_seed` — never entropy — so any failure is a permanent,
reproducible regression; all scratch lives on the caller stack (allocation-free,
payload capped at 4096). Two helper self-tests pin the call count and seed
reproducibility.

Bounded-mutation tests were added to all nine public fuzz targets
(`src/alpha.zig`, `src/animation_decode.zig`, `src/animation_encode.zig`,
`src/decode.zig`, `src/demux.zig`, `src/encode.zig` lossless+lossy,
`src/mux.zig` static+animation), each using a unique seed in `0x11d_0001`…
`0x11d_0009` so the targets diverge. The internal VP8/VP8L fuzz targets are
intentionally untouched.

Gates verified 2026-07-06 on the branch: `zig fmt --check .` pass, `zig build
check` pass, `zig build test` pass (451/451 tests). Full-suite timing was main
baseline 153.09s vs branch 154.36s (+1.26s), within noise for the 128-variant
budgets across nine targets plus the two `runMutations` self-tests.

### Step 11 — Robustness Hardening (slice 11a: limits matrix review follow-up)

Review follow-up for PR #80 closed three hardening gaps in the Step 11a matrix.
`src/testing/hardening.zig` now includes a crafted `VP8X` container with
65,536x65,536 canvas fields, proving the bitstream-reachable 24-bit dimension
overflow path rejects with `DimensionsOverflow`; the audit row no longer marks
that case unreachable. `demux.parseFeatures` now has explicit non-input limit
coverage for still canvas pixels, animation canvas pixels, chunk count, frame
count, allocation bytes, and VP8X dimension overflow, so feature probing keeps
the same untrusted-input contract as full demux. Static lossy decode now has
allocation-limit cases that fail only after demux bookkeeping, covering the VP8
decode stage and compressed `ALPH` scratch.

The lossy allocation case required a code fix, not just a test:
`src/vp8/decoder.zig` now computes and validates a frame reconstruction
allocation plan before allocating macroblocks, context rows, and padded YUV
planes; `src/decode.zig` includes that plan in the cumulative
`decodeStatic` allocation budget before allocating output pixels or optional
alpha planes. `src/alpha.zig` now also accepts a remaining allocation cap for
VP8L-compressed `ALPH` decode, pre-reserves its alpha work buffers, and passes
the leftover cap to VP8L prefix-group storage. This brings VP8 lossy color and
lossy compressed-alpha decode in line with the existing public `decodeStatic`
allocation-budget contract. Verified 2026-07-04 with `zig fmt .` and
`zig build test`.

### Step 10 — Performance Work (slice 10b: SIMD color conversion)

Slice 10b is the first optimization slice: an `@Vector` implementation of the
YUV→RGB **fancy upsampling + BT.601 conversion** (`src/color.zig`), the largest
data-parallel hot loop in lossy decode. The key enabler: `upsampleLinePair`'s
interior output pair at columns `(2x-1, 2x)` is a pure stencil over chroma
columns `(x-1, x)` and never reads previously produced output, so it has no
serial dependency. The interior was first made stateless (`upsampleInteriorPair`
reads `chroma[x-1]` directly instead of carrying it), then a SIMD path
(`upsampleInteriorSimd`/`upsampleChunk`, 8 chroma columns → 16 output pixels per
chunk) computes the diamond filter and the conversion in `@Vector(16, i32)`
lanes and stores a packed-`u32`-per-pixel vector. It runs for the 4-channel
formats on little-endian; the scalar path (unchanged, the reference) handles the
first/last/odd-width-tail pixels, `rgb`, and big-endian.

Bit-exactness: the BT.601 lanes use the same fixed-point `mulHi` (`>>8`) and the
identity `clip8(v) == clamp(v >> 6, 0, 255)` (since `yuv_fix2 == 6`), and the
diamond keeps `u`/`v` in separate i32 lanes (the scalar packed-`u32` trick was
only a scalar-ALU convenience). Verified by the committed corpus-hash gate (88
lossy stills decode byte-for-byte vs the libwebp-correct hashes, most at
SIMD-triggering widths) plus a new non-circular unit test: a wide image's `.rgb`
output (forced scalar — SIMD is 4-channel only) equals the `.rgba` SIMD path's
R/G/B, catching any diamond/interleave/store-layout bug independent of the
formula.

Measured (ReleaseFast, i5-13450HX, single thread, thermal-controlled interleaved
A/B vs `main`): **aggregate lossy decode 1.11×** (763.6→690.2 ms over the lossy
corpus), up to **1.31×** on conversion-heavy files (`vp80-00-comprehensive-008`)
and **1.2×** on lossy+alpha; lossless decode unchanged (1.02×, noise — VP8L emits
ARGB directly and never calls this path). `zig build test` green; `zig fmt`
clean. See the 2026-06-26 (slice 10b) oracle row.

### Step 10 — Performance Work (slice 10a: baseline harness)

Slice 10a is the **measurement foundation** for the performance step: it adds a
benchmark harness and records the scalar baseline, with no codec changes (the
hot loops are optimized in 10b/10c). New `tools/zig-webp-bench.zig` (`zig build
bench`) times the public entry points — `decodeStatic`, `decodeAnimation`,
`encodeLossless`, `encodeLossy` — entirely **in memory** (no PAM/file writes, so
the numbers are codec time, not disk I/O). For each input it runs untimed warmup
iterations then repeated timed iterations and reports the **median** wall-clock
time (via the `std.Io` monotonic clock), with a per-measurement time budget so a
single multi-second image cannot blow up the run. It enumerates `testdata/`
into asset classes (icon / photo / large / alpha / animation for decode; the
synthetic matrix + photos for encode) and emits a TSV with throughput in
megapixels/second. Correctness is **not** re-checked here — that stays with `zig
build test` (the committed-hash corpus regression and the encoder
self-consistency gates); the harness only measures the speed of a build that
already passes them. An optional `tools/webp-bench.sh` times libwebp's
`dwebp`/`cwebp` over the same files (skipping gracefully when absent, never a
build dependency) for a same-machine ratio.

**Baseline (2026-06-26, ReleaseFast, 13th Gen Intel Core i5-13450HX, single
thread; libwebp 1.5.0):**

- *Decode* (pixel-weighted aggregate MP/s): lossy ≈39, lossless ≈28. Per class:
  large ≈40, alpha ≈34, photo ≈28, with icon/animation dominated by per-decode
  overhead rather than throughput (tiny canvases), so MP/s understates them.
- *Decode vs single-threaded `dwebp`* (our min ÷ `dwebp` min; `dwebp` also
  formats PAM output, so the ratio mildly favors us and is indicative, not
  exact): lossy `bryce` 11158×2156 **2.5×**, `lossy_extreme` 800×534 **2.0×**;
  lossless `lossless_big_random_alpha` 2048² **1.8×**, `lossless_color_transform`
  512² **2.8×**, `photo_foliage` 512×342 (lossless) **5.6×**. Lossy decode and
  large lossless are inside the ≤3× scalar target; small/medium lossless decode
  is the clear miss.
- *Encode* (MP/s): lossless ≈1.3 (photos), lossy q75 ≈8.8 (photos). vs `cwebp`
  on `photo_foliage`: lossless 125 ms vs 88 ms (**1.4×**), lossy 22 ms vs 12 ms
  (**1.8×**) — already competitive, so decode is the optimization priority.

`zig build test` unchanged (all gates pass); `zig build check` compiles the new
tool. See the 2026-06-26 oracle row.

### Step 9 — Animation and Metadata Encode (slice 9c: frame optimization)

Slice 9c delivers **automatic frame optimization**, the inter-frame half of the
animation encoder, and completes step 9's feature set. New
`animation_optimize.encodeAnimationMinimized` (public `encodeAnimationMinimized`)
takes full-canvas frames (the desired display at each timestamp) + timing +
per-frame codec and derives a minimal `ANMF` layout that composites back to
exactly those frames; the explicit-rect `encodeAnimationFromBuffers` (9b) stays
the manual API. All four PLAN.MD §9 optimization features live in the new module:

- **Sub-rectangle detection.** `changeRect` computes the minimal bounding box of
  pixels that differ from the decoder's reconstructed previous canvas (an exact
  pixel compare, mirroring libwebp's `MinimizeChangeRectangle`), snapped to even
  offsets (the container stores offsets in 2-pixel units).
- **Inter-frame differencing + blend strategy.** Inside the diff rect, pixels
  equal to the previous canvas are made transparent and the frame is emitted as
  `alpha_blend` so the previous canvas shows through — but only when that
  reconstructs exactly (`blendCandidateExact`: every changed pixel must be fully
  opaque, a sound subset of libwebp's `IsLosslessBlendingPossible`). Otherwise
  the frame is a verbatim `replace` of the cropped target. Both stay byte-exact.
- **Dispose strategy.** A one-frame lookahead picks dispose-to-background when
  clearing this frame's rect gives the next frame a strictly smaller change rect.
  Correct regardless of the choice, because the optimizer re-tracks the canvas
  with whatever dispose it picked.
- **Keyframe insertion.** Frame 0 is a full-canvas `replace` keyframe; further
  keyframes are forced on any full-canvas change and on a bounded
  `keyframe_interval` (clamped to `[1, 4096]`).

The correctness invariant is enforced by tracking the decoder's *reconstructed*
canvas, not the source: after encoding each frame, the optimizer re-decodes the
bitstream it just produced and composites it into `prev_canvas` with the exact
`animation_decode` rules (`zeroTransparentPixels`, `blendPixelNonPremult`, the
previous background-disposed-rect skip, keyframe clear). For lossy frames this is
what keeps the round-trip valid — diffing the next frame against the source
canvas instead would accumulate error. `animation_encode` exposes one narrow hook
(`encodeFrameForOptimizer`) so both encode APIs share a single per-frame codec;
the heavy optimization logic is isolated in `src/animation_optimize.zig` (no
monolith). Canvas-sized scratch (`prev_canvas` + a target buffer) is bounded
against the allocation budget up front, and every loop is bounded by the canvas
or the clamped keyframe interval.

**CI gate (byte-exact lossless round-trip), `zig build test`, 394/394 pass, +11
new:** the gate builds several all-lossless full-canvas input sequences, encodes
via `encodeAnimationMinimized`, decodes via `decodeAnimationAlloc`, and asserts
each composited frame equals the input canvas **byte-for-byte** — covering a
static background with a small moving opaque sub-region (and asserting, via
`demux`, that at least one `ANMF` rect is smaller than the canvas, i.e. the
optimizer actually shrinks), a frame identical to the previous (degenerate 1×1
rect), a full-canvas change (forces a keyframe — full-canvas `replace`), a
transparency-reveal over an opaque background (falls back to a `replace`
sub-rect), a blend+dispose multi-frame sequence, and a forced keyframe interval
(frames 0/2/4 full-canvas at interval 2). A lossy minimized animation decodes at
the canvas dimensions without error, and the whole path survives allocation
failure at every site over a mixed lossless + lossy two-frame encode.

**Local `anim_dump` gate (libwebp 1.5.0):** two minimized 96×64 6-frame samples
(`testdata/animation/anim_minimized_lossless.webp`, `testdata/animation/anim_minimized_lossy.webp`, a
textured background with a moving 16×16 sub-region) pass
`tools/webp-oracle.sh compare-anim` — `anim_dump` matches this library's own
composition byte-for-byte across all 6 frames each (compared=2, failed=0) — and
`webpinfo` reports no errors for both. The lossless sample's frames after frame 0
are 28×28/28×40 sub-rects (the dot's bounding box); the lossy sample's are
full-canvas (see the size note below). See the third 2026-06-23 oracle row.

**Compression payoff (reported, not gated):** on the 6-frame moving-sub-region
sample the minimized lossless encode is 3840 bytes vs the naive full-canvas
`encodeAnimationFromBuffers` 4174 bytes — an 8.0% reduction. The lossy minimized
encode is byte-identical to naive (7942 bytes, 0% reduction): VP8 reconstruction
differs from the source almost everywhere, so the exact diff rect against the
reconstructed canvas is the whole canvas and every frame stays a full-canvas
keyframe. This is a deliberate correctness-first choice — libwebp shrinks lossy
frames by treating near-equal pixels as unchanged (a quality tolerance), which
trades exactness for size and is left as future work.

**Browser-render check (step-9 completion gate):** set up, not closed. The two
`testdata/animation/` animations validate cleanly under `webpinfo` and match `anim_dump`;
the manual ≥2-browser confirmation is intentionally not wired into CI (it is the
only remaining manual step-9 item).

### Step 9 — Animation and Metadata Encode (slice 9d: still-encode metadata)

Slice 9d closes the still pixel-encode metadata gap. The mux already wrote
`ICCP`/`EXIF`/`XMP ` (and `StaticImage.metadata` supported them), but the public
still encoders called it with empty metadata, silently dropping any profile/EXIF/
XMP. 9d threads metadata through.

- **API.** `EncoderOptions` (the shared options bag for both still encoders)
  gained `metadata: metadata.RawPayloads = .{}` (raw `?[]const u8`
  `color_profile`/`exif`/`xmp`, caller-owned, written verbatim). It is forwarded
  into the `mux.encodeStatic` calls in `encodeStaticLossless` and
  `encodeStaticLossy` (the latter in `encodeLossyPass`, so it also rides every
  probe of the target-size/PSNR searches). `options.zig` imports `metadata.zig`;
  `metadata.zig` imports only `container.zig`, so there is no import cycle.
- **Output.** Present metadata forces the extended (`VP8X`) container and emits
  the chunks in spec-canonical order — `VP8X` → `ICCP` → (`ALPH`) → `VP8(L)` →
  `EXIF` → `XMP `. Metadata and a lossy `ALPH` chunk coexist correctly. With
  empty metadata (the default) the output is byte-identical to the pre-9d path.
- **Allocation accounting.** The lossy pass charges the live metadata payload
  bytes against the mux allocation budget alongside the borrowed `ALPH` payload
  (`metadataByteCount`); the mux's own `validateAllocationBytes(file_size)`
  remains the authoritative gate.
- **Chunk-order honesty.** The from-pixels encoders emit canonical order (there
  is no caller-specified order to preserve on that path). Caller chunk-order
  preservation is the `mux.encodeStaticFromDemux` remux path's job (unchanged
  here, already covered by its round-trip test). Animation-level metadata stays
  owned by 9a's `AnimationImage.metadata`; 9d does not duplicate it.

Round-trip (CI gate, `zig build test`, 370/370 pass): 5 new encode tests assert
(a) `encodeLossless`/`encodeLossy` with ICCP+EXIF+XMP recover each payload
byte-exactly through `demux` with the chunks in spec order and the file an
extended (`VP8X`) container; (b) a lossy+alpha+metadata case keeps `ALPH` and the
metadata chunks in canonical order and round-trips alpha exactly; (c) the
empty-metadata lossless path is byte-identical to a direct simple-`VP8L` mux; and
(d) allocation-failure-at-every-site for both encoders with metadata present. The
existing lossy "byte-identical with target modes inert" test continues to assert
the empty-metadata lossy path is unchanged.

Browser-render check (step-9 completion gate): **set up, not closed.** Three
samples were generated via the new API and the in-main `mux.encodeAnimation` (a
metadata-bearing lossless still, a metadata-bearing lossy still, and a two-frame
lossless animation with XMP) and validated with `webpinfo` — all "No error
detected", with the ICCP/EXIF/XMP/Animation flags and chunk offsets in
spec-canonical order. The full "renders in ≥2 major browsers" gate is a manual
step best run once 9c lands frame-optimized animations; it is **not** treated as a
hard gate for this slice and **not** added to CI. See the second 2026-06-23
oracle row.

### Step 9 — Animation and Metadata Encode (slice 9b: pixel-level encode)

Slice 9b delivers the **pixel-level** animation encoder — the animated analogue
of the still `encodeLossy`/`encodeLossless`. `animation_encode.encodeAnimationFromBuffers`
(public `encodeAnimationFromBuffers`) takes a caller-supplied ordered list of
pixel-buffer frames, encodes each to a bitstream, and muxes them via slice 9a.

- **Inputs.** A `FrameSource` carries the frame's `image.Buffer` (any supported
  pixel format), its even canvas offset (`x`/`y`), duration, blend/dispose
  methods, and per-frame codec (`.lossy`/`.lossless`). The buffer's own
  dimensions are the frame rectangle. An `Options` struct carries the canvas,
  loop count, background, animation-level metadata, resource limits, and the
  shared per-frame `quality`/`method`/`alpha_quality` knobs.
- **Per-frame encode reuses the still machinery** rather than reimplementing
  codecs: `encode.gatherArgbAlloc` gathers the frame's ARGB, then a lossless
  frame runs `vp8l_encoder.encodeAlloc` (VP8L carries its own alpha) and a lossy
  frame runs `color.rgbaToYuv420Alloc` + `vp8_encoder.encodeAlloc`, plus
  `alpha.encodePlaneAlloc` into an `ALPH` payload when the plane carries
  transparency (a fully-opaque lossy frame is a plain `VP8 `). Each frame's
  scratch is freed before the next; the per-frame allocation budgets mirror
  `encode.zig`'s. The caller dictates the rectangle/blend/dispose; inter-frame
  optimization is slice 9c.
- **Mux and validation.** The encoded frames go straight into
  `mux.encodeAnimation`, which re-validates every rectangle (inside the canvas,
  even offsets), bitstream dimensions, alpha placement, and the frame/chunk
  limits — so this layer leans on the mux for the container rules and adds only
  the canvas/frame-count fast-fail and per-buffer `validate()`.

Round-trip (CI gate, `zig build test`, 378/378 pass, +13 new): an all-lossless
full-canvas-keyframe animation composites back **byte-for-byte** to its source
frames through `decodeAnimationAlloc` (the full pixel round-trip); further tests
cover a lossy frame (decodes at the right dimensions), a lossless sub-rect over a
keyframe, a lossless alpha frame and a lossy+alpha frame (alpha recovered
exactly), per-frame blend/dispose (a background-disposed sub-rect clears for the
next frame), loop count + background round-trip, metadata pass-through, the input
errors (empty list, odd offset, rect outside canvas) and the frame-count limit,
and survive allocation failure at every site (`checkAllAllocationFailures` over a
mixed lossless + lossy-alpha animation). Validity (local, libwebp 1.5.0):
`tools/webp-oracle.sh compare-anim` confirms `anim_dump` of four generated
animations (lossless full-canvas, lossless sub-rect with background-dispose,
lossy full-canvas, mixed lossless + lossy-alpha with alpha-blend) matches this
library's own composition byte-for-byte across all 8 frames, and `webpinfo`
reports "No error detected" for all four. See the second 2026-06-23 oracle row.
Inter-frame sub-rectangle/differencing optimization (9c) remains.

### Step 9 — Animation and Metadata Encode (slice 9a: container mux)

Slice 9a delivers the animation **container muxer** — the step-9 analogue of
`encodeStatic`. `mux.encodeAnimation` (public `encodeAnimation`) assembles
already-encoded frame bitstreams into a valid animated WebP; it does not encode
pixels (that is slice 9b).

- **Inputs.** `AnimationImage` carries the canvas, loop count, background color,
  optional metadata, and an ordered list of `AnimationFrameImage` frames. Each
  frame supplies its rectangle, duration, blend/dispose methods, codec
  (`.lossy`/`.lossless`), the raw `VP8 `/`VP8L` bitstream, and an optional lossy
  `ALPH` payload — the bitstream-carrying analogue of `StaticImage`.
- **Output layout.** `VP8X` (animation flag + canvas) → optional `ICCP` → `ANIM`
  (background + loop count) → one `ANMF` per frame (16-byte frame header +
  optional `ALPH` + image) → optional `EXIF`/`XMP `. The `VP8X` alpha flag is set
  iff any frame carries alpha.
- **Validation.** Every frame's rectangle must lie inside the canvas with even
  offsets (the container stores them in 2-pixel units), its bitstream dimensions
  must equal the rectangle, `ALPH` is rejected on `.lossless` frames, and the
  duration fits the 24-bit field — the same constraints `demux` enforces on read,
  so a muxed animation always round-trips. Resource limits bound frame count,
  chunk count, and the single output allocation.

Round-trip (CI gate, `zig build test`, 365/365 pass): 12 new tests mux
multi-frame lossy+lossless animations and parse them back through `demux`
(rects, durations, blend/dispose, loop count, background, metadata), cover the
validation errors (odd offset, lossless+`ALPH`, rect outside canvas, dimension
mismatch, empty list) and the frame-count limit, and survive allocation failure
at every site. Validity (local, libwebp 1.5.0): a 32×32 two-frame animation
built from real library-encoded frames (lossless full-canvas + lossy 16×16
sub-rect with background dispose) is accepted by `webpinfo` ("No error
detected"), listed correctly by `webpmux -info`, and decoded to per-frame images
by `anim_dump`. See the 2026-06-23 oracle row. Pixel-level `encodeAnimation`
from buffers (and the `anim_dump`-matches-our-composition gate), inter-frame
optimization, and metadata-from-pixels are slices 9b–9d.

### Step 8 — VP8 Lossy Encoder (step 8c: controls and parity)

Step 8c completes the VP8 lossy encoder with its controls and parity features,
landed as an options scaffold plus four reviewable slices. Every piece keeps its
default path byte-identical to the 8b encoder and holds `dwebp` validity at
0/135 invalid:

- **Scaffold.** Inert `EncoderOptions` knobs (`method`, `target_size`,
  `target_psnr`, `alpha_quality`, `use_sharp_yuv`) and an `EncodeConfig` struct
  on `vp8.encoder.encodeAlloc`, landed first so the four slices could be built
  in parallel without colliding on the public surface.
- **8c-1 — method/effort knob.** `method` (0..6, `cwebp -m` compatible) scales
  the rate-distortion search via an `Effort` tier (DC-only at 0–1, all 16x16 /
  chroma modes at 2–3, full B_PRED + segmentation at 4–6). Method 4 (the
  default) is byte-identical to the 8b encoder; methods 5–6 currently clamp to 4
  (no extra search above the 8b baseline yet — the knob's present value is the
  faster low end: m2 ≈ 2.2x and m0 ≈ 3.4x faster than m4).
- **8c-2 — lossy+alpha (`ALPH`).** The straight (non-premultiplied) alpha plane
  is row-filtered and stored as the cheaper of uncompressed or a headerless VP8L
  stream (reusing the step-7 encoder), emitted as a `VP8X`+`ALPH`+`VP8 `
  container; `alpha_quality` selects 0 = uncompressed / 1..100 = lossless VP8L.
  Fully-opaque inputs stay byte-identical to the color-only path. Alpha
  round-trips byte-exactly through `decodeStatic` and `dwebp -pam`.
- **8c-3 — target-size / target-PSNR.** A bounded (≤8-probe) binary search over
  the quantizer index hits a requested byte size or BT.601 luma PSNR; both
  unset → byte-identical to the single-pass quality path, both set →
  `error.InvalidEncodeOptions`. The `ALPH` payload is encoded once and reused
  across probes (it is independent of the color quantizer).
- **8c-4 — sharp-YUV.** Optional iterative (bounded 4-pass Gauss–Seidel) chroma
  downsampling (`use_sharp_yuv`) that minimizes the residual against the
  decoder's fancy upsampler; the default box-average path is unchanged.

The step-8c acceptance gate holds: the method-preset matrix encodes the corpus
with no validity regression (0/135 across methods) and target-size lands within
5% (0.32–2.83% on the photos). See the five 2026-06-22 oracle rows. With step 8c
done the VP8 lossy encoder is feature-complete; remaining lossy work is
performance (step 10) and release hardening (step 11).

### Step 8 — VP8 Lossy Encoder (slice 8a)

The first VP8 lossy encoder slice emits a valid `VP8 ` key-frame bitstream with
a deliberately fixed mode decision; real mode decision and quality are step 8b.
The correctness rule is self-consistency: the encoder reconstructs every
macroblock through the same inverse routines the decoder uses, so a conforming
decoder reproduces the stored reconstruction bit-for-bit. New and changed code:

- `src/color.zig` gains the forward RGB→YUV420 conversion (BT.601 with libwebp's
  `VP8RGBToY/U/V` coefficients, a 2x2 chroma box-average, and edge-replicated
  macroblock padding). Color comes from raw RGB regardless of alpha, so a fully
  transparent pixel keeps its hidden color — the transparent-RGB case 8a must
  handle exactly.
- `src/vp8/forward_transform.zig` is the encode pair of `transform.zig`: a
  forward 4x4 DCT and forward WHT, locked by round-trip unit tests against the
  inverse routines before anything depends on them.
- `src/vp8/quant.zig` gains forward quantization (a bias-toward-zero quantizer
  reusing the existing dequant tables, with a matching dequantize helper) and a
  monotone quality→quantizer-index map.
- `src/vp8/tokens.zig`, `src/vp8/modes.zig`, and `src/vp8/frame_header.zig`
  promote their previously test-only encode mirrors to production: coefficient
  token emission (`writeBlock` / `writeMacroblock`), key-frame mode writing
  (`encodeKeyFrameModes`), and the compressed first-partition header writer —
  each the exact inverse of the corresponding parser, sharing its tables so the
  halves cannot drift.
- `src/vp8/encoder.zig` orchestrates the per-macroblock raster loop: DC-predict
  from reconstructed neighbors, forward-transform the residual, quantize,
  reconstruct through the shared inverse routines, and emit the quantized levels
  as tokens. It writes partition 0 (compressed header + all-DC mode records) and
  the single token partition, then assembles the frame with the back-patched
  first-partition size.
- The public API gains `encodeLossy` / `encodeStaticLossy` (typed pixel buffer →
  muxed `VP8 ` WebP file; alpha is dropped until 8c) and `encodeVP8Bitstream`
  (raw VP8 payload), wired through `src/encode.zig` and `src/root.zig`.
- `encodeStaticLossy` now accounts for its ARGB copy, YUV source/reconstruction
  planes, VP8 partition/token scratch, raw VP8 bitstream, and final mux output
  against `EncoderOptions.limits.allocation_bytes_max` before large scratch
  buffers are allocated.

Validity and the self-consistency gate run under `zig build test`:
`src/testing/encode_corpus.zig` encodes every synthetic source and committed
photo through the low-level encoder, decodes the result, and asserts the
decoder's YUV planes equal the encoder's reconstruction byte-for-byte; the
smooth photos and a flat fully-transparent field additionally clear an RGB PSNR
floor, and the public `encodeStaticLossy`+`decodeStatic` path round-trips at the
source dimensions. New tooling: `zig build encode-lossy-report` reports size,
bits-per-pixel, and luma PSNR per source, `zig build encode-lossy` re-encodes a
WebP as lossy, and `tools/webp-oracle.sh compare-encode-lossy` feeds every
encoded file to `dwebp` for the external validity check and pairs sizes against
`cwebp -q -noalpha` (matching step 8a's alpha-dropping behavior). Deep encoder
fuzzing and allocation-failure depth stay deferred to step 11, though the public
path already passes `checkAllAllocationFailures`.
The lossy oracle fails on still-image encode errors, reference-tool failures,
and empty validation sets; only animated files are skipped after `webpinfo`
classification.

### Encode Test Corpus (pre-step-8 harness)

Before the VP8 lossy encoder (step 8), the encode side gained a defined source
corpus and measurement harness, because step 8's gates are measured on source
images rather than on decoded WebP files:

- `src/testing/synth.zig` generates a deterministic matrix of 30 synthetic
  sources crossing VP8 macroblock geometry (1x1; 15/16/17 luma-block edges;
  asymmetric partials; primes; 1xN/Nx1 strips; larger canvases), content (flat,
  gradient, high-frequency checker, saturated bars, noise, radial,
  neutral-chroma ramp, two-tone), and alpha (opaque, ramp, binary, and
  fully-transparent pixels carrying non-zero RGB — the case step 8a must handle
  exactly). Nothing is committed; the images are rebuilt at test time.
- `testdata/photos/` holds four committed CC0 photographs (a face, a foliage
  macro, signage with text, and a sunset gradient) downscaled to a 512 px
  longest side and stored as `cwebp -lossless` WebP, so they decode to pristine
  pixels. Licenses and provenance are in `testdata/photos/PROVENANCE.md`.
- `src/testing/encode_corpus.zig` round-trips every synthetic source and every
  committed photo through `encodeStaticLossless` and back through the decoder,
  asserting bit-exact recovery under `zig build test` (the in-tree lossless
  corpus is already round-tripped by `corpus.zig`). All 30 synthetic sources and
  4 photos round-trip with zero mismatches.
- `src/testing/metrics.zig` provides MSE and PSNR (overall plus BT.601 luma,
  using libwebp's `VP8RGBToY` weights so step-8 figures line up with `cwebp`).
- Tooling: `zig build encode-report [-- --with-corpus] [OUT.tsv]` reports
  encoded size, bits-per-pixel, and round-trip per source (committed baseline
  `testdata/encode-corpus-sizes.tsv`); `tools/webp-oracle.sh
  compare-encode-corpus REPORT.tsv` pairs our sizes against `cwebp -lossless`.

This concretely realizes step 7's "encode corpus", which previously named the
unversioned "libwebp gallery images": a committed CC0 photo set plus the
synthetic matrix and the in-tree lossless files. Re-measured against
`cwebp -lossless` (libwebp 1.5.0) over the 43 in-tree lossless files plus the 4
photos, the per-file median size ratio is 1.0368x (aggregate 1.046x), so the
step-7 1.10x median gate still holds; the photographic files (1.05x–1.18x on the
photos, up to 1.59x on `lossless2`/`lossless3`) remain the known gap that
per-block predictor selection will close.

### Step 7 — VP8L Lossless Encoder (slice 3)

The third encoder slice adds entropy-coding depth on top of slice 2's
transforms, all in `src/vp8l/encoder.zig` (mirroring the decode side's
`color_cache.zig`, `meta_prefix.zig`, `prefix_groups.zig`, and the group-store
entropy path in `entropy.zig`):

- An optional color cache. The LZ77 token stream is lowered to an "op stream"
  while simulating the decoder's cache exactly: lowering reads the materialized
  main-image pixels so every copied pixel is inserted into the cache just as the
  decoder inserts it, and a literal whose pixel already sits at its hashed slot
  is emitted as a cache-index green symbol (`green_base + index`), the exact
  inverse of `color_cache.zig` + the cache path in `entropy.zig`. A guard gives
  any empty channel histogram a single symbol so the prefix code stays a valid
  single-leaf tree — this matters for a solid all-zero image whose first pixel
  hits the zero-initialized cache and emits no literals at all.
- An optional entropy image / multiple Huffman groups (meta-prefix). The image
  is tiled into prefix blocks (block-size log2 in [3,5]); per-block green
  histograms are clustered greedily (L1 distance, bounded at 16 groups); the
  entropy image (group index per block, red high byte / green low byte) is
  emitted as a transform-role single-group literal stream, followed by the
  per-group prefix codes and a symbol stream that selects each op's group by its
  starting block. This inverts `meta_prefix.zig` + `prefix_groups.zig`.
- Both choices are gated by *measuring the real encoded size*: each candidate
  (single group with each candidate cache size, and the multi-group plan) is
  fully encoded into a scratch buffer and the smallest is re-emitted into the
  output. Because the comparison is exact, a candidate is never kept when it
  would enlarge the output, so slice 3 is never larger than slice 2 on any file.

Validity and round-trip stay gated by `zig build test`: the slice-1 corpus
round-trip test still passes with the richer encoder, and new tests cover a
cache-friendly repeated-palette image, the cache-hit/copy-insert lowering rules
(white-box on `lowerOps`), the empty-cache solid-image edge case, and a
two-region image whose `planMultiGroup` is asserted to open at least two groups
and which round-trips through the multi-group emission path.

### Step 7 — VP8L Lossless Encoder (slice 2)

The second encoder slice adds compression transforms on top of slice 1's
literal output, each the exact inverse of the corresponding decode routine so
every combination still round-trips bit-exactly through this library's decoder:

- LZ77 back-reference matching (`src/vp8l/lz77.zig`): a hash-chain greedy
  matcher over packed ARGB pixels emits literal/copy tokens. `prefixForValue`
  inverts the decoder's `image_data.readPrefixValue` (length and distance
  prefix symbols + extra bits), and `distanceCodeForPixels` inverts
  `distanceFromCode` by emitting the direct `distance + 120` code form
  (matches are capped at `(1 << 20) - 120` pixels so the code is always
  representable). Copies extend the green channel's alphabet with length
  symbols and use the distance prefix code, exactly as the decoder reads them.
- Forward transforms (`src/vp8l/forward_transform.zig`): subtract-green, the
  per-block color transform (signed 3.5 fixed-point green→red / green→blue /
  red→blue multipliers), the per-block predictor transform (all 14 modes), and
  the color-table delta coding for palettes. Each is the bit-exact inverse of
  `inverse_transform.zig` (proven by per-mode round-trip unit tests).
- The encoder (`src/vp8l/encoder.zig`) now plans a transform stack: a
  palette / color-indexing transform for images with at most 256 distinct
  colors (with the decoder's index bit-packing for 2/4/16/256-color tables and
  a delta-coded color table), or, for higher-color images, a single global
  predictor mode (chosen by minimizing a residual-magnitude proxy) followed by
  the cheaper of a color transform or subtract-green (mutually exclusive so
  red/blue are not adjusted twice). Each transform is applied only when its
  estimated gain is positive. The main image is then LZ77-tokenized and
  entropy-coded. Prefix-code descriptors now pick the cheapest of the simple
  form (1–2 length-1 symbols) and the normal form with run-length packing
  (code-length repeat codes 16/17/18), which slashed the per-file overhead on
  small images (e.g. the 1x1 `lossless_vec_1_*` files dropped from 382 to 48
  bytes).

Validity and round-trip stay gated by `zig build test`: the slice-1 corpus
round-trip test (decode every still VP8L corpus file to RGBA, re-encode, decode,
assert bit-identical) still passes with the richer encoder, and new synthetic
cases cover low-color palettes (including odd-width 1-bit-packed indices),
LZ77-friendly repetition, and a chroma-correlated image whose transform plan is
asserted to include the color transform.

### Step 7 — VP8L Lossless Encoder (slice 1)

The first encoder slice emits valid still VP8L bitstreams from ARGB literals
only — no LZ77 backward references, no transforms, and no color cache yet. A
canonical Huffman writer (`src/vp8l/huffman_writer.zig`) is the exact inverse
of the decoder's reader (`src/vp8l/huffman.zig`): it assigns length-limited
canonical code lengths from a histogram, then emits codes in the reader's
canonical (length, symbol) order with the same bit-reversal, including the
single-leaf zero-bit exception and a length-limited build for the 7-bit
code-length-code. The encoder (`src/vp8l/encoder.zig`) writes the VP8L image
header, a "no transform" terminator, the no-color-cache / single-prefix-group
flags, the five prefix-code descriptors (green/red/blue/alpha/distance) in
normal form, and the per-pixel literal symbol stream, all through the existing
LSB-first `BitWriter`. The public API gains `encodeLossless` (typed pixel
buffer → muxed simple `VP8L` WebP file, any RGBA/BGRA/ARGB/RGB input honoring
stride) and `encodeVP8LBitstream` (ARGB → raw VP8L payload), wired in
`src/encode.zig` and `src/root.zig` and muxed via the existing
`mux.encodeStatic`.

Validity and round-trip are gated by committed tests under `zig build test`:
synthetic edge cases (1x1, solid color, two-axis gradient, full-range alpha,
single-row, single-column) plus a corpus test that decodes every still VP8L
file in `testdata/libwebp-test-data` to RGBA, re-encodes it, decodes the
re-encoded bytes, and asserts the pixels are bit-identical to the source.
Size is not gated for this slice (LZ77/transforms come next).

### Step 6 — Extended Decode and Animation

Animated WebP decode is implemented in `src/animation_decode.zig`, composing
frames onto a canvas to match libwebp's `anim_dump` byte-for-byte. The
container layer (`src/demux.zig`) already enforced the `VP8X` feature flags and
extended chunk-ordering rules and parsed `ANIM`/`ANMF` (frame rectangles,
durations, dispose/blend methods, background color, loop count) into
`animation.Info`/`animation.Frame`; step 6 adds the pixel decode and
compositing on top.

Each frame is reconstructed through the shared still decoder
(`decode.decodeImage`, extracted in the first step-6 slice so VP8/VP8L/alpha is
reused rather than duplicated). Compositing replicates libwebp exactly: a
transparent-canvas start (the `ANIM` background color is informational only),
keyframe detection that clears the canvas, source-over non-premultiplied alpha
blend (blend method 0) or verbatim copy (method 1), the skip of blending inside
a previous frame's background-disposed rectangle, dispose-to-background between
frames, and the zeroing of fully transparent pixels' RGB (libwebp's animation
decoder, unlike `-exact` static decode, does not preserve it). The blend math
is the integer `BlendPixelNonPremult` approximation libwebp uses for
`MODE_RGBA`.

Two public entry points share the compositor: `decodeAnimation` returns every
composited frame as its own buffer, and the streaming `AnimationDecoder`
(`init`/`next`/`reset`/`info`/`deinit`) yields one frame at a time over a reused
canvas for bounded memory. A new `error.NotAnimated` rejects still inputs;
animation requires a 4-channel output format. The `zig build anim` tool and the
`compare-anim` / `compare-anim-corpus` oracle modes mirror the still tooling,
and `tools/zig-webp-anim-hashes.zig` (`zig build anim-hashes`) regenerates the
committed frame-hash manifest. A fuzz smoke target covers the animation entry
point.

### Step 5 — VP8 Lossy Decoder

Key-frame header parsing is implemented in `src/vp8/frame_header.zig` on top
of the existing boolean reader: frame tag (key-frame/version/show-frame
validation), picture header (start code, dimensions, scale codes), and the
compressed first-partition header through color space, segmentation, loop
filter, token partition layout, quantizer indices, `refresh_entropy_probs`,
DCT coefficient probability updates, and the skip probability. The RFC 6386
default and update token probability tables live in
`src/vp8/token_probs.zig`, transcribed from the normative tables and
cross-checked value-for-value between `references/libwebp` and
`references/ffmpeg` before committing. All 88 lossy still files in the
committed corpus parse with dimensions matching demux features.

Macroblock prediction record parsing is implemented in `src/vp8/modes.zig`
on top of a generic RFC 6386 treed read added to the boolean reader:
per-macroblock segment ids, coefficient-skip flags, key-frame 16x16 luma and
chroma intra modes, and B_PRED subblock modes with above/left contexts
(including the derived contexts that 16x16 modes contribute). The key-frame
mode trees and the 10x10x9 `kf_bmode_prob` table are transcribed from RFC
6386 and were cross-checked value-for-value against `references/libwebp` and
`references/ffmpeg` under their permuted mode enumerations. Prediction
records for all 88 lossy still files in the committed corpus parse without
error, and a fuzz smoke target covers the record parser.

Dequantization factor resolution is implemented in `src/vp8/quant.zig`: the
RFC 6386 section 14.1 dc/ac lookup tables (cross-checked value-for-value
against `references/libwebp` and `references/ffmpeg`), index clamping,
per-segment quantizer resolution (absolute and relative), the y2_dc doubling,
the y2_ac 155/100 scaling with its floor of 8 (comptime-verified equivalent
to libwebp's fixed-point form), and the uv_dc saturation at 132.

Coefficient token decode is implemented in `src/vp8/tokens.zig`: the RFC
6386 section 13 token tree as explicit branches, coefficient bands with the
position-16 sentinel, zigzag scatter, extra-bit categories with MSB-first
probabilities (cat6 reaching 2114; the RFC's "67 - 2048" comment is wrong),
sign bits, dequantize-at-store with wrapping i16 semantics, per-plane
first-coefficient handling (Y-after-Y2 starts at 1), left/above nonzero
contexts at subblock granularity, the skipped-macroblock rule that preserves
Y2 context for B_PRED macroblocks, and implicit-skip reporting for the loop
filter. The boolean reader now zero-pads short initial loads (tiny final
token partitions are valid; `vp80-05-sharpness-1430.webp` splits 4 bytes
across partitions) and `BoolReader.init` no longer fails. A corpus test
decodes every coefficient of all 88 lossy still files end-to-end (modes,
per-row partition selection, contexts) without error.

The inverse transforms are implemented in `src/vp8/transform.zig`: the
exact-integer inverse 4x4 DCT (columns then rows, lone `(x+4)>>3` rounder,
Q16 constants 20091/35468 with the K-1 split) fused with add-to-prediction
and unconditional [0,255] clamping, and the inverse Walsh-Hadamard transform
for Y2 with its distinct (0,3)/(1,2) butterfly pairing and `(x+3)>>3`
rounder. Arithmetic uses wrapping i32 ops so hostile wrapped-i16
coefficients cannot panic. Unit vectors were generated independently from
the RFC pseudocode (twice) rather than from reference C code.

Intra prediction kernels are implemented in `src/vp8/prediction.zig` as
pure functions over explicit neighbor values: 16x16 luma and 8x8 chroma
DC (with the edge-variant denominators and the 128 no-neighbor case),
V/H/TM, and all ten 4x4 B_PRED modes including the B_VL final-pixel
exceptions and the RFC's `svg2p` typo resolution. Unit vectors were
computed independently from the RFC formula tables; synthetic-border
identities (127/129) are covered. Neighbor gathering (frame edges, the
fixed top-right rule for subblocks 3/7/11/15) belongs to the
reconstruction slice.

Full-frame reconstruction is implemented in `src/vp8/decoder.zig`: the
whole-frame decode loop (persistent per-partition token readers selected by
row, nonzero contexts, Y2 WHT scatter before luma IDCTs), a bordered
scratch macroblock with the synthetic 127/129 edges, left-sample rotation
including the above-left corner, top-sample snapshots taken from the
unfiltered reconstruction, the fixed top-right rule for right-edge
subblocks, B_PRED predict/add interleaving, and macroblock-padded plane
output with ceil-rounded chroma crop dimensions. The `zig build yuv` tool
and the `compare-yuv` / `compare-yuv-corpus` oracle modes (plus their
`-nofilter` variants) mirror the alpha tooling.

The in-loop deblocking filter is implemented in `src/vp8/loop_filter.zig`
(RFC 6386 section 15) and runs as a final pass over the reconstructed,
macroblock-padded planes — deferring every edge to after whole-frame
reconstruction is bit-identical to libwebp's row pipeline because intra
prediction only ever reads the unfiltered above-row snapshot. The simple
(2-tap) and normal (4/6-tap) kernels, the high-edge-variance and
interior-smoothness tests, and the per-segment / per-prediction-size
strength derivation (sharpness narrowing, loop-filter ref/mode deltas, and
the `f_inner |= has-nonzero-coefficients` rule, where the nonzero flag is
`decodeMacroblock`'s return) are transcribed from `references/libwebp` and
cross-checked against the normative text. Macroblocks are filtered in raster
order, each applying left / inner-vertical / top / inner-horizontal edge
groups in libwebp's exact sequence. Decoding exposes
`DecodeOptions{ .apply_loop_filter }` so the tool can still emit
`dwebp -nofilter`-equivalent output for regression isolation.

The YUV-to-RGB conversion layer is implemented in `src/color.zig` as a pure
function over borrowed planes: the BT.601 fixed-point conversion and the
"fancy" bilinear chroma upsampler (with its mirror-at-the-boundary first/last
row handling) are transcribed from `references/libwebp` (`src/dsp/yuv.h`,
`src/dsp/upsampling.c`, `src/dec/io_dec.c`) and produce bit-identical output
to libwebp's scalar path. Because conversion is implementation-defined rather
than RFC-fixed, correctness is pinned to `dwebp -pam` (which defaults to
fancy upsampling) instead of to a spec formula. The `zig build rgb` tool and
the `compare-rgb` / `compare-rgb-corpus` oracle modes (plus their
`-nofilter` variants) mirror the YUV tooling; alpha-bearing lossy files are
handled by the alpha-composition stage described next.

The public `decodeStatic` decodes lossy stills end-to-end: it reconstructs the
YUV frame, converts with fancy upsampling, and composes the decoded ALPH plane
(when present and the output format carries alpha) verbatim over the result —
lossy WebP uses straight, non-premultiplied alpha, so RGB is left untouched.
The `compare-rgb` oracle and the `zig-webp-rgb` tool no longer skip
alpha-bearing files. Lossless and lossy stills are byte-exact against the
committed plane hashes, closing the step 5 decode gate.

## Completed Steps

### Step 0 — Project Foundation

Package-level API types, resource limits, corpus helpers, current
`zig build test` coverage, and optional local oracle tooling are in place.

### Step 1 — RIFF/WebP Container

Done for static container scope. Strict demux covers RIFF sizing, padding,
chunk order, duplicate chunks, unknown chunks, trailing data, simple
`VP8 `/`VP8L`, `VP8X` feature probing, raw metadata exposure, and chunk
locations. Static mux/remux writes valid canonical chunk ordering and
preserves metadata payloads.

### Step 2 — Core Bitstream Infrastructure

Bounded little-endian byte readers/writers, LSB-first bit readers/writers,
VP8L canonical Huffman table construction/lookup, and VP8 boolean arithmetic
reader/writer are implemented with unit, invalid-input, round-trip, and
compile-time capacity tests.

### Step 3 — VP8L Lossless Decoder

Done for still-image lossless corpus scope. VP8L image header parsing,
transform-list parsing and dimension bookkeeping, single-prefix-group
image-data Huffman parsing, code-length repeat handling, color-cache
metadata validation, distance mapping, bounded entropy-stream scanning, and
no-transform single-prefix-group ARGB materialization for literals, LZ77
copies, color-cache references, and meta-prefix entropy image parsing are
implemented with focused tests. Multiple Huffman group storage and
meta-prefix selection during main-image entropy decode are also in place.
Subtract-green, predictor, color, and color-indexing inverse transform
support are wired into the limited raw VP8L decoder. Main-image
meta-prefix/group-store entropy decoding is available through the
allocator-backed raw decoder path. Public static lossless decode composition
is available for still VP8L images.

### Step 4 — Alpha Chunk Decode

Alpha-plane decode is done; composition with lossy VP8 color output is
tracked under step 5. ALPH header parsing (compression, filter,
preprocessing, reserved-bit validation), uncompressed alpha stream decode,
the none/horizontal/vertical/gradient unfilters, and VP8L-compressed alpha
decode through the headerless VP8L image-stream entry point are implemented
in `src/alpha.zig` with unit, invalid-input, filter round-trip, and corpus
decode tests. The committed oracle workflow (`compare-alpha`/
`compare-alpha-corpus` modes backed by the `zig build alpha` plane-dump
tool) compares decoded ALPH planes against the alpha region of
`dwebp -alpha -pgm`.

Note: strict demux keeps its lenient ALPH policy (reserved bits tolerated
and canonicalized on remux); the decode path rejects them like `dwebp`.

## Oracle Results

| Date | Scope | Result |
|---|---|---|
| 2026-06-11 | VP8L still-image decode vs `dwebp` PAM output | Matched all 43 VP8L files in `references/libwebp-test-data`; 88 non-lossless files skipped. |
| 2026-06-12 | ALPH plane decode vs `dwebp -alpha -pgm` | Matched all 18 ALPH-bearing files byte-for-byte (both compression methods, all four filters, color cache); 113 non-ALPH files skipped. |
| 2026-06-12 | Pre-loop-filter VP8 reconstruction vs `dwebp -nofilter -yuv` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (Y, U, and V planes), plus 43 locally generated `cwebp` files (qualities 10-95, segments, filter/sharpness settings, odd dimensions down to 1x1); 43 non-lossy corpus files skipped. |
| 2026-06-13 | Filtered VP8 decode vs plain `dwebp -yuv` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (Y, U, and V planes), plus 31 locally generated `cwebp` files exercising both the simple (`-nostrong`) and normal (`-strong`) filters, filter strengths 0/20/60, qualities 8-92, sharpness 0/4/7, and odd dimensions down to 1x1; 43 non-lossy corpus files skipped. The `-nofilter` oracle still matches. |
| 2026-06-14 | VP8 YUV-to-RGB + fancy upsampling vs `dwebp -pam` | Matched all 70 lossy-without-alpha still files in `libwebp-test-data` byte-for-byte (full RGBA PAM), plus 84 locally generated `cwebp` files (two-axis gradients at odd dimensions 1x1 through 64x48, qualities 5-95, simple and normal filters, segments + sharpness 7); 61 non-lossy / lossy+alpha corpus files skipped. The `-nofilter` oracle matches all 154 too. |
| 2026-06-14 | Composited lossy RGBA (with ALPH alpha) vs `dwebp -pam` | Matched all 88 lossy still files in `libwebp-test-data` byte-for-byte (full RGBA PAM), now including all 18 lossy+alpha files via ALPH composition, plus 18 locally generated `cwebp` lossy+alpha files (RGBA gradients at odd dimensions 1x1 through 64x48, qualities 30-95, alpha quality 60-100, full-range alpha); 43 non-lossy corpus files skipped. Both the filtered and `-nofilter` oracle modes match. |
| 2026-06-14 | Composited animation frames vs `anim_dump -pam` (libwebp 1.5.0) | Matched 14 locally generated animations byte-for-byte across all composited frames (`img2webp` lossless/lossy/mixed plus `webpmux`-assembled frames): every dispose×blend combination, full-canvas and sub-rect frames, binary and gradient alpha, background-dispose with overlapping and disjoint rectangles, and canvases from 2x1 to 100x80. The 8 most representative (29 frames) are committed under `testdata/animation` with SHA-256 frame hashes in `testdata/animation/hashes.tsv`. |
| 2026-06-16 | VP8L literal encoder round-trip (own decoder + `dwebp`) | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode (ARGB literals only) and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus test). Locally, `dwebp -pam` also decodes the encoder's output bit-exactly to the source on `lossless_vec_2_0.webp` (128x128); `dwebp` is not on CI, so CI relies on the own-decoder round-trip. Encoded size is ~1.28x the original corpus bytes (literals only; size is not gated this slice). |
| 2026-06-16 | VP8L transform encoder (slice 2) round-trip + size vs `cwebp -lossless` | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode with LZ77 + the decision-gated subtract-green/color/predictor/palette transforms and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus test, runs under `zig build test`). Locally `dwebp` (libwebp 1.5.0) also decodes all 43 re-encoded files to pixels byte-identical to the originals (full corpus cross-check, 0 mismatches). Size vs `cwebp -lossless` (cwebp 1.5.0, default settings, same decoded source pixels): per-file median ratio 1.0986x (37/43 files at or below 1.10x; range 0.92x–1.63x), aggregate-bytes ratio 1.044x. Size is reported, not yet hard-gated; the worst cases are small/synthetic vector images where cwebp's entropy-image and color-cache machinery (slice 3) wins. |
| 2026-06-16 | VP8L entropy encoder (slice 3) round-trip + size vs `cwebp -lossless` | All 43 still VP8L files in `testdata/libwebp-test-data` re-encode with the slice-2 transforms plus the optional color cache and optional entropy-image/multiple-Huffman-groups, each chosen by measuring the real encoded size, and decode back bit-exactly to the source RGBA via this library's decoder (committed corpus round-trip test, runs under `zig build test`). Locally `dwebp` (libwebp 1.5.0) decodes all 43 re-encoded files to pixels byte-identical to the originals (full corpus cross-check, 0 mismatches). Size vs `cwebp -lossless` (cwebp 1.5.0, default settings, same decoded source pixels): per-file median ratio 1.0368x (37/43 files at or below 1.10x; range 0.92x–1.59x), and no file is larger than the slice-2 encoding (the measure-by-encoding selection only keeps genuine wins). The remaining files above 1.10x are the photographic `lossless1`–`lossless4` / `lossless_color_transform` / `near_lossless_75`, which need per-block predictor selection (a later refinement) to close the gap. The 1.10x median size gate for step 7 holds against `cwebp` on this corpus; the PNG comparison is not yet recorded. |
| 2026-06-18 | Encode test corpus round-trip + lossless size vs `cwebp -lossless` | New pre-step-8 harness. Round-trip (CI gate, runs under `zig build test`): all 30 synthetic sources (macroblock-edge dimensions × content × alpha) and the 4 committed CC0 photos (512px) re-encode through `encodeStaticLossless` and decode back bit-exactly, 0 mismatches; the 43 in-tree lossless files stay covered by the existing corpus round-trip test. Size (reported, via `tools/webp-oracle.sh compare-encode-corpus`) over 47 real-image files (43 in-tree lossless + 4 photos), `cwebp -lossless` (libwebp 1.5.0), identical decoded source pixels: per-file median ratio 1.0368x, aggregate 1.046x (range 0.92x–1.59x; the 4 photos 1.05x–1.18x). Confirms the step-7 1.10x median gate on the now-defined encode corpus. |

| 2026-06-19 | VP8 lossy encoder (slice 8a) round-trip + validity vs `dwebp`/`cwebp` | New baseline encoder. Self-consistency (CI gate, runs under `zig build test`): the decoder reproduces the encoder's reconstruction byte-for-byte at the YUV layer for all 30 synthetic sources (every macroblock geometry × content × alpha, including the transparent-RGB case) and the 4 committed photos; the public `encodeStaticLossy`+`decodeStatic` path round-trips at the source dimensions. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 encoded still files (4 photos + 131 in-tree corpus stills, lossless and lossy sources re-encoded) without error — 0 failures. Quality (reported, not gated): mean BT.601 luma PSNR 37.1 dB over the 34-source report at q75 (photos 34.7–40.8 dB); encoded size median 1.17x and aggregate 1.464x vs `cwebp -q 75 -noalpha` — a DC-only baseline with no rate-distortion, to be closed by step 8b. |
| 2026-06-20 | VP8 lossy encoder (slice 8b-1) intra mode decision: self-consistency + validity + quality vs 8a | Replaces the fixed all-DC decision with a per-macroblock intra mode choice: each macroblock picks its 16x16 luma mode and its shared 8x8 chroma mode among DC/V/H/TM by a rate-distortion score (reconstruction SSE plus a quantizer-scaled penalty on coded coefficients, weight 1 chosen by measurement). B_PRED (4x4 luma intra) stays deferred to slice 8b-2. Self-consistency (CI gate, `zig build test`): the decoder still reproduces the encoder's reconstruction byte-for-byte at the YUV layer across every macroblock geometry × content × alpha and the 4 photos — now exercising TrueMotion at the left frame edge via a single-column geometry, and a neighbor-gather unit test pins the decoder-mirroring above-left corner (synthetic 129 at column 0 / row > 0) that all-DC never read. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 encoded stills without error — 0 failures (the 8a validity gate holds). Quality (reported, not gated, q75): on the 4-photo corpus mean BT.601 luma PSNR 37.97 → 38.07 dB (+0.10) while total photo bytes drop 72,496 → 69,124 (−4.7%) — every photo improves on both PSNR and size; over the 30 synthetic+photo sources with finite PSNR in both baselines, +0.11 dB at −4.4% bytes. (The 34-source report mean reads lower than 8a only because `alpha_gradient_32x32` now reconstructs losslessly — PSNR ∞ — and the report excludes ∞ from its mean; it is an improvement, not a regression.) |
| 2026-06-20 | VP8 lossy encoder (slice 8b-2a) token bit-cost rate model | Replaces slice 8b-1's nonzero-coefficient rate proxy with an accurate VP8 token bit-cost model: `src/vp8/cost.zig` holds `VP8EntropyCost` (transcribed value-for-value from `references/libwebp` `src/dsp/cost.c`; index 128 = 256 fixes the 1/256-bit unit), and `tokens.blockCost` mirrors `writeBlock`/`writeBlockTokens`/`writeLargeValue` boolean-for-boolean to return the exact ideal coding cost. The 16x16-luma and chroma rate-distortion decisions now weigh reconstruction SSE against real coded bits via a quantizer-scaled Lagrange multiplier (λ ∝ AC-step², tuned by measurement). Self-consistency (CI gate, `zig build test`) and `dwebp` validity (0/135 invalid) hold unchanged. Quality (reported, q75): on the 4-photo corpus the mean luma PSNR is unchanged (38.065 dB) at 1.1% fewer bytes (69,124 → 68,386); over the 30 finite-PSNR synthetic+photo sources, −0.025 dB at −2.0% bytes; the per-file median size vs `cwebp -q 75 -noalpha` improves from 1.169x to 1.124x over the 135-file corpus. The standalone gain is small by design — the model's purpose is the rate-accurate 16x16-vs-B_PRED comparison slice 8b-2b needs. |
| 2026-06-20 | VP8 lossy encoder (slice 8b-2b) B_PRED intra mode | Adds B_PRED (per-subblock 4x4 luma intra) to the mode decision. Each macroblock now also evaluates B_PRED — choosing one of the ten 4x4 intra modes per luma subblock by rate-distortion (subblock SSE + the slice-8b-2a token bit cost + the submode-tree signaling cost via `modes.treeCost`) — and the 16x16-vs-B_PRED choice compares full luma RD costs including each mode's signaling. The encoder mirrors the decoder's bordered scratch (synthetic borders plus the fixed macroblock-row top-right for right-edge subblocks), so the self-consistency gate holds for B_PRED too: a new test confirms B_PRED is selected on detailed content and the decoder reproduces the reconstruction byte-for-byte. `has_y2` is now per-macroblock (B_PRED codes its luma DC per subblock, with no Y2 block). Because B_PRED codes far more mode data, very large detail-rich frames can overflow VP8's 19-bit first-partition size; the encoder detects this and re-encodes the frame with B_PRED disabled (a rare second pass), so every corpus file still encodes. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid (including the 11158x2156 `bryce` via the fallback). Quality (reported, q75): on the 4-photo corpus mean BT.601 luma PSNR 38.07 → 39.57 dB (+1.51) at 6.6% fewer bytes (68,386 → 63,862) — every photo gains ~1.1–2.1 dB; over the 30 finite-PSNR synthetic+photo sources, +1.04 dB at −7.8% bytes; the per-file median size vs `cwebp -q 75 -noalpha` improves from 1.124x to 1.088x over the 135-file corpus. |
| 2026-06-21 | VP8 lossy encoder (slice 8b-3a) skip decisions + loop-filter selection | Adds two header-level quality features. A macroblock whose residue quantizes entirely to zero is now coded as `mb_skip_coeff` (no residual tokens emitted), with the frame's `prob_skip_false` derived from the realized skip ratio (libwebp `CalcSkipProba`); skip coding is always enabled, which is valid for any ratio and avoids a buffering pass. The RFC 6386 §15 in-loop deblocking filter runs at a level chosen from the AC quantizer (libwebp `SetupFilterStrength`, single segment, default `-f 60`, sharpness 0, normal filter; e.g. q75 → level 10), and the encoder filters its finished reconstruction in place via the decoder's own `loop_filter.applyFrame`. Self-consistency (CI gate, `zig build test`): intra prediction reads only unfiltered pixels during the pass, so filtering the whole frame afterward leaves the decoder's filtered output byte-identical to the encoder's stored reconstruction; the gate now exercises both skip and filtering (q75 → level 10), with new tests that flat content is skipped, that filtering actually changes pixels (and unfiltered decode does not match), and that the level / skip-probability heuristics hold. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid. Quality (reported, q75): on the 4-photo corpus mean BT.601 luma PSNR 39.65 → 39.99 dB (+0.34) at +0.08% bytes (63,614 → 63,668; every photo flat-or-better in PSNR, foliage also smaller); over the 34-source report +0.48 dB (36.82 → 37.30); per-file median size vs `cwebp -q 75 -noalpha` unchanged at 1.088x. The PSNR gain is entirely the deblocking filter (skip never alters the reconstruction); skip coding is byte-neutral on this textured corpus — it shrinks low-detail content but the per-frame skip overhead offsets that on busy photos — and pays off more on flat content. Segmentation (adaptive quant) and the matched-size PSNR gate close in slice 8b-3b. |

| 2026-06-21 | VP8 lossy encoder (slice 8b-3b) segmentation: matched-size luma-PSNR gate vs `cwebp -q 75 -m 4` | Adds adaptive per-segment quantization — the step-8b gate slice. A pre-pass (`src/vp8/segment.zig`) buckets macroblocks into up to four segments by luma complexity (summed \|AC\| of the source luma subblocks, integer 1-D k-means, ≤6 iterations) and assigns each segment a quantizer delta on the frame base — finer for busier segments, the SSE-optimal direction, spread ±4 indices — emitted through the new `frame_header.writeSegmentation` and the per-macroblock segment map (`modes.encodeKeyFrameModes`). Flat/uniform or low-variation frames keep segmentation off, byte-identical to 8b-3a. The encoder reconstructs each macroblock with its segment's factors — exactly what the decoder resolves from the header via `quant.segmentFactors` — so the self-consistency gate holds. Self-consistency (CI gate, `zig build test`): the decoder reproduces the encoder's reconstruction byte-for-byte across every macroblock geometry × content × alpha and the 4 photos, plus a new mixed flat/textured case that exercises ≥2 segments; `frame_header.writeSegmentation` round-trips through `parseSegmentation` and `segment.zig` unit tests cover the k-means split, the uniform-collapse fallback, and the tree-probability derivation. Validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0): `dwebp` decodes all 135 stills, 0 invalid; the per-file median size vs `cwebp -q 75 -noalpha` is unchanged at 1.088x (the symmetric spread is bit-neutral at a fixed base quantizer). **Gate (matched output size, photo corpus, BT.601 luma PSNR vs `cwebp -q 75 -m 4`):** mean 40.79 dB vs cwebp 40.70 dB, **+0.08 dB** — inside the 1.0 dB target and ahead of `cwebp`; per photo: foliage +0.42, sky +0.31, portrait +0.04, signage −0.44 (sizes matched within 0.2–4.2%). Against the 8b-3a uniform-quant baseline at matched size (−0.02 dB vs cwebp), segmentation adds +0.10 dB. The spread magnitude was tuned by measurement: the matched-size gain plateaus across spreads 2..5 (≈+0.1 dB), is neutral by spread 6, and goes negative by spread 12 (coarsened segments then lose more than refined ones gain). |

| 2026-06-22 | VP8 lossy encoder (slice 8c-1) method/quality effort knob | Honors `EncodeConfig.method` (0..6, `cwebp -m` compatible) to scale the rate-distortion search via an `Effort` tier (`src/vp8/encoder.zig`), threaded `encodeAlloc` → `encodeFramePass` → `encodeMacroblock` → `selectLuma`/`selectChroma`: methods 0–1 code DC-only (no B_PRED, no segmentation), 2–3 evaluate all four 16x16/chroma intra modes, 4–6 run the full search (B_PRED + segmentation). **Method 4 — the default, matching the 8b gate's `-m 4` — is byte-identical to the 8b encoder** (asserted by test); methods 5–6 clamp to 4, i.e. no extra search above the 8b baseline yet, so the knob's present value is the faster low end. Self-consistency (CI gate, `zig build test`) and `dwebp` validity (`tools/webp-oracle.sh compare-encode-lossy`, libwebp 1.5.0: 0/135 invalid) hold. Quality/speed (reported, 4 photos, q75): m4 and m6 identical in size and PSNR; m2 ≈ 2.2x faster than m4 (~10 vs ~22 ms) at −0.9 to −1.4 dB luma; m0 ≈ 3.4x faster (DC-only). |
| 2026-06-22 | VP8 lossy encoder (slice 8c-2) lossy+alpha via the `ALPH` chunk | `encodeStaticLossy` encodes the straight (non-premultiplied) alpha plane into an `ALPH` chunk and emits a `VP8X`+`ALPH`+`VP8 ` container; a fully-opaque input still emits a plain `VP8 ` file byte-identical to the color-only path. Alpha is lossless: the plane is row-filtered (best of none/H/V/gradient) and stored as the cheaper of uncompressed or a headerless VP8L stream (`src/alpha.zig` `encodePlaneAlloc`, reusing the step-7 encoder's new `encodeImageStreamAlloc`), the exact inverse of `alpha.zig` decode; `encode_options.alpha_quality` selects 0 = uncompressed / 1..100 = lossless VP8L. Round-trip (CI gate, `zig build test`): the synth RGBA alpha cases (ramp, binary checker, transparent-over-nonzero-RGB) recover the alpha plane byte-exactly through `decodeStatic`; fully-opaque output is asserted byte-identical to the `VP8 `-only path. Validity: locally `dwebp -pam` recovers alpha byte-for-byte on the re-encoded libwebp alpha fixtures (all four filters + the color-cache fixture), and `compare-encode-lossy` is 0/135 invalid. Note: the `compare-encode-lossy` *size* ratio is now skewed (aggregate ~1.98x) because our output carries `ALPH` alpha while its `cwebp -q -noalpha` baseline strips it — validity is the gate; a fair alpha-vs-alpha size comparison needs an alpha-carrying `cwebp` baseline (a tooling follow-up). |
| 2026-06-22 | VP8 lossy encoder (slice 8c-3) target-size / target-PSNR modes | `EncoderOptions.target_size` (bytes) and `target_psnr` (dB) drive a bounded (≤8-probe, `search_passes_max`) binary search over the quantizer index, re-encoding each probe and keeping the closest-to-target candidate; both unset → byte-identical to the single-pass quality path (asserted at q0/25/50/75/100), both set → `error.InvalidEncodeOptions`. target-PSNR measures full-range BT.601 luma PSNR of the reconstruction (the metric `cwebp` reports). Alpha rides through the search unchanged: the `ALPH` payload is encoded once and reused across probes. Gates (CI `zig build test`, 345/345 pass; `dwebp` `compare-encode-lossy` 0/135 invalid): on the 4 photos target-size lands 0.32–2.83% off (step-8c gate ≤5%), target-PSNR 38.0 dB → 38.01–38.08 dB achieved; a new test confirms target-size on an alpha source still recovers alpha byte-exactly. **This slice carries the step-8c target-size gate and completes the VP8 lossy encoder.** |
| 2026-06-22 | VP8 lossy encoder (slice 8c-4) sharp (iterative) RGB→YUV chroma | Adds `color.rgbaToYuv420SharpAlloc`, selected by `encodeStaticLossy` when `encode_options.use_sharp_yuv` is set; the default (false) box-average path is byte-identical to before (asserted). Sharp starts from the box grid and runs a bounded 4-pass integer Gauss–Seidel refinement that minimizes, per chroma cell, the residual between the full-resolution chroma target (`rgbToU`/`rgbToV`) and what the decoder's fancy upsampler reconstructs over that cell (a closed-form 9:3:3:1 diamond matching `upsampleFancy`, gated by test); luma is left at full resolution. Self-consistency holds (sharp changes only the source chroma, not the encoder-vs-decoder equivalence). Validity: locally `dwebp` 1.5.0 decodes all 4 sharp photo outputs; `compare-encode-lossy` 0/135 invalid. Quality (reported): on an isolated saturated red/blue color edge the converter gains +2.20 dB RGB PSNR at matched size (13.89 → 16.09); end-to-end (encode q75 → decode, sharp vs box) RGB PSNR +0.55–1.36 dB on signage/foliage/sky and −0.03 dB on portrait — but at matched *quality*, so sharp preserves more chroma detail and the outputs run slightly larger (a matched-size comparison would narrow the gain to roughly the isolated-converter figure). Merged, briefly reverted (#66), and re-applied (#67) during integration; net result is in `main`. |
| 2026-06-23 | Animation container mux (slice 9a) accepted by `webpinfo`/`webpmux`/`anim_dump` | New `mux.encodeAnimation` (public `encodeAnimation`) assembles already-encoded frame bitstreams into an animated WebP: `VP8X` (animation flag + canvas) → optional `ICCP` → `ANIM` (background + loop count) → one `ANMF` per frame (16-byte frame header + optional lossy `ALPH` + `VP8 `/`VP8L`) → optional `EXIF`/`XMP `. It does not encode pixels — `AnimationImage`/`AnimationFrameImage` carry the bitstreams, the animated analogue of `StaticImage`/`encodeStatic`. Every frame's rectangle (inside the canvas, even offsets), codec, bitstream dimensions, and alpha are validated, and the `VP8X` alpha flag is set iff any frame carries alpha — the same constraints `demux` enforces on read, so a muxed animation always round-trips. Round-trip (CI gate, `zig build test`, 365/365 pass): 12 new tests mux multi-frame lossy+lossless animations and parse them back through `demux` (rects, durations, blend/dispose, loop count, background, metadata), cover the validation errors (odd offset, lossless+`ALPH`, rect outside canvas, dimension mismatch, empty list) and the frame-count limit, and survive allocation failure at every site. Validity (local, libwebp 1.5.0): a 32×32 two-frame animation built from real library-encoded frames (lossless full-canvas + lossy 16×16 sub-rect with background dispose) is accepted by `webpinfo` ("No error detected"), listed correctly by `webpmux -info`, and decoded to per-frame PNGs by `anim_dump`. This is the step-9 container layer; pixel-level `encodeAnimation` from buffers (and the `anim_dump`-matches-our-composition gate) is slice 9b. |
| 2026-06-23 | Still-encode metadata (slice 9d) round-trips through `demux`; samples validate under `webpinfo` | `EncoderOptions` gained `metadata: metadata.RawPayloads = .{}`, threaded into the `mux.encodeStatic` calls in `encodeStaticLossless`/`encodeStaticLossy` (the latter via `encodeLossyPass`, so it rides every target-size/PSNR probe). The public still encoders (`encodeLossless`/`encodeLossy`) can now attach raw `ICCP`/`EXIF`/`XMP ` (the mux already wrote them; this closes the from-pixels API gap). Present metadata forces the extended (`VP8X`) container; the chunks emit in spec-canonical order (`VP8X` → `ICCP` → (`ALPH`) → `VP8(L)` → `EXIF` → `XMP `) and coexist with a lossy `ALPH`. `options.zig` imports `metadata.zig`, which imports only `container.zig` — no import cycle. Round-trip (CI gate, `zig build test`, 370/370 pass): 5 new tests assert lossless and lossy both recover ICCP+EXIF+XMP byte-exactly through `demux` with chunks in spec order; a lossy+alpha+metadata case keeps `ALPH`+metadata in canonical order and round-trips alpha exactly; the empty-metadata lossless path is byte-identical to a direct simple-`VP8L` mux (the lossy empty-metadata path stays covered by the existing 8c-3 byte-identical test); and allocation-failure-at-every-site holds for both encoders with metadata present. Chunk-order honesty: the from-pixels path emits canonical order (no caller-specified order to preserve); the `mux.encodeStaticFromDemux` remux path preserves unknown-chunk order. Browser-render gate set up, not closed: three samples (metadata-bearing lossless still, lossy still, and a 2-frame lossless animation with XMP via in-main `mux.encodeAnimation`) validate under `webpinfo` ("No error detected", ICCP/EXIF/XMP/Animation flags set, chunks in spec order); the ≥2-browser manual check is deferred to once 9c lands frame-optimized animations and is not in CI. |
| 2026-06-23 | Pixel-level animation encode (slice 9b) `anim_dump` matches our composition | New `animation_encode.encodeAnimationFromBuffers` (public `encodeAnimationFromBuffers`) encodes a caller-supplied ordered list of pixel-buffer frames into an animated WebP — the animated analogue of `encodeLossy`/`encodeLossless`. Each `FrameSource` (an `image.Buffer` + even canvas offset + duration + blend/dispose + lossy/lossless codec) is encoded by reusing the still machinery (`encode.gatherArgbAlloc`, then `vp8l_encoder.encodeAlloc` for lossless, or `color.rgbaToYuv420Alloc` + `vp8_encoder.encodeAlloc` + `alpha.encodePlaneAlloc` for lossy+alpha) and muxed via slice 9a; the caller dictates each frame's rectangle/blend/dispose (inter-frame optimization is 9c). Round-trip (**CI gate, `zig build test`, 378/378 pass, +13 new**): an all-lossless full-canvas-keyframe animation composites back **byte-for-byte** to its source frames via `decodeAnimationAlloc`; further tests cover a lossy frame (right dims), a lossless sub-rect over a keyframe, a lossless and a lossy+alpha frame (alpha recovered exactly), per-frame blend/dispose (background-dispose clears a sub-rect for the next frame), loop count + background + metadata round-trip, the input errors (empty list, odd offset, rect outside canvas) and the frame-count limit, and survive allocation failure at every site over a mixed lossless + lossy-alpha animation. **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim` — `anim_dump` of four generated animations (lossless full-canvas, lossless sub-rect with background-dispose, lossy full-canvas, mixed lossless + lossy-alpha with alpha-blend) matches this library's own composition byte-for-byte across all 8 frames (compared=4, failed=0), and `webpinfo` reports "No error detected" for all four.** This carries the step-9 pixel-path gate; sub-rectangle/differencing optimization (9c) remains. |
| 2026-06-23 | Animation frame optimization (slice 9c) byte-exact lossless round-trip + `anim_dump` parity; ≈8% lossless reduction vs naive | New `animation_optimize.encodeAnimationMinimized` (public `encodeAnimationMinimized`, module `src/animation_optimize.zig`) takes full-canvas frames + timing + per-frame codec and auto-derives a minimal `ANMF` layout that composites back to exactly those frames: **sub-rectangle detection** (minimal bounding box vs the decoder's reconstructed previous canvas, even-snapped), **inter-frame differencing + blend strategy** (equal-to-prev pixels made transparent under `alpha_blend` when it provably reconstructs exactly — every changed pixel fully opaque — else verbatim `replace`), **dispose** (one-frame lookahead picks background when it shrinks the next diff rect), and **keyframe insertion** (frame 0, any full-canvas change, bounded `keyframe_interval`). Reuses the 9b per-frame encoder via one narrow hook (`encodeFrameForOptimizer`) and the 9a mux. Correctness key: the optimizer tracks the decoder's **reconstructed** canvas — re-decoding each frame it emits and compositing with the exact `animation_decode` rules (transparent-RGB zeroing, source-over non-premultiplied blend, previous background-disposed-rect skip) — so lossy error never accumulates. **CI hard gate (byte-exact lossless round-trip), `zig build test`, 394/394 pass, +11 new:** all-lossless minimized animations decode byte-for-byte back to the input canvases across a static-background-with-moving-sub-region (asserted via `demux` to actually shrink at least one `ANMF` rect below the canvas), a degenerate identical frame (1×1 rect), a full-canvas change (forced keyframe), a transparency-reveal (replace fallback), a blend+dispose multi-frame sequence, and a forced keyframe interval (frames 0/2/4 full-canvas at interval 2); a lossy minimized animation decodes at the right dims; allocation failure survived at every site. **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim`** on two minimized 96×64 6-frame samples (`testdata/animation/anim_minimized_lossless.webp`, `testdata/animation/anim_minimized_lossy.webp`) — `anim_dump` matches this library's composition byte-for-byte across all 6 frames each (compared=2, failed=0), and `webpinfo` reports "No error detected" for both. **Compression (reported, not gated):** minimized lossless 3840 B vs naive `encodeAnimationFromBuffers` 4174 B (8.0% smaller, sub-rect frames 28×28/28×40); minimized lossy byte-identical to naive (7942 B, 0%) — VP8 reconstruction differs almost everywhere so the exact diff rect is full-canvas every frame, a deliberate correctness-first choice (libwebp's quality-tolerance lossy shrink is future work). Step 9 is now feature-complete; the ≥2-browser render check is set up (the two `testdata/animation/`) but manual and not in CI. |
| 2026-06-23 | Lossy animation frame optimization (slice 9c-2) shrinks lossy sub-rects, PSNR within tolerance of naive, ≈48% smaller | Extends `animation_optimize.encodeAnimationMinimized` so **lossy** frames are inter-frame optimized instead of emitted as full-canvas keyframes. The change rect is now detected against a **source-quality carryover** canvas (the original input pixels carried frame to frame, dispose clears applied — mirroring libwebp's `canvas_carryover`), not the noisy reconstruction, so VP8 noise (which 9c's exact diff flagged almost everywhere → full-canvas every frame) no longer inflates the rect. A pixel counts as unchanged via a per-channel content-change tolerance `T` (libwebp's `PixelsAreSimilar`: alpha must match, each RGB channel diff alpha-weighted ≤ `T·255`). New `AnimationMinimizeOptions.tolerance: ?u8 = null` defaults to a quality-derived value (`qualityToMaxDiff`, libwebp's `QualityToMaxDiff`: 31 at q=0, ≈5 at q=75, 1 at q=100); lossless frames force `T = 0` (exact) with a carryover equal to the reconstruction, so the byte-exact lossless path is **unchanged**. The blend/transparent path stays lossless-only (lossy sub-rects are always verbatim `replace`); inherited regions come from the previous decoded frame and drift is bounded by `keyframe_interval`. **CI gates, `zig build test`, 398/398 pass, +4 new:** the 9c all-lossless byte-exact round-trips still pass unchanged (hard lossless gate); a lossy 64×48 5-frame moving-region animation shrinks ≥1 `ANMF` rect below the canvas (asserted via `demux`) and decodes valid; the optimized lossy mean luma PSNR (`src/testing/metrics.zig`, vs the source) stays within **0.5 dB** of the naive `encodeAnimationFromBuffers` full-canvas encode and the optimized stream is strictly smaller; `qualityToMaxDiff`/`pixelsSimilar` unit-checked at reference points; allocation failure survived at every site (now three carryover buffers). **Gate (local, libwebp 1.5.0): `tools/webp-oracle.sh compare-anim`** on a generated 96×64 8-frame lossy minimized sample — `anim_dump` matches this library's composition byte-for-byte across all 8 frames (compared=1, failed=0), and `webpinfo` reports "No error detected" (frame 0 a full-canvas keyframe, frames 1–7 shrunk to 22×22 sub-rects). **Compression (reported):** lossy minimized **1390 B vs naive 2680 B (48.1% smaller)** at q=75, mean luma PSNR **45.96 vs 45.82 dB (+0.14 dB, not a loss** — the inherited gradient is quantized once at the keyframe rather than re-noised each frame). Tolerance chosen: ≤0.5 dB below naive, justified because the only quality difference is inherited (non-rect) regions carrying the previous frame's lossy values; the measured delta is comfortably positive. Closes 9c's "lossy = full-canvas keyframes, future work" caveat. |
| 2026-06-26 | Performance baseline (slice 10a) via new `zig build bench`; scalar decode/encode throughput + same-machine libwebp ratio | New `tools/zig-webp-bench.zig` (`zig build bench`) times the public `decodeStatic`/`decodeAnimation`/`encodeLossless`/`encodeLossy` entry points **in memory** (no file I/O), reporting the median of repeated timed runs (via the `std.Io` monotonic clock) with a per-measurement time budget, over `testdata/` asset classes (decode: icon/photo/large/alpha/animation; encode: synthetic matrix + 4 CC0 photos). No codec change — pure measurement; correctness stays with `zig build test` (committed-hash regression + encoder self-consistency), which the harness assumes. An optional `tools/webp-bench.sh` times `dwebp`/`cwebp` over the same files (graceful SKIP when absent, never a build dependency). **Baseline (ReleaseFast, 13th Gen Intel Core i5-13450HX, single thread, libwebp 1.5.0; 213 rows):** decode pixel-weighted aggregate ≈39 MP/s lossy, ≈28 MP/s lossless. Same-machine vs single-threaded `dwebp` (our min ÷ `dwebp` min; `dwebp` also formats PAM output, so indicative not exact): lossy `bryce` 11158×2156 **2.5×**, `lossy_extreme` 800×534 **2.0×**; lossless `lossless_big_random_alpha` 2048² **1.8×**, `lossless_color_transform` 512² **2.8×**, `photo_foliage` 512×342 (lossless) **5.6×**. Encode vs `cwebp` on `photo_foliage`: lossless 125 ms vs 88 ms (**1.4×**), lossy q75 22 ms vs 12 ms (**1.8×**). Read honestly: lossy decode and large lossless are inside the ≤3× single-threaded scalar target; small/medium VP8L lossless decode (2.8–5.6×) is the miss and the priority for 10b/10c; the encoder is already competitive. Timing is environment-dependent and **not** a CI gate. `zig build test` unchanged; `zig build check` compiles the tool. |

| 2026-06-26 | SIMD YUV→RGB color conversion (slice 10b): 1.11× lossy decode, byte-exact | `@Vector` rewrite of `color.upsampleLinePair`'s interior (fancy chroma upsample + BT.601 conversion), the largest data-parallel hot loop in lossy decode. Each output pair is a stencil over chroma columns `(x-1, x)` with no dependency on prior output, so it vectorizes; an 8-chroma-column (16-pixel) chunk computes the diamond and conversion in `@Vector(16, i32)` lanes and stores a packed-`u32`-per-pixel vector, for the 4-channel formats on little-endian. The scalar path is unchanged and remains the reference for boundaries, odd-width tail, `rgb`, and big-endian. **Bit-exact (CI gate, `zig build test`):** the committed corpus-hash regression (88 lossy stills → byte-for-byte vs libwebp-correct hashes, most at SIMD widths) still passes, plus a new non-circular equivalence test (wide-image `.rgb` scalar output == `.rgba` SIMD output for R/G/B). **Speed (local, thermal-controlled interleaved A/B vs `main`, ReleaseFast, i5-13450HX, single thread):** aggregate lossy decode **1.11×** (763.6→690.2 ms over the lossy corpus), up to **1.31×** on conversion-heavy files and ~1.2× on lossy+alpha; lossless decode unchanged (1.02×, noise — VP8L never calls this path). Reduces the `bryce` lossy-decode ratio vs single-threaded `dwebp` from ≈2.5× to ≈2.3×. Honest note: scalar micro-restructuring of the inverse transforms / IDCT DC fast-path was prototyped and rejected as code-layout noise (those stages aren't the bottleneck); the remaining lossless gap is the serial entropy decoder (already a fast multi-level Huffman table), documented as future work. |
| 2026-06-26 | VP8 boolean-reader renormalization (slice 10c): 1.20× lossy decode, byte-exact | Replaces the VP8 bool reader's one-shift-at-a-time renormalization loop with a compile-time 128-entry shift-count table plus one bulk shift/load step. The arithmetic split and lazy truncation behavior are unchanged; this only removes per-bit loop overhead in the entropy hot path used by mode parsing and coefficient token decode. **Bit-exact (CI gate, `zig build test`):** the full suite and committed corpus-hash regression pass. **Speed (local, ReleaseFast, single thread, same benchmark harness):** aggregate lossy decode **1.20×** (699.5→583.3 ms over 88 lossy stills on this machine), `bryce` **563.1→475.5 ms** (local ratio vs `dwebp -pam` ≈1.96×→≈1.65×), `vp80-00-comprehensive-008` **10.03→8.84 ms**, `lossy_extreme_probabilities` **15.6→9.8 ms**. Lossless decode is unchanged in substance because VP8L does not use this reader. Rejected in the same investigation: scalar loop-filter index reshaping (byte-exact, no measurable win) and a dedicated probability-128 `readBit` path (slightly slower). Remaining lossy levers are loop-filter SIMD/lookup tables, row-pipeline locality, and threading. |

Record new milestones here as dated rows: corpus, file counts, byte-exact or
gate metric, and skips.
