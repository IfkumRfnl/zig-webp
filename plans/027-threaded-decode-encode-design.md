# Plan 027: Threading design document — opt-in parallel decode/encode (design only, no code)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- PLAN.MD PROGRESS.MD`
> `PLAN.MD`/`PROGRESS.MD` have in-flight edits from other work at planning
> time — that alone is NOT a stop condition for this plan; only a
> restructuring of `PLAN.MD`'s section layout is.

## Status

- **Priority**: P3 (post-1.0 track, like plan 015)
- **Effort**: M (thinking + writing; zero code)
- **Risk**: LOW (a document)
- **Depends on**: plans/020 (soft — attribution data informs the split);
  plans/021–023 (soft — thread nothing that scalar work can still fix).
  Sequencing note: like plan 015 (C-ABI design), execute after the 1.0
  release decisions settle.
- **Category**: direction / perf
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

Threading is the one lever that can make this library **beat** single-thread
`dwebp` wall-clock outright (dwebp is single-threaded by default), which
matches `AGENTS.MD`'s targeted-outperformance policy — and it is the last
lever named by the slice-10c record ("loop-filter SIMD/lookup tables,
row-pipeline locality, and threading"). But threading touches the project's
deepest contracts: deterministic allocation, allocation *budgets*
(`ResourceLimits.allocation_bytes_max`), byte-exact output, wasm32 support
(no threads), and the frozen Tier-1 API. Designing it in a document first —
exactly as plan 015 did for the C-ABI — is how the repo already handles
this class of decision. The deliverable is a `PLAN.MD` section the
maintainer can approve, reject, or trim before anyone writes `std.Thread`
code.

## Current state

Facts the design must honor (all verifiable in-repo):

- **Thread-compatibility statement**: `PLAN.MD:43-45` — "The library is
  thread-compatible: no global mutable state, so distinct decode/encode
  jobs may run on distinct threads. Internal parallelism is deferred to
  step 10." Step 10 is delivered without it; this design picks that thread
  up explicitly.
- **Zero-dependency policy** (`AGENTS.MD`): `std.Thread` only; no runtime
  deps. wasm32-wasi and wasm32-freestanding must keep compiling and passing
  tests — threading must be compile-time absent or runtime-degraded there
  (CI: `zig build wasm-check` + wasmtime suite; big-endian powerpc64 under
  QEMU).
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

## Scope

**In scope** (the only files you should modify):
- `PLAN.MD` (one new section; forward-looking content only, per `AGENTS.MD`)
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

Read, in this order: `PLAN.MD` (the step-10 section and the 1.0/post-1.0
sections), `src/root.zig` module doc (stability tiers), `src/limits.zig`
(`ResourceLimits` fields), the `PROGRESS.MD` step-10 and step-11a entries,
and `plans/015-c-abi-design.md` (the format precedent). List, in your
working notes, every constraint you found with its `file:line`.

**Verify**: your notes name ≥ 6 constraints with citations (the six bullets
in "Current state" are the checklist).

### Step 2: Write the `PLAN.MD` section

Add a section titled "Threading (post-1.0 design)" adjacent to the other
forward-looking capability sections, containing:

1. **Goals/non-goals.** Goal: beat default single-threaded `dwebp`
   wall-clock on large stills; scale animation encode. Non-goal: threading
   as default behavior; non-goal: wasm threads.
2. **API shape (decide one, record the alternatives).** Additive options
   field vs separate entry points; default = single-threaded; interaction
   with the Tier-1 contract quoted from `src/root.zig`.
3. **Determinism contract.** Output byte-identical for every thread count;
   the corpus gates run the threaded path at ≥ 2 threads in CI (state how:
   a test-only option matrix).
4. **Budget accounting.** How `allocation_bytes_max` covers per-worker
   scratch (reserve-before-spawn; spawn fewer workers if the budget caps
   out — never fail a decode that would succeed single-threaded).
5. **Structure per codec path.** The four candidate structures from
   "Current state", each with: dependency analysis (what is causal, what is
   free), expected ceiling (Amdahl: entropy decode is serial in VP8L —
   state what fraction that is per plan-020 attribution when available),
   and a build-order recommendation (recommended first slice: animation
   encode frame-parallelism — simplest contract, biggest user-visible win;
   then the lossy-decode pipeline split).
6. **Platform matrix.** linux/macos native threads; wasm32 and
   single-core: compile-time capability check (`builtin.single_threaded`,
   target has-threads) with the scalar path as the only path; big-endian
   unaffected but CI must run one threaded configuration.
7. **Acceptance gates for the future implementation plan(s).** Byte-exact
   corpus at 1/2/4 threads; no new allocation outside the budget
   (`checkAllAllocationFailures` extended to the spawn path); a dated bench
   row showing wall-clock < single-thread `dwebp` on at least the `bryce`
   class; `zig build wasm-check` green.

Keep it under ~120 lines of `PLAN.MD` text — a decision record, not a
novel.

**Verify**: every numbered item above appears; every factual claim carries
a `file:line` or `PROGRESS.MD` citation; no code blocks that could be
mistaken for implementation.

### Step 3: Gate

`zig fmt .` (PLAN.MD is untouched by fmt but the gate must stay green) and
`zig build ci` → exit 0.

## Test plan

None — documentation deliverable. The verification is Step 2's checklist
plus `zig build ci`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "Threading (post-1.0 design)" PLAN.MD` → present
- [ ] The section contains the 7 numbered elements (grep for
      "Determinism", "allocation_bytes_max", "wasm32", "Acceptance")
- [ ] `zig build ci` exits 0
- [ ] Only `PLAN.MD` and `plans/README.md` modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `PLAN.MD` has been restructured since `29be0df` such that there is no
  clear home for the section.
- You find an existing threading design decision recorded anywhere in
  `PLAN.MD`/`PROGRESS.MD` that contradicts this plan's premise (then the
  maintainer must reconcile, not you).
- You feel the need to prototype code to answer a design question — write
  the question into the section's "open questions" list instead.

## Maintenance notes

- The implementation slices that come out of this design should each be
  planned separately (the acceptance gates in item 7 are their skeleton).
- Reviewer should scrutinize: the budget-accounting rule (item 4) — it is
  the easiest place to silently break the step-11 hardening contract — and
  the determinism CI story (item 3), which is what keeps the corpus gates
  meaningful once threads exist.
