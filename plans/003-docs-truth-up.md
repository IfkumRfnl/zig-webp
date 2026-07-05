# Plan 003: Bring README, PLAN.MD, and options docs back in line with the code

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1aa7670..HEAD -- README.MD PLAN.MD src/options.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (PROGRESS.MD changing is fine —
> read its latest state instead of the excerpts here.)

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `1aa7670`, 2026-06-13

## Why this matters

AGENTS.md (line 9) requires README/PLAN/PROGRESS to track behavior, and the
repo's own agents rely on them as ground truth for every slice. Three drifts
exist today: (1) README's status line still says "VP8L decoder groundwork in
progress" although VP8L still decode, alpha decode, and pre-loop-filter VP8
reconstruction are all complete and byte-exact against dwebp on the full
corpus; (2) `DecoderOptions.decode_animation` and
`DecoderOptions.preserve_metadata` (and all of `EncoderOptions`) are accepted
but ignored by every code path — an API that silently swallows options
misleads early adopters; (3) PLAN.MD's "Proposed Module Layout" names files
that don't exist (`src/pixel.zig`, `src/color.zig`, `src/vp8/frame.zig`,
`src/vp8/loop_filter.zig`, `src/vp8l/lz77.zig`, `src/testing/metrics.zig`)
while omitting files that do. Each is minutes to fix; together they decide
whether a newcomer (human or agent) can trust the docs.

## Current state

- `README.MD:5-18` — the Status paragraph. Begins:
  "Status: VP8L decoder groundwork in progress." and ends
  "…lossy decode and animation are not available yet."
- `PROGRESS.MD` — authoritative status. Key facts at planning time (re-read
  the live file; it moves fast): steps 0-4 complete; step 5 in progress with
  full-frame pre-loop-filter VP8 reconstruction landed and byte-exact against
  `dwebp -nofilter -yuv` on all 88 lossy corpus files plus 43 generated
  files (PROGRESS.MD:185); loop filtering, `compare-yuv`, YUV-to-RGB, and
  alpha-over-lossy composition not started (PROGRESS.MD:122-123).
- `src/options.zig` (19 lines, whole relevant excerpt):

```zig
// src/options.zig:7-19
pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    preserve_metadata: bool = true,
    decode_animation: bool = true,
};

pub const EncoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    format: features.FormatKind = .lossless,
    quality: u8 = 75,
    preserve_metadata: bool = true,
};
```

  Verified at planning time: `grep -rn "decode_animation\|preserve_metadata" src/ tools/`
  matches only `src/options.zig` — no reader anywhere. `decode.decodeStatic`
  returns `error.UnsupportedAnimationDecode` for animations regardless of
  `decode_animation` (`src/decode.zig:27`). `EncoderOptions` is referenced
  by no entry point (`mux.encodeStatic` takes `mux.Options`).
- `PLAN.MD:123-156` — "Proposed Module Layout" code block listing the
  planned files, including six that do not exist on disk and missing
  existing ones (`src/decode.zig`, `src/errors.zig`, `src/limits.zig`,
  `src/options.zig`, `src/vp8/frame_header.zig`, `src/vp8/modes.zig`,
  `src/vp8/tokens.zig`, `src/vp8/token_probs.zig`, `src/vp8l/*` actuals,
  `src/testing/fuzz.zig`).
- Repo writing conventions: prose wrapped near 80 columns; factual,
  unhyped tone; capability claims always paired with their oracle scope
  (corpus, file counts, byte-exactness) — match PROGRESS.MD's style.

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|--------------------------|---------------------|
| Format (also formats doc comments in .zig) | `zig fmt .` | exit 0 |
| Tests | `zig build test` | exit 0 |
| Layout ground truth | `find src tools -name "*.zig" \| sort` | the list the PLAN section must match |

## Scope

**In scope** (the only files you should modify):
- `README.MD` (Status paragraph; add a short Scope/Non-goals pointer)
- `PLAN.MD` (Proposed Module Layout section only)
- `src/options.zig` (doc comments only — no field changes)

**Out of scope** (do NOT touch):
- `PROGRESS.MD` — it is correct; it is your source, not your target.
- Removing or renaming the unused option fields — they are forward-looking
  API per PLAN.MD steps 6-8; this plan documents, it does not redesign.
- `AGENTS.md`, `src/root.zig` (root doc comments are plan 005).

## Git workflow

- Branch: `claude/docs-truth-up`
- Single imperative commit, e.g. `Update README status, PLAN module layout, and option doc comments`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Rewrite the README Status paragraph

