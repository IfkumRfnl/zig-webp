# Plan 029: Attribute and remove the VP8L `decodeStaticInto` output tax

> **Executor instructions:** Read this plan completely before editing code. Run
> every gate in order. The first phase is measurement-only. Keep production code
> only when its own correctness and performance gates pass; do not stack failed
> candidates. Stop at every stated STOP condition and report rather than
> substituting a different optimization.

## Status

- **Priority:** P1
- **Effort:** M-L (attribution plus at most two independently gated changes)
- **Risk:** MED (Tier-1 implementation and allocation-budget behavior; no API
  signature change)
- **Depends on:** accepted plan 022 and the reviewed plan 028 rejection record
  on `perf/vp8l-rust-informed-loops` at `30cc1ba`
- **Category:** performance / allocation / API implementation
- **Planned at:** commit `703297c`, 2026-07-15
- **Status:** DONE — Candidate A accepted; Candidate B skipped below its 5% attribution gate

## Problem

The local pure-Rust `image-webp` decoder still leads the paired lossless
`decode-into` comparison by about **2.7621x** on opaque images and **2.8057x**
on alpha images, with Zig winning **0/47** lossless files in the last accepted
three-run comparison. The four plan 028 experiments did not close that gap and
all were rejected after a decisive 47-file lossless remeasure. Their source
changes are absent; they must not be recombined speculatively.

The remaining comparison is directionally fair but the two implementations do
not have the same output pipeline:

- Zig `decodeStaticInto` calls `decodeImage`, which allocates a packed owned
  output buffer, converts every internal VP8L ARGB `u32` pixel into it with
  `writePixels`, then copies every row into the caller's already-allocated
  destination (`src/decode.zig`). The timed path therefore allocates and frees
  an avoidable full output plane and performs an avoidable full-frame copy.
- Rust `WebPDecoder::read_image` decodes alpha-bearing VP8L directly into the
  reused RGBA destination. For opaque VP8L it allocates one RGBA intermediate
  and copies RGB into the destination (`references/image-webp/src/decoder.rs`).
- Existing temporary stage timing attributes about **66%-95%** of Zig VP8L
  decode to entropy. Predictor and color transforms account for about
  **5.8%-16%** and **4.3%-12.7%** when present. Those measurements did not
  isolate demux, allocation/free, `writePixels`, or the final destination copy.

The avoidable output work cannot plausibly explain the entire 2.8x gap without
measurement. It is nevertheless the next clean architectural difference to
measure: unlike another entropy micro-optimization, removing it improves the
truth of the caller-owned-buffer API, reduces deterministic allocation demand,
and can create a real alpha-heavy asset-class edge if the tax is material.

## Goal

Measure the inclusive and exclusive owners of the paired VP8L gap, then remove
the packed output allocation and second output copy from the **lossless**
`decodeStaticInto` path only if attribution and A/B gates justify it. If output
conversion remains material after that cut, test one format-specialized output
kernel independently.

This plan does **not** promise a general win over Rust. It must finish with one
of three honest verdicts:

1. **general edge:** Zig is no slower than Rust on both lossless opaque and
   alpha by both geomean and summed time;
2. **declared class edge / useful narrowing:** a predeclared class beats Rust,
   or the Zig-only change clears its retain gate while the remaining gap is
   reported exactly; or
3. **rejected:** attribution or A/B results miss the gates and production source
   returns to the baseline.

## Non-goals and rejected shapes

Do not reopen or combine any of the following without a separate new
attribution plan:

- plan 021's bulk refill / unchecked Huffman lookup;
- a fixed 10-bit Huffman root;
- plan 028 spatial-copy run retention, cached-copy specialization,
  packed-byte palette expansion, or summary-free high-level decode;
- an unconditional constant-prefix-group branch;
- threading, SIMD entropy decode, architecture-specific assembly, or a native
  RGBA rewrite of the internal VP8L `Pixel` representation;
- VP8 lossy internals, animation decode, encoders, public API renames, or new
  package/build dependencies.

Local profilers and a disposable instrumented `image-webp` checkout are allowed
under `.zig-cache/plan029/` for measurement only. They must not become package
or CI dependencies, and `references/image-webp` itself remains unmodified.

