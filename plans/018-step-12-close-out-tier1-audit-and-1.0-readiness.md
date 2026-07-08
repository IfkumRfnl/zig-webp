# Plan 018: Step-12 close-out — Tier-1 API audit, docs completeness, 1.0 release readiness

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 6d62f55..HEAD -- src/root.zig src/options.zig src/errors.zig src/image.zig src/limits.zig README.MD PLAN.MD PROGRESS.MD RELEASING.MD`
> Also run `git status --porcelain`. Expected state: the commit diff is empty,
> and the working tree carries at most (a) an uncommitted `PROGRESS.MD` edit
> recording the 2026-07-08 browser-check pass (step 0 handles it) and
> (b) uncommitted changes under `plans/`. Any *other* in-scope drift means
> compare the "Current state" excerpts against the live code before
> proceeding, and treat a mismatch as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW–MED (docs-heavy; the only risky moves — Tier-1 renames — are
  gated behind operator approval)
- **Depends on**: 012 (DONE), 013 (DONE)
- **Category**: release
- **Planned at**: commit `6d62f55`, 2026-07-08 (authored on maintainer
  request, outside an audit session; refined same day after a cold-read
  review — baseline re-verified: 464/464 tests pass at `6d62f55`)

## Why this matters

`PLAN.MD` step 12 has three unfinished bullets standing between the project
and 1.0.0:

1. "Stabilize APIs for …" (`PLAN.MD:378-385`) — five of the six named
   surfaces (feature probing, static encode from typed pixel buffers,
   animation iteration/composition, metadata extraction and muxing,
   memory/security limits) have working, documented code but **no recorded
   pass** confirming their ownership and error semantics are final. After
   1.0, every rename is a breaking change; this audit is the last cheap
   moment to catch an inconsistency.
2. "Document pixel formats, ownership, allocation behavior, and error
   semantics" (`PLAN.MD:386-387`) — `src/root.zig` is dense with per-decl
   docs, but nobody has checked it against that four-item list as a
   completeness gate.
3. The 1.0.0 criterion itself (`PLAN.MD:392-394`) — every other gate now
   holds: 8b/8c encoder gates, animation encode, metadata, hardening, CI
   (Linux/macOS/big-endian), and the compatibility matrix's browser row
   (recorded 2026-07-08, Firefox + Chromium, both minimized samples pass).
   What remains is exactly items 1–2 plus the release procedure.

`PROGRESS.MD`'s "Current Position" also still names `decodeStaticInto` as the
next gap — stale since plan 012 delivered it; this plan truths that up.

## Current state

- `src/root.zig:17-40` — the Tier-1/Tier-2 stability contract (plan 013).
  Tier 1 names exactly **16 entry points** (`src/root.zig:19-24`):
  `decodeStatic`, `decodeStaticInto`, `decodeAnimation`, `AnimationDecoder`,
  `encodeLossless`, `encodeLossy`, `encodeStatic`, `encodeAnimation`,
  `encodeAnimationFromBuffers`, `encodeAnimationMinimized`, `parseFeatures`,
  `parseWebP`, `isWebP`, `parseHeader`, `parseChunkHeader`, `errorCategory` —
  plus **21 enumerated types** (`src/root.zig:25-32`): `DecoderOptions`,
  `EncoderOptions`, `ResourceLimits`, `ImageBuffer`, `Dimensions`,
  `PixelFormat` (via `image`), `Error`, `ErrorCategory`, `FeatureSummary`,
  `DemuxResult`, `AnimationImage`, `AnimationFrameImage`, `AnimationInfo`,
  `CompositedFrame`, `DecodedAnimation`, `DecodedAnimationFrame`,
  `AnimationFrameSource`, `AnimationEncodeOptions`, `AnimationFrameInput`,
  `AnimationMinimizeOptions`, `MetadataPayloads`.
- `src/root.zig` forwarding functions carry substantive `///` docs
  (ownership, limits, errors); alias re-exports carry shorter ones. The audit
  measures these against a fixed checklist, not taste.
