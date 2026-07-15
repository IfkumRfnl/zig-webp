# Plan 027: Threading design document — opt-in parallel decode/encode (design only, no code)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 7686a55..HEAD -- PLAN.MD PROGRESS.MD plans/README.md`
> This plan was refreshed after PRs #98–#103 settled the attribution data and
> after the post-1.0 C-ABI design landed. A later restructuring of those
> roadmap sections is a STOP condition; ordinary dated progress rows are not.

## Status

- **Priority**: P3 (post-1.0 track, like plan 015)
- **Effort**: M (thinking + writing; zero code)
- **Risk**: LOW (a document)
- **Depends on**: the settled plan-020–024 measurement record. Plans 020,
  022, and 023 landed; plans 021 and 024 were rejected at their gates.
  No implementation dependency remains, but the design should stay deferred
  until a concrete threaded workload is selected.
- **Category**: direction / perf
- **Planned at**: commit `7686a55`, refreshed 2026-07-15 (originally authored
  at `29be0df`)

## Why this matters

Internal threading may improve large lossy stills, ALPH/color overlap, or
animation encode, but the completed scalar campaign shows it is not a general
answer: VP8L entropy accounts for roughly 66%–95% of measured lossless decode,
plan 021's reader fast path was rejected, and the accepted plan-022/023 gains
were path-specific. The design must therefore select a profiled workload before
adding API or scheduler machinery. Threading also touches the project's
deepest contracts: deterministic allocation, allocation budgets
(`ResourceLimits.allocation_bytes_max`), byte-exact output, wasm32 support
(no threads), and the frozen Tier-1 API. Designing it in a document first —
as plan 015 did for the C ABI — lets the maintainer approve, reject, or trim a
specific concurrency model before any `std.Thread` or `std.Io` code lands.

## Current state

Facts the design must honor (all verifiable in-repo):

- **Thread-compatibility statement**: `PLAN.MD:37-48` — current portability
  matrix plus "no global mutable state, so distinct decode/encode jobs may run
  on distinct threads"; internal parallelism is still deferred to step 10 even
  though step 10 is delivered.
- **Zero-dependency policy** (`AGENTS.MD`): stdlib only; no runtime deps.
  Prefer comparing raw `std.Thread.spawn` against Zig 0.16 `std.Io`
  structured concurrency in the design (record which the implementation
  should use and why). wasm32-wasi and wasm32-freestanding must keep
  compiling and passing tests — threading must be compile-time absent or
  runtime-degraded there (CI: `zig build wasm-check` + wasmtime suite;
  big-endian powerpc64 under QEMU).
- **Determinism/byte-exactness**: the SHA-256 corpus gates pin decode
  output; the encode corpus pins round-trips. The design MUST require
  thread-count-independent, byte-identical output (like libwebp's `-mt`,
  which is bit-exact vs single-threaded).
- **Allocation budgets**: `decodeStatic`/`encode*` charge scratch against
  `ResourceLimits.allocation_bytes_max` (see the step-11a entries in
  `PROGRESS.MD`). Per-thread scratch multiplies budgets — the design must
  say how budgets account for worker count (e.g. budget is global and
  checked before spawning; workers reserve from it up front).
- **Tier-1 freeze**: `src/root.zig`'s stability contract — new options
  fields with defaults are additive/non-breaking; changed semantics of
  existing entry points are not. An opt-in knob (e.g.
  `DecoderOptions.thread_count_max: u8 = 1` or a separate `*Threaded` entry
  point) must be argued against the contract text.
- **No current concurrency handle**: the Tier-1 still entry points take
  `gpa` + bytes/buffer + options, not `std.Io` (`src/root.zig:393-505`).
  Zig 0.16's own `std/Io/Threaded.zig:1695-1704` says applications choose the
  `Io` implementation and library code should accept an `Io` parameter; the
  only stdlib global is single-threaded and explicitly has no concurrency or
  cancellation. Therefore an options-only `thread_count_max` proposal is
  incomplete unless the design also specifies where the concurrency provider
  comes from.
- **Candidate parallel structures** (ground each in the named modules):
  1. *Lossy decode pipeline split*: entropy/token decode
     (`src/vp8/tokens.zig` + bool reader) feeding reconstruction + loop
     filter (`src/vp8/decoder.zig`, `src/vp8/loop_filter.zig`) — the
     libwebp `-mt` shape; bounded row-queue handoff.
  2. *Animation decode/encode frame parallelism*: `AnimationDecoder`
     composites serially by contract (frames depend on prior canvas), but
     per-frame *bitstream* decode can be pipelined ahead of composition;
     animation **encode** (`src/animation_encode.zig`) is embarrassingly
     parallel per frame EXCEPT that `src/animation_optimize.zig` re-decodes
     its own output to track the reconstructed canvas (serial dependency —
     the 2026-07-04 unplanned-findings note about the optimizer re-decode
     is directly relevant; cite it).
  3. *Lossy encode macroblock-row workers* with deterministic reduction
     (the RD decisions in `src/vp8/encoder.zig` are row-causal via
     reconstructed neighbors — the design must map which dependencies allow
     wavefront parallelism vs force pipelining).
  4. *ALPH plane* decode/encode overlap with the color plane
     (`src/alpha.zig` is independent of VP8 reconstruction until
     composition).

