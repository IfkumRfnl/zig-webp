# Plan 015: Design the C-ABI export layer (design document only — no implementation)

> **Executor instructions**: Follow this plan step by step. This plan's
> deliverable is a DESIGN DOCUMENT, not code — do not create any `.zig`
> source files or modify `build.zig`. Run every verification command and
> confirm the expected result. If anything in the "STOP conditions" section
> occurs, stop and report. When done, update the status row in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- src/root.zig src/errors.zig src/limits.zig src/image.zig src/options.zig PLAN.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. In particular, check whether plans
> 012/013 have landed (`grep -c decodeStaticInto src/root.zig`; stability
> tiers in the root doc comment) — this design builds on both.

## Status

- **Priority**: P2
- **Effort**: M (analysis + writing; no code)
- **Risk**: LOW (a document; the risk is designing against APIs that then
  change — hence the dependency ordering)
- **Depends on**: plans/012-decode-static-into-caller-owned-buffer.md,
  plans/013-one-oh-stability-contract-and-compat-matrix.md
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

`PLAN.MD:32` scopes out "a C ABI or bindings layer **before the Zig API
stabilizes**" — a sequencing decision, not a rejection. With steps 0–11
delivered and step 12 (stabilization) in flight, that condition is nearly
met, and a C ABI is the single largest adoption lever available: it opens
the library to every FFI-capable language (Python, Rust, Go, Node, JVM) and
gives the WASM embedding (plan 014) its export surface. Designing it now —
while the Zig API's ownership and limits idioms are being frozen — prevents
1.0 from accidentally stabilizing shapes that are hostile to FFI (e.g.
returning Zig error unions or allocator-coupled structs). The deliverable is
a written design in PLAN.MD that a later implementation plan can execute
mechanically.

## Current state

- `PLAN.MD:24-32` — non-goals list, including: "A C ABI or bindings layer
  before the Zig API stabilizes."
- `src/root.zig` — the Zig public surface the C ABI must mirror. Key entry
  points: `decodeStatic`, `decodeStaticInto` (if plan 012 landed),
  `decodeAnimation`/`AnimationDecoder`, `encodeLossless`, `encodeLossy`,
  `parseFeatures`, `parseWebP`, `isWebP`, `errorCategory`.
- `src/errors.zig` — one flat `pub const Error = error{...}` set (~50
  members) plus `Category` (`container`, `resource_limit`, `unsupported`,
  `bitstream`, `allocation`) and `category(err)`. This taxonomy is the raw
  material for C error codes.
- `src/limits.zig` — `ResourceLimits`: six plain integer fields
  (`input_bytes_max: u64`, `output_pixels_max: u64`,
  `allocation_bytes_max: u64`, `frame_count_max: u32`,
  `animation_canvas_pixels_max: u64`, `chunk_count_max: u32`). Already
  extern-friendly.
- `src/image.zig` — `Buffer` (`pixels: []u8`, `dimensions {u32,u32}`,
  `stride: u32`, `format` enum) — a Zig slice is not C-ABI; the C mirror is
  pointer+len. `PixelFormat`: `rgb`, `rgba`, `bgra`, `argb`.
- `src/options.zig` — `DecoderOptions` (limits + output_format + two
  reserved bools), `EncoderOptions` (limits, format, quality, method,
  target_size `?u32`, target_psnr `?f32`, alpha_quality, use_sharp_yuv,
  metadata payloads as optional slices). Zig optionals (`?u32`) are not
  C-ABI; the design must pick sentinels or presence flags.
- `build.zig:14-19` — already builds a static library artifact
  (`addLibrary(.{ .name = "zig-webp", ... .linkage = .static })`), so the
  artifact side of a C ABI is nearly free; a shared-library option and an
  install step for a header would be implementation work (out of scope
  here, but the design should specify them).
- Repo policy (`AGENTS.md`): PLAN.MD is forward-looking (scope, ordering,
  acceptance gates) — which is exactly what this design section is;
  completed work goes to PROGRESS.MD.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm docs build nothing broke | `zig build ci` | exit 0 (you changed only markdown) |