- `src/options.zig` — `DecoderOptions`/`EncoderOptions`. Three knobs are
  documented, honest no-ops/clamps — **all non-blocking for 1.0** (the honest
  documentation already satisfies the contract; do not report them as
  findings): `EncoderOptions.method` 5–6 clamp to 4 (`src/options.zig:29-32`;
  plan 016 measures the headroom), and `DecoderOptions.preserve_metadata` /
  `DecoderOptions.decode_animation` have no effect today
  (`src/options.zig:11-18`).
- `src/errors.zig` — one shared `errors.Error` set + `Category`
  (`src/errors.zig:3,11,66`). The documented breaking-change rule: additions
  are not breaking.
- `README.MD:10-18` — the README's condensed tier statement. It is
  deliberately coarser than `root.zig` (groups "the `encode*` functions",
  enumerates no types, and points at `src/root.zig` for the full list).
  Coarser is fine; *contradicting* the fixed docs is not.
- `RELEASING.MD` — gate table (`Gate → check mapping`, lines 19-28),
  compatibility matrix (lines 63-74, all rows green or recorded-deferred),
  browser-check procedure, release procedure. Version is `0.2.0`
  (`build.zig.zon:3`).
- Recorded follow-up, **out of scope and non-blocking**: threading the
  caller's stride through codec output stages (`decodeStaticInto` v1 is
  copy-based by design).
- Open plans 014 (WASM spike), 016 (m5/6 measurement), 017 (info CLI) are
  additive and non-breaking; 015 (C-ABI design) is sequenced post-1.0. None
  blocks this plan; whether any lands *before* the 1.0 tag is an operator
  call surfaced in step 5.

### Known leads (verify during step 1 — do not take on faith)

Two contract gaps were spotted while writing this plan; the audit must
confirm and record them (fix class: doc, both):

1. **Tier-1 parameter/result types missing from the enumerated list.** The
   contract says "plus their parameter and result types:" and then lists 21
   names — but Tier-1 signatures also use `OwnedBuffer` (result of
   `decodeStatic`, `src/root.zig:406-410`), `DemuxOptions` (parameter of
   `parseFeatures`/`parseWebP`, `src/root.zig:238-253`), `MuxOptions` and
   `StaticImage` (parameters of `encodeStatic`/`encodeAnimation`,
   `src/root.zig:262-282`), and `ContainerHeader`/`ChunkHeader` (results of
   `parseHeader`/`parseChunkHeader`, `src/root.zig:225-231`). These are
   de-facto frozen (a frozen function's parameter type cannot be renamed
   without breaking it); adding them to the list at `src/root.zig:25-32` is
   truth-up, not scope expansion. Audit each with the checklist once added.
2. **Two public root functions in neither tier.** `encodeVP8LBitstream`
   (`src/root.zig:353`) and `encodeVP8Bitstream` (`src/root.zig:390`) are
   root-level `pub fn`s, absent from the Tier-1 list, and not covered by
   Tier 2's "module exports and aliased types" wording. Their own docs say
   "Most callers want `encodeLossless`/`encodeLossy`; this is for tooling" —
   recommend an explicit Tier-2 classification in the contract doc comment
   (doc-class fix). If the audit concludes they belong in Tier 1 instead,
   treat that as a rename-class finding: surface to the operator in step 3,
   don't decide unilaterally. Note in passing: `encodeVP8Bitstream` takes
   `[]const VP8LARGBPixel` (a VP8L-named type in a VP8 signature) — record
   whatever the checklist's naming item concludes.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check + compile + all tests) |
| Tests only | `zig build test` | exit 0 (464/464 at planning time, re-verified 2026-07-08) |
| Compile check (library + 4 CLI tools) | `zig build check` | exit 0 |
| CI state of the planning commit | `gh run list --commit 6d62f55` | three jobs (`test`, `big-endian`, `macos`), all `completed`/`success` |
| Local oracle (per-mode, tool-gated) | `tools/webp-oracle.sh` modes per `RELEASING.MD:19-28` | matches recorded gate rows |

The oracle tools were all present on the planning machine (`command -v cwebp
dwebp anim_dump webpinfo` all resolve); still gate each mode on its own
`command -v` check — your environment may differ.

## Suggested executor toolkit

- Consult the `zig-0.16` and `zig-tiger-style` skills before touching Zig
  code.
- A Zig language server (`zls`) was NOT installed on the planning machine;
  if your environment lacks LSP rename too, step 3 includes a textual
  fallback.

## Scope

**In scope** (the only files you should modify):

