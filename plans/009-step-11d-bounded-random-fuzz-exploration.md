# Plan 009: Give fuzz targets real input exploration under the blocked toolchain (step 11d)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5d6ed3c..HEAD -- src/testing/fuzz.zig src/decode.zig src/demux.zig src/alpha.zig src/animation_decode.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Also check `PROGRESS.MD` for a note
> that coverage-guided fuzzing was unblocked — if it was, this plan may be
> obsolete; STOP and report.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (additive tests; deterministic by construction, no CI flake)
- **Depends on**: plan 008 (soft — do 008 first so its new encode targets can
  be wired into the same mechanism; this plan works without it)
- **Category**: tests
- **Planned at**: commit `5d6ed3c`, 2026-07-04

## Why this matters

The repo has 9 decode fuzz targets (plus plan 008's encode targets), but under
plain `zig build test` each one runs exactly its corpus seed + an empty input —
zero input-space exploration. Coverage-guided runs (`zig build test --fuzz`)
are blocked by an upstream Zig 0.16.0 bug (bundled `lib/compiler/test_runner.zig`
fails to compile under fuzz instrumentation — `*builtin.StackTrace` vs
`*debug.StackTrace`; documented at `PROGRESS.MD:286-290` and probed weekly by
`.github/workflows/zig-master-canary.yml`). Until that unblocks, "fuzz coverage
on all entry points" overstates the real assurance. This plan is roadmap slice
**11d**'s interim form: deterministic, bounded, *mutation-based* exploration
that runs inside plain `zig build test` — each target's valid seed gets K
byte-mutated variants fed through the same fuzz body. Mutated-valid inputs
penetrate far deeper than random bytes (which die at the RIFF signature check)
and the fixed PRNG seed makes runs reproducible: a failure is a permanent
regression test, never a flake.

## Current state

- `src/testing/fuzz.zig` — 28 lines; sole content is `sliceCorpusEntry`
  (frames a payload as a length-prefixed Smith slice input) plus its test:

  ```zig
  pub const slice_length_prefix_size = 4;

  pub fn sliceCorpusEntry(buffer: []u8, payload: []const u8) []const u8 {
      assert(buffer.len >= payload.len + slice_length_prefix_size);
      std.mem.writeInt(u32, buffer[0..slice_length_prefix_size], @intCast(payload.len), .little);
      @memcpy(buffer[slice_length_prefix_size..][0..payload.len], payload);
      return buffer[0 .. slice_length_prefix_size + payload.len];
  }
  ```

- Fuzz-target shape (all 9 follow it; exemplar `src/decode.zig:603-628`): a
  test builds a valid file, frames it via `sliceCorpusEntry`, calls
  `std.testing.fuzz({}, fuzzBodyOne, .{ .corpus = &.{seed} })`. Each body is a
  standalone `fn (void, *std.testing.Smith) anyerror!void` that reads one
  slice and calls the entry point with tight `ResourceLimits`, `catch return`.
  Bodies are reusable: `std.testing.Smith` is a plain struct constructible as
  `std.testing.Smith{ .in = bytes }` (see the test in `src/testing/fuzz.zig:24`).
- The 9 existing fuzz bodies and their locations (grep `std.testing.fuzz` to
  re-verify): `demux.zig:1201`, `decode.zig:614`, `alpha.zig:724`,
  `animation_decode.zig:646`, `vp8/frame_header.zig:875`, `vp8/modes.zig:821`,
  `vp8/decoder.zig:712`, `vp8/tokens.zig:1061`, `vp8l/decoder.zig:623`.
- Determinism constraint: this repo's tests must be reproducible. Use
  `std.Random.DefaultPrng` with a **fixed literal seed** — never a
  time/entropy seed.
- Repo conventions: Zig 0.16.0; bounded loops; tests inline in the module they
  exercise; shared test helpers live in `src/testing/`; `zig fmt .` before
  handing back.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tests | `zig build test` | exit 0, "All N tests passed" |
| Time the suite | `time zig build test` (after a warm cache run) | note the delta vs pre-plan |
| Format | `zig fmt .` / `zig fmt --check .` | exit 0 |
| Tool compile | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/testing/fuzz.zig` — add the mutation-exploration helper + its own unit test
- `src/decode.zig`, `src/demux.zig`, `src/alpha.zig`, `src/animation_decode.zig`
  — add one exploration test each, next to the existing fuzz test
- (If plan 008 landed) `src/encode.zig`, `src/mux.zig` — same, one test each

**Out of scope** (do NOT touch, even though they look related):
- The five `vp8/*` / `vp8l/*` internal fuzz targets — their input spaces are
  subsets of what the four public composition targets reach; wiring the public
  entry points explores through them anyway. Extend later only if the public
  targets prove too shallow.
- `.github/workflows/*` — no CI changes; the exploration runs inside the
  existing `zig build test` gate.
- The existing fuzz bodies — reuse them verbatim; do not modify their limits
  or logic. Exception: if a body is declared with a lowercase private name and
  the new test in the same file can already see it, nothing needs to change;
  the new tests live in the same module precisely so no visibility change is
  needed.
- `PROGRESS.MD` — the maintainer records progress; you may note the delivered
  mechanism in your report instead.

## Git workflow

- Branch: `claude/step-11d-bounded-random-fuzz` (repo convention: `claude/` prefix).
- Commit style: short imperative summary, e.g. `Add bounded mutation exploration to fuzz targets`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the mutation-exploration helper to `src/testing/fuzz.zig`

Add a public helper that, given a valid payload and a fuzz body, runs the body
against K mutated variants (each variant = the payload with 1–8 random byte
substitutions at random offsets, plus occasional truncation), all driven by a
fixed-seed PRNG:

```zig
pub const MutationOptions = struct {
    /// Number of mutated variants to run. Keep the per-target budget small:
    /// the goal is exploration-per-millisecond, not exhaustiveness.
    variant_count: usize = 128,
    /// Fixed PRNG seed — determinism is load-bearing (no CI flake, and any
    /// failure is reproducible). Vary per call site so targets diverge.
    prng_seed: u64,
};

/// Feeds `body` (a `std.testing.fuzz`-shaped function) `variant_count`
/// deterministic mutations of `payload`, each framed exactly like a corpus
/// entry so the body's `smith.slice` read sees the mutated bytes.
pub fn runMutations(
    comptime body: fn (void, *std.testing.Smith) anyerror!void,
    payload: []const u8,
    mutation_options: MutationOptions,
) !void {
    // Implementation outline (bounded, allocation-free):
    //   var prng = std.Random.DefaultPrng.init(mutation_options.prng_seed);
    //   const random = prng.random();
    //   stack buffers sized payload.len + slice_length_prefix_size (assert a cap, e.g. 4096);
    //   for (0..variant_count):
    //     copy payload; apply 1 + random.uintLessThan(u8, 8) byte substitutions
    //       at random offsets; with probability 1/8 truncate to a random length;
    //     frame via sliceCorpusEntry; construct
    //       var smith = std.testing.Smith{ .in = entry };
    //     try body({}, &smith);   // body must tolerate arbitrary input — it
    //                             // already does, that is its contract.
  }
```

Adjust to the real `std.testing.Smith` construction if it differs — the
in-repo exemplar is `src/testing/fuzz.zig:24` (`std.testing.Smith{ .in = entry }`).
Add a unit test for the helper itself: a trivial body that records it was
called `variant_count` times and asserts the input length never exceeds the
frame size, and a determinism check (two runs with the same seed produce the
same first mutated variant — easiest by having the body copy its first input
out to a captured buffer).

**Verify**: `zig build test` → exit 0, helper tests pass.

### Step 2: Wire the four public-entry-point targets

In each of `src/decode.zig`, `src/demux.zig`, `src/alpha.zig`,
`src/animation_decode.zig`: next to the existing `test "fuzz ..."` block, add
a test that builds the same valid input the fuzz test builds (reuse the same
builder calls) and runs the existing body through the helper. Use a distinct
`prng_seed` literal per file (e.g. `0x11d_0001`, `0x11d_0002`, ...) so the
targets explore different corners. Example for `src/decode.zig`:

```zig
test "bounded mutation exploration of static decode" {
    // ... build `encoded` exactly as the fuzz test above does ...
    try testing_fuzz.runMutations(fuzzDecodeStaticOne, encoded, .{ .prng_seed = 0x11d_0001 });
}
```

The existing bodies keep tight `ResourceLimits`, so 128 variants each should
add well under a second in total. Time the suite before and after.

**Verify**: `zig build test` → exit 0, 4 new tests pass; suite wall-clock
delta < ~3 seconds. If it exceeds that, halve `variant_count` and re-measure.

### Step 3 (only if plan 008 is merged): wire the encode targets

Same pattern in `src/encode.zig` and `src/mux.zig` over plan 008's bodies and
seeds. Skip cleanly if plan 008 hasn't landed — check with
`grep -l "std.testing.fuzz" src/encode.zig`.

**Verify**: `zig build test` → exit 0.

### Step 4: If a mutation finds a crash

A panic/leak surfaced by `runMutations` is a real bug and reproducible (fixed
seed). Do NOT fix codec code under this plan. Capture the failing variant
(print its bytes as hex from the helper or re-derive from the seed), STOP, and
report it with the target name, seed, and variant index. A found bug is this
plan *succeeding*, not failing.

### Step 5: Format and final gates

**Verify**: `zig fmt --check .` → exit 0; `zig build test` → exit 0;
`zig build check` → exit 0.

## Test plan

- New unit tests in `src/testing/fuzz.zig`: helper runs exactly
  `variant_count` variants; same seed ⇒ same mutations (determinism).
- One `"bounded mutation exploration of ..."` test per wired module (4 decode
  targets; +2 encode if plan 008 landed), each reusing the module's existing
  fuzz body and valid-input builder.
- Verification: `zig build test` → all pass; total suite slowdown < ~3s.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "pub fn runMutations" src/testing/fuzz.zig` returns 1
- [ ] `grep -rl "runMutations" src/decode.zig src/demux.zig src/alpha.zig src/animation_decode.zig` lists all four files
- [ ] `zig build test` exits 0
- [ ] Suite wall-clock within ~3s of pre-plan baseline (measured warm)
- [ ] `zig fmt --check .` exits 0; `zig build check` exits 0
- [ ] No `std.time`/entropy-seeded PRNG anywhere in the diff (`git diff | grep -i "timestamp\|nanoTime\|std.crypto.random"` → empty)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `PROGRESS.MD` or the canary workflow indicates `zig build test --fuzz` now
  works — real coverage-guided fuzzing supersedes this mechanism; report so
  the maintainer can choose.
- `std.testing.Smith` cannot be constructed directly from bytes (the
  `Smith{ .in = ... }` pattern at `src/testing/fuzz.zig:24` no longer
  compiles) — the whole design rests on it.
- A mutation surfaces a crash (Step 4 — report, don't fix).
- The suite slowdown cannot be brought under ~3s even at `variant_count = 32`
  (report the numbers; the maintainer may prefer a separate build step).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- When upstream Zig fixes the fuzz-instrumentation bug (the weekly canary
  workflow probes it), coverage-guided `--fuzz` becomes available and this
  mechanism becomes the deterministic regression layer beneath it — keep it;
  it guards the seeds' neighborhoods in every CI run, which `--fuzz` (being
  time-budgeted and stochastic) does not.
- If a future change adds a new fuzz target, wire it here too — one
  `runMutations` test per target is the convention this plan establishes.
- Deferred deliberately: growing committed corpora from found inputs (11d's
  other half) — until a crash is actually found there is nothing to commit;
  the STOP-and-report flow in Step 4 feeds that when it happens.
