# Plan 002: Add allocation-failure injection tests to every public decode/demux entry point

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1aa7670..HEAD -- src/decode.zig src/demux.zig src/alpha.zig src/mux.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (001 recommended first so CI is stronger, but not required)
- **Category**: tests
- **Planned at**: commit `1aa7670`, 2026-06-13

## Why this matters

This library decodes untrusted input with caller-supplied allocators, and its
roadmap (PLAN.MD step 11) promises "allocation-failure injection tests around
every public entry point". Today there are none: `std.testing.checkAllAllocationFailures`
appears nowhere in `src/`. The existing tests and fuzz smoke targets use
`std.testing.allocator` (which catches leaks on *success and ordinary error
paths*), but nothing exercises the case where an allocation **fails partway
through** a decode — exactly where a missing `errdefer` causes a leak or an
invalid free. Adding these tests now is cheap because every entry point
already has small synthetic valid inputs in its test blocks, and it protects
all future decoder work (the VP8 lossy path is being wired up right now).

`std.testing.checkAllAllocationFailures` (Zig 0.16,
`lib/std/testing.zig:1115`) runs a function once to count its allocations,
then re-runs it N times, failing allocation 0, 1, … N-1 in turn, and verifies
that each run returns `error.OutOfMemory` cleanly without leaking. The
function under test must take an `std.mem.Allocator` as its first parameter
and tolerate `error.OutOfMemory` at any allocation site.

## Current state

- No file under `src/` references `checkAllAllocationFailures` or
  `FailingAllocator` (verified by grep at planning time).
- Repo conventions: tests are inline `test "..."` blocks at the bottom of
  the module they exercise; they use `std.testing.allocator`; fuzz targets
  follow the same placement (e.g. `src/decode.zig:366`, `src/demux.zig:1200`,
  `src/alpha.zig:497`).

Entry points to cover, with the existing synthetic-input source for each:

1. **`decode.decodeStatic(gpa, bytes, decode_options)`** — `src/decode.zig:17`.
   Synthetic inputs already exist in this file's tests: `makeConstantVP8L`
   (`src/decode.zig:230`) builds a tiny valid VP8L bitstream and
   `mux.encodeStatic` wraps it into a full WebP file — see the test
   `"decodes a simple lossless WebP to RGBA"` (`src/decode.zig:280-303`):

```zig
// src/decode.zig:280-294 (existing test, the input-construction pattern to reuse)
test "decodes a simple lossless WebP to RGBA" {
    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);
    ...
```

   Also cover the meta-prefix path via `makeMetaPrefixVP8L`
   (`src/decode.zig:260`) — it exercises the allocator-backed prefix-group
   store, a different allocation profile.

