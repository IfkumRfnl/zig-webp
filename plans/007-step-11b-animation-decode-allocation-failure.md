# Plan 007: Add allocation-failure injection to the animated decode paths (step 11b)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 5d6ed3c..HEAD -- src/animation_decode.zig`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (test-only; may surface a real leak, which is the point)
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `5d6ed3c`, 2026-07-04

## Why this matters

This repo's hardening contract (PLAN.MD step 11) requires every public entry
point to survive allocation failure at every allocation site: the call must
return `error.OutOfMemory` cleanly, with no leaks and no partial state. Seven
files already enforce this with `std.testing.checkAllAllocationFailures`
(`src/decode.zig`, `src/demux.zig`, `src/alpha.zig`, `src/mux.zig`,
`src/encode.zig`, `src/animation_encode.zig`, `src/animation_optimize.zig`) —
but `src/animation_decode.zig`, the most allocation-heavy decode path (per-frame
canvases, owned-frame lists, per-frame codec scratch), has **zero**. This is
roadmap slice **11b** (step 11 is sliced 11a–11d; 11a landed as PR #80). Closing
it brings the animated decode surface up to the same OOM contract as every
other entry point.

## Current state

- `src/animation_decode.zig` — the animated decode module. Public surface:
  - `Decoder` struct at line 68, with `init` at line 89, `deinit` at line 127,
    `next` at line 153 (streaming per-frame decode).
  - `decodeAnimationAlloc` at line 300 (decodes all frames; re-exported as the
    public `decodeAnimation` at `src/root.zig:394`).
  - `OwnedAnimation.deinit` at line 291.
- The module already contains an in-memory animation builder used by its own
  tests: `buildAnimation(allocator, width, height, frame_specs)` (see its use
  in the existing fuzz test at lines 634–647):

  ```zig
  // src/animation_decode.zig:637-641
  const file = try buildAnimation(testing.allocator, 4, 4, &.{
      .{ .x = 0, .y = 0, .width = 4, .height = 4, .color = .{ 255, 0, 0, 255 }, .blend = .replace },
      .{ .x = 2, .y = 2, .width = 2, .height = 2, .color = .{ 0, 255, 0, 64 }, .dispose = .background },
  });
  defer testing.allocator.free(file);
  ```

  Frame specs are `TestFrameSpec` (line 439): `x`, `y`, `width`, `height`,
  `color: [4]u8`, optional `duration_ms`, `blend`, `dispose`.
- Verified absence: `grep -n checkAllAllocationFailures src/animation_decode.zig`
  returns nothing at the planned-at commit.
- The repo convention for these tests is a **probe function + a test block in
  the same module as the entry point**. Exemplar — match this shape exactly
  (`src/decode.zig:630-656`):

  ```zig
  fn decodeStaticAllocationProbe(gpa: std.mem.Allocator, encoded: []const u8) !void {
      var decoded = try decodeStatic(gpa, encoded, .{});
      decoded.deinit();
  }

  test "static decode survives allocation failure at every site" {
      // ... build a small valid file into `encoded` ...
      try std.testing.checkAllAllocationFailures(
          std.testing.allocator,
          decodeStaticAllocationProbe,
          .{encoded},
      );
  }
  ```

  Note: `checkAllAllocationFailures` requires the probe's first parameter to be
  the allocator, and it re-runs the probe once per allocation site, injecting
  failure at each.
- Repo conventions that apply: Zig 0.16.0; `zig fmt .` before handing back;
  tests live inline in the module; explicit bounded loops; test names are
  descriptive sentences in double quotes.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tests | `zig build test` | exit 0, "All N tests passed" (433 at planning time; you will add more) |
| Format | `zig fmt .` | exit 0 |
| Format check | `zig fmt --check .` | exit 0, no output |
| Tool compile | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/animation_decode.zig` (add probe functions + test blocks only)

**Out of scope** (do NOT touch, even though they look related):
- `src/decode.zig`, `src/demux.zig`, `src/alpha.zig` — their injection tests
  already exist; do not "improve" them.
- `src/testing/hardening.zig` — that file is the *limits* contract matrix
  (slice 11a), a different concern from allocation-failure injection.
- Any non-test code in `src/animation_decode.zig` — unless Step 3's leak
  exception applies (read it carefully).

## Git workflow

- Branch: `claude/step-11b-animation-decode-alloc-failure` (repo convention:
  `claude/` prefix, see `git log` — e.g. branch for PR #80 was
  `claude/step-11a-limits-hardening`).
- Commit style: short imperative summary, e.g. `Add allocation-failure
  injection to animated decode` (match `git log --oneline`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an allocation-failure test for `decodeAnimationAlloc`

In `src/animation_decode.zig`, near the existing fuzz test (after line ~660),
add a probe and test:

```zig
fn animationAllocationProbe(gpa: std.mem.Allocator, file: []const u8) !void {
    var animated = try decodeAnimationAlloc(gpa, file, .{});
    animated.deinit();
}

test "animated decode survives allocation failure at every site" {
    const file = try buildAnimation(testing.allocator, 4, 4, &.{
        .{ .x = 0, .y = 0, .width = 4, .height = 4, .color = .{ 255, 0, 0, 255 }, .blend = .replace },
        .{ .x = 2, .y = 2, .width = 2, .height = 2, .color = .{ 0, 255, 0, 64 }, .dispose = .background },
    });
    defer testing.allocator.free(file);

    try std.testing.checkAllAllocationFailures(
        testing.allocator,
        animationAllocationProbe,
        .{file},
    );
}
```

Use the same two-frame spec as the fuzz test (it exercises replace + blend +
dispose-to-background composition). `buildAnimation`'s exact signature may
differ slightly from this sketch — read its definition in the file and match it.

**Verify**: `zig build test` → exit 0, test count increased by 1, new test passes.

### Step 2: Add an allocation-failure test for the streaming `Decoder`

Same file, add a probe that drives the streaming API through its full
lifecycle (init → drain all frames → deinit), and a test wiring it to the same
built animation:

```zig
fn animationStreamingAllocationProbe(gpa: std.mem.Allocator, file: []const u8) !void {
    var decoder = try Decoder.init(gpa, file, .{});
    defer decoder.deinit();
    while (try decoder.next()) |_| {}
}

test "streaming animated decode survives allocation failure at every site" { ... }
```

The `defer decoder.deinit()` placement matters: `deinit` must be safe to call
after a failed `next`, and the probe must not leak when `init` itself fails
(`try` before the `defer` handles that — a failed `init` returns before the
defer is registered, and `init` must clean up after itself).

**Verify**: `zig build test` → exit 0, test count increased by 1 more.

### Step 3: Handle any failure the injection surfaces

If Step 1 or 2 fails, `checkAllAllocationFailures` reports either a leak or a
state corruption at a specific allocation site. That is a **real bug** — the
finding this plan exists to surface. The rule:

- If the leak/corruption is inside `src/animation_decode.zig` itself (e.g. a
  missing `errdefer` in `Decoder.init` or `next`): fix it **minimally** in that
  file (typically adding one `errdefer`), keep the fix in a separate commit
  from the tests, and re-run. This is the one sanctioned non-test change.
- If the leak is in another module (`src/decode.zig`, `src/vp8/*`, `src/vp8l/*`,
  `src/alpha.zig`, `src/demux.zig`): **STOP and report** the exact failing
  allocation site and stack. Do not fix other modules under this plan.

**Verify**: `zig build test` → exit 0, all tests pass.

### Step 4: Format and final check

Run `zig fmt .`, then the full gate set.

**Verify**: `zig fmt --check .` → exit 0; `zig build test` → exit 0;
`zig build check` → exit 0.

## Test plan

The tests ARE the deliverable:
- `"animated decode survives allocation failure at every site"` — covers
  `decodeAnimationAlloc` (public `decodeAnimation`) end to end over a two-frame
  animation with replace, alpha-blend, and dispose-to-background.
- `"streaming animated decode survives allocation failure at every site"` —
  covers `Decoder.init`/`next`/`deinit` over the same input.
- Structural pattern: `src/decode.zig:630-656`.
- Verification: `zig build test` → all pass, 2 new tests present.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c checkAllAllocationFailures src/animation_decode.zig` returns `2` (or more)
- [ ] `zig build test` exits 0 with the 2 new tests passing
- [ ] `zig fmt --check .` exits 0
- [ ] `zig build check` exits 0
- [ ] `git status` shows no modified files outside `src/animation_decode.zig` (plus `plans/README.md` status row)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `src/animation_decode.zig` changed since `5d6ed3c` and
  the excerpts above no longer match (someone may have landed 11b already —
  check `git log --oneline` for it).
- `buildAnimation` does not exist or its signature is incompatible with
  building a two-frame animation (the plan's assumption about the test helper
  is false).
- Injection surfaces a leak **outside** `src/animation_decode.zig` (Step 3).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Any future allocation added to `Decoder.init`/`next`/`decodeAnimationAlloc`
  is automatically covered by these tests — that is their point. Reviewers of
  future animated-decode changes should expect these tests to catch missing
  `errdefer`s.
- Follow-up deferred: allocation-failure injection over a *lossy*-frame
  animation (the committed fixture `testdata/animation/lossy_frames.webp` could
  drive it, read via the pattern in `src/testing/corpus.zig`). Deferred because
  the synthetic VP8L animation already exercises every allocation site in
  `animation_decode.zig` itself; the lossy per-frame codec sites are covered by
  `src/decode.zig`'s existing lossy injection tests.
