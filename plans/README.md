# Implementation Plans

Plans 001–005: improve-skill audit of 2026-06-13 (commit `1aa7670`). Plan 006:
step-11a slice authored against the roadmap. Plans 007–011: improve-skill
audit of 2026-07-04 (commit `5d6ed3c`, standard depth, all categories).
Plans 012–017: improve-skill **direction** audit of 2026-07-07 (commit
`4c5572a`, `next` variant — roadmap options, not defects; the maintainer
selected all six).
Plan 018: authored 2026-07-08 on maintainer request (step-12 close-out and
1.0 release readiness), outside an audit session; refined the same day after
a fresh-context cold read (18 gaps triaged) and baseline re-verification
(464/464 tests at `6d62f55`).
Plan 019: authored 2026-07-08 on maintainer request (`plan` variant — speed
up the big-endian CI job), outside an audit session; grounded in same-machine
QEMU measurements (Debug 18m24s vs ReleaseSafe 4m23s, full 464-test suite on
powerpc64 at `29be0df`); maintainer selected ReleaseSafe + 4-way sharding.
Plans 020–027: improve-skill `plan` session of 2026-07-09 (commit `29be0df`;
maintainer requested plans for the advised performance push after reviewing
the step-10 record). See "Planning session — 2026-07-09" below for the
selection rationale and one recorded reversal.
Plan 028: Rust-informed VP8L performance audit of 2026-07-15 (commit
`02f4e05`), with four independently gated decode experiments.
Plan 029: authored 2026-07-15 after review of plan 028's decisive rejection
record; attribution-gated removal of the avoidable VP8L `decodeStaticInto`
packed-output allocation/copy, with a conditional output-kernel experiment.
Execute in the order below unless dependencies say otherwise. Each executor:
read the plan fully before starting, honor its STOP conditions, and update
your row when done.