## Current implementation and invariants

### Zig lossless output path

`src/decode.zig` currently performs:

1. `parseStaticSource` (container parse and still-image selection);
2. `decodeLossless`, which budgets and allocates:
   - `argb_pixels` (`pixel_count * 4`),
   - transform scratch,
   - `entropy_image` (`pixel_count * 4`),
   - packed public output (`pixel_count * channel_count`);
3. `vp8l_decoder.decodeARGBAlloc` into internal `Pixel = u32` storage;
4. `writePixels` from numeric ARGB into RGB/RGBA/BGRA/ARGB bytes;
5. `decodeStaticInto` row copies from that packed owned output into `dest`;
6. free all internal allocations.

The new path must preserve these Tier-1 contracts:

- validate `dest` and dimensions before pixel decode;
- `dest.format` overrides `DecoderOptions.output_format`;
- support `.rgb`, `.rgba`, `.bgra`, and `.argb`;
- honor arbitrary valid stride;
- leave row padding and tail slack untouched;
- preserve all malformed/truncated-stream errors and resource bounds;
- preserve allocation-failure cleanup;
- keep `decodeStatic` byte-for-byte equivalent in output and ownership;
- keep animation and VP8 lossy behavior unchanged.

The intended allocation-budget change is narrow and observable:
`decodeStaticInto` must stop charging the caller-owned destination and the
removed packed output plane against `allocation_bytes_max`; all actual internal
scratch remains charged. This is a backward-compatible relaxation, not an
excuse to weaken other limits.

### Rust comparison path

The paired harness times `WebPDecoder::new + read_image` into a reused buffer.
File I/O, output allocation, and digest validation are outside the timed region.
For alpha VP8L, `LosslessDecoder::decode_frame` works in the caller's four-byte
buffer and applies transforms in place. For opaque VP8L, Rust uses a temporary
RGBA vector and then copies RGB. Preserve the existing paired harness contract;
do not make either side artificially exclude constructor, parsing, or its real
internal allocations.

## Commands and benchmark contract

| Purpose | Command | Expected on success |
|---|---|---|
| Toolchain | `zig version` | `0.16.0` |
| Full paired comparison | `tools/webp-rust-bench.sh --all -n 15 --warmup 2 --budget-ms 1500 -o OUT.tsv` | 135 validated, 0 skipped |
| Focused long run | `zig build -Doptimize=ReleaseFast bench -- --decode-only --file FILE --iters 25 --warmup 3 --budget-ms 15000 OUT.tsv` | target receives 25 timed samples |
| Focused tests | `zig build test --summary all` | all tests pass |
| Full local gate | `zig build ci` | exit 0 |
| wasm compile gate | `zig build wasm-check` | wasi and freestanding compile |
| Formatting | `zig fmt .` | exit 0 |

Use separate clean baseline and candidate worktrees. Run three alternating
baseline/candidate orderings on the same otherwise-idle host. Aggregate in this
order:

1. median-of-three timed medians **per file**;
2. bucket geomean and bucket summed time from those per-file medians.

Never take the median of already-aggregated ordering summaries. Report Zig/Rust
ratios as `zig_ms / rust_ms` (below 1.0 is a Zig win) and Zig candidate speedup
as `baseline_ms / candidate_ms` (above 1.0 is an improvement). Report sample
counts and skips. A tiny-file-heavy geomean is not a general throughput claim.

Predeclare these attribution assets before measuring:

- `testdata/photos/photo_foliage.webp` — spatial/LZ77 photo;
- `testdata/photos/photo_signage.webp` — spatial photo;
- `testdata/libwebp-test-data/color_cache_bits_11.webp` — cache-heavy;
- `testdata/libwebp-test-data/bad_palette_index.webp` — palette control;
- `testdata/libwebp-test-data/lossless_big_random_alpha.webp` — large alpha
  stress/control;
- `testdata/libwebp-test-data/lossless_vec_1_0.webp` — tiny
  startup/allocation contamination control.

## Scope

**Production files allowed only after an attribution PROCEED verdict:**