Format precedent: plan 015 (`plans/015-c-abi-design.md`) — a design-doc plan
whose deliverable is a `PLAN.MD` section; read it for structure and for how
its "Design decisions to record" list is phrased.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (docs-only change must not break fmt) |
| Local concurrency API | `zig env` then read `<std_dir>/Io.zig` and `<std_dir>/Io/Threaded.zig` | confirm Zig 0.16 `Io.Group`/`concurrent`/cancel contracts and caller-owned `Io` guidance |

## Scope

**In scope** (the only files you should modify):
- `PLAN.MD` (one new step-14 design section plus the near-term roadmap
  summary line that must name it; forward-looking content only)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- ALL `src/`, `tools/`, `build.zig` — no code, no prototypes, no "quick
  spike while writing".
- `PROGRESS.MD` — nothing was measured or completed; design docs are not
  progress rows.
- `README.MD` — user-facing docs change when the feature ships, not at
  design time.

## Git workflow

- Branch: `threading-design-doc`
- One commit, e.g. `Add threading design section to PLAN.MD`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Read the constraint sources

Read, in this order: `PLAN.MD` (step 10, the end of step 13, and
`Near-Term Work Items`), `src/root.zig:393-505` (current entry-point
signatures), `src/root.zig`'s module doc (stability tiers), `src/limits.zig`
(`ResourceLimits` fields), the `PROGRESS.MD` step-10 / plan-020–024 and
step-11a entries, and `plans/015-c-abi-design.md` (format precedent). Run
`zig env`, then read the installed Zig 0.16 `std/Io.zig` `Group` APIs and
`std/Io/Threaded.zig:1695-1704`; do not rely on memory from a different Zig
release. List every constraint in working notes with `file:line`.

**Verify**: notes name ≥ 7 constraints with citations: the six original
contract bullets plus the missing-`Io`/concurrency-provider constraint.

### Step 2: Write the `PLAN.MD` section

Add `### 14. Threading (post-1.0 design)` immediately after the end of
step 13's open questions and before `## Near-Term Work Items`. Do not nest it
inside the C-ABI section. The section must contain:
1. **Goals/non-goals.** Goal: evaluate and, where the profile supports it,
   beat default single-threaded `dwebp` wall-clock on large lossy stills or
   scale animation encode. Non-goal: threading as default behavior; non-goal:
   wasm threads.
2. **API and concurrency-provider shape (decide one, record alternatives).**
   Compare an additive options field, separate `*Threaded`/`*WithIo` entry
   points accepting caller-supplied `std.Io`, and internal raw
   `std.Thread.spawn`. An options-only thread count is not a complete design:
   name who constructs/owns/deinitializes the provider and how it reaches the
   codec. Default stays single-threaded. Quote the Tier-1 compatibility rule
   and state whether the selected new surface is Tier 1 or Tier 2.
3. **Determinism contract.** Output byte-identical for every thread count;
   the corpus gates run the threaded path at ≥ 2 threads in CI (state how:
   a test-only option matrix).
4. **Budget accounting.** How `allocation_bytes_max` covers per-worker
   scratch (reserve-before-spawn; spawn fewer workers if the budget caps
   out — never fail a decode that would succeed single-threaded).
5. **Failure / lifetime semantics (required).** The design must specify, as
   normative rules (not open questions):
   - **Deterministic error precedence** when multiple workers fail (which
     error is returned; order must not depend on scheduling races).
   - **Cancellation**: how in-flight workers are cancelled or drained after
     the first fatal error (or explicit cancel), and that cancel is
     cooperative with the byte-exact / budget contracts.
   - **Join-before-return**: every spawned worker is joined before the
     entry point returns success or error (no detached leaks of threads or
     stack references into caller-owned buffers).
   - **Scratch cleanup**: per-worker scratch is freed on both success and
     every error path, including mid-flight cancel, and charged/uncharged
     against `allocation_bytes_max` consistently.
   - **Partial-spawn failure**: if the Nth `spawn` fails after K workers
     started, join/cancel those K, free their scratch, and return a
     defined error without leaking threads or budget charges.
