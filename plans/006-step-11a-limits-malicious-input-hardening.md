# Plan 006: Step 11a — Limits & malicious-input hardening (audit + end-to-end contract matrix)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise, and do not patch library code to make a test
> pass. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat e824d0c..HEAD -- src/limits.zig src/demux.zig src/decode.zig src/animation_decode.zig src/encode.zig src/animation_encode.zig src/animation_optimize.zig src/options.zig src/root.zig src/testing.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch in a signature or a line you depend on, treat it as a STOP
> condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (test-only; a failing test signals a real bug to report, not patch)
- **Depends on**: none (plan 002 already added allocation-failure injection; this is the limits/malicious-input half of step 11)
- **Category**: tests / hardening
- **Planned at**: commit `e824d0c` (origin/main), 2026-06-30
- **Roadmap**: PLAN.MD step 11 ("Robustness Hardening"), slice 11a

## Why this matters

PLAN.MD step 11 promises decode/encode paths "suitable for untrusted input":
malicious inputs must "fail with errors, not panics or unbounded allocation",
and every loop must stay "bounded by parsed dimensions, chunk sizes, or
explicit limits". The enforcement machinery for this already exists —
`src/limits.zig` defines `ResourceLimits` and it is threaded into every public
entry point (see "Current state" for the exact call sites). What is **missing**
is a single, auditable, release-grade test that proves the contract holds
**end to end through the public API**: today the limit checks are exercised
mostly by per-module unit tests that call internal functions, not by tests that
drive `decodeStatic` / `decodeAnimation` / `parseWebP` / the encoders with a
caller-tightened `ResourceLimits` and assert the exact error.

This slice delivers that contract test as one consolidated module, plus a
committed audit (a coverage table mapping each PLAN-named adversarial input to
its existing test, and a bounded-loop checklist). It is deliberately test-only:
if a test reveals that an entry point does *not* honor a limit, that is a real
finding to **report** (a follow-up fixes the library), not something to patch
under this plan.

**This is NOT a rewrite.** Do not change `src/limits.zig` or any enforcement
code. Do not add new limit knobs. The job is to *prove and document* what is
already enforced and to surface any gap.

## Current state

`ResourceLimits` (`src/limits.zig:8`) and its validators:

- `validateInputBytes(len)` → `error.InputTooLarge`
- `validateAllocationBytes(len)` → `error.AllocationLimitExceeded`
- `validateChunkCount(count)` → `error.TooManyChunks`
- `validateFrameCount(count)` → `error.FrameCountTooLarge`
- `validateCanvas(w, h, animated)` → `error.InvalidCanvasSize` (zero dim),
  `error.CanvasTooLarge` (pixels over `output_pixels_max` for stills /
  `animation_canvas_pixels_max` for animation)
- `pixelCount(w, h)` → `error.DimensionsOverflow` when `w*h > maxInt(u32)`

`ResourceLimits` lives inside the public options structs:
`DecoderOptions.limits` (`src/options.zig:9`), `EncoderOptions.limits`
(`src/options.zig:23`), `demux.Options.limits` (`src/demux.zig:17`),
`animation_encode.Options.limits` (`src/animation_encode.zig:80`),
`animation_optimize.Options.limits`.

**Enforcement is already wired into every public entry point** (verified at
planning time — these are the call sites your tests will trip):