- `src/decode.zig`;
- `src/root.zig` (allocation-contract documentation only);
- `README.MD` only if its caller-owned-buffer wording needs clarification;
- focused tests in existing Zig test locations;
- `PROGRESS.MD` for dated measurements and accepted/rejected outcomes;
- `plans/README.md` for this plan's status.

**Temporary measurement-only files:**

- `.zig-cache/plan029/**`;
- disposable instrumentation in dedicated Zig/Rust worktrees, reverted before
  final review.

**Do not modify:**

- `src/vp8l/entropy.zig`, `src/vp8l/huffman.zig`, `src/bit_reader.zig`, or
  `src/vp8l/inverse_transform.zig`;
- `references/image-webp/**` in place;
- Tier-1 signatures/types, `CHANGELOG.MD`, animation code, or encoder code.

## Steps

### Step 1: Freeze the paired baseline

From clean `703297c` source (or a descendant whose diff over the scoped decoder
files is empty), run three full paired comparisons. Also run three long-budget
Zig baselines for the five named assets; the big-alpha file must receive 25/25
samples in each long run.

Record:

- all 47 lossless files, split into the existing 24 opaque / 23 alpha buckets;
- per-file Zig and Rust median milliseconds;
- per-bucket geomean and summed-time Zig/Rust ratios;
- the five named assets and the tiny control;
- exact Zig/Rust identities, machine, optimization mode, ordering, sample
  counts, and skips.

**Verify:** all three full comparisons say 135 validated and 0 skipped; output
digests match before timing; no baseline file is silently missing.

**STOP:** if the benchmark cannot reproduce byte-identical 135/135 validation,
or the three-run bucket ratios differ by more than 15% without an explained
host issue. Fix only harness invocation/environment, not codec code.

### Step 2: Attribute inclusive and exclusive stage cost

Create disposable instrumented worktrees. Do not commit the timers. Accumulate
stage nanoseconds in memory and print once after the timed set; never print per
decode or per symbol.

At minimum isolate these Zig stages:

1. `parseStaticSource` / demux;
2. reserve arithmetic and the three VP8L scratch allocations;
3. packed public-output allocation;
4. VP8L transform-image parsing;
5. main entropy image decode;
6. predictor, color, palette, and subtract-green inverse transforms separately;
7. `writePixels` conversion;
8. final destination row copy;
9. frees (scratch and packed output separately where practical).

Run the coarse Zig counters over all 47 validated lossless files so the
full-lossless summed output-tax share is measurable. The more invasive Rust
instrumentation and symbol-level attribution are required only for the six
predeclared assets.

The stage total must reconcile to within 5% of independently measured
end-to-end time on the five non-tiny assets. If clock overhead prevents that,
wrap whole stages over repeated decodes rather than timing finer regions.

Instrument a disposable local `image-webp` checkout equivalently enough to
separate constructor/container parse, lossless entropy, inverse transforms,
and final RGB/RGBA handling. Use `objdump -drC` on both ReleaseFast/release
binaries to identify whether Zig's output-format switch remains inside the
pixel loop and whether the conversion loop is already vectorized. `perf` or
`samply` data may supplement this record when already available, but is not a
prerequisite and must not be installed into the package.

For every named asset, report:

- Zig and Rust end-to-end milliseconds;
- Zig stage milliseconds and percent;
- Rust coarse stage milliseconds and percent;
- output tax = packed-output allocation/free + `writePixels` + final copy;
- entropy and inverse-transform shares;
- top exclusive symbols when a sampling profiler is available.

Also report opaque, alpha, and full-lossless Zig stage sums across all 47
files; this aggregate is the source of the 5% PROCEED threshold below.

#### Attribution decision

**PROCEED to Step 3** when either condition holds:

- output tax is at least **5% of summed Zig time** across the 47 lossless files;
  or
- output tax is at least **10%** on the large alpha asset or at least **20%** on
  the predeclared tiny control, with no timer-reconciliation failure.

Otherwise record the result and **STOP this plan with no production code**.
The next plan must target an untried whole-stream entropy architecture; it must
not relabel output work as the 2.8x owner.

Regardless of the verdict, record these secondary decisions for the next plan:

