# Plan 008: Add fuzz smoke targets to the public encode entry points (step 11c)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5d6ed3c..HEAD -- src/encode.zig src/mux.zig src/testing/fuzz.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (additive tests; may surface real panics, which is the point)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `5d6ed3c`, 2026-07-04

## Why this matters

Every public **decode** entry point has a fuzz smoke target (9 targets across
`demux.zig`, `decode.zig`, `alpha.zig`, `animation_decode.zig`, `vp8/*`,
`vp8l/*`), but the public **encode** surface — now half the codec — has zero.
Two encode entry points (`mux.encodeStatic`, `mux.encodeAnimation`) accept
caller-supplied *pre-encoded bitstreams* plus frame geometry, i.e. semi-trusted
input validated by mux logic; the pixel encoders accept arbitrary dimensions,
strides, and option combinations. None of that input space gets automated
panic/overflow exploration today. This is roadmap slice **11c** (step 11 is
sliced 11a–11d; 11a landed as PR #80). The targets this plan adds also assert a
stronger property than "doesn't crash": when an encoder *succeeds*, its output
must decode successfully — encoder output is always a valid WebP.

## Current state

- Fuzz-target convention (match it exactly): a `test "fuzz ..."` block builds a
  small **valid** input, frames it as a corpus seed with
  `src/testing/fuzz.zig`'s `sliceCorpusEntry`, and calls `std.testing.fuzz`
  with a body function that reads Smith slices. Exemplar
  (`src/decode.zig:603-628`, abridged):

  ```zig
  var seed_buffer: [128]u8 = undefined;
  const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, encoded);
  try std.testing.fuzz({}, fuzzDecodeStaticOne, .{ .corpus = &.{seed} });

  fn fuzzDecodeStaticOne(_: void, smith: *std.testing.Smith) anyerror!void {
      var input_buffer: [2048]u8 = undefined;
      const input_len = smith.slice(&input_buffer);
      var decoded = decodeStatic(std.testing.allocator, input_buffer[0..input_len], .{
          .limits = .{ .output_pixels_max = 1 << 16, .allocation_bytes_max = 1 << 22 },
      }) catch return;
      decoded.deinit();
  }
  ```

- `src/testing/fuzz.zig` — the whole framing helper (28 lines): a corpus entry
  is a little-endian u32 length prefix + payload, so one `smith.slice` call
  receives the payload byte-for-byte. **The only Smith method used anywhere in
  this repo is `smith.slice`** — derive all fuzz-variable values (dimensions,
  flags, pixels) from slice bytes, not from other Smith methods, so corpus
  seeds stay constructible with `sliceCorpusEntry`. Multiple `smith.slice`
  calls in one body are fine (frame each payload in sequence in the seed
  buffer by calling `sliceCorpusEntry` on adjacent buffer regions, or use a
  single slice and split it yourself — the single-slice-then-split approach is
  simpler and preferred here).
- Public encode entry points (`src/root.zig`): `encodeStatic` (:235, wraps
  `mux.encodeStatic`), `encodeAnimation` (:252, wraps `mux.encodeAnimation`),
  `encodeAnimationFromBuffers` (:270), `encodeAnimationMinimized` (:291),
  `encodeLossless` (:314, wraps `encode.encodeStaticLossless`),
  `encodeVP8LBitstream` (:326), `encodeLossy` (:351, wraps
  `encode.encodeStaticLossy`), `encodeVP8Bitstream` (:363).
- `mux.StaticImage` (`src/mux.zig:25-34`):

  ```zig
  pub const StaticImage = struct {
      canvas: image.Dimensions,
      format: features.FormatKind,
      bitstream: []const u8,
      alpha: ?[]const u8 = null,
      has_alpha: bool = false,
      metadata: metadata.RawPayloads = .{},
      unknown_chunks: []const RawChunk = &.{},
      force_extended: bool = false,
  };
  ```

  `mux.encodeStatic` (`src/mux.zig:71`) validates canvas/limits, parses the
  bitstream header via `demux.parseBitstreamInfo`, and rejects mismatched
  dimensions/format with `error.InvalidMuxChunk` — that validation logic is the
  fuzz target.
- `mux.FrameImage`/`mux.AnimationImage` (`src/mux.zig:40-69`) — per-frame rect,
  duration, blend/dispose, format, bitstream, optional alpha; `encodeAnimation`
  at `src/mux.zig:256`.
- Pixel-encoder input type: `image.Buffer` (aliased `ImageBuffer` in root) —
  `pixels: []u8`, `dimensions`, `stride`, `format` (`.rgba/.bgra/.argb/.rgb`).
  See any encode test in `src/encode.zig` for construction.
- `EncoderOptions` (`src/options.zig:22`): `format` must be `.lossless` for
  `encodeLossless` and `.lossy` for `encodeLossy`; `quality: u8`, `method: u8`,
  `target_size: ?u32`, `target_psnr: ?f32`, `alpha_quality: u8`,
  `use_sharp_yuv: bool`.
- Existing valid-input builders you can reuse for seeds: `encodeVP8LBitstream`
  / `encodeVP8Bitstream` (public, above) produce valid bitstreams for mux
  seeds; `src/decode.zig`'s tests build tiny VP8L payloads with
  `makeConstantVP8L` (private to that file — use the public encoders instead).
- Repo conventions: Zig 0.16.0; tests inline in the module they exercise;
  bounded loops; `zig fmt .` before handing back. Under plain `zig build test`
  each fuzz target runs corpus seeds + an empty input as a smoke pass with
  leak detection (coverage-guided `--fuzz` is blocked upstream; that is plan
  009's concern, not yours).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tests | `zig build test` | exit 0, "All N tests passed" (433 at planning time) |
| Format | `zig fmt .` | exit 0 |
| Format check | `zig fmt --check .` | exit 0, no output |
| Tool compile | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/encode.zig` (add fuzz tests for `encodeStaticLossless`/`encodeStaticLossy`)
- `src/mux.zig` (add fuzz tests for `encodeStatic`/`encodeAnimation`)
- `src/animation_encode.zig` (add a fuzz test for `encodeAnimationFromBuffers` — Step 4, optional scope, see step)

**Out of scope** (do NOT touch, even though they look related):
- `src/animation_optimize.zig` (`encodeAnimationMinimized`) — its optimizer
  loop re-encodes and re-decodes per frame; a fuzz body would be slow and its
  input contract equals `encodeAnimationFromBuffers`'s. Deliberately deferred.
- `src/vp8/encoder.zig`, `src/vp8l/encoder.zig` internals — fuzz through the
  public wrappers only.
- `src/testing/fuzz.zig` — reuse as-is; extending it is plan 009's job.
- Decode-side fuzz targets — already exist; don't modify.

## Git workflow

- Branch: `claude/step-11c-encoder-fuzz` (repo convention: `claude/` prefix).
- Commit style: short imperative summary, e.g. `Add encoder fuzz smoke targets`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fuzz `encodeLossless` from Smith-derived pixels (in `src/encode.zig`)

Add a fuzz body that reads one Smith slice and splits it: first 2 bytes →
width/height (each clamped to `1..=64` via `1 + (byte % 64)`), remaining bytes
→ RGBA pixel data (zero-pad or truncate to `width*height*4` using a fixed
buffer — max 64×64×4 = 16384 bytes). Build an `image.Buffer` with
`.format = .rgba`, `.stride = width * 4`. Then:

```zig
const encoded = encodeStaticLossless(std.testing.allocator, buffer, .{}) catch return;
defer std.testing.allocator.free(encoded);
// Encoder output must always decode: this is the strong property.
var decoded = try decode.decodeStatic(std.testing.allocator, encoded, .{});
decoded.deinit();
```

Note the `try` on the decode: if encoding succeeded but decoding fails, the
test **should** fail — that is a real encoder bug. (Check `src/encode.zig`'s
imports for how it references the decode module; it already imports what its
round-trip tests use.)

Seed: a small valid input — e.g. 2 bytes `{4, 4}` (dims) + 64 bytes of varied
RGBA — framed with `sliceCorpusEntry` (seed buffer ≥ payload + 4).

The test block: `test "fuzz lossless encode from pixel buffers" { ... }` with
`try std.testing.fuzz({}, fuzzEncodeLosslessOne, .{ .corpus = &.{seed} });`

**Verify**: `zig build test` → exit 0, new test passes.

### Step 2: Fuzz `encodeLossy` the same way (in `src/encode.zig`)

Same body shape as Step 1 with `.format = .lossy` in the options and one
addition: derive `quality` from one more input byte (`byte % 101`). Keep
dimensions clamped to `1..=64` (lossy encode is heavier — 64×64 = 16
macroblocks is plenty). Round-trip-decode the output with `try` as in Step 1.

**Verify**: `zig build test` → exit 0, new test passes. Note the wall-clock
delta of `zig build test` vs before this plan; if the suite got more than ~5
seconds slower, shrink the dimension clamp to `1..=32`.

### Step 3: Fuzz `mux.encodeStatic` and `mux.encodeAnimation` (in `src/mux.zig`)

These take pre-encoded bitstreams — the fuzz input IS the bitstream bytes plus
geometry, and the interesting code is the validation.

- `fuzzMuxStaticOne`: read one slice; use byte 0/1 → canvas width/height
  (clamped `1..=256`), byte 2 → flags (bit 0: format `.lossy`/`.lossless`,
  bit 1: `has_alpha`), rest → `bitstream`. Call
  `encodeStatic(std.testing.allocator, .{ .canvas = ..., .format = ...,
  .bitstream = ..., .has_alpha = ... }, .{}) catch return;` free on success.
  On success, also `try demux`-parse the output (`parseWebP` or this module's
  round-trip helper — see the existing mux round-trip tests near
  `src/mux.zig:730` for the call shape): mux output must always re-demux.
- `fuzzMuxAnimationOne`: read one slice; split into two frame bitstreams
  (first half / second half), fixed 16×16 canvas, two `FrameImage`s at rect
  (0,0,16,16) with formats from a flag byte. Call `encodeAnimation(...) catch
  return;` on success `try` re-demux.
- Seeds: build valid bitstreams with the *public* `vp8l_encoder.encodeAlloc`
  (or `encode.encodeVP8Bitstream`) over a tiny constant pixel array — check
  what `src/mux.zig`'s existing tests already use to build valid frames (near
  lines 730–960) and reuse that helper if one exists in-file.

**Verify**: `zig build test` → exit 0, both new tests pass.

### Step 4 (optional — skip if any earlier step ran into trouble): Fuzz `encodeAnimationFromBuffers` (in `src/animation_encode.zig`)

One slice → dims byte, per-frame codec flag byte, pixels for two small
full-canvas frames; options `.{ .canvas = ..., ... }` per
`AnimationEncodeOptions` (read its definition in the file). `catch return` on
error; on success `try decodeAnimation` on the output (the module's existing
round-trip tests show the import). If this step's test is slow (>2s added),
drop the frame count to 1 or skip the step and note it in the plan status.

**Verify**: `zig build test` → exit 0.

### Step 5: Format and final gates

`zig fmt .`, then all gates.

**Verify**: `zig fmt --check .` → exit 0; `zig build test` → exit 0;
`zig build check` → exit 0.

## Test plan

The fuzz targets ARE the tests. Final inventory (grep-checkable):
- `src/encode.zig`: `"fuzz lossless encode from pixel buffers"`,
  `"fuzz lossy encode from pixel buffers"`.
- `src/mux.zig`: `"fuzz static mux from untrusted bitstream"`,
  `"fuzz animation mux from untrusted bitstreams"`.
- `src/animation_encode.zig` (optional): `"fuzz animation encode from pixel buffers"`.
- Every body enforces: no panic, no leak (automatic under the test allocator),
  and **encode success ⇒ decode/demux success**.
- Pattern exemplar: `src/decode.zig:603-628`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "std.testing.fuzz" src/encode.zig` ≥ 2
- [ ] `grep -c "std.testing.fuzz" src/mux.zig` ≥ 2
- [ ] `zig build test` exits 0 with all new tests passing
- [ ] `zig build test` wall-clock is within ~5s of the pre-plan baseline (time it before starting)
- [ ] `zig fmt --check .` exits 0
- [ ] `git status` shows no modified files outside the in-scope list (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows in-scope files changed since `5d6ed3c` and the
  excerpts no longer match (check `git log --oneline` for an 11c slice that
  may have landed).
- A fuzz body's round-trip `try` fails on a **seed** input (encoder produced
  undecodable output on valid input — a real encoder bug; report the input).
- `std.testing.Smith` has no `slice` method or `std.testing.fuzz`'s signature
  differs from the exemplar (toolchain drift).
- A new fuzz test makes `zig build test` more than ~10 seconds slower even
  after shrinking dimensions (report; do not silently drop the target).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- These are smoke targets: under `zig build test` they run seeds + empty input
  only. Plan 009 adds bounded-random exploration on top; coverage-guided
  `--fuzz` unblocks when upstream Zig fixes the `test_runner.zig`
  instrumentation bug (watched by `.github/workflows/zig-master-canary.yml`).
- The "encode success ⇒ decode success" property makes these targets sharper
  than the decode ones — reviewers of future encoder changes should keep that
  `try`, never downgrade it to `catch return`.
- Deferred: fuzzing `encodeAnimationMinimized` (slow optimizer loop, same
  input contract as `encodeAnimationFromBuffers`) and option-struct fuzzing
  beyond quality/format flags (the only cross-field invariant,
  `target_size`+`target_psnr` exclusivity, is already unit-tested at
  `src/encode.zig:1132`).
