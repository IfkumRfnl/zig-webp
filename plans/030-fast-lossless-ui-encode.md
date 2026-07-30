# Plan 030: Beat libwebp on fast lossless UI encoding

> **Executor instructions**: This is a measurement-gated performance campaign,
> not a mandate to merge an optimization. Follow the gates in order. You own the
> exact implementation strategy; use profiles and generated output rather than
> mechanically applying the candidate levers listed below. If a STOP condition
> occurs, revert production experiments, record the result, and mark the plan
> REJECTED rather than broadening the scope. When done, update this plan's row in
> `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat a3a0e40..HEAD -- src/options.zig src/root.zig src/encode.zig src/vp8l/encoder.zig src/vp8l/lz77.zig src/testing/synth.zig tools/zig-webp-bench.zig tools/webp-bench.sh build.zig testdata/ui README.MD PLAN.MD PROGRESS.MD CHANGELOG.MD plans/README.md`
> If the public options contract, VP8L planning pipeline, benchmark conventions,
> or lossless size baseline changed, reconcile those changes before proceeding.
> Stop if the acceptance metrics can no longer be reproduced honestly.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: none (plan 011's O(pixels) palette probe is already DONE)
- **Category**: direction / performance
- **Planned at**: commit `a3a0e40`, 2026-07-29
- **Result**: REJECTED on 2026-07-29 — two focused prototypes missed the
  preset-0 speed gate; the best reached 2.4682× time with 0/2 real rows faster
  and also failed the 1.15× aggregate / 1.30× maximum size gates. Production
  changes were reverted; the matched-effort benchmark/corpus was retained.

**Follow-up result**: a maintainer-authorized default-path campaign continued
after this formal rejection and reached **0.729310×** preset-0 primary geomean
time, **2/2** real rows faster, **0.802863×** aggregate bytes, and a
**1.176471×** maximum row. It does not retroactively accept this plan because
it intentionally exposes no explicit fast-lossless effort and changes default
output bytes. See the dated record in `PROGRESS.MD`.

## Why this matters

The project intends to beat libwebp on selected dimensions rather than claim
blanket superiority. `AGENTS.md` explicitly names fast basic lossless encoding
and UI/alpha-heavy assets as suitable targets. The current VP8L encoder is
close on compression ratio—**1.0368x median and 1.0460x aggregate bytes** versus
`cwebp -lossless`—but its only recorded C speed comparison is a photo at full
effort, where Zig took 125 ms versus 88 ms. There is no matched-effort UI
benchmark and no fast lossless mode.

This plan targets one publishable claim:

> On a pinned low-color UI/icon corpus, zig-webp's explicit fast-lossless mode
> encodes at least 10% faster than libwebp's `WebPConfigLosslessPreset(..., 0)`
> (`cwebp -z 0` semantics), while remaining pixel-exact and staying within the
> size gates below.

The claim is class-specific. It must never be restated as a general encode-speed
or compression-ratio win.

## Current state

- `src/encode.zig:37-61` gathers caller pixels and calls
  `vp8l_encoder.encodeAlloc` without an effort/config argument. Every lossless
  call therefore uses the same search depth.
- `src/options.zig:21-68` exposes a shared `EncoderOptions`; `method` currently
  controls only the VP8 lossy search. There is no documented VP8L effort
  control.
- `src/vp8l/encoder.zig:316-382` first tries the palette/color-indexing path.
  Palette hits skip predictor and color transforms, which is the right basis for
  low-color UI specialization.
- `src/vp8l/encoder.zig:574-608` evaluates every predictor mode with a complete
  image transform and residual scan. Despite the comment mentioning a strided
  sample, the current loop is full-image.
- `src/vp8l/lz77.zig:101-215` uses one greedy hash-chain matcher with a fixed
  `chain_limit = 64` for every lossless encode.
- `src/vp8l/encoder.zig:1064-1119` measures entropy choices by encoding trial
  streams: both cache candidates, optional multi-group planning over several
  block sizes, a multi-group trial, then final emission. This protects size but
  is avoidable work at the fastest effort.
- `tools/zig-webp-bench.zig` measures Zig entry points in memory. The companion
  `tools/webp-bench.sh` times the `cwebp` CLI, including I/O, and has no `-z`
  ladder; it is not sufficient for this claim.
- `testdata/encode-corpus-sizes.tsv` and
  `tools/webp-oracle.sh compare-encode-corpus` are the authoritative default
  size/round-trip baseline. The 2026-07-22 record is 77/77 round trips, 1.0368x
  median and 1.0460x aggregate versus libwebp 1.5.0.
- Plan 025's per-tile predictor experiment was rejected after increasing
  aggregate bytes and encode time. Do not reopen tiled predictor selection in
  this campaign.

Applicable conventions:

- Zig 0.16.0, no package/runtime dependencies, and no C in the package build.
  A local libwebp benchmark adapter may be materialized under `.zig-cache/`,
  following the optional-reference pattern in `tools/webp-rust-bench.sh`.
- Scalar correctness remains authoritative. Fast mode may do less search, but
  it may not use unchecked reads/writes or weaken resource limits.
- Keep the existing default behavior. The speed tier must be explicit; no
  automatic content heuristic may silently switch existing callers to it.
- Public declarations stay in `src/root.zig`; implementation stays under
  `src/`. Keep VP8L independent of RIFF/container policy.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Toolchain | `zig version` | `0.16.0` |
| C oracle | `cwebp -version` | libwebp `1.5.x` |
| Baseline gate | `zig build ci` | exit 0 |
| Wasm/32-bit gate | `zig build wasm-check` | exit 0 |
| Default lossless report | `zig build encode-report -- --with-corpus .zig-cache/plan030-encode.tsv` | 77 rows, 0 round-trip mismatches |
| Default C size oracle | `tools/webp-oracle.sh compare-encode-corpus .zig-cache/plan030-encode.tsv` | median ≤1.10x, 0 failures |
| Existing encode benchmark | `zig build -Doptimize=ReleaseFast bench -- --encode-only` | encode rows emitted |
| New matched-effort report | `tools/webp-fast-lossless-bench.sh --output .zig-cache/plan030-fast-lossless.tsv` | complete Zig/C rows, no validity failures |

The exact benchmark implementation is the executor's choice, but the final
matched-effort command and TSV contract above must be stable and documented.

## Scope

**In scope**:

- A reproducible, same-process or equivalently isolated in-memory benchmark of
  Zig lossless encode and libwebp lossless presets.
- A pinned UI/icon benchmark corpus with clear provenance and class labels.
- An explicit fast VP8L effort exposed through the public `encodeLossless` path.
- Profile-guided reductions in VP8L search work.
- Tests, build wiring, and required README/PLAN/PROGRESS/CHANGELOG updates after
  a successful implementation.
- `plans/README.md` status/result update.

Likely files are those in the drift check. The executor may add one narrow
module under `src/vp8l/` if that keeps effort policy out of the already-large
encoder file, and may add benchmark support under `tools/` plus
`testdata/ui/`.

**Out of scope**:

- Lossy VP8 quality work, methods 5-6, target-size/target-PSNR changes, or ALPH
  chunk optimization. Alpha-bearing *lossless VP8L* UI images remain in scope.
- Near-lossless preprocessing; every output in this plan is exactly lossless.
- Per-tile predictor selection from rejected plan 025.
- VP8/VP8L decode optimization, threading, C ABI work, or animation encoding.
- Adding C, libwebp, benchmark adapters, or corpus tooling to the package build
  or `build.zig.zon` dependencies.
- A general “faster than libwebp” claim.

## Git workflow

- Suggested branch: `fast-lossless-ui`.
- Keep benchmark/corpus work separate from production optimization commits so a
  rejected implementation can be reverted without discarding measurement
  infrastructure.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Establish the fair benchmark and corpus

Create the matched-effort benchmark before changing production encoding. Both
implementations must consume identical in-memory RGBA pixels, include output
allocation and encode work, run single-threaded with warmups and repeated
samples, and use the same timing aggregation. The C side must use libwebp's
public encode API and `WebPConfigLosslessPreset` rather than measuring CLI
startup or file I/O. Keep the adapter local-only under `.zig-cache/` or another
ignored reference location.

Pin and classify enough inputs to prevent a synthetic microbenchmark claim:

- low-color opaque UI/icons;
- low-color images with meaningful alpha;
- palette-miss antialiased/gradient UI as a separately reported secondary
  class;
- a range of small and medium dimensions, with batching for sub-millisecond
  cases;
- a mix of deterministic generated fixtures and real assets whose provenance
  permits committing them.

Record at least Zig-current, libwebp lossless preset 0, and a normal-effort
libwebp control. Report per-file median time, MP/s, bytes, palette-hit/class,
and round-trip validity; summarize geomean and summed time plus aggregate bytes
per class. Store methodology in the tool's help/header so the result is
reproducible.

**Verify**:
`tools/webp-fast-lossless-bench.sh --output .zig-cache/plan030-fast-lossless-before.tsv`
must produce complete rows for every pinned input and zero decode/round-trip
failures. Do not publish a win from the existing synthetic matrix alone.

### Step 2: Profile and choose the smallest fast-effort policy

Use the benchmark corpus to attribute current Zig time across transform
selection, LZ77 matching, and entropy-choice planning. Select only the work
reductions supported by that profile. Candidate levers include predictor
sampling/subsets, shallower match search, fewer cache/group trials, and a
palette-index specialization; they are hypotheses, not required edits.

Prototype the fast tier behind internal/Tier-2 configuration first. Preserve
all checked bounds and make the normal tier invoke the current code path.
Proceed to public wiring only if the prototype has a credible route to the
final speed gate without exceeding the size limits.

**Verify**: record a before/prototype table in scratch notes. The prototype must
be faster on the primary class and pixel-exact on every row. If its primary
geomean is not below libwebp preset 0 after at most two focused, profile-backed
iterations, trigger the STOP condition; do not begin an encoder rewrite.

### Step 3: Integrate the successful tier cleanly

If Step 2 passes, make fast lossless effort explicitly selectable through
`encodeLossless`. Choose the least surprising public option shape after reading
the frozen Tier-1 contract: either give the existing generic effort field
well-documented lossless semantics or add one defaulted lossless-specific
field. In either case:

- the default must retain today's lossless behavior;
- fast effort must be explicit and deterministic;
- invalid values must follow existing option-validation conventions;
- lower effort changes compression decisions only, never pixel fidelity;
- Tier-2 bitstream tooling should use a narrow config type rather than import
  public API policy into VP8L internals.

Keep the implementation proportional to the measured win. If the policy grows
into a distinct concern, split it into a narrow VP8L module instead of further
monolithically growing `encoder.zig`.

**Verify**: focused tests for the fast and default paths pass, and a fresh
matched-effort report still clears the Step 2 result.

### Step 4: Prove correctness, compatibility, and the competitive gate

Run the full default and fast paths over the pinned UI corpus and existing
encode corpus. Decode every output with zig-webp and `dwebp`; pixels must match
the source exactly. Exercise allocation-failure and resource-limit behavior on
at least one fast palette hit and one fast palette miss.

Compare the unchanged default path against a pre-change digest/size baseline.
The default configuration must produce the same bytes on the existing 77-source
lossless report. Do not accept a default compression regression as payment for
an opt-in fast mode.

Primary competitive gates, all required:

- fast Zig primary-class geomean encode time ≤ **0.90x** libwebp preset 0;
- at least 70% of primary real-asset rows individually faster than libwebp;
- primary-class aggregate bytes ≤ **1.15x** libwebp preset 0;
- no primary real-asset row > **1.30x** libwebp preset 0 without rejecting the
  production change;
- every output pixel-exact; zero Zig or `dwebp` validity failures;
- default 77-source output byte-identical to the pre-change baseline;
- default size oracle still ≤1.10x median versus `cwebp -lossless`.

Report secondary palette-miss and tiny-image results even when they lose; they
are excluded from the primary claim only because the class was predeclared,
not because results may be hidden after measurement.

**Verify**:

- `zig build ci` → exit 0;
- `zig build wasm-check` → exit 0;
- `zig build encode-report -- --with-corpus .zig-cache/plan030-encode-after.tsv`
  → 77 rows, 0 mismatches;
- `tools/webp-oracle.sh compare-encode-corpus .zig-cache/plan030-encode-after.tsv`
  → 0 failures, median ≤1.10x;
- `tools/webp-fast-lossless-bench.sh --output .zig-cache/plan030-fast-lossless-after.tsv`
  → all primary gates above.

### Step 5: Record the result without overclaiming

If accepted, update public option/API documentation and usage, the forward
roadmap where behavior/scope changed, `CHANGELOG.MD`, and `PROGRESS.MD` with the
dated machine/toolchain/corpus/methodology and full primary/secondary results.
The wording must name the exact class, effort settings, time statistic, size
guardrail, and single-thread condition.

If rejected, revert production/API changes. Keep only generally useful
benchmark/corpus infrastructure if it is clean and reproducible, record the
negative result in `PROGRESS.MD`, and mark plan 030 REJECTED with the measured
reason. A rejected measured experiment is a complete outcome.

**Verify**: documentation contains no unqualified “faster than libwebp” or
“beats cwebp” claim; every claim includes the UI/low-color and fast-preset
qualifiers.

## Test plan

Match the existing inline Zig test style in `src/encode.zig` and
`src/vp8l/encoder.zig`. Tests must cover observable behavior rather than the
chosen internal heuristic:

- fast lossless round-trip for palette-hit opaque and alpha inputs;
- fast lossless round-trip for a palette miss and odd dimensions;
- normal/default output unchanged for representative palette-hit and miss
  inputs;
- option boundary/validation behavior;
- allocation-failure survival on fast palette-hit and miss paths;
- resource limits unchanged;
- external `dwebp` validity across the benchmark corpus;
- wasm compilation of the public and Tier-2 paths.

Performance thresholds belong in the local benchmark report, not flaky CI
unit tests.

## Done criteria

All must hold for an accepted implementation:

- [ ] A reproducible direct-API Zig/libwebp matched-effort benchmark exists and
      reports every pinned source.
- [ ] The corpus provenance and class definitions are recorded.
- [ ] Fast lossless effort is explicit through `encodeLossless`; the default is
      unchanged.
- [ ] Every fast output round-trips pixel-exactly through Zig and `dwebp`.
- [ ] Fast primary geomean time is ≤0.90x libwebp preset 0, with the 70% row,
      1.15x aggregate-size, and 1.30x outlier gates satisfied.
- [ ] Existing 77-source default output is byte-identical to the before report;
      the lossless oracle remains ≤1.10x median with 0 failures.
- [ ] `zig build ci` and `zig build wasm-check` exit 0.
- [ ] README/PLAN/PROGRESS/CHANGELOG accurately describe the accepted behavior
      and narrow claim.
- [ ] `plans/README.md` records DONE with the measured result.

For a rejected experiment, completion instead requires: production/API changes
reverted, `zig build ci` green, the dated negative result in `PROGRESS.MD`, and
plan 030 marked REJECTED with the gate that failed.

## STOP conditions

Stop and report rather than improvising if:

- Zig is not 0.16.0, libwebp 1.5.x or the local reference tools are unavailable,
  or a direct-API matched-effort comparison cannot be built without adding a
  package dependency.
- The corpus cannot be made reproducible and legally/provenance-safe.
- The default encoder or 77-source baseline drifts before this work and the
  change cannot be reconciled cleanly.
- Two focused, profile-backed fast-tier iterations fail to beat libwebp preset
  0 on the primary class.
- The speed gate requires unchecked memory access, weakened limits, threading,
  copied libwebp code, or a default-path regression.
- The size gates fail. Do not relax them after seeing results.
- The apparent win exists only under CLI/I/O asymmetry, different input pixels,
  different threading, synthetic-only inputs, or post-hoc corpus filtering.

## Maintenance notes

- Preserve the benchmark as a narrow local oracle, not a build dependency.
- Reviewers should focus on comparator fairness, predeclared corpus classes,
  default-path identity, and whether complexity is proportional to the measured
  win.
- Future VP8L compression-ratio work must benchmark normal effort separately;
  it must not silently make the fast tier expensive.
- ALPH filter/VP8L fan-out remains a separate potential alpha-heavy campaign;
  do not fold it into this plan after implementation begins.