- if main entropy is at least 80% on foliage/signage and its Zig/Rust ratio is
  within 15% of the end-to-end ratio, entropy owns the remaining general gap;
- if parse is below 3% on both photos, drop parse optimization from the backlog;
- plan 028's palette candidate stays rejected even if palette remains material;
  new palette work needs a different mechanism and plan.

### Step 3: Remove the packed output allocation and second copy

Implement a lossless-only direct destination sink without changing the public
signature.

Required shape:

1. Keep the shared container parse and pre-decode destination validation.
2. Dispatch `.lossless` from `decodeStaticInto` to a private lossless-into path.
   Keep `.lossy` on the existing owned-decode-and-copy path in this plan.
3. Factor the common VP8L working-set allocation/decode code into a small private
   helper or owned working-set struct. Both `decodeLossless` and the new into
   path must use it; do not duplicate the codec pipeline and do not add a hot
   callback/virtual sink.
4. For `decodeLossless`, continue reserving and allocating the packed owned
   output exactly as required by `decodeStatic`.
5. For lossless `decodeStaticInto`, reserve/allocate only actual VP8L internal
   scratch, decode into internal ARGB pixels, then write each result row
   directly to `dest.pixels` at `y * dest.stride`. Do not allocate a packed
   public output and do not perform a second row copy.
6. Move the pixel-format switch outside the per-pixel loop by dispatching to a
   format-specific private worker. Keep this first candidate scalar so the copy
   removal and dispatch shape are measured independently from vectorization.
7. Preserve checked integer conversions and exact cleanup on every error path.

Do not change the numeric `Pixel = u32` layout. The new path is still an
ARGB-scratch-to-destination conversion; “direct” in this plan means direct to
the caller's output sink after codec reconstruction, not entropy decode into
RGBA bytes.

#### Required tests

Extend existing `src/decode.zig` behavior tests rather than adding a new test
module:

- lossless `decodeStaticInto` equals `decodeStatic` for all four pixel formats;
- packed and padded strides, including odd widths and unaligned row starts;
- row padding and tail slack retain sentinels;
- `dest.format` still overrides options;
- dimensions and undersized buffers fail before decode;
- an allocation-limit boundary succeeds when it includes all actual scratch
  but excludes the removed packed output plane, while one byte below required
  scratch still fails;
- allocation-failure injection leaves no leak and no partially owned state;
- malformed/truncated VP8L errors remain unchanged on representative fixtures.

Then run the full 135-file Rust differential so every decoded destination digest
is checked before performance timing.

#### Candidate A performance gate

Run three alternating baseline/candidate comparisons and aggregate per-file as
specified above. Keep Candidate A only if **either**:

- full-lossless summed-time speedup is at least **1.05x**, with neither opaque
  nor alpha geomean below **0.99x**; or
- alpha summed-time speedup is at least **1.05x** and alpha geomean at least
  **1.10x**, with opaque geomean and full summed time both at least **0.99x**.

The second rule permits an honest alpha-class win; label it that way. If both
rules fail, revert Candidate A, record the rejection, and STOP. Do not continue
to Step 4 on top of a failed copy-removal candidate.

### Step 4: Conditionally specialize the output conversion kernel

This is a separate candidate and commit. Attempt it only when post-Candidate-A
attribution shows `writePixels`-equivalent conversion is still at least **5%**
of lossless alpha time and ReleaseFast disassembly shows a scalar inner loop or
per-pixel format branch.

Required shape:

- retain a simple scalar format-specific worker as the equivalence authority;
- use `comptime` format specialization so no runtime format switch remains in
  the pixel loop;
- for four-channel formats, a portable `@Vector` numeric-lane permutation is
  allowed, with explicit little-/big-endian handling, bounded vector loops, and
  a scalar tail;
- do not cast an arbitrarily aligned `[]u8` destination to an aligned `[]u32`;
- do not vectorize three-byte RGB stores unless isolated codegen and timing show
  they are a material owner;
- add deterministic equivalence cases covering every format, vector boundary,
  odd tail, unaligned destination offset, alpha extremes, and channel patterns
  that expose cross-lane carry or byte-order mistakes.