| Check plan-012 landed | `grep -c "pub fn decodeStaticInto" src/root.zig` | ≥1 (else see STOP conditions) |

## Scope

**In scope** (the only files you should modify):

- `PLAN.MD` — a new section (place it after "### 12. Public API and Release
  Criteria", titled e.g. "### 13. C ABI (post-1.0)"), containing the design.
- `plans/README.md` — status row.

**Out of scope** (do NOT touch):

- Any `.zig` file, `build.zig`, `build.zig.zon`, CI. No prototype code — the
  design document may contain illustrative C declarations as fenced code
  blocks, but nothing compiled.
- Language-specific bindings (Python/Rust/etc.) — downstream consumers of
  the C ABI, not part of it.

## Git workflow

- Branch: `c-abi-design` (repo convention: `<slug>`).
- Commit style: single imperative summary line, e.g.
  `Add C-ABI design section to PLAN.MD (step 13, post-1.0)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Study the surfaces the design must mirror

Read, in this order: `src/root.zig` (entire — it is ~450 lines and IS the
API), `src/errors.zig`, `src/limits.zig`, `src/image.zig`, `src/options.zig`,
and the stability-tier doc comment from plan 013. Optional but useful
prior art for *shape* (not code): libwebp's public headers under
`references/libwebp/src/webp/` (`decode.h`, `encode.h`) — per `AGENTS.md`,
study behavior/API shape only, never copy code.

**Verify**: you can state, without re-opening the files, what
`decodeStaticInto`'s dest contract is and what the five `ErrorCategory`
values are. (Self-check, no command.)

### Step 2: Write the design section in PLAN.MD

The section must answer ALL of the following, each with a decision, a
one-line rationale, and (where real) the rejected alternative. Recommended
positions are given; deviate only with a written reason:

1. **Scope of the exported surface (v1)**: Tier-1-only, and within that the
   still-image core first: probe (`parseFeatures` analogue), decode
   (`decodeStaticInto` analogue — caller-owned buffers ONLY; no
   library-allocated-pixels variant in v1, so no cross-boundary pixel
   ownership), still encode (`encodeLossless`/`encodeLossy` analogues,
   which DO return library-allocated bytes and therefore need a paired
   free). Animation APIs: design the shape but mark them v2 — the
   `AnimationDecoder` streaming type needs an opaque-handle design.
2. **Naming and header**: prefix (`webp_zig_` vs `zwebp_` — recommend
   `zwebp_` for brevity and to avoid colliding with libwebp's `WebP*`
   namespace, which matters because a C program may link both), one
   hand-written `include/zwebp.h` (Zig has no reliable auto-header emit;
   the header is a maintained artifact whose drift is checked by a test —
   specify that an implementation-plan gate must compile the header against
   the exports, e.g. a CI step building a tiny C smoke program).
3. **Error model**: functions return `int32_t` status; `0` success. Decide:
   negative enum per `errors.Error` member (stable numbering appended-only)
   plus a `zwebp_error_category(int32_t)` mirroring `errors.category`, and a
   `zwebp_error_name(int32_t)` returning a static string. Additions of new
   error codes are non-breaking (mirrors plan 013's rule).
4. **Memory model**: no allocator crosses the boundary in v1. Internally the
   implementation uses a Zig allocator (decide which: recommend
   `std.heap.smp_allocator` or page allocator wrapped — leave the concrete
   choice to the implementation plan but state the requirement: thread-safe,
   no global mutable state per the PLAN.MD threading stance). Encoder
   outputs are freed via `zwebp_free(ptr)`. Decoder output memory is always
   caller's (via the Into contract). Document that `ResourceLimits.
   allocation_bytes_max` remains the caller's bound on internal scratch.
5. **Struct strategy**: extern structs for `zwebp_limits` (mirror the six
   fields), `zwebp_buffer` (`uint8_t* pixels; uint64_t len; uint32_t width,
   height, stride; int32_t format;`), decode/encode option structs. Optionals
   (`target_size: ?u32`, `target_psnr: ?f32`) become value+`bool has_*`
   fields or 0-as-unset sentinels — decide (recommend explicit `has_*`
   bools; 0 is a legal PSNR target in principle and sentinel ambiguity is
   how C APIs rot). Every option struct gets a
   `zwebp_<name>_init(struct*)`-style defaulting function so C callers
   never hand-fill defaults, plus a leading `uint32_t struct_size`
   version-check field (the libwebp trick) — decide and justify.
6. **Feature probe result**: by-value extern struct mirroring
   `features.Summary`'s scalar fields (kind, format, width, height,
   has_alpha, is_animation, metadata presence bits, chunk/frame counts) —
   no pointers, nothing to free.
7. **Artifact & build**: `build.zig` gains a `capi` module rooted at a new
   `src/capi.zig` (Tier-2 internal), built into the existing static lib plus
   an optional shared lib step; header installed via `b.installFile`. State
   the acceptance gate for the future implementation plan: C smoke tests
   (compile small `.c` programs against the header, link the static lib;
   decode a corpus file into a caller buffer and byte-compare against
   `decodeStatic`; encode from a const image view, validate the returned
   WebP bytes, and free via `zwebp_free`) wired into `zig build check` or
   a dedicated step.
8. **ABI stability policy**: the C ABI versions with the library (no
   independent soname games pre-1.0); the header carries
   `ZWEBP_ABI_VERSION`; appended-only enums/structs (via struct_size).
9. **Explicit non-goals for v1**: no callbacks, no streaming, no
   incremental decode (mirrors the library), no allocator injection, no
   thread-pool knobs, animation encode (the option structs are large and
   still moving — v2).
10. **Open questions genuinely left open** (list them honestly rather than
    forcing a decision): whether WASM freestanding exports share this exact
    surface or a slimmed one; whether `parseWebP`'s chunk-location detail is
    worth exporting at all vs. just the probe.

Also update `PLAN.MD:24-32`: reword the non-goal line to reference the new
section ("A C ABI before the Zig API stabilizes — designed in step 13,
implementation post-1.0"), keeping the sequencing intent.

**Verify**: `grep -n "C ABI" PLAN.MD` → the new section header and the
updated non-goal line both appear; every numbered item above has a
corresponding decision in the text.

### Step 3: Cross-check against the live API and close out

Re-read the section once against `src/root.zig` checking there is no
function it claims to mirror that doesn't exist and no Tier-1 entry point it
silently omits (omitting is fine — silently is not; the v1/v2/non-goal
lists must partition the Tier-1 surface completely).
Update `plans/README.md` (status row) and note in the row that the follow-up
implementation plan should be authored AFTER 1.0 tags, per the design's own
sequencing.

**Verify**: `zig build ci` → exit 0 (markdown-only change; this catches an
accidental stray edit).

## Test plan

None — documentation deliverable. The design itself specifies the future
implementation plan's test gates (C decode + encode smoke tests,
header-drift check).

## Done criteria

Machine-checkable. ALL must hold:

- [x] `PLAN.MD` contains the new C-ABI design section answering all ten
      numbered items (each present as a heading or bolded lead-in).
- [x] The `PLAN.MD:32` non-goal line now references the design section.
- [x] No `.zig`, `build.zig`, or CI files modified (`git status`).
- [x] `zig build ci` exits 0.
- [x] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 012 has not landed (`grep -c "pub fn decodeStaticInto" src/root.zig`
  = 0): the decode-side memory model (decision 4) rests on it. Report and
  wait rather than designing against a hypothetical signature.
- Plan 013's stability tiers are absent from `src/root.zig`'s doc comment:
  decision 1 needs the Tier-1 list. Same response.
- You find a Tier-1 API whose shape cannot be honestly mirrored in C at all
  (not merely awkwardly): record it as a design finding and stop — it may
  mean the Zig API needs a pre-1.0 change, which is a maintainer decision.

## Maintenance notes

- The follow-up implementation plan (post-1.0) executes this design; if the
  Zig API changes between this design landing and 1.0, whoever changes it
  must sweep the design section (add that to review checklists for
  root.zig-touching PRs).
- Plan 014's WASM follow-ups should consume decision 10's answer about the
  freestanding export surface rather than inventing a third surface.