| Public entry point | Source | Limits enforced (file:line) |
|---|---|---|
| `decode.decodeStatic` | `src/decode.zig:21` | calls `demux.parse` with `decode_options.limits`; then `decodeImage` reserves against `allocation_bytes_max` |
| `animation_decode.decodeAnimationAlloc` | `src/animation_decode.zig:300` | `validateAllocationBytes` (`:317`); per-frame decode threads `limits` |
| `animation_decode.Decoder.init` | `src/animation_decode.zig:89` | `demux.parse` w/ limits (`:100`) + `validateAllocationBytes` (`:107`) |
| `demux.parse` | `src/demux.zig:76` | `validateInputBytes` (`:81`), `validateChunkCount` (`:99`), `validateCanvas` (`:264` extended, `:400` simple), `validateFrameCount` (`:371`,`:463`), slice-allocation checks (`:120`–`:128`,`:164`) |
| `demux.parseFeatures` | `src/demux.zig:143` | same as `parse` (it calls `parse`) |
| `encode.encodeStaticLossless` | `src/encode.zig:37` | `validateCanvas(..., false)` (`:48`) |
| `encode.encodeStaticLossy` | `src/encode.zig:107` | `validateCanvas(..., false)` (`:124`) |
| `mux.encodeAnimation` | `src/mux.zig:256` | `validateCanvas(..., true)` (`:263`), `validateFrameCount` (`:269`) |
| `animation_encode.encodeAnimationFromBuffers` | `src/animation_encode.zig:98` | `validateCanvas(..., true)` (`:107`), `validateFrameCount` (`:115`) |
| `animation_optimize.encodeAnimationMinimized` | `src/animation_optimize.zig:152` | `validateCanvas(..., true)` (`:160`), `validateFrameCount` (`:162`) |

**Order of validation matters** (this is what makes the matrix a real test, not
a tautology): in `demux.parse`, `validateInputBytes` runs first (`:81`), then
per-chunk `validateChunkCount`, then `validateCanvas` when the canvas is known.
So a test that wants to isolate, say, `output_pixels_max` must set **only** that
knob tight and leave `input_bytes_max` / `allocation_bytes_max` at their
defaults — otherwise an earlier check fires and the assertion is meaningless.

Existing module-level negative tests already cover the bitstream-structure
adversarial inputs (you will *reference* these in the audit table, not
re-create them):

- Invalid LZ77 copy distance → `error.InvalidVP8LImageData`, enforced at
  `src/vp8l/image_data.zig:202`; tested at `src/vp8l/image_data.zig:725`
  ("rejects copy distances before the decoded prefix").
- Invalid Huffman tree → tested at `src/vp8l/huffman.zig:542`
  ("rejects invalid trees").
- Too many / duplicate VP8L transforms → `transform_count_max` at
  `src/vp8l/transform.zig:70`; duplicate-kind rejection tested at
  `src/vp8l/transform.zig:278`; block-bits cap at
  `src/vp8l/inverse_transform.zig:411`.