Replace the paragraph at `README.MD:5-18` ("Status: …are not available
yet.") with an accurate summary derived from the **live** PROGRESS.MD.
Target shape (adjust to live status before writing):

> Status: static lossless (VP8L) decode and ALPH alpha-plane decode are
> complete and match `dwebp` byte-for-byte on the local
> `libwebp-test-data` corpus. The VP8 lossy decoder has reached full-frame
> reconstruction, byte-exact against `dwebp -nofilter -yuv` for all 88
> lossy corpus files; loop filtering, YUV-to-RGB conversion, alpha
> composition over lossy color, and animation decode are not available
> yet. The library also exposes bounded option/limit types, image buffers,
> metadata, feature probing, RIFF/WebP demux, static mux, and the VP8/VP8L
> bitstream infrastructure.

Then add, after the Goals section, a two-sentence pointer:

> Scope boundaries (no streaming decode, no inter-frame VP8, no ICC
> application, no C ABI yet) and the full roadmap with acceptance gates
> live in `PLAN.MD`; current status and dated oracle results live in
> `PROGRESS.MD`.

**Verify**: `grep -c "groundwork in progress" README.MD` → `0`.

### Step 2: Sync PLAN.MD's module layout

Replace the file list inside the "## Proposed Module Layout" code block
(`PLAN.MD:125-156`) with the actual tree from
`find src -name "*.zig" | sort`, and append the genuinely *planned* files
with a trailing comment marker so intent stays visible, e.g.:

```text
src/vp8/loop_filter.zig    (planned: step 5)
src/vp8/encoder.zig        (planned: step 8)
src/vp8l/encoder.zig       (planned: step 7)
src/color.zig              (planned: step 5 YUV-to-RGB)
src/testing/metrics.zig    (planned: step 10)
```

Keep the surrounding prose; update the sentence after the block only if it
references a file that no longer exists.

**Verify**: every non-"(planned…)" path in the block exists:
`for f in $(grep -o 'src/[a-z0-9_/]*\.zig' PLAN.MD); do test -f "$f" || echo "MISSING $f"; done`
→ prints only the planned-marker files you annotated, or nothing if the
grep excludes annotated lines. Simplest expected result: no `MISSING` line
for any unannotated path.

### Step 3: Document the not-yet-honored option fields

In `src/options.zig`, add doc comments (no field/value changes):

```zig
pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    /// Not yet honored: metadata chunks are currently always exposed via
    /// demux results. Reserved for the step 6 extended-decode work.
    preserve_metadata: bool = true,
    /// Not yet honored: animated inputs currently fail static decode with
    /// `error.UnsupportedAnimationDecode`. Reserved for step 6.
    decode_animation: bool = true,
};

/// Forward-looking surface for the planned encoders (PLAN.MD steps 7-8).
/// No encode path consumes these options yet; `mux.encodeStatic` takes
/// `mux.Options`.
pub const EncoderOptions = struct {
```

**Verify**: `zig build test` → exit 0 and `zig fmt --check .` → exit 0.

## Test plan

No new tests — docs and doc comments only. `zig build test` guards that the
doc comments didn't break compilation.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "groundwork in progress" README.MD` returns 0
- [ ] `grep -c "PLAN.MD" README.MD` returns >= 1 (scope pointer present)
- [ ] Every unannotated `src/*.zig` path in PLAN.MD's layout block exists on disk
- [ ] `grep -c "Not yet honored" src/options.zig` returns 2
- [ ] `zig build test` exits 0; `zig fmt --check .` exits 0
- [ ] `git status --porcelain` shows only the three in-scope files and `plans/README.md` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- PROGRESS.MD's live "Current Position" contradicts the capability summary
  in Step 1's target text in any direction (e.g. the loop filter has since
  landed) — rewrite from the live file, and if you cannot reconcile the
  two, stop.
- You find a code reader of `decode_animation` or `preserve_metadata` that
  grep missed — the "not yet honored" comments would then be wrong; report
  the reader's location instead of writing them.
- The README has been restructured since planning (drift check fires).

## Maintenance notes

- The repo's own rule (AGENTS.md line 9) makes every behavior-changing PR
  responsible for keeping these files current — this plan resets the
  baseline; reviewers should hold the line per-slice afterwards.
- When step 6 wires `decode_animation`/`preserve_metadata`, delete the
  "Not yet honored" comments in the same change (grep for them).
- Deferred deliberately: prose docs for the public API surface (plan 005)
  and any restructuring of README sections.