6. **Concurrency primitive and ownership comparison.** Compare raw
   `std.Thread.spawn` (library owns thread creation, joins, and partial-spawn
   cleanup) with Zig 0.16 caller-supplied `std.Io` plus
   `std.Io.Group.concurrent`/`await`/`cancel` (application owns the `Io`
   implementation; library owns each operation's group and joins/cancels it
   before return). Record which model the post-1.0 implementation should use
   and why. Do not propose the non-concurrent
   `std.Io.Threaded.global_single_threaded` as a scheduler. wasm/single-threaded
   targets stay on the scalar path either way.
7. **Structure per codec path.** Analyze the four candidates from "Current
   state", each with dependency analysis (what is causal and what can run
   independently), expected ceiling, and a build-order recommendation.
   Current evidence in `PROGRESS.MD:314-330,1431-1434` puts VP8L entropy at
   roughly 66%–95% and records the accepted/rejected scalar and SIMD
   experiments; use those measurements rather than estimates. Condition the
   **animation-encode frame-parallelism** recommendation on the serial
   optimizer dependency in `src/animation_optimize.zig` (it re-decodes its
   own output to track the reconstructed canvas): recommend that first
   slice **only if** the design shows a path that either bypasses the
   optimizer for the parallel path, serializes the optimizer barrier, or
   otherwise makes the dependency explicit — do not treat animation encode
   as embarrassingly parallel without that caveat. Then the lossy-decode
   pipeline split.
8. **Platform matrix.** linux/macos native threads; wasm32 and
   single-core: compile-time capability check (`builtin.single_threaded`,
   target has-threads) with the scalar path as the only path; big-endian
   unaffected but CI must run one threaded configuration.
9. **Acceptance gates for the future implementation plan(s).** Byte-exact
   corpus at 1/2/4 threads; no new allocation outside the budget
   (`checkAllAllocationFailures` extended to the spawn path); a dated bench
   row showing wall-clock < single-thread `dwebp` on at least the `bryce`
   class; `zig build wasm-check` green; tests that exercise partial-spawn
   failure, cancel/join-before-return, and scratch cleanup on error.
10. **Roadmap consistency.** Update the sentence in `Near-Term Work Items`
    that currently says step 13 is the only remaining roadmap item. It must
    name step 14 as a design decision still to execute, without claiming
    threading is implemented.

Keep it under ~120 lines of `PLAN.MD` text — a decision record, not a
novel.

**Verify**: every numbered item above appears (including failure/lifetime
semantics, provider ownership, and the Zig-0.16-accurate `std.Io` comparison);
every factual claim carries a `file:line` or `PROGRESS.MD` citation; the new
section sits between step 13 and `Near-Term Work Items`; the summary names
step 14 without claiming it shipped; no implementation-like code blocks.

### Step 3: Gate

`zig fmt .` (PLAN.MD is untouched by fmt but the gate must stay green) and
`zig build ci` → exit 0.

## Test plan

None — documentation deliverable. The verification is Step 2's checklist
plus `zig build ci`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "Threading (post-1.0 design)" PLAN.MD` → one step-14 heading,
      after step 13 and before `Near-Term Work Items`
- [ ] The section contains every numbered element (grep for "Determinism",
      "allocation_bytes_max", "wasm32", "Acceptance", "error precedence" or
      "partial-spawn", `std.Io`, "provider", and "join")
- [ ] The near-term roadmap summary names both the C-ABI implementation and
      threading design; it does not claim threading is implemented
- [ ] `zig build ci` exits 0
- [ ] Only `PLAN.MD` and `plans/README.md` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `PLAN.MD` has been restructured after `7686a55` such that there is no clear
  home for the section.
- You find an existing threading design decision recorded anywhere in
  `PLAN.MD`/`PROGRESS.MD` that contradicts this plan's premise (then the
  maintainer must reconcile, not you).
- The proposed `std.Io` path cannot explain how a caller-owned provider enters
  the codec without breaking or ambiguously extending Tier 1 — record the
  alternatives and stop for maintainer selection rather than hiding a global
  scheduler behind the existing entry points.
- You feel the need to prototype code to answer a design question — write
  the question into the section's "open questions" list instead.

## Maintenance notes

- The implementation slices that come out of this design should each be
  planned separately (the acceptance gates in item 9 are their skeleton).
- Reviewer should scrutinize: the budget-accounting rule (item 4) — it is
  the easiest place to silently break the step-11 hardening contract — the
  determinism CI story (item 3), and the failure/lifetime rules (item 5:
  error precedence, cancel, join-before-return, scratch cleanup,
  partial-spawn). Also whether the animation-encode first-slice
  recommendation honestly accounts for the optimizer's serial re-decode.
- Future implementation plans must preserve the chosen concurrency-provider
  ownership contract. A plan that adds only `thread_count_max` while silently
  constructing an internal `std.Io.Threaded` instance has drifted from this
  design and should be rejected.
