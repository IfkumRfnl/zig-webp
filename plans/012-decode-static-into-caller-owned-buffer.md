# Plan 012: Add `decodeStaticInto` — static decode into a caller-owned pixel buffer

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- src/decode.zig src/image.zig src/root.zig src/options.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches the public decode path; the byte-exact corpus gate must not move)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

`PLAN.MD`'s step 12 (public API and release criteria) commits to "static
decode to caller-owned buffers" as a stabilized API, and `AGENTS.md` names
"deterministic allocation" as one of the library's chosen competitive
dimensions — but no such entry point exists: `decodeStatic` always returns a
library-allocated `OwnedBuffer`. Callers who manage their own pixel memory
(frame pools, arena-per-frame decoders, FFI embeddings, WASM hosts) currently
cannot use this library without an extra copy and an imposed lifetime. This
plan adds `decodeStaticInto`, the caller-owned-buffer analogue of
`decodeStatic`, with the same validation and limits behavior. It is also the
foundation the future C-ABI layer (plan 015) will export.

## Current state

- `src/decode.zig` — the public static decode composition. `decodeStatic`
  (lines 22–43) demuxes, rejects animations, and calls the shared
  `decodeImage` primitive, which returns an `image.OwnedBuffer`:

  ```zig
  // src/decode.zig:22
  pub fn decodeStatic(
      gpa: std.mem.Allocator,
      bytes: []const u8,
      decode_options: options.DecoderOptions,
  ) errors.Error!image.OwnedBuffer {
      var parsed = try demux.parse(gpa, bytes, .{
          .limits = decode_options.limits,
      });
      defer parsed.deinit();

      if (parsed.features.is_animation) return error.UnsupportedAnimationDecode;

      const format = parsed.features.format orelse return error.MissingImageData;
      const image_chunk = parsed.features.image_data orelse return error.MissingImageData;

      return decodeImage(gpa, .{
          .format = format,
          .bitstream = image_chunk.payload(bytes),
          .alpha = if (parsed.features.alpha) |location| location.payload(bytes) else null,
          .dimensions = parsed.features.canvas,
      }, decode_options);
  }
  ```

  `decodeImage` (lines 67–76) dispatches to `decodeLossless`/`decodeLossy`,
  each of which allocates a packed output buffer (`out`) from `gpa`, budgeted
  against `decode_options.limits.allocation_bytes_max` via `reserveElements`,
  and returns it wrapped in `image.OwnedBuffer` with `stride == rowBytes`.

- `src/image.zig` — `Buffer` (lines 43–70) is the caller-visible pixel-buffer
  type: `pixels: []u8`, `dimensions`, `stride: u32`, `format: PixelFormat`.
  `Buffer.validate()` already checks dimensions validity, `stride >= rowBytes`,
  and that `pixels.len` covers `stride * (height-1) + rowBytes`. `OwnedBuffer`
  (lines 72–79) is `gpa` + `Buffer` with `deinit`.

- `src/options.zig` — `DecoderOptions` (lines 8–19): `limits`,
  `output_format: image.PixelFormat = .rgba`, plus two documented-reserved
  flags.

- `src/root.zig` — public surface. `decodeStatic` is re-exported at lines
  383–389. Convention: every public function in root.zig is a thin forwarding
  wrapper with a substantive `///` doc comment describing ownership, limits,
  and error behavior (see `decodeStatic`'s comment at lines 376–382 as the
  exemplar to match).

- Stale doc comment to fix while here: `src/root.zig:133-135` reads

  ```zig
  /// Forward-looking encode options; no encode path consumes these yet
  /// (encoders are PLAN.MD steps 7-8).
  pub const EncoderOptions = options.EncoderOptions;
  ```

  This is false — `encodeLossless`/`encodeLossy` consume `EncoderOptions`
  (steps 7–8 landed). See `src/options.zig:21-22` for accurate framing.

- Repo conventions: Zig 0.16.0; zero dependencies; explicit bounded parsing;
  every public entry point honors `ResourceLimits` and returns members of
  `errors.Error` (never panics on untrusted input); tests live in the same
  file or under `src/testing/`. Match the doc-comment density of the
  surrounding code.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check + compile + all tests) |
| Tests only | `zig build test` | exit 0, all tests pass (452 at planning time; you will add more) |
| Format | `zig fmt .` | exit 0 |
| Compile lib + tools | `zig build check` | exit 0 |

## Suggested executor toolkit

- If a `zig-0.16` or `zig-tiger-style` skill is available in your environment,
  consult it before writing new Zig code.