Selection note (2026-07-04): the session ran non-interactively (no answer to
the selection question), so per the skill's default the top five findings by
leverage were planned. Unplanned findings and direction options are listed
below and can be turned into plans on request.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 001 | Make CI compile the CLI tools | P1 | S | — | DONE — verified at `f0c00c9` (merged #33, commit `c4f9d86`) |
| 002 | Allocation-failure injection tests for public entry points | P1 | M | — | DONE — verified at `f0c00c9` (merged #34, commit `2e8ec67`) |
| 003 | Bring README/PLAN/options docs in line with the code | P2 | S | — | DONE — verified at `f0c00c9` (merged #35, commit `5a129a3`) |
| 004 | Scheduled Zig-master canary workflow (toolchain + fuzz watch) | P2 | S | — | DONE — verified at `f0c00c9` (merged #36, commit `d96dc73`) |
| 005 | Document the public API surface in src/root.zig | P3 | M | 003 (soft) | DONE — verified at `f0c00c9` (merged #37, commit `353178c`) |
| 006 | Step 11a — limits & malicious-input contract matrix | P1 | M | — | DONE — merged to main via PR #80 (commit `5d6ed3c`; follow-up commits `735e0de`/`5178480` closed enforcement gaps) |
| 007 | Step 11b — allocation-failure injection for animated decode | P1 | S | — | DONE — merged as PR #81 (merge commit `fc33d30`; implementation commit `462183a`) |
| 008 | Step 11c — fuzz smoke targets for the encode entry points | P1 | M | — | DONE — merged as PR #82 (commit `f512f5e`; review follow-up PR #83, commit `0c33777`) |
| 009 | Step 11d — bounded mutation exploration for all fuzz targets | P2 | M | 008 (soft) | DONE — merged as PR #84 (commit `71ae902`; gate results in PROGRESS.MD) |
| 010 | Docs truth-up: encoder options, root docs, install flow, `zig build ci` | P1 | S | — | DONE — merged as PR #86 (commit `ce11ad6`) |
| 011 | VP8L palette detection O(pixels) via fixed hash probe | P2 | S | — | DONE — merged as PR #85 (commit `6922f08`) |
| 012 | `decodeStaticInto` — decode into caller-owned buffers (step 12) | P1 | M | — | DONE — merged as PR #90 (merge commit `772485e`; implementation commit `5843be4`; codex review green on first pass) |
| 013 | 1.0 stability contract + compatibility matrix (BE/macOS CI, browser gate) | P1 | M | 012 (soft) | DONE — merged as PR #92 (merge commit `753b6e7`); big-endian and macOS CI passed, the manual browser gate later closed, and `v1.0.0` shipped |
| 014 | WASM (wasm32) build spike + compile gate | P2 | S | — | DONE — merged as PR #96 (merge commit `29be0df`); `wasm-check` plus the full wasm32-wasi suite run in CI, and the 32-bit Huffman shift fix landed |
| 015 | C-ABI export layer — design document (PLAN.MD section, no code) | P2 | M | 012, 013 | DONE — merged as PR #102 (merge commit `7839d8d`); `PLAN.MD` step-13 section only, with implementation left to separate post-1.0 plans |
| 016 | Lossy encoder m5/m6 headroom measurement + recommendation | P3 | M | — | TODO |
| 017 | `zig-webp-info` CLI (webpinfo-style probe) | P3 | S | — | DONE — merged as PR #99 (merge commit `08561a2`); `zig build info` probes container structure through public `parseWebP` |
| 018 | Step-12 close-out: Tier-1 API audit + docs completeness + 1.0 readiness | P1 | M | 012, 013 | DONE — merged as PR #94 (merge commit `31ecd89`); reviewer-verified Tier-1 audit and release-readiness record |
| 019 | Big-endian CI job to ~3 min: ReleaseSafe + 4-way sharded QEMU run | P1 | M | — | DONE — PR #97 CI green; full 464-test powerpc64 ReleaseSafe suite passed in 3m9s with 4 QEMU shards (run `28993818050`) |
| 020 | Record dwebp internal decode time in webp-bench.sh (drop the I/O asterisk) | P1 | S | — | DONE — merged as PR #98 (merge commit `91298d9`); `decode_int_ms` records `dwebp -v` internal decode time |
| 021 | VP8L bit reader: bulk 64-bit refill + unchecked fast path, byte-exact | P1 | M | 020 (soft) | REJECTED — byte-exact experiment measured about 1.011× aggregate lossless speedup, below the plan's 1.05× complexity gate; not merged |
| 022 | VP8L pixel loop: comptime variants, hoisted group lookup, chunked copies | P1 | M | 021 (soft; independently executable) | DONE — merged as PR #100 (merge commit `2369b01`); about 1.05×–1.08× aggregate lossless speedup with byte-exact output |
| 023 | VP8 loop-filter SIMD (@Vector), byte-exact | P2 | M | 020 (soft) | DONE — merged as PR #101 (merge commit `28d9a58`); horizontal SIMD improved aggregate lossy decode 1.0654×, while vertical edges remain scalar |
| 024 | Attribution-gated spike: VP8 IDCT/prediction SIMD | P3 | S–M | 023 (hard) | REJECTED for merge — all-lossy 1.0287×–1.0375× straddled 1.03×; PR #103 retained scalar IDCT and left prediction untouched |
| 025 | VP8L encoder: per-tile predictor selection (close the 1.59× tail) | P2 | L | — | REJECTED — 16×16 tiled predictor helped photos/lossless1–3 but missed the <1.40× gate (1.455×) and grew the 77-source aggregate; production source reverted |
| 026 | Luma SSIM column in the lossy encode report | P3 | S | — | DONE — `fd1b77d` on `metrics-luma-ssim`; textbook `ssimLuma` + report column; first corpus mean SSIM 0.989985; finite-row PSNR mean fixed to 42.08 dB / 30 |
| 027 | Threading design doc in PLAN.MD (post-1.0, no code) | P3 | M | 020–023 (soft) | DONE — merged as PR #112 (merge `8f2a7e1`); PLAN.MD step 14 records the opt-in caller-supplied `std.Io` + `Io.Group` model, determinism/budget/failure contracts, per-path structure, and implementation gates; no code |
| 028 | Rust-informed VP8L entropy, cache-copy, palette, and summary experiments | P1 | L | 022 + `02f4e05` | REJECTED — all four candidates missed their gates; source reverted, decisive record on `perf/vp8l-rust-informed-loops` at `30cc1ba` |
| 029 | Attribute and remove the VP8L `decodeStaticInto` output tax | P1 | M-L | 022 + reviewed 028 outcome | DONE — direct lossless sink accepted at 1.0714× full-lossless summed speedup; output-kernel follow-on skipped below its 5% gate |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (with one-line reason) | REJECTED (with one-line rationale)

## Reconcile log

- **2026-07-21** — Plan **025** is REJECTED: 16×16 tiled prediction shrank
  photos but missed its `< 1.40×` tail gate and grew the 77-source aggregate,
  so production source was reverted. With plan **026** complete on the stacked
  base, the executable TODO set is now **016/027**.

- **2026-07-15** — Reconciled all 27 plans against `origin/main` at
  `7686a55`. Representative cheap HEAD checks still hold for every DONE
  cohort (CI/tool compilation, hardening/fuzz wiring, Tier-1/portability
  contracts, and accepted decode-performance paths); no plan is BLOCKED or
  stale IN PROGRESS. Plans **014/015/017–020/022/023** are merged.
  Plans **021/024** remain REJECTED measurement outcomes; their retained
  notes are historical evidence, not authorization to reopen either
  experiment without a new measurement plan.
- The executable TODO set is **016/025/026/027**. All four commit-range drift
  checks are empty at `7686a55`; cwebp/dwebp 1.5.0 and the reference/photo
  inputs required by plan 016 are present. Plan 025's global-predictor premise
  still matches the encoder and its 34-source committed / 77-source local
  report contracts remain distinct.
- Refreshed active-plan accuracy: plan 016 now rejects the lossy report's
  incorrect 37.13 dB headline denominator and requires photo-only finite rows;
  plan 026 includes correcting that report accounting (34 total, 30 finite,
  42.0847 dB finite-row mean) and its false oracle-consumer comment; plan 027
  pins its step-14 insertion point and requires an explicit caller-owned
  `std.Io`/provider ownership decision instead of an implicit global scheduler.

- **2026-07-14** — Cumulative draft PR #103 rebased onto main after #100/#101/#102
  squash-merges. Conservative cut through compact Huffman `fbe738c`: plan
  **024** vector IDCT (`e9254a3`) omitted because all-lossy
  **1.0287×–1.0375×** straddled the 1.03× gate. Focused Huffman
  multi-subtable / 4-byte allocation and max-`block_bits` tile-run
  equivalence tests retained on the draft head. C-ABI plan **015** history
  from #102 is preserved alongside the #103 perf record.

- **2026-07-11** — Compact VP8L Huffman `Entry` accepted at `fbe738c`
  (`Entry` **6→4** bytes, **33%** denser; 8-bit root **1.5KB→1KB**). Two
  serial 135-file ReleaseFast comparisons vs `e45fafd` base: lossless
  opaque **1.0908×**/**1.0935×**, lossless alpha **1.3504×**/**1.3627×**,
  lossy opaque **0.9911×**/**0.9897×** (noise), lossy alpha
  **1.1011×**/**1.1170×** (ALPH uses VP8L). **135** validated; focused
  **11+5**; root compile; CI; wasm. Gains are a **small-heavy aggregate**;
  large-file variance exists (`photo_foliage` ~**0.99×**,
  `lossless_big_random_alpha` **0.985–1.070×**). Rejected 10-bit root
  experiment `391f449` (+**3072** bytes/non-single table, +**15360**
  five-table scratch): lossless opaque **0.9620×**, alpha **0.9261×** vs
  accepted 8-bit compact base → **reject / no merge**; tests **481** pass.
  No general `image-webp` beat; accepted draft production cut is compact
  Huffman `fbe738c` (tile-run transforms retained). Plan **024** IDCT was
  omitted from the cumulative draft because all-lossy straddled the 1.03×
  gate.

- **2026-07-09** — Plan 014 (wasm32 build spike) executed on branch
  `wasm32-spike`. Drift vs `4c5572a`: `ci.yml` gained plan-013 BE/macOS
  jobs and `limits.zig` gained doc comments only — plan excerpts still
  held. Both `wasm32-wasi` and `wasm32-freestanding` compile via
  `zig build-lib` / `zig build wasm-check`. Initial spike found
  `src/vp8l/huffman.zig:180` (`u6` shift into 32-bit `usize`); same on
  `x86-linux`. Follow-up on the same branch fixed the five Huffman
  `usize` shift sites (`@intCast` → `Log2Int(usize)`), strengthened
  `wasm-check` to compile wasi unit tests (full analysis), and CI now
  runs the full suite under wasmtime.

- **2026-07-08** — Plan 018 executed end to end on branch
  `step-12-tier1-audit` (isolated worktree `/home/hayk/zig-webp-exec-018`,
  three commits `b76811f`/`432dcb1`/`131efd0` from planning commit `6d62f55`;
  drift check clean). Dispatch note: an interrupted first dispatch's executor
  completed the work; a second executor verified it and reported — the
  reviewer re-ran every done criterion regardless. The Tier-1 audit scored
  all 16 entry points + 29 type/lead rows (45 total); **every finding was
  doc-class** — no behavior changes, no Tier-1 renames (step 3 skipped, no
  operator approval needed). Both plan leads confirmed: six missing
  parameter/result types added to the contract list (`OwnedBuffer`,
  `DemuxOptions`, `MuxOptions`, `StaticImage`, `ContainerHeader`,
  `ChunkHeader`), and `encodeVP8LBitstream`/`encodeVP8Bitstream` classified
  explicitly Tier 2 (root.zig + README). New audit finding:
  `EncoderOptions.preserve_metadata` is a never-read knob, now documented
  reserved/no-effect. Reviewer verification: `zig build ci` exit 0 in the
  worktree (464/464), all done-criteria greps pass, scope clean (7 files,
  all in-scope), CI run `28878252291` at `6d62f55` confirmed green via `gh`
  (3 jobs), oracle modes re-run by the executor with artifacts on disk
  (`/tmp/plan018-encode-corpus.tsv`, `/tmp/plan018-anim-diff/`) matching the
  0.2.0 records digit-for-digit. The audit subsequently landed through PR #94
  (`31ecd89`); release PR #95 produced tag `v1.0.0`. Plans 014 and 017 later
  merged through PRs #96 and #99. Plan 016 remains an independent post-release
  measurement TODO.

- **2026-07-07** — Plan 012 executed end to end on branch
  `decode-static-into`, commit `5843be4`. Drift check against planning commit
  `4c5572a` was clean (zero diff in every in-scope file). Added
  `decodeStaticInto` to `src/decode.zig` (shared `parseStaticSource` prologue
  with `decodeStatic`, copy-based v1 per the plan's design decisions) and
  re-exported it from `src/root.zig`; the stale `EncoderOptions` comment was
  fixed in the same step. Seven decode tests plus five hardening-matrix rows
  landed (452→464 tests, all passing); no STOP condition triggered and the
  SHA-256 corpus gate pins `decodeStatic` unchanged. `zig build ci` exit 0.

- **2026-07-04** — Plan 006 verified DONE on main: branch
  `claude/step-11a-limits-hardening` merged as PR #80 (HEAD `5d6ed3c`), with
  review follow-ups (`735e0de`, `5178480`) that also closed real enforcement
  gaps (VP8 frame-reconstruction and compressed-ALPH allocation budgeting).
  Fresh audit at `5d6ed3c` produced plans 007–011; see "Audit context —
  2026-07-04". The 2026-06-13 unplanned findings were re-checked: the demux
  layering call and CLI-boilerplate items remain as recorded (boilerplate
  since consolidated into `tools/cli_common.zig` by plan 001's follow-ups —
  treat that row as resolved).

- **2026-06-13** — All five plans verified DONE on HEAD `f0c00c9`. Each
  landed as a merged PR (#33–#37); every post-audit commit maps to plan
  work, so the unplanned and rejected findings below are unchanged. Spot
  checks re-run and passing: `check_step.dependOn`=5, `zig build check`
  in CI, `checkAllAllocationFailures`≥6 (=6), no "groundwork in progress"
  in README, `Not yet honored`=2 in options.zig, canary workflow present
  (`version: master`, `continue-on-error`, no `pull_request`), root.zig
  `///`=35 / `//!`=14. Full gates green: `zig fmt --check .`,
  `zig build check`, `zig build test` all exit 0 on Zig 0.16.0.
  **Backlog is fully drained — nothing TODO/BLOCKED/IN PROGRESS remains.**
- **2026-06-30** — Plan 006 (step-11a limits/malicious-input contract
  matrix) executed end to end on branch `claude/step-11a-limits-hardening`,
  commit `d5103ce`. Drift check against the planning commit `e824d0c` was
  clean (HEAD was exactly `e824d0c` at branch time, zero diff in every
  in-scope file). Added `src/testing/hardening.zig` (19 tests, all passing:
  403→422 total), registered in `src/testing.zig` and `src/root.zig`. Every
  decode/parse/encode entry point in the matrix honored its tightened
  `ResourceLimits` knob with the exact documented error — no STOP condition
  triggered, no library code changed. `zig build test` and
  `zig fmt --check .` both exit 0. Not yet merged (no PR opened per
  instructions).

## Dependency notes

- 013 depends softly on 012: the stability-tier list in 013 should include
  `decodeStaticInto` if it exists. 013 works without it.
- 015 depends hard on 012 and 013: the C-ABI design's memory model rests on
  the caller-owned decode API, and its export scope on the Tier-1 list. Its
  drift check enforces this.
- 014, 016, 017 are pairwise independent of everything (disjoint files:
  014 touches build.zig+CI, 016 touches only PROGRESS.MD, 017 touches
  tools/+build.zig — 014 and 017 both edit `build.zig`'s different regions;
  execute serially or rebase, don't run concurrently on the same branch).
- Recommended order: 012 → 013 → 014 → 017 → 016 → 015 (015 is written to be
  executed after 1.0-track work; its own sequencing note says the follow-up
  implementation waits for 1.0).
- 018 (added 2026-07-08) depends hard on 012 and 013 (both DONE) and is the
  1.0 critical path: execute it before deciding to tag. 014/016/017 are
  additive and may land before or after the tag — 018's step 5 surfaces that
  choice to the operator. 015 stays post-1.0 per its own sequencing note.
- 005 depends softly on 003: plan 003 writes the "not yet honored"
  doc-comment framing for `EncoderOptions` that 005's alias comments mirror.
  Different files, no merge conflict — just execute 003 first.
- 001 first is recommended overall: it strengthens the verification net the
  other plans run under.
- 009 depends softly on 008: it wires 008's encode fuzz bodies into the
  mutation-exploration mechanism. It works without 008 (decode targets only).
- 007/008/010/011 are pairwise independent (disjoint files); any order.
  Recommended: 007 → 010 → 008 → 009 → 011.
- 020 before 021–024 is soft but recommended: it upgrades the libwebp-side
  ratio every perf plan records.
- 021 before 022: independent changes to different files, but sequencing
  them isolates each speedup in the PROGRESS.MD record (10b/10c precedent).
- 024 depends HARD on 023: its Step-1 profile gate must run after the loop
  filter is vectorized or the attribution is wrong. A REJECTED outcome for
  024 is a valid, expected completion.
- 025 and 026 are independent of everything above (disjoint files); 026
  complements 016 — if 016 runs after 026 it should quote both PSNR and
  SSIM.
- 027 is post-1.0 track like 015; execute after the release decisions, with
  020–023's measurements in hand.
- 028 starts from the cumulative packed-entry/scratch/predictor branch at
  `02f4e05`. Its four candidates are measured independently in this order:
  preserve spatial-group state, specialize cached copies, specialize palette
  expansion, then inspect/remove discarded summary work. Rejected plan-021
  refill and 10-bit-root shapes stay out of scope.
- 029 starts from source-equivalent `703297c` after plan 028 rejected every
  candidate. It first isolates parse/allocation/entropy/transform/conversion/
  copy cost. Production work proceeds only if the packed-output tax is
  material, then removes that allocation and second copy from lossless
  `decodeStaticInto`; format-kernel specialization is a separate gate.

## Performance audit — 2026-07-15 (commit `02f4e05`)

The maintainer asked why the local pure-Rust `image-webp` source was not being
used systematically to explain its remaining lead. A direct source comparison
confirmed that the 135-file benchmark is directionally comparable and found
four Zig-side opportunities, recorded with excerpts, tests, gates, and STOP
conditions in plan 028:

- LZ77 copies currently discard valid spatial Huffman-group run state and
  trigger another checked, by-value group lookup.
- Cached copies remain scalar, including redundant distance-one cache
  insertion; Rust separates copying from cache updates and peeks a second
  primary-table cache symbol.
- Palette expansion performs per-output-pixel coordinate/shift/bounds work;
  Rust specializes packed-byte expansion by palette-size band.
- High-level decode discards `DecodeSummary`, but per-operation counters may
  survive unless ReleaseFast inlining eliminates them; assembly inspection is
  required before changing code.

Current three-run medians: Zig / Rust lossless opaque **2.7621x**, lossless
alpha **2.8057x**, Zig wins **0/47** lossless files. Existing attribution says
entropy is about **66%–95%** of VP8L decode, so plan 028 orders entropy work
before palette work. Already measured and rejected: 10-bit Huffman root,
plan-021 bulk refill/unchecked lookup, and an unconditional constant-group
fill branch.

Plan 028's decisive 47-file lossless-only remeasure rejected all four
candidates; its implementation was reverted and the reviewed result branch is
`perf/vp8l-rust-informed-loops` at `30cc1ba`. Plan 029 does not stack those
misses. It measures the still-unattributed packed-output/conversion/copy tax in
`decodeStaticInto` and changes production code only if that tax and the
resulting A/B speedup clear explicit gates.


## Planning session — 2026-07-09 (commit `29be0df`, `plan` variant)

No audit this session: the maintainer reviewed the step-10 performance
record against libwebp and requested plans for the advised next push. Eight
plans (020–027) cover: measurement honesty (020, 026), the lossless-decode
scalar gap (021, 022), remaining lossy-decode SIMD (023, gated 024), the
lossless-encode size tail (025), and a threading design doc (027).

**Recorded reversal.** The 2026-07-07 session listed "re-opening step-10
lossless-decode perf" as a decided tradeoff and did not offer it. That
decision rested on the rationale recorded in `PLAN.MD` (the remaining gap
is "a SIMD/maturity difference vs libwebp"). Code-level review this session
found the rationale does not hold: libwebp's VP8L entropy loop is scalar C,
and the measured 1.8–5.6× gap traces to per-symbol overhead in this
library's own hot loop — double `ensureBits` per symbol and byte-at-a-time
refill (`src/bit_reader.zig:150-194`), a per-pixel meta-prefix group lookup
(`src/vp8l/entropy.zig:181`), and pixel-at-a-time LZ77 copies
(`src/vp8l/entropy.zig:274-279`). The maintainer re-opened the item on that
evidence → plans 021/022. Executors of those plans should also correct the
`PLAN.MD` step-10 rationale sentence if their measurements confirm the new
attribution.

**Overlap check.** Plan 016 (m5/m6 headroom measurement, TODO) already
covers the lossy-encoder measurement half of the advice; only the SSIM
metric axis was new → plan 026. Nothing else in 020–027 duplicates an
existing TODO/DONE plan or a rejected finding.

## Audit context — 2026-07-07 (commit `4c5572a`, direction/`next` variant)

Direction-only audit at the 0.2.0 release commit; no defect sweep this run
(the 2026-07-04 full audit stands). Six grounded direction findings were
presented; the maintainer selected all six, planned as 012–017:

- **D1** Step-12 caller-owned decode buffers (`PLAN.MD` step 12, no code
  existed) → plan 012.
- **D2** "Compatibility testing" undefined in the 1.0 gate; big-endian and
  macOS untested in CI; browser check unrecorded → plan 013.
- **D3** WASM build spike (carried from 2026-07-04 options) → plan 014.
- **D4** C-ABI layer, design only, sequenced after API stabilization per
  `PLAN.MD:32` → plan 015.
- **D5** `EncoderOptions.method` 5–6 are a documented no-op clamp; measure
  the headroom before (or instead of) building the lever → plan 016.
  Near-lossless noted as adjacent future work, not measured there.
- **D6** `zig-webp-info` CLI (carried from 2026-06-13 options) → plan 017.

Not offered, again: streaming/incremental decode (rejected by design,
`PLAN.MD:26-27`); re-opening step-10 lossless-decode perf (decided tradeoff
with recorded rationale). Incidental docs finding: `src/root.zig:133-135`
still claims no encode path consumes `EncoderOptions` — folded into plan 012
step 3 rather than a separate plan.

## Audit context — 2026-07-04 (commit `5d6ed3c`)

Second full audit, covering the ~50 commits since `1aa7670` (steps 8b/8c
lossy-encoder quality+controls, step 9 animation/metadata encode, step 10
performance, step 11a limits). Verification baseline green: 433/433 tests,
`zig fmt --check` clean. **Correctness/security sweep again found no
confirmed defects** — every public decode path honors the step-11 contract
(errors not panics, budgeted allocation, overflow-checked arithmetic),
including the newest encoder, SIMD, and bool-reader code. Not audited at this
depth: `references/` clones (policy), binary corpus, per-line DSP tables
(oracle-locked), big-endian behavior (documented as untested), and
line-by-line reads of the encode-only trusted-input modules
(`vp8/encoder.zig`, `vp8l/encoder.zig` internals — mirror-tested against the
audited decoders).

### Findings recorded but not planned (2026-07-04)

- **Animation optimizer re-decodes every frame it just encoded**
  (`src/animation_optimize.zig:508`), including all-lossless frames where the
  reconstruction is byte-equal to the source it already holds. Real overhead
  (~1 decode/frame), MED risk to fix (must preserve the byte-exact anim gate).
  Plan on request.
- **Single-frame encode path + `AllocationBudget` duplicated** between
  `src/encode.zig:574` and `src/animation_encode.zig:294` (docstring admits
  the mirror). Consolidation must keep both outputs byte-identical. Plan on
  request.
- **Dispose lookahead does two extra full-canvas scans per frame** with a
  per-pixel format switch (`src/animation_optimize.zig:733-777,860`). Fold
  into the optimizer perf plan if that is picked up.
- **CLI tools/`cli_common.zig` compiled but never behaviorally tested**
  (no `test` blocks under `tools/`). Low value relative to the codec suite.
- **`vp8l/encoder.zig` (2132 lines) bundles planning + entropy machinery**;
  clean split boundary exists (`entropy_encode.zig`). Judgment call — the
  file is cohesive; maintainer should decide before anyone plans it.
- **VP8L encoder entropy-encodes the image ~5–6× to pick the smallest form**
  (`src/vp8l/encoder.zig:1039-1094`). Deliberate exactness tradeoff;
  investigate-grade only (estimate-driven pruning could regress sizes).

### Direction options (2026-07-04, maintainer decisions)

All three options below were picked up by the 2026-07-07 direction audit and
are now planned — see plans 012 (`decodeStaticInto`), 014 (WASM spike), and
015 (C-ABI design).

- **`decodeStaticInto` (caller-owned buffers)** — stated step-12 goal
  (PLAN.MD:379) with no code yet; fits the deterministic-allocation
  competitive dimension. → plan 012.
- **WASM (`wasm32`) build spike** — zero-dep no-libc pure Zig makes it
  disproportionately cheap; 32-bit `usize` paths and allocator story are the
  unknowns. → plan 014.
- **C-ABI export layer** — PLAN.MD:32 sequences it after API stabilization;
  nearly reached. → plan 015 (design doc; implementation post-1.0).
- Streaming/incremental decode was considered and NOT offered: PLAN.MD:26-27
  explicitly rejects it (complete input buffers by design).

### Findings considered and rejected (2026-07-04)

- `zig build test` prints a `failed command:` line on a *passing* run (exit 0,
  "All 433 tests passed" when run directly): Zig 0.16.0 runner output quirk,
  not a repo defect; revisit only if CI misreports.
- Optimizer blend/zero helpers duplicated from `animation_decode`
  (`animation_optimize.zig:874-903`): intentional bit-for-bit mirrors,
  documented in-code; a shared helper would couple the modules the mirror
  exists to decouple.
- Encoder option validation gaps: the only cross-field invariant
  (`target_size`+`target_psnr`) is validated and tested; scalar knobs are
  clamped internally.
- Missing `zig build check` in CI: false — present at `ci.yml:28` (the *docs*
  omit it; that is plan 010).
- Lossless-decode speed gap vs `dwebp`, lossy-encoder quality gap vs
  libwebp, big-endian coverage, browser-render manual gate: all documented,
  decided tradeoffs in PLAN/PROGRESS/AGENTS — not findings.

## Audit context — 2026-06-13 (commit `1aa7670`)

The audit's headline result: the correctness/security sweep found no
confirmed defects. The codebase's discipline (bounded parsers, explicit
limits via `src/limits.zig`, byte-exact dwebp oracles, fuzz smoke targets
landing with each entry point) held up under adversarial reading. What was
NOT audited at this depth: the `references/` clones (out of scope by
policy), the binary corpus, per-line review of the VP8 DSP tables
(`token_probs.zig` values are oracle-locked instead), and big-endian
behavior (untested by CI, documented in PLAN.MD).

## Findings recorded but not planned

- **Layering inconsistency in demux** (`src/demux.zig:13` imports
  `vp8l/header.zig` for feature probing while `parseVP8Info` at
  `src/demux.zig:631` hand-rolls the VP8 probe): real but a judgment call —
  either extract a thin probe API per codec or document the exception in
  AGENTS.md. Maintainer should pick a direction; planning it without that
  choice would guess.
- **CLI tool boilerplate duplicated 4×** (`tools/zig-webp-*.zig`): real,
  but the tools are churning with step 5 oracle work; consolidate after the
  loop-filter/YUV tooling settles.

## Direction options (maintainer decisions, not defects)

- Lossless-decode preview release: `decodeStatic` is complete, fuzzed, and
  oracle-locked for still VP8L today (`src/decode.zig:17-92`); a scoped
  0.0.x announcement is possible before the 0.1.0 gate.
- `zig-webp-info` CLI: `parseFeatures` + `metadata.RawLocations` already
  expose everything a webpinfo-equivalent needs; aligns with AGENTS.md's
  chosen competitive dimensions (probing speed, mux/demux ergonomics).
  → planned 2026-07-07 as plan 017.
- Encoder API symmetry spike before PLAN step 7: decide the
  `encode(gpa, image.Buffer, options)` shape now so the VP8L encoder
  doesn't inherit the bitstream-in-only `mux.encodeStatic` asymmetry.
- Make the 0.1.0 gate operational: tie PLAN.MD:350-353's release criteria
  to checkable CI state / a milestone checklist.

## Findings considered and rejected

(So nobody re-audits them.)

- `@intCast(pixelCount)` truncation on 32-bit targets: `limits.pixelCount`
  caps at `maxInt(u32)` (`src/limits.zig:55`), which always fits `usize`.
- Animation frame-chunk loop reading past the frame end: bounds are
  enforced by `readChunkLocation`'s explicit end parameter
  (`src/demux.zig:222`).
- VP8L Huffman slow-path DoS: `decodeSlow` is O(15) per symbol and only
  reachable near stream end (`src/vp8l/huffman.zig:259-273`).
- Color-cache index check "in the wrong module": the check exists at the
  lookup site (`src/vp8l/color_cache.zig`); placement preference.
- Untested `features.zig`/`metadata.zig`/`options.zig`: pure data structs;
  `refAllDecls` in root.zig covers compilation; tests would be tautological.
- `bool_writer`/`EncoderOptions` exported without an encoder: deliberate,
  tested groundwork for PLAN steps 7-8 (EncoderOptions is now documented as
  such by plan 003).
- ALPH payload validation deferred to decode for VP8L-compressed alpha:
  consistent with the documented lenient-demux/strict-decode split.
- `animation.zig` redundant bounds checks: style-level, checks are correct.
- Publishing the test corpus as an artifact: the corpus is upstream's
  (`webm/libwebp-test-data`) and already committed under `testdata/`.