Keep Candidate B only if, relative to accepted Candidate A, lossless-alpha
summed time improves at least **1.03x**, no lossless bucket geomean falls below
**0.99x**, and lossy control buckets remain within 1%. Otherwise revert only B.

**STOP:** if LLVM already emits equivalent vector code, conversion is below 5%,
or portability requires changing the internal Pixel representation. A native
RGBA internal layout is a separate high-risk plan with big-endian and animation
implications.

### Step 5: Recompare against Rust and render the campaign verdict

With only accepted candidates present, rerun:

- three full paired 135-file comparisons;
- the five predeclared long-budget assets and tiny control;
- `zig fmt .`;
- `zig build ci`;
- `zig build wasm-check`.

Classify the result without moving the goalposts:

- **General edge:** both lossless opaque and alpha have Zig/Rust geomean and
  summed-time ratios `<= 1.00`, and no predeclared long asset regresses >1% vs
  the accepted Zig baseline.
- **Alpha-class edge:** the 23-file alpha bucket has both ratios `<= 1.00` and
  clears the Zig-only retain gate, while opaque is reported separately.
- **Photo focus edge:** both predeclared photos beat Rust in their
  median-of-three values, their two-file summed ratio is `<= 1.00`, and neither
  loses in more than one ordering. Label this as the two-file focus set, not a
  general photographic-corpus claim.
- **Individual file win:** report it as a file result only, never as an
  asset-class edge.
- **Useful narrowing, not an edge:** accepted Zig-only speedup clears the retain
  gate but the relevant Zig/Rust ratio remains above 1.00.
- **Rejected:** no candidate clears its gate; source returns to baseline.

If the remaining general Zig/Rust ratio is above **1.5x** and entropy is at
least 80% on both photos, recommend one separate next plan: a whole-stream
entropy-state redesign with a local bit-buffer/table cursor and a checked tail.
That plan must start from codegen/profile evidence and require at least a
**1.20x full-lossless summed-time** gate to justify duplicating a safety-critical
kernel. Do not implement it here and do not reopen plan 021 under a new name.

## Verification matrix

| Check | Candidate A | Candidate B | Final |
|---|---:|---:|---:|
| Existing focused `decodeStaticInto` tests | required | required | required |
| New four-format/stride/allocation tests | required | required | required |
| Allocation-failure coverage | required | required | required |
| Rust differential | 135/135, 0 skip | 135/135, 0 skip | 135/135, 0 skip |
| Three alternating A/B orderings | required | required | required |
| Long big-alpha samples | 25/25 each run | 25/25 each run | 25/25 each run |
| `zig fmt .` | before commit | before commit | clean |
| `zig build ci` | required if kept | required if kept | required |
| `zig build wasm-check` | required if kept | required if kept | required |

## STOP conditions

Stop and report immediately when any applies:

- baseline validation is not 135/135 byte-identical;
- attribution does not reconcile within 5%;
- output tax misses the Step 2 threshold;
- a candidate fails correctness, wasm compilation, allocation cleanup, or its
  independent performance gate;
- an improvement exists only in one noisy ordering and disappears under
  median-of-three per-file aggregation;
- keeping a candidate requires weakening bounds/error behavior, changing a
  Tier-1 signature, modifying the reference oracle, or adding a dependency;
- the work starts to include a rejected plan 021/028 mechanism.

On STOP, revert only experimental production code, retain the dated
measurement record, set this plan to `REJECTED` with one-line rationale, and
leave `.zig-cache/` artifacts untracked.

## Done criteria

The plan is done only when all of the following hold:

- baseline and final paired records use the exact aggregation contract;
- attribution names the measured output, entropy, transform, parse, and
  allocation shares for every predeclared asset;
- every attempted candidate has an isolated accept/reject result and rejected
  source is absent;
- accepted code preserves every Tier-1 behavior and passes the verification
  matrix;
- `src/root.zig` and `src/decode.zig` allocation docs match actual behavior;
- `PROGRESS.MD` records dated metrics, machine, sample counts, skips, and the
  final general/class/narrowing/rejected verdict;
- `plans/README.md` carries the final status;
- the worktree is clean and contains no profiler output or generated build
  artifacts.
