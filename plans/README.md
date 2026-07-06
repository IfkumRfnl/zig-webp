# Implementation Plans

Plans 001–005: improve-skill audit of 2026-06-13 (commit `1aa7670`). Plan 006:
step-11a slice authored against the roadmap. Plans 007–011: improve-skill
audit of 2026-07-04 (commit `5d6ed3c`, standard depth, all categories).
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
| 007 | Step 11b — allocation-failure injection for animated decode | P1 | S | — | DONE — verified at `87ed625` (branch `deepseek/step-11b-animation-decode-alloc-failure`) |
| 008 | Step 11c — fuzz smoke targets for the encode entry points | P1 | M | — | DONE — verified on branch `claude/step-11c-encoder-fuzz` |
| 009 | Step 11d — bounded mutation exploration for all fuzz targets | P2 | M | 008 (soft) | DONE — verified on branch `claude/step-11d-bounded-random-fuzz` (gate results in PROGRESS.MD) |
| 010 | Docs truth-up: encoder options, root docs, install flow, `zig build ci` | P1 | S | — | DONE — merged as PR #86 (commit `ce11ad6`) |
| 011 | VP8L palette detection O(pixels) via fixed hash probe | P2 | S | — | TODO |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (with one-line reason) | REJECTED (with one-line rationale)

## Reconcile log

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

- 005 depends softly on 003: plan 003 writes the "not yet honored"
  doc-comment framing for `EncoderOptions` that 005's alias comments mirror.
  Different files, no merge conflict — just execute 003 first.
- 001 first is recommended overall: it strengthens the verification net the
  other plans run under.
- 009 depends softly on 008: it wires 008's encode fuzz bodies into the
  mutation-exploration mechanism. It works without 008 (decode targets only).
- 007/008/010/011 are pairwise independent (disjoint files); any order.
  Recommended: 007 → 010 → 008 → 009 → 011.

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

- **`decodeStaticInto` (caller-owned buffers)** — stated step-12 goal
  (PLAN.MD:379) with no code yet; fits the deterministic-allocation
  competitive dimension. Design/spike plan on request.
- **WASM (`wasm32`) build spike** — zero-dep no-libc pure Zig makes it
  disproportionately cheap; 32-bit `usize` paths and allocator story are the
  unknowns.
- **C-ABI export layer** — PLAN.MD:32 sequences it after API stabilization;
  nearly reached. Queue a design plan post-1.0.
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