2. **`demux.parse(gpa, bytes, options)`** — `src/demux.zig:75`. Returns a
   `Result` with a `deinit()`. Reuse the synthetic extended-WebP bytes from
   an existing passing test in `src/demux.zig` (e.g. the input built in
   `"parses extended metadata and rejects duplicate metadata chunks"`,
   `src/demux.zig:830`, or any simpler passing input in that file). Pick one
   that **parses successfully** and allocates (animated or chunk-list-bearing
   inputs allocate; check the chosen test's input parses with `.{}` options).

3. **`demux.parseFeatures(gpa, bytes, options)`** — `src/demux.zig:142`.
   Same input as (2).

4. **`alpha.decodePlaneAlloc(gpa, payload, dimensions, output)`** —
   `src/alpha.zig:82`. The VP8L-compressed branch (`decodeLossless`,
   `src/alpha.zig:107`) makes three allocations. The uncompressed branch
   allocates nothing — cover the *compressed* branch. An existing corpus-free
   synthetic compressed-alpha input exists in this file's tests; if none
   parses the compressed branch synthetically, build the payload with the
   same helpers those tests use. If only the uncompressed branch has a
   synthetic input, still add the check for it (a zero-allocation function
   passes trivially and guards future changes), and note in the test comment
   that the compressed branch is covered through `decodeStatic`-style corpus
   tests.

5. **`mux.encodeStatic(gpa, static_image, mux_options)`** — `src/mux.zig:35`.
   Returns an allocated `[]u8`. Input: the same `StaticImage` literal used in
   (1).

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|--------------------------|---------------------|
| Format | `zig fmt .` | exit 0 |
| Tests | `zig build test` | exit 0, no output |
| One-module iteration | `zig test src/decode.zig` is NOT supported (module imports); always use `zig build test` | — |

## Scope

**In scope** (the only files you should modify):
- `src/decode.zig` (add tests + wrapper fns only)
- `src/demux.zig` (add tests + wrapper fns only)
- `src/alpha.zig` (add tests + wrapper fns only)
- `src/mux.zig` (add tests + wrapper fns only)

**Out of scope** (do NOT touch, even though they look related):
- Any non-test code change in `src/**` — if injection exposes a real leak,
  that is a STOP-and-report, not a fix-it-here (see STOP conditions).
- `src/vp8/decoder.zig` and `src/vp8l/decoder.zig` internals — they are
  reached through `decodeStatic`/`decodePlaneAlloc`; direct coverage of their
  internal entry points is deferred (see Maintenance notes).
- `src/testing/corpus.zig` — corpus tests stay as they are; these new tests
  must NOT depend on `testdata/` (they must run even where the corpus is
  absent).

## Git workflow

- Branch: `claude/allocation-failure-injection`
- Single imperative commit, e.g. `Add allocation-failure injection tests for public entry points`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `decode.decodeStatic` (both VP8L shapes)

At the bottom of `src/decode.zig` (after the existing tests), add a wrapper
and two tests:

```zig
fn decodeStaticAllocationProbe(gpa: std.mem.Allocator, encoded: []const u8) !void {
    var decoded = try decodeStatic(gpa, encoded, .{});
    decoded.deinit();
}

test "static decode survives allocation failure at every site" {
    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeStaticAllocationProbe,
        .{encoded},
    );
}
```

Add a second test, same shape, using `makeMetaPrefixVP8L` with
`Dimensions.init(3, 1)` (copy the input construction from the existing test
at `src/decode.zig:345-354`).

**Verify**: `zig build test` → exit 0. If it reports a leak or an unexpected
error with an induced-failure trace, see STOP conditions.

### Step 2: `demux.parse` and `demux.parseFeatures`

At the bottom of `src/demux.zig`, add wrappers and one test each, reusing
bytes from an existing passing parse test in that file:

```zig
fn parseAllocationProbe(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var result = try parse(gpa, bytes, .{});
    result.deinit();
}

fn parseFeaturesAllocationProbe(gpa: std.mem.Allocator, bytes: []const u8) !void {
    _ = try parseFeatures(gpa, bytes, .{});
}
```

Note `parseFeatures` returns a `features.Summary` by value (no deinit —
confirm by reading `src/demux.zig:142`; if it allocates into the summary,
free accordingly).

**Verify**: `zig build test` → exit 0.

### Step 3: `alpha.decodePlaneAlloc`

At the bottom of `src/alpha.zig`, add a wrapper that owns a fixed output
buffer and a test per the guidance in "Current state" item 4:

```zig
fn decodePlaneAllocationProbe(gpa: std.mem.Allocator, payload: []const u8) !void {
    const dimensions = try image.Dimensions.init(8, 8);
    var output: [64]u8 = undefined;
    _ = try decodePlaneAlloc(gpa, payload, dimensions, &output);
}
```

Use a payload that exercises the VP8L-compressed branch if one can be built
from this file's existing test helpers; otherwise use the uncompressed
payload from the fuzz seed at `src/alpha.zig:500-501`
(`[_]u8{0} ++ [_]u8{0x80} ** 64`) and say so in a comment.

**Verify**: `zig build test` → exit 0.

### Step 4: `mux.encodeStatic`

At the bottom of `src/mux.zig`:

```zig
fn encodeStaticAllocationProbe(gpa: std.mem.Allocator, static_image: StaticImage) !void {
    const encoded = try encodeStatic(gpa, static_image, .{});
    gpa.free(encoded);
}
```

with a test passing the same `StaticImage` literal as the existing mux tests
(any passing one in `src/mux.zig`).

**Verify**: `zig build test` → exit 0.

### Step 5: Format pass

**Verify**: `zig fmt --check .` → exit 0.

## Test plan

The new tests ARE the deliverable:

- `src/decode.zig`: 2 new tests (constant VP8L, meta-prefix VP8L).
- `src/demux.zig`: 2 new tests (`parse`, `parseFeatures`).
- `src/alpha.zig`: 1 new test.
- `src/mux.zig`: 1 new test.
- Pattern to model after: the existing inline tests in each file; wrappers
  named `*AllocationProbe` for greppability.
- Verification: `zig build test` → exit 0 including the 6 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -rn "checkAllAllocationFailures" src/ | wc -l` returns >= 6
- [ ] `zig build test` exits 0
- [ ] `zig fmt --check .` exits 0
- [ ] New tests do not read `testdata/` (grep the new test bodies for `testdata` → no matches)
- [ ] `git status --porcelain` shows only the four in-scope files and `plans/README.md` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- **An injection test fails with a leak or invalid free**: this means the
  plan found a real bug — the intended outcome. Capture the full failure
  output (it names the failing allocation index and stack trace), write it
  into your report, mark this plan BLOCKED in `plans/README.md` with a
  one-line pointer, and stop. Do not patch library code under this plan.
- A test fails with `error.SwallowedOutOfMemoryError` — the entry point
  catches OOM somewhere instead of propagating it; report the location.
- The wrapper signatures don't match the actual entry-point signatures
  (drift), or `checkAllAllocationFailures` is not found in this Zig
  version's `std.testing`.
- Allocation counts are nondeterministic across the two passes (the helper
  will error; likely cause: hash-map-order-dependent allocation). Report it.

## Maintenance notes

- Every NEW public decode/encode entry point should land with an
  `*AllocationProbe` test in the same change — same rule the repo already
  applies to fuzz targets (PLAN.MD Cross-Cutting Practices). Reviewers:
  look for it.
- When VP8 lossy decode is wired into `decode.decodeStatic` (step 5 of
  PLAN.MD), extend the `decodeStatic` probe with a small synthetic lossy
  input; ditto lossy+alpha composition.
- Deferred: direct probes for `vp8l_decoder.decodeARGBAlloc` and
  `vp8/decoder.zig`'s frame decode — they are currently covered through
  `decodeStatic`; add direct probes when their public signatures stabilize.