## Scope

**In scope** (the only files you should modify):

- `src/decode.zig` — add the Into entry point.
- `src/root.zig` — re-export + doc comment; fix the stale `EncoderOptions`
  comment.
- `src/testing/hardening.zig` — extend the limits/contract matrix to the new
  entry point (this is where allocation-failure and limits tests for public
  entry points live).
- `README.MD` — one sentence adding `decodeStaticInto` to the status/API
  description.
- `PLAN.MD` — tick the "static decode to caller-owned buffers" step-12 item
  as delivered (keep PLAN forward-looking; one clause, details go to
  `PROGRESS.MD`).
- `PROGRESS.MD` — dated entry describing what landed and the test evidence.
- `plans/README.md` — status row.

**Out of scope** (do NOT touch, even though they look related):

- `src/vp8/**`, `src/vp8l/**`, `src/color.zig`, `src/alpha.zig` — no codec
  internals change. This plan deliberately does NOT thread the caller's
  stride through the codec output stages (see "Design decisions" below).
- `decodeAnimation` / `AnimationDecoder` — caller-owned animation buffers are
  a separate future decision.
- Any change to `decodeStatic`'s behavior or output — the corpus hash gate
  pins it byte-for-byte.

## Design decisions (already made — do not re-litigate)

1. **Signature**:

   ```zig
   pub fn decodeStaticInto(
       gpa: std.mem.Allocator,
       bytes: []const u8,
       dest: image.Buffer,
       decode_options: options.DecoderOptions,
   ) errors.Error!void
   ```

   `gpa` funds internal scratch only (budgeted against
   `decode_options.limits.allocation_bytes_max` exactly like `decodeStatic`);
   the decoded pixels land in `dest.pixels`, row-major, honoring
   `dest.stride`. Bytes in `dest.pixels` outside the written rows (stride
   padding, tail slack) are left untouched.

2. **Format contract**: `dest.format` is authoritative.
   `decode_options.output_format` is ignored on this path; the doc comment
   must say so explicitly.

3. **Dimension contract**: `dest.validate()` must pass, and
   `dest.dimensions` must exactly equal the file's canvas dimensions.
   Any mismatch (larger or smaller) returns `error.InvalidCanvasSize`.
   Do NOT add new members to `errors.Error`.

4. **Implementation shape (v1 = copy-based, zero codec-internals risk)**:
   `decodeStaticInto` performs the same demux/animation/format checks as
   `decodeStatic` (extract a small shared helper rather than duplicating
   them), decodes via the existing `decodeImage` into a packed internal
   buffer using a `DecoderOptions` whose `output_format` is `dest.format`,
   then copies row-by-row into `dest.pixels` honoring `dest.stride`, and
   frees the internal buffer. The doc comment must be honest that internal
   scratch (including one output-sized buffer) is still allocated and
   budgeted. Writing directly through the caller's stride is a follow-up
   optimization recorded in "Maintenance notes", not this plan.

5. **Ordering of checks**: validate `dest` (validate() + dimension match
   against the parsed canvas) BEFORE decoding any pixels, so contract
   violations fail fast without paying decode cost.

## Git workflow

- Branch: `decode-static-into` (repo convention: `<slug>`; see `git log` merges like `step-11a-limits-hardening`).
- Commit style: single imperative summary line, e.g.
  `Add decodeStaticInto: static decode into caller-owned buffers`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extract the shared demux/validation prologue in `src/decode.zig`

Factor the body of `decodeStatic` (demux, animation rejection, format/chunk
extraction, `ImageSource` construction) into a private helper (suggested
name: `parseStaticSource`) that returns the `ImageSource` plus anything the
caller needs, so `decodeStatic` and `decodeStaticInto` share it. Note the
lifetime subtlety: `ImageSource` slices borrow from `bytes` (fine), but the
`demux.Result` must stay alive while they are used — keep the
`parsed`/`deinit` handling in the callers or return the `Result` for the
caller to deinit. `decodeStatic`'s behavior and output must be unchanged.

**Verify**: `zig build test` → exit 0, all existing tests pass (the SHA-256
corpus regression pins `decodeStatic` byte-for-byte).

### Step 2: Implement `decodeStaticInto` in `src/decode.zig`

Per the design decisions above. Row copy: for each row `y`, copy
`row_bytes` (from `dest.rowBytes()`) from the packed internal buffer at
`y * row_bytes` to `dest.pixels[y * dest.stride ..]`.

Include tests in `src/decode.zig` (or alongside the existing decode tests)
covering at least:

- packed-stride `rgba` output equals `decodeStatic` output byte-for-byte on
  a real corpus file (pick one from `testdata/libwebp-test-data/`, both a
  lossless and a lossy file);
- `stride > rowBytes`: rows land at stride offsets and a sentinel byte
  written into the padding beforehand is untouched after decode;
- `dest.format` different from `decode_options.output_format` → `dest.format`
  wins (compare against `decodeStatic` called with that format);
- dimension mismatch → `error.InvalidCanvasSize`;
- undersized `pixels` slice → error from `dest.validate()`
  (`error.OutputTooLarge`);
- animated input → `error.UnsupportedAnimationDecode`.

**Verify**: `zig build test` → exit 0, including the new tests.

### Step 3: Re-export from `src/root.zig` and fix the stale comment

Add a `decodeStaticInto` forwarding function next to `decodeStatic`
(root.zig:383) with a doc comment matching the surrounding style and stating:
caller-owned output, `dest.format` authoritative / `output_format` ignored,
exact-dimension contract and its error, internal scratch still allocated and
budgeted, padding bytes untouched. Add `decodeStaticInto` to the "most
callers need only a handful of names" module doc list (root.zig:3-13).

Separately, replace the stale comment at `src/root.zig:133-135` with accurate
text, e.g.: `/// Options bag for the still pixel encoders
(`encodeLossless`/`encodeLossy`); see `options.EncoderOptions`.`

**Verify**: `zig build test` → exit 0 (`refAllDecls` compiles the new
export); `grep -n "no encode path consumes" src/root.zig` → no matches.

### Step 4: Extend the hardening matrix

`src/testing/hardening.zig` holds the step-11a limits/malicious-input
contract matrix and allocation-failure injection for every public entry
point. Add `decodeStaticInto` coverage mirroring what `decodeStatic` has
there: tightened `ResourceLimits` produce the documented errors, truncated/
malformed input fails with errors not panics, and
`std.testing.checkAllAllocationFailures`-style injection passes (the dest
buffer is caller-provided, so only scratch allocations are injected).

**Verify**: `zig build test` → exit 0, hardening tests include the new entry
point (grep the test names you added).

### Step 5: Documentation and index

- `README.MD`: extend the API status paragraph with one sentence:
  `decodeStaticInto` decodes into a caller-owned buffer honoring stride.
- `PLAN.MD`: in the step-12 list ("static decode to caller-owned buffers"),
  mark the item delivered with a pointer to PROGRESS.MD (PLAN stays
  forward-looking per `AGENTS.md`).
- `PROGRESS.MD`: dated row/entry: what the API is, the contract, and the test
  evidence (corpus-equality tests, hardening coverage).
- `plans/README.md`: set this plan's row to DONE with the commit.

**Verify**: `zig build ci` → exit 0.

## Test plan

Covered in steps 2 and 4. Structural patterns to imitate: existing decode
tests in `src/decode.zig` / `src/testing/corpus.zig` for corpus-file loading,
and `src/testing/hardening.zig` for the limits matrix. Total: ≥6 new test
cases in decode, ≥2 in hardening.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0.
- [ ] `grep -n "pub fn decodeStaticInto" src/decode.zig src/root.zig` → one
      match in each file.
- [ ] New tests exist and pass: equality-with-`decodeStatic`, stride padding
      untouched, dimension mismatch error, animated rejection.
- [ ] `grep -n "no encode path consumes" src/root.zig` → no matches.
- [ ] `git status` shows no modified files outside the in-scope list.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" doesn't match the excerpts.
- The corpus hash regression fails after step 1 (the refactor changed
  `decodeStatic` behavior — that must not happen).
- Honoring the contract seems to require modifying any file under `src/vp8/`,
  `src/vp8l/`, `src/color.zig`, or `src/alpha.zig`.
- You find yourself wanting to add a new error to `errors.Error` — the design
  says reuse `error.InvalidCanvasSize` / `error.OutputTooLarge`.

## Maintenance notes

- Deferred optimization: thread `dest`'s stride through the codec output
  stages so the copy (and the extra output-sized scratch) disappears. That
  touches `src/color.zig` (lossy) and the VP8L output emit; it must keep the
  corpus hash gate byte-exact. Only worth doing with a benchmark showing the
  copy matters.
- Plan 015 (C-ABI design) builds on this API — if the signature changes
  during review, update that plan's assumption.
- Reviewers should scrutinize: the demux-result lifetime in the step-1
  refactor, and that `decodeStaticInto` validates `dest` before decoding.