- Animation frame count → tested at `src/demux.zig` ("enforces configured
  frame count limits before parsing frame payload", ~`:1126`).
- Dimension overflow / zero canvas → tested at `src/limits.zig:60` and
  `src/image.zig:95`.

Repo conventions you must follow:

- Tests are inline `test "..."` blocks. Cross-cutting test harnesses that span
  several modules live under `src/testing/` (e.g. `src/testing/corpus.zig`,
  `src/testing/encode_corpus.zig`) and are pulled into the test build from
  `src/root.zig` via a `const <name>_tests = @import("testing/<name>.zig");`
  line plus a `_ = <name>_tests;` in the `test "root public declarations
  compile"` block (`src/root.zig:411`–`416`), and re-exported from
  `src/testing.zig`.
- There is no per-file test runner: always build with `zig build test`.
- New tests must NOT read `testdata/` — they build their inputs in-process via
  the public encoders, so they run anywhere.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Drift check | see top of plan | no in-scope file changed, or excerpts still match |
| Format | `zig fmt .` | exit 0 |
| Format check | `zig fmt --check .` | exit 0 |
| Tests | `zig build test` | exit 0, no output |
| Count new tests | `grep -c 'test "' src/testing/hardening.zig` | ≥ 19 |

## Scope

**In scope** (the only files you create/modify):

- `src/testing/hardening.zig` — **new file**, the consolidated contract matrix
  + committed audit tables. This is the deliverable.
- `src/testing.zig` — add one `pub const hardening = ...` re-export line.
- `src/root.zig` — add one import line + one `_ =` line (test registration).
- `plans/README.md` — add/refresh this plan's status row.

**Out of scope** (do NOT touch):

- `src/limits.zig` and every enforcement call site. If a test fails, the bug is
  in the library and the fix is a *separate* plan — STOP and report.
- Bitstream-structure unit tests (invalid distance/Huffman/transform). You
  *reference* them in the audit table; you do not move or rewrite them, and you
  do not hand-author new corrupt VP8/VP8L bitstreams (intricate, already
  unit-covered; an end-to-end propagation test for them is deferred to 11c
  fuzzing).
- Allocation-failure injection (`checkAllAllocationFailures`) — that is plan
  002 / slice 11b, already covered for the existing entry points.

## Git workflow

- Branch off `main`: `git switch main && git pull && git switch -c claude/step-11a-limits-hardening`
  (branch name follows the repo's `claude/` convention).
- Single imperative commit, e.g.
  `Add step-11a limits & malicious-input contract matrix`.
- End the commit message with the trailer the repo requires (see AGENTS.md).
- Do NOT push or open a PR unless the operator instructs it.

## Steps

### Step 1: Create `src/testing/hardening.zig` with the module header and audit tables

Create the file with the imports, a doc-comment header, and the two **committed
audit tables**. The tables are part of the deliverable — they make the audit
reviewable and greppable. Fill the "Existing test" column by confirming each
cited test exists at the cited location during the drift check; if a citation is
stale, that is a STOP condition (report the drift, do not guess a new line).

```zig
//! Step 11a — limits & malicious-input contract matrix.
//!
//! End-to-end proof that every public entry point honors a caller-supplied
//! `ResourceLimits`. Each test builds a VALID input in-process via the public
//! encoders (no `testdata/` dependency), then tightens exactly ONE limit knob
//! and asserts the exact rejection error. Building uses default limits; only
//! the decode/parse/encode call under test gets the tight limit.
//!
//! This module is test-only and registered from `root.zig`. It deliberately
//! changes no enforcement code: a failing test here is a library bug to report,
//! not to patch (see plans/006).
//!
//! ── Adversarial-input coverage audit (PLAN.MD step 11) ───────────────────
//! | Adversarial input        | Enforced at                      | Existing test                         | Covered here |
//! |--------------------------|----------------------------------|---------------------------------------|--------------|
//! | Huge dimensions (overflow)| limits.pixelCount (DimensionsOverflow) | limits.zig:60, image.zig:95     | matrix (CanvasTooLarge) |
//! | Oversized / over-count chunks | demux readChunkLocation + validateChunkCount | demux "enforces chunk count" | matrix (TooManyChunks, AllocationLimitExceeded) |
//! | Invalid LZ77 distances   | vp8l/image_data.zig:202          | vp8l/image_data.zig:725               | unit (referenced) |
//! | Invalid Huffman trees    | vp8l/huffman buildTable          | vp8l/huffman.zig:542                  | unit (referenced) |
//! | Recursive/duplicate VP8L transforms | vp8l/transform.zig:70, :278 | vp8l/transform.zig:278, inverse_transform.zig:411 | unit (referenced) |
//! | Animation frame counts   | demux:371,:463; encoders         | demux "enforces frame count"          | matrix (FrameCountTooLarge) |
//! | Input too large          | demux.parse:81                   | (this module)                         | matrix (InputTooLarge) |
//!
//! ── Bounded-loop audit (confirmed by reading at planning commit) ─────────
//! Each parsing/decoding loop is bounded by a parsed-and-validated quantity.
//! Re-confirm each during Step 5; an unbounded loop is a STOP condition.
//! | Loop                          | Site                    | Bound |
//! |-------------------------------|-------------------------|-------|
//! | demux top-level chunk walk    | demux.zig:97            | file_end + validateChunkCount |
//! | demux animation frame parse   | demux.zig (frame loop)  | file_end + validateFrameCount |
//! | VP8L image-data decode        | vp8l/image_data.zig     | pixel_count |
//! | VP8 macroblock reconstruction | vp8/decoder.zig         | mb_w * mb_h |
//! | alpha plane fill              | alpha.zig               | pixel_count |
//! | YUV->RGB upsample             | color.zig               | width * height |

const std = @import("std");

const animation = @import("../animation.zig");
const animation_decode = @import("../animation_decode.zig");
const animation_encode = @import("../animation_encode.zig");
const animation_optimize = @import("../animation_optimize.zig");
const decode = @import("../decode.zig");
const demux = @import("../demux.zig");
const encode = @import("../encode.zig");
const features = @import("../features.zig");
const image = @import("../image.zig");
const limits = @import("../limits.zig");

const testing = std.testing;
```

> Note the `../` import prefix: this file is under `src/testing/`, the codec
> modules are under `src/`. Match the prefix used by `src/testing/corpus.zig`
> (read it first to confirm the exact prefix this repo uses; copy that).

### Step 2: Add the in-process input builders

These build valid files entirely through the public encoders, so the tests need
no corpus. Add them after the imports. They use small canvases; the matrix sets
limits relative to the known pixel counts.

```zig
/// Canvas used by the still builders: 8x8 = 64 px.
const still_w: u32 = 8;
const still_h: u32 = 8;
const still_px: u64 = still_w * still_h; // 64

fn fillGradient(pixels: []u8, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const base = (y * w + x) * 4;
            pixels[base + 0] = @intCast((x * 32) & 0xff);
            pixels[base + 1] = @intCast((y * 32) & 0xff);
            pixels[base + 2] = @intCast(((x + y) * 16) & 0xff);
            pixels[base + 3] = 255;
        }
    }
}

/// Encodes an 8x8 lossless still through the public encoder with default
/// limits. Caller frees the returned bytes.
fn buildLosslessStill(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };
    return encode.encodeStaticLossless(gpa, buffer, .{ .format = .lossless });
}

/// Encodes an 8x8 lossy still through the public encoder with default limits.
fn buildLossyStill(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };
    return encode.encodeStaticLossy(gpa, buffer, .{ .format = .lossy, .quality = 75 });
}
```

For the animation builders, read `animation_encode.FrameSource` /
`animation_encode.Options` (`src/animation_encode.zig:48`,`:69`) and
`animation_optimize.FrameInput` / `animation_optimize.Options` to confirm the
field names below before relying on them. Build a **3-frame, 8x8 full-canvas**
animation so the frame-count tests have ≥ 2 frames to trip a limit of 1:

```zig
const anim_w: u32 = 8;
const anim_h: u32 = 8;
const anim_px: u64 = anim_w * anim_h; // 64
const anim_frames: u32 = 3;

/// Three full-canvas lossless frames muxed via the public buffer encoder.
fn buildAnimationFile(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_encode.FrameSource{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame, frame };
    return animation_encode.encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(anim_w, anim_h),
    });
}
```

(The same 3-frame shape, expressed as `animation_optimize.FrameInput`, drives
the `encodeAnimationMinimized` tests in Step 4.)

### Step 3: Implement the decode/parse contract matrix

Add one `test` per row below. Each builds the input, then calls the entry point
with a `DecoderOptions` / `demux.Options` that sets **only** the listed knob and
asserts the **exact** error with `testing.expectError`. Free every successfully
returned value; on the error path there is nothing to free.

Worked example (implement the rest in this exact shape):

```zig
test "decodeStatic honors input_bytes_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.InputTooLarge, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .input_bytes_max = 8 } },
    ));
}
```

Decode/parse matrix to implement (knob → expected error). Set ONLY the named
knob; leave the rest default:

| Test | Entry point | Input builder | Knob (tight value) | Expected error |
|------|-------------|---------------|--------------------|----------------|
| 1 | `decode.decodeStatic` | `buildLosslessStill` | `input_bytes_max = 8` | `InputTooLarge` |
| 2 | `decode.decodeStatic` | `buildLosslessStill` | `output_pixels_max = still_px - 1` | `CanvasTooLarge` |
| 3 | `decode.decodeStatic` | `buildLosslessStill` | `allocation_bytes_max = 16` | `AllocationLimitExceeded` |
| 4 | `decode.decodeStatic` | `buildLossyStill` | `output_pixels_max = still_px - 1` | `CanvasTooLarge` |
| 5 | `demux.parse` | `buildLosslessStill` | `input_bytes_max = 8` | `InputTooLarge` |
| 6 | `demux.parse` | `buildAnimationFile` | `chunk_count_max = 1` | `TooManyChunks` |
| 7 | `demux.parse` | `buildAnimationFile` | `frame_count_max = 1` | `FrameCountTooLarge` |
| 8 | `demux.parse` | `buildAnimationFile` | `allocation_bytes_max = 16` | `AllocationLimitExceeded` |
| 9 | `demux.parseFeatures` | `buildLosslessStill` | `input_bytes_max = 8` | `InputTooLarge` |
| 10 | `animation_decode.decodeAnimationAlloc` | `buildAnimationFile` | `input_bytes_max = 8` | `InputTooLarge` |
| 11 | `animation_decode.decodeAnimationAlloc` | `buildAnimationFile` | `animation_canvas_pixels_max = anim_px - 1` | `CanvasTooLarge` |
| 12 | `animation_decode.decodeAnimationAlloc` | `buildAnimationFile` | `frame_count_max = 1` | `FrameCountTooLarge` |

Notes:
- `demux.parse` returns a `Result` with `deinit()`; `decodeStatic` returns an
  `OwnedBuffer` with `deinit()`; `decodeAnimationAlloc` returns an
  `OwnedAnimation` with `deinit()`; `parseFeatures` returns a `Summary` by value
  (nothing to free). On the asserted error paths none of these are produced, so
  `expectError` alone is correct — no defer needed inside the error tests.
- Test 6 uses the animation file because it has several top-level chunks
  (`VP8X`, `ANIM`, `ANMF`, …); `chunk_count_max = 1` trips on the 2nd chunk.
- Test 3 / Test 8: any allocation site over the tiny budget yields
  `AllocationLimitExceeded`; assert that error regardless of which site fires.

### Step 4: Implement the encode contract matrix

Same shape, for the encoders. The encoders validate the canvas/frame count
**before** allocating, so a tight knob fails fast.

| Test | Entry point | Input | Knob (tight value) | Expected error |
|------|-------------|-------|--------------------|----------------|
| 13 | `encode.encodeStaticLossless` | 8x8 buffer | `output_pixels_max = still_px - 1` | `CanvasTooLarge` |
| 14 | `encode.encodeStaticLossy` | 8x8 buffer | `output_pixels_max = still_px - 1` | `CanvasTooLarge` |
| 15 | `animation_encode.encodeAnimationFromBuffers` | 3 frames | `animation_canvas_pixels_max = anim_px - 1` | `CanvasTooLarge` |
| 16 | `animation_encode.encodeAnimationFromBuffers` | 3 frames | `frame_count_max = 1` | `FrameCountTooLarge` |
| 17 | `animation_optimize.encodeAnimationMinimized` | 3 frames | `animation_canvas_pixels_max = anim_px - 1` | `CanvasTooLarge` |
| 18 | `animation_optimize.encodeAnimationMinimized` | 3 frames | `frame_count_max = 1` | `FrameCountTooLarge` |

For 13/14, pass the tight knob through `EncoderOptions.limits`:
`.{ .format = .lossless, .limits = .{ .output_pixels_max = still_px - 1 } }`.
For 15–18, set the knob on the animation `Options.limits` and build the frame
list inline (reuse the 8x8 gradient buffer; for 17/18 wrap each in a
`animation_optimize.FrameInput`).

> Capability checkpoint: 18 tests total (≥ 19 with the worked example counted —
> the `grep -c 'test "'` done-criterion is ≥ 19, so add at least one extra,
> e.g. a `decodeStatic` `chunk_count_max` test on the animation file decoded via
> `decodeAnimationAlloc`, or split a combined assertion). Getting each
> *expected error* right is the point — do not weaken an assertion to
> `expectError(anyerror, ...)`; if the real error differs, that is a STOP.

### Step 5: Complete the bounded-loop audit

Re-read each loop in the "Bounded-loop audit" table in the module header and
confirm the loop counter cannot exceed the cited bound for adversarial input
(the count is parsed then validated *before* the loop, or the loop condition is
the validated bound). For each row, leave the table entry if confirmed. If any
loop can run past its bound on crafted input (e.g. a length read from the
stream used directly as a loop count without a prior check), do **not** edit
code — record it and STOP (it is a real bug for a follow-up plan).

This audit is a re-confirmation: the 2026-06-13 improve audit already concluded
the parsers are bounded (`plans/README.md`, "Findings considered and
rejected"). You are verifying that still holds at `e824d0c` for the loops above.

### Step 6: Register the module for the test build

1. In `src/testing.zig`, add (keeping alphabetical order with the existing
   re-exports):
   ```zig
   pub const hardening = @import("testing/hardening.zig");
   ```
2. In `src/root.zig`, alongside the other `*_tests` imports (near `:17`):
   ```zig
   const hardening_tests = @import("testing/hardening.zig");
   ```
   and inside `test "root public declarations compile"` (near `:412`), add:
   ```zig
   _ = hardening_tests;
   ```

**Verify**: `zig build test` → exit 0 (the new tests now run). If a test fails
with the *wrong* error or a panic, see STOP conditions.

### Step 7: Format pass

**Verify**: `zig fmt --check .` → exit 0.

## Test plan

The new tests ARE the deliverable. After Step 7:

- `src/testing/hardening.zig` exists, is registered, and contributes ≥ 19
  passing tests covering the decode/parse and encode matrices above.
- The module header carries the two committed audit tables (adversarial-input
  coverage, bounded-loop), each row confirmed.
- `zig build test` exits 0; `zig fmt --check .` exits 0.
- No test reads `testdata/`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `test -f src/testing/hardening.zig` (file exists)
- [ ] `grep -c 'test "' src/testing/hardening.zig` returns ≥ 19
- [ ] `grep -n "hardening_tests" src/root.zig` shows both the import and the `_ =` line
- [ ] `grep -n "pub const hardening" src/testing.zig` shows the re-export
- [ ] `grep -c "expectError" src/testing/hardening.zig` returns ≥ 18
- [ ] `grep -n "Bounded-loop audit" src/testing/hardening.zig` shows the audit section
- [ ] `grep -rn "testdata" src/testing/hardening.zig` returns nothing
- [ ] `zig build test` exits 0
- [ ] `zig fmt --check .` exits 0
- [ ] `git status --porcelain` shows only: `src/testing/hardening.zig` (new),
      `src/testing.zig`, `src/root.zig`, `plans/README.md`
- [ ] `git diff --stat` shows NO change to `src/limits.zig` or any enforcement
      call site
- [ ] `plans/README.md` status row updated to DONE (with the verifying commit)

## STOP conditions

Stop and report back (do not improvise, do not patch library code) if:

- **A matrix test does not produce the expected error** — it returns a
  *different* error, returns success, or panics/`unreachable`/integer-overflow
  traps. This means an entry point does not honor that limit (or honors it with
  the wrong error): a real step-11 finding. Capture the entry point, knob,
  expected vs. actual, and the full failure output; mark this plan BLOCKED in
  `plans/README.md` with a one-line pointer; stop. The fix is a separate plan.
- **A bounded-loop audit row cannot be confirmed** — a loop can exceed its
  bound on crafted input. Record the site and the unbounded path; stop.
- **An audit-table citation is stale** (the referenced test/line moved or is
  gone) — drift; report which citation and where it actually is now (or that it
  is gone), and stop rather than silently "fixing" the table to a guess.
- **A public entry-point signature differs** from "Current state" (e.g.
  `decodeAnimationAlloc` or `encodeAnimationFromBuffers` changed parameters) —
  drift; reconcile against the live code and report before continuing.
- `error.SwallowedOutOfMemoryError`-style behavior: an entry point catches a
  limit error internally instead of propagating it — report the location.

## Maintenance notes

- Every NEW public decode/encode entry point should land with its row added to
  this contract matrix in the same change — the same rule the repo applies to
  fuzz targets and allocation-failure probes (PLAN.MD Cross-Cutting Practices).
- This slice (11a) intentionally does **not** add end-to-end propagation tests
  for crafted invalid *bitstreams* (bad LZ77 distance, malformed Huffman tree,
  excess transforms): those are unit-covered today and are better exercised
  end-to-end by the 11c fuzzing slice, which mutates valid seeds through the
  public decoders under a time budget. Keep them in the audit table so the
  coverage stays visible.
- Follow-ups in step 11: 11b extends allocation-failure injection to the
  remaining entry points (notably `animation_decode`); 11c grows fuzz corpora
  and adds encoder round-trip fuzz + a CI fuzz-time budget (currently blocked by
  the upstream Zig 0.16.0 `test_runner.zig` fuzz-instrumentation bug recorded in
  PROGRESS.MD).
```