- `src/root.zig`, `src/options.zig`, `src/errors.zig`, `src/image.zig`,
  `src/limits.zig` — doc-comment fixes only, unless a rename is
  operator-approved (STOP condition).
- `README.MD` — API-surface parity fixes found by the audit.
- `PLAN.MD` — tick the remaining step-12 bullets as delivered (one clause
  each; details go to `PROGRESS.MD`).
- `PROGRESS.MD` — rewrite the stale "Current Position" closing paragraph;
  dated step-12 audit entry with the findings table and outcomes.
- `RELEASING.MD` — only if the audit finds a gate-table inaccuracy.
- `plans/README.md` — status row.

**Rename exception**: if (and only if) the operator approves a rename in
step 3, the files mechanically touched by that rename — callsites under
`src/` and `tools/`, plus name mentions in the `.MD` docs — become in scope
*for the rename commit only*. Record the approval verbatim in the commit
message.

**Out of scope** (do NOT touch):

- Codec internals (`src/vp8/**`, `src/vp8l/**`, `src/color.zig`,
  `src/alpha.zig`, decode/encode composition logic) — this plan changes no
  behavior. The SHA-256 corpus gate and encode round-trip gates pin outputs.
- The caller-stride decode optimization (recorded follow-up).
- Executing plans 014–017.
- The `git tag` itself (step 5 ends at readiness; tagging is the operator's
  release decision per `RELEASING.MD`).

## Design decisions (already made — do not re-litigate)

1. **Audit checklist** — every Tier-1 entry point is scored against exactly
   these five questions; every Tier-1 type against 2–5:
   - (a) Who allocates and who frees? Returned memory's owner and its
     `deinit`/free obligation stated in the doc comment.
   - (b) Allocation bounded? The doc states scratch/output allocation is
     budgeted against `ResourceLimits.allocation_bytes_max` where it is.
   - (c) Error semantics: notable failure modes named; nothing panics on
     untrusted input; `errorCategory` coverage for any newly-noticed error.
   - (d) Naming and parameter-order consistency across the surface
     (`gpa` first, options bag last, `*_options` naming).
   - (e) Pixel-format/stride contract stated wherever an `ImageBuffer`
     crosses the API.

   Table hygiene: one row per name; `Error` and `ErrorCategory` are separate
   rows. A checklist item that does not apply to a row (e.g. (a) for a
   by-value type that allocates nothing, (e) for a function no `ImageBuffer`
   crosses) is recorded as `n/a` — never left blank. "Checked, no finding"
   is a valid, required row. `AnimationDecoder` is scored as an **entry
   point**: apply (a)–(e) to its public methods (`init`, `next`, `deinit`,
   and any other `pub fn` on it), one row covering the type.
2. **One shared error set stays.** Per-function error sets would be a design
   change with no 1.0 payoff; the audit checks *documentation* accuracy, not
   set granularity.
3. **Renames are findings, not actions.** Any inconsistency whose fix is a
   Tier-1 rename goes in the findings table with a recommendation; applying
   it requires explicit operator approval (STOP condition). Doc fixes apply
   directly.
4. **The findings table is committed** to `PROGRESS.MD` (house precedent:
   audit results live there, dated), including clean rows — "checked, no
   finding" is the evidence 1.0 rests on.

## Git workflow

- Branch: `step-12-tier1-audit`, created from HEAD (step 0 defines the
  starting state).
- Commit style: single imperative summary line.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0: Establish a clean starting state

Create branch `step-12-tier1-audit` from HEAD. If `git status` shows the
uncommitted `PROGRESS.MD` edit recording the 2026-07-08 browser-check pass
(a small diff in the "Current Position" step-9 paragraph and the
compatibility-matrix follow-up paragraph, plus the `Last updated` line),
commit it first, alone: `Record 2026-07-08 browser-check pass in
PROGRESS.MD`. Uncommitted changes under `plans/` may also exist (index
bookkeeping) — leave them or commit them separately; they are not code. Any
*other* uncommitted change is a STOP condition.

**Verify**: `git status --porcelain -- src/ tools/ README.MD PLAN.MD PROGRESS.MD RELEASING.MD build.zig build.zig.zon` → empty output.

### Step 1: Audit pass (read-only)

Walk every Tier-1 entry point (16, listed in "Current state") and every
Tier-1 type (21, listed there too — plus the missing-type lead below)
against the design-decision checklist. Read the forwarding docs in
`root.zig` AND the underlying decls (`options.zig`, `image.zig`,
`errors.zig`, `limits.zig`, module fns) — the audit is against behavior, not
just prose. Explicitly work the two **Known leads** from "Current state"
into the table (missing parameter/result types; the two unclassified
bitstream encoders). Build the findings table:
`name | checklist item | finding | fix class (doc / rename / none)`.

**Verify**: the table has ≥ 37 rows (16 entry points + 21 types; more if
the missing-type lead confirms), every cell filled (`n/a` counts, blank does
not), and each of the two Known leads has a row recording its outcome.

### Step 2: Apply doc-class fixes

Fix every `doc` finding in the in-scope files. Then check `README.MD`
agrees with the fixed docs — specifically the tier statement at
`README.MD:10-18` and the status paragraphs describing decode/encode
behavior — through the `PLAN.MD:386-387` four-item lens (pixel formats,
ownership, allocation behavior, error semantics). README stays coarser than
`root.zig` by design; fix only statements that *contradict* the audited
docs. No behavior changes; no test deltas expected beyond `refAllDecls`
compilation.

**Verify**: `zig build ci` → exit 0.

### Step 3: Surface rename-class findings (if any)

If the table contains rename recommendations, STOP and present them to the
operator with the tradeoff (breaking to 0.x users now vs frozen forever at
1.0). Apply only what is approved. Mechanics: use LSP rename if your
environment has a Zig language server; otherwise rename textually —
`grep -rn '\b<OldName>\b' src/ tools/ README.MD PLAN.MD PROGRESS.MD RELEASING.MD`,
edit every hit (word-boundary matches only; leave historical `PROGRESS.MD`
oracle-log entries as-is, they describe past states), and let `zig build ci`
prove closure. Update README/docs in the same commit; quote the operator's
approval in the commit message. The Scope section's rename exception governs
which files may change.

**Verify**: `zig build ci` → exit 0 after any approved rename; step skipped
cleanly if the table has no rename rows.

### Step 4: Truth-up the documents

- `PROGRESS.MD` — three precise edits:
  1. Replace the stale closing paragraph of `## Current Position`
     (currently lines 62-65, beginning "The next roadmap area is step 12" and
     containing the phrase "highest-leverage API gap") with a paragraph
     stating the audit outcome and release posture.
  2. Insert a new section `### Step 12 — Tier-1 API audit and 1.0 readiness`
     directly under the `## Recently Completed` heading (newest-first house
     order; it lands above the existing
     `### Step 12 — Release criteria (1.0 stability contract + compatibility matrix)`
     entry — both existing step-12 entries stay untouched). Contents: dated
     prose (2026-07-08 or the execution date), the full findings table from
     step 1, and the list of applied fixes. Step 5 appends its readiness
     paragraph to this same section.
  3. Bump the `Last updated:` line at the top.
- `PLAN.MD` — mark the remaining step-12 "Stabilize APIs" sub-items
  (`PLAN.MD:379,382-385`) and the "Document …" bullet (`PLAN.MD:386-387`)
  delivered, mirroring the existing house style at `PLAN.MD:380-381`:
  a parenthetical `(delivered: <one clause>, see `PROGRESS.MD`)` on each —
  PLAN stays forward-looking, details live in PROGRESS.

**Verify**: `grep -c "highest-leverage API gap" PROGRESS.MD` → `0`;
`grep -n "Tier-1 API audit" PROGRESS.MD` → exactly one hit, located under
`## Recently Completed`; `grep -c "delivered" PLAN.MD` ≥ 6 (the five
stabilize sub-items + the document bullet, plus any pre-existing uses);
`zig build ci` → exit 0.

### Step 5: Release-readiness record (no tag)

Confirm the `RELEASING.MD` gate table at HEAD, splitting by where each gate
runs (per `RELEASING.MD:19-36`):

- **CI-covered gates** (fmt, build, step-5 corpus hashes, lossless
  round-trip units): covered by your local `zig build ci` pass plus the CI
  record — run `gh run list --commit 6d62f55` and confirm the three jobs
  (`test`, `big-endian`, `macos`) succeeded. If `gh` is unavailable or
  unauthenticated, record that the local `zig build ci` pass stands in and
  cite the last recorded green (plan 013's row in `plans/README.md`).
- **Local-oracle gates** (lossless size ratio, 8b PSNR, 8c target-size,
  animation `anim_dump` parity): for each mode in `RELEASING.MD:24-28`, run
  it iff its tool resolves (`command -v cwebp`, `dwebp`, `anim_dump`) and
  compare against the recorded "0.2.0 gate status" section
  (`RELEASING.MD:37+`). For any mode whose tool is missing, record
  explicitly that the 0.2.0-recorded result stands.
- **Compatibility matrix** (`RELEASING.MD:63-74`): browser row = the
  2026-07-08 record (committed in step 0); Windows = recorded-deferred.

Append a "1.0.0 readiness" paragraph to the step-4 audit section in
`PROGRESS.MD` stating what is green and that the remaining decisions are the
operator's: (1) tag now vs land any of plans 014/016/017 first; (2) execute
`RELEASING.MD`'s procedure (version bump, CHANGELOG, release PR, tag).

**Verify**: `grep -c "1.0.0 readiness" PROGRESS.MD` ≥ 1; `zig build ci` →
exit 0.

### Step 6: Update the plans index

Set this plan's row in `plans/README.md` following the house form for
unmerged work (see the 2026-06-30 reconcile-log precedent):
`DONE — executed on branch step-12-tier1-audit (commit <sha>); not merged
(no PR per instructions)` — or the merged form if the operator had you open
a PR.

**Verify**: `grep -n "018" plans/README.md` shows the updated status.

## Test plan

No new behavior → no new tests. The gates that must stay green are the
existing ones: `zig build ci` (fmt, compile, 464 tests including the SHA-256
corpus regression and encode round-trips). Any test delta is a STOP signal —
this plan must not move behavior.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0.
- [ ] `PROGRESS.MD` contains a dated `### Step 12 — Tier-1 API audit and 1.0
      readiness` section under `## Recently Completed`, whose findings table
      has ≥ 37 rows (16 entry points + 21 Tier-1 types) with no blank cells.
- [ ] `grep -c "highest-leverage API gap" PROGRESS.MD` → `0`.
- [ ] `PLAN.MD:378-387`: all five remaining stabilize sub-items and the
      document bullet carry a `(delivered: …, see PROGRESS.MD)` marker.
- [ ] `grep -c "1.0.0 readiness" PROGRESS.MD` ≥ 1.
- [ ] `git status` shows no modified files outside the in-scope list —
      except files touched solely by an operator-approved rename (approval
      quoted in that commit's message).
- [ ] No Tier-1 rename applied without a recorded operator approval.
- [ ] `plans/README.md` status row updated.

## STOP conditions

- Any audit finding whose fix would change **behavior** (not docs): stop and
  report; that is a defect, not a stabilization item, and needs its own plan.
  (The three documented no-op knobs in "Current state" are NOT this — they
  are recorded, decided tradeoffs.)
- Any rename-class finding: stop and present before applying (step 3).
- Any test failure or corpus-hash mismatch at any step: stop — this plan
  cannot be the cause and something else is wrong.
- Drift check mismatch beyond the expected `PROGRESS.MD` browser-check edit
  and `plans/` bookkeeping (see step 0).
- The audit concludes `encodeVP8LBitstream`/`encodeVP8Bitstream` must be
  Tier 1 (not the recommended Tier-2 classification): that changes the
  frozen surface — operator decision, same gate as renames.

## Maintenance notes

- If the operator green-lights the release after step 5, execute
  `RELEASING.MD`'s procedure as its own change (version `1.0.0` in
  `build.zig.zon`, dated `CHANGELOG.MD` entry, release PR, tag after merge).
- The caller-stride `decodeStaticInto` optimization and plan 015's C-ABI
  implementation both key off the surface this audit freezes; run them
  post-1.0 against the frozen contract.
- Reviewer focus: the findings table's *clean* rows are the load-bearing
  artifact — spot-check a few against the code, not just the fixes. If the
  missing-type lead lands, the Tier-1 list at `src/root.zig:25-32` grows;
  every added name is a new freeze commitment the reviewer should consciously
  accept.
