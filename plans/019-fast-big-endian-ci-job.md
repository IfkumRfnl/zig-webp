# Plan 019: Make the big-endian CI job run in ~3 minutes (ReleaseSafe + 4-way sharding)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 29be0df..HEAD -- build.zig .github/workflows/ci.yml tools/ RELEASING.MD PLAN.MD CHANGELOG.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (custom test runner must preserve leak/skip/fuzz/log
  semantics; the reference implementation below was compiled and
  probe-verified on zig 0.16.0 at planning time — residual risk is the full
  464-test suite through it, plus CI-environment behavior)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `29be0df`, 2026-07-08

## Why this matters

The `big-endian` CI job (`Big-endian tests (powerpc64, QEMU)`) gates every PR
and currently takes 12m49s–16m40s (three most recent runs on 2026-07-08:
12m49s, 13m50s, 16m40s), while every other job finishes in 2m30s–3m30s. The
QEMU test step is ~96% of that time (latest run: 12m17s of 12m49s; checkout +
setup-zig + qemu install ≈ 30s combined). The cause is that the suite runs in
**Debug** mode under qemu TCG emulation: LLVM `-O0` codegen multiplied by
emulation overhead. Measured on the planning machine (same hardware, same
qemu 10.0.8, full 464-test suite on powerpc64):

| Mode | Emulated suite run | Result |
|---|---|---|
| Debug | 18m24s | all tests pass |
| ReleaseSafe | 4m23s (4m59s incl. cold cross-compile) | all 464 pass, exit 0 |

ReleaseSafe alone is ~4.2×. Sharding the suite across 4 parallel qemu
processes (CI runners have 4 vCPUs; qemu user-mode emulation of a
single-threaded test binary uses 1 core) divides the remaining ~4 minutes
again. Expected job total after this plan: **~2.5–3.5 minutes**, on par with
the other jobs. The maintainer approved both changes (2026-07-08): ReleaseSafe
for the BE gate, plus sharding.

Why ReleaseSafe is sound for this gate: the job's purpose is the byte-exact
SHA-256 corpus regression on a big-endian host (RELEASING.MD calls it "the
substantive row"). Decoded bytes are optimize-mode-independent; ReleaseSafe
keeps all runtime safety checks and `std.debug.assert`. Debug coverage is not
lost overall — the `test` (Linux), `macos`, and `wasm` jobs still run Debug.

## Current state

Relevant files:

- `.github/workflows/ci.yml` — the `big-endian` job (lines 63–82) runs
  `zig build test -Dtarget=powerpc64-linux -fqemu` on ubuntu-latest after
  `sudo apt-get install -y qemu-user-static`:

  ```yaml
  # ci.yml:76-82 at 29be0df
        - name: Install QEMU user-mode emulation
          run: |
            sudo apt-get update
            sudo apt-get install -y qemu-user-static

        - name: Run tests on powerpc64 under QEMU
          run: zig build test -Dtarget=powerpc64-linux -fqemu
  ```

- `build.zig` — single test binary with the default runner (lines 163–169),
  plus a `ci` step that reuses `run_unit_tests` (line 222):

  ```zig
  // build.zig:163-169 at 29be0df
  const unit_tests = b.addTest(.{
      .root_module = webp_module,
  });
  const run_unit_tests = b.addRunArtifact(unit_tests);

  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&run_unit_tests.step);
  ```

- `RELEASING.MD:93` — compatibility-matrix row to update:

  ```
  | Big-endian (powerpc64) | `zig build test -Dtarget=powerpc64-linux -fqemu` | CI (`ci.yml` `big-endian` job), every PR | exit 0 |
  ```

- `PLAN.MD:34-40` — portability stance quoting the same command:

  ```
  ... CI additionally runs
  the full test suite on big-endian powerpc64 under user-mode QEMU
  (`zig build test -Dtarget=powerpc64-linux -fqemu`) and on 32-bit
  wasm32-wasi under wasmtime ...
  ```

- `CHANGELOG.MD` — Keep-a-Changelog format; latest section is
  `## [1.0.0] — 2026-07-08`; there is currently no `[Unreleased]` section.

- Test registration: `src/root.zig:524-525` uses
  `std.testing.refAllDecls(@This())`; the suite is 464 tests in one binary,
  including 14 fuzz tests (`std.testing.fuzz(...)` call sites across
  `src/`). Corpus tests read `testdata/` **relative to the cwd** (repo
  root); the current `run_unit_tests` sets no explicit cwd and works, so the
  shard run steps must not set one either.

Zig 0.16.0 facts this plan depends on (verified by reading the installed
toolchain at `lib/std` / `lib/compiler`; re-verify if the pinned Zig version
changes):

1. `b.addTest(.{ .test_runner = .{ .path = ..., .mode = .simple } })` builds
   the test binary with a custom runner that communicates via **exit code**,
   not the `--listen` server protocol (`std.Build.addRunArtifact`,
   `lib/std/Build.zig:962-992`).
2. **Pitfall**: for a *custom* simple-mode runner, `addRunArtifact` adds
   neither server mode nor an exit-code check (`Build.zig:988-991` only adds
   `expectExitCode(0)` when `test_runner == null`). Each shard run step must
   call `run.expectExitCode(0)` explicitly, otherwise a failing shard would
   NOT fail the build.
3. `std.testing.fuzz` dispatches to `@import("root").fuzz`
   (`lib/std/testing.zig:1227-1233`) — root is the test runner, so the custom
   runner **must export `pub fn fuzz`**. The default runner's non-fuzz-mode
   behavior (`lib/compiler/test_runner.zig:596-606`): run `testOne` once per
   corpus entry, then once with empty input.
4. The reference for per-test semantics is the default runner's
   `mainTerminal` (`lib/compiler/test_runner.zig:257-340`): per test it does
   `testing.allocator_instance = .{};`,
   `testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });`,
   `testing.log_level = .warn;`, `testing.environ = init.environ;`, a
   deferred `io_instance.deinit()` + leak check, `error.SkipZigTest`
   handling, error-return-trace dump on failure, and
   `std.process.exit(1)` if `fail_count != 0 or leaks != 0 or log_err_count != 0`.
   It counts error-level logs via `pub const std_options: std.Options = .{ .logFn = log };`.
5. Env lookup without allocation: `init.environ.getPosix("NAME")`
   (`std.process.Environ.getPosix`, returns `?[:0]const u8`).
6. `run.setEnvironmentVariable(key, value)` and `run.expectExitCode(0)` exist
   on `std.Build.Step.Run`.

Known local quirk (do NOT chase it): on a machine **without** binfmt_misc
registration, `zig build test -Dtarget=powerpc64-linux -fqemu` (the *current*,
default-runner command) reports a spurious step failure — trailer
`failed command: qemu-ppc64 .../test --cache-dir=... --seed=... --listen=-`
with a stray `" w"` annotation and **no error message** — even though running
the same binary directly under `qemu-ppc64` prints `All 464 tests passed.`
and exits 0. Reproduced at `29be0df` in both Debug and ReleaseSafe with qemu
10.0.8. It is a zig 0.16 build-runner/server-protocol issue on the explicit
qemu interpreter path; CI is unaffected because `qemu-user-static` registers
binfmt handlers and zig spawns the test binary directly
(`lib/std/Build/Step/Run.zig:1247` spawns argv first; the qemu fallback is
only used when direct spawn fails). The sharded runner in this plan uses
`.simple` mode (no `--listen`), which sidesteps the issue entirely — local
verification of the *sharded* command is reliable.

Repo conventions to match:

- `build.zig` wires runnable artifacts as compact blocks near their step
  definitions; see the `Tool` loop (`build.zig:133-161`). Comment style is
  full-sentence `//` comments explaining *why*.
- Commit messages: imperative, capitalized, no prefixes (e.g.
  `Fix 32-bit Huffman shifts and run wasm32 tests in CI`).
- AGENTS.md: keep `README.MD`/`PLAN.MD` forward-looking state accurate;
  completed work and dated results go in `PROGRESS.MD`. Run `zig build ci`
  before handing back. Zero-dependency policy: the new runner must be pure
  Zig with no new packages (it is).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 |
| Format | `zig fmt .` | exits 0; no unexpected diffs |
| Native suite (default runner, unchanged path) | `zig build test` | exit 0 |
| Native sharded suite | `zig build test -Dtest-shards=4` | exit 0; 4 shard summary lines |
| BE sharded suite under qemu | `zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu` | exit 0 |
| Install qemu (with sudo) | `sudo apt-get install -y qemu-user-static` | `qemu-ppc64-static` on PATH + binfmt registered |
| Install qemu (no sudo, Debian/Ubuntu) | see Step 4 | `qemu-ppc64` symlink on a PATH dir |
| CI observation | `gh run view <run-id> --json jobs` | `big-endian` job success, duration recorded |

## Scope

**In scope** (the only files you should modify/create):

- `tools/shard_test_runner.zig` (create)
- `build.zig` (add `-Dtest-shards` option and shard wiring)
- `.github/workflows/ci.yml` (the `big-endian` job's test command only)
- `RELEASING.MD` (compatibility-matrix BE row + one rationale sentence)
- `PLAN.MD` (portability-stance sentence, lines ~34-40)
- `CHANGELOG.MD` (new `[Unreleased]` section, one `### Changed` bullet)
- `PROGRESS.MD` (dated entry with measured before/after)
- `plans/README.md` (status row for 019)

**Out of scope** (do NOT touch, even though they look related):

- Any file under `src/` — the library and its tests change zero bytes. If a
  test fails under ReleaseSafe/powerpc64, that is a STOP condition, not a fix.
- The `test`, `macos`, and `wasm` CI jobs — they intentionally keep Debug
  (the wasm job is already fast under wasmtime's JIT).
- The `Install QEMU user-mode emulation` step — keep `qemu-user-static`
  (its binfmt registration is what makes zig's direct spawn work in CI).
- `.github/actions/setup-zig` and any toolchain caching (deferred follow-up).
- `PROGRESS.MD` history rewrites — append a new dated entry only.

## Git workflow

- Branch: `advisor/019-fast-big-endian-ci`
- Commit per logical unit (runner + build wiring; CI + docs), imperative
  style matching `git log` (e.g. `Shard big-endian CI tests and run them in ReleaseSafe`).
- Do NOT push or open a PR unless the operator instructed it; Step 7's CI
  observation requires a pushed PR, so ask the operator to push/merge if you
  cannot.

## Steps

### Step 1: Create `tools/shard_test_runner.zig`

Create the file with the following content (this is a complete reference
implementation, mirroring zig 0.16.0's default-runner terminal path; adjust
only if the compiler rejects an API name, and record any adjustment):

```zig
//! Sharded simple-mode test runner (used by `zig build test -Dtest-shards=N`;
//! plans/019). Runs the subset of `builtin.test_functions` whose index `i`
//! satisfies `i % TEST_SHARD_COUNT == TEST_SHARD_INDEX`, so N processes
//! cover the full suite by construction — no name filters, no drift risk.
//!
//! Behavior mirrors the terminal path of Zig 0.16.0's default test runner
//! (`lib/compiler/test_runner.zig`, `mainTerminal`): per-test testing
//! allocator and io instance, leak accounting, `error.SkipZigTest`
//! handling, error-log counting, and a nonzero exit code on any failure,
//! leak, or error log. `pub fn fuzz` mirrors the default runner's
//! non-fuzz-mode behavior (`std.testing.fuzz` dispatches to
//! `@import("root").fuzz`). Re-sync both on Zig upgrades.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    const shard_count = envUsize(init, "TEST_SHARD_COUNT") orelse 1;
    const shard_index = envUsize(init, "TEST_SHARD_INDEX") orelse 0;
    if (shard_count == 0 or shard_index >= shard_count) {
        std.debug.print(
            "invalid shard config: TEST_SHARD_INDEX={d} TEST_SHARD_COUNT={d}\n",
            .{ shard_index, shard_count },
        );
        std.process.exit(1);
    }

    var ran: usize = 0;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    for (builtin.test_functions, 0..) |test_fn, i| {
        if (i % shard_count != shard_index) continue;
        ran += 1;

        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
                std.debug.print("LEAK: {s}\n", .{test_fn.name});
            }
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        if (test_fn.func()) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skip_count += 1,
            else => {
                fail_count += 1;
                std.debug.print("FAIL: {s} ({t})\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    std.debug.print(
        "shard {d}/{d}: ran {d} of {d} tests; {d} passed; {d} skipped; " ++
            "{d} failed; {d} leaked; {d} error logs\n",
        .{
            shard_index,       shard_count, ran,   builtin.test_functions.len,
            ok_count,          skip_count,  fail_count,
            leaks,             log_err_count,
        },
    );
    if (fail_count != 0 or leaks != 0 or log_err_count != 0) {
        std.process.exit(1);
    }
}

/// `std.testing.fuzz` dispatches here via `@import("root")`. Mirrors the
/// default runner's non-fuzz-mode behavior: run every corpus input, then an
/// empty input as a smoke test.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

fn envUsize(init: std.process.Init.Minimal, key: []const u8) ?usize {
    const value = init.environ.getPosix(key) orelse return null;
    return std.fmt.parseUnsigned(usize, value, 10) catch {
        std.debug.print("invalid {s}: {s}\n", .{ key, value });
        std.process.exit(1);
    };
}
```

Formatting/layout of the multi-value print tuple is up to `zig fmt`.

**Verify**: `zig fmt tools/shard_test_runner.zig` → exit 0. This exact code
was verified at planning time on zig 0.16.0 via
`zig test --test-runner shard_test_runner.zig <probe>.zig`: fail probe →
`FAIL: ...` + error-return trace + exit 1; leak probe → `LEAK: ...`,
`1 leaked; 1 error logs`, exit 1; `TEST_SHARD_COUNT=2` split a 2-test file
one test per shard; `TEST_SHARD_INDEX=9 TEST_SHARD_COUNT=4` →
`invalid shard config` + exit 1. A compile error against the pinned
toolchain therefore means drift — see STOP conditions. (Full-suite
compilation through `zig build` is exercised in Step 3.)

### Step 2: Wire `-Dtest-shards` into `build.zig`

Replace the test wiring at `build.zig:163-169` with:

```zig
const unit_tests = b.addTest(.{
    .root_module = webp_module,
});
const run_unit_tests = b.addRunArtifact(unit_tests);

// Optional N-way sharding for slow environments (the big-endian CI job
// runs 4 shards in parallel under QEMU). Sharding uses a custom
// simple-mode runner that partitions tests by index modulo the shard
// count, so N shards cover the full suite by construction. The default
// path (no -Dtest-shards) is unchanged: one binary, default runner.
const test_shards = b.option(
    u32,
    "test-shards",
    "Split `zig build test` across N parallel shard processes",
);

const test_step = b.step("test", "Run unit tests");
if (test_shards) |shard_count| {
    if (shard_count == 0) {
        std.debug.panic("-Dtest-shards must be >= 1", .{});
    }
    const sharded_tests = b.addTest(.{
        .root_module = webp_module,
        .test_runner = .{
            .path = b.path("tools/shard_test_runner.zig"),
            .mode = .simple,
        },
    });
    var shard_index: u32 = 0;
    while (shard_index < shard_count) : (shard_index += 1) {
        const run_shard = b.addRunArtifact(sharded_tests);
        run_shard.setEnvironmentVariable(
            "TEST_SHARD_COUNT",
            b.fmt("{d}", .{shard_count}),
        );
        run_shard.setEnvironmentVariable(
            "TEST_SHARD_INDEX",
            b.fmt("{d}", .{shard_index}),
        );
        // addRunArtifact only adds an exit-code check for the default
        // simple runner; a custom simple-mode runner must request it
        // explicitly or a failing shard would not fail the build.
        run_shard.expectExitCode(0);
        test_step.dependOn(&run_shard.step);
    }
} else {
    test_step.dependOn(&run_unit_tests.step);
}
```

Keep `run_unit_tests` and the `ci` step's `ci_step.dependOn(&run_unit_tests.step)`
(line 222) exactly as they are — `zig build ci` stays native, unsharded,
default-runner.

**Verify**: `zig build test` → exit 0 (default path unchanged), and
`zig build --help | grep test-shards` → shows the option.

### Step 3: Native sharded verification (counts, failure propagation, leak path)

1. `zig build test -Dtest-shards=4 2>&1 | tee /tmp/shards.log` → exit 0.
2. Coverage-by-construction check — the four `ran X of T` numbers must sum
   to `T` (T is 464 at `29be0df`; use whatever T the summaries print):
   `grep -o 'ran [0-9]* of [0-9]*' /tmp/shards.log` → 4 lines; sum of the
   first numbers == the (identical) second number.
3. `zig build test -Dtest-shards=1` → exit 0, one summary line,
   `ran T of T`.
4. Failure propagation — create `/tmp/probe_fail.zig` (outside the repo):

   ```zig
   test "passes" {}
   test "fails" {
       try @import("std").testing.expect(false);
   }
   ```

   Run `zig test --test-runner tools/shard_test_runner.zig /tmp/probe_fail.zig`
   → prints `FAIL: ...`, summary shows `1 failed`, **exit code 1**
   (`echo $?`). This proves a red test turns into a nonzero exit, which
   `expectExitCode(0)` then turns into a build failure.
5. Leak propagation — create `/tmp/probe_leak.zig`:

   ```zig
   test "leaks" {
       _ = try @import("std").testing.allocator.alloc(u8, 16);
   }
   ```

   Same invocation → prints `LEAK: ...`, exit code 1.
6. Misconfig guard:
   `TEST_SHARD_COUNT=4 TEST_SHARD_INDEX=9 zig test --test-runner tools/shard_test_runner.zig /tmp/probe_fail.zig`
   → `invalid shard config` message, exit 1.

**Verify**: all six checks as stated. Also `zig build ci` → exit 0 (fmt,
compile, native default-runner tests all still green).

### Step 4: Local big-endian proof under qemu

If you have sudo: `sudo apt-get install -y qemu-user-static`. Without sudo
(as on the planning machine):

```sh
mkdir -p /tmp/qemu && cd /tmp/qemu
apt-get download qemu-user
dpkg -x qemu-user_*.deb root
mkdir -p bin && ln -sf /tmp/qemu/root/usr/bin/qemu-ppc64 bin/qemu-ppc64
export PATH=/tmp/qemu/bin:$PATH
qemu-ppc64 --version   # sanity
```

Then from the repo root:

```sh
time zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu
```

Expected: exit 0; four shard summaries with zero failed/leaked; the four
`ran` counts sum to the full suite count. Wall time on 4 cores should be
roughly 1.5–3 minutes (single-shard ReleaseSafe baseline measured 4m23s).
Record the wall time for the PROGRESS.MD entry.

Note: do NOT be alarmed if the *unsharded* command
(`zig build test -Dtarget=powerpc64-linux -fqemu`, no `-Dtest-shards`) shows
the known spurious `failed command:` trailer on a non-binfmt machine — that
is the pre-existing local quirk documented in "Current state", not caused by
your change, and not a STOP condition. The sharded path does not use the
`--listen` protocol and is immune.

**Verify**: command above → exit 0, counts sum, time recorded.

### Step 5: Update the CI job

In `.github/workflows/ci.yml`, change only the last step of the `big-endian`
job (lines 81–82 at `29be0df`):

```yaml
      - name: Run tests on powerpc64 under QEMU (ReleaseSafe, 4 shards)
        run: zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu
```

Also extend the job's leading comment (lines 63–65) with one sentence, e.g.:
`# ReleaseSafe (safety checks stay on) and 4-way sharding keep the emulated
run to minutes; see plans/019 and RELEASING.MD for the rationale.`

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`
→ exit 0 (or any YAML parse check available).

### Step 6: Update the docs

1. `RELEASING.MD:93` — replace the BE row's check command with
   `zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu`.
   In the paragraph below (lines 97–100), append one sentence: the run is
   ReleaseSafe (runtime safety checks and assertions stay enabled; decoded
   bytes and the SHA-256 corpus comparison are optimize-mode-independent)
   and sharded 4-way for speed; Debug coverage remains on the native jobs.
2. `PLAN.MD:34-40` — update the quoted command in the portability stance to
   the same string, adding a clause like: `(ReleaseSafe, sharded 4-way so the
   emulated gate stays fast; native jobs keep Debug)`.
3. `CHANGELOG.MD` — insert above the `## [1.0.0]` section:

   ```markdown
   ## [Unreleased]

   ### Changed

   - The big-endian CI job runs the full suite in ReleaseSafe split across
     four parallel QEMU shard processes (was: Debug, single process),
     cutting the job from ~13-17 min to ~3 min. Same 464 tests, safety
     checks still on; native jobs still run Debug.
   ```

4. `PROGRESS.MD` — append a dated entry (match existing entry style): the
   measured numbers (CI before: 12m49s-16m40s; local Debug 18m24s vs
   ReleaseSafe 4m23s; local sharded time from Step 4; CI after from Step 7),
   plus a note of the local-qemu `--listen` quirk and that the sharded
   runner sidesteps it.

**Verify**: `grep -n "test-shards=4" RELEASING.MD PLAN.MD CHANGELOG.MD .github/workflows/ci.yml`
→ all four hit. `zig build ci` → exit 0 (fmt check covers the new file).

### Step 7: CI observation

Push the branch / open a PR (operator permitting). Confirm the
`Big-endian tests (powerpc64, QEMU)` job is green and record its duration
(`gh run view <run-id> --json jobs`). Expect ~2.5–4 minutes total. Update the
PROGRESS.MD entry and the plans/README.md status row with the observed time.

**Verify**: job conclusion `success`; duration recorded.

## Test plan

No new committed Zig tests: the deliverable is CI/build infrastructure, and
its contract is machine-checked by Step 3's six probes (count-sum coverage
guard, failure propagation, leak propagation, misconfig guard) plus the
existing 464-test suite running unmodified through the new runner natively
(Step 3) and on powerpc64/ReleaseSafe (Step 4) and in CI (Step 7). The probe
files live in `/tmp` and are not committed — record their outputs in the PR
description or PROGRESS.MD entry.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0 (fmt + compile + native default-runner suite).
- [ ] `zig build test` (no options) behavior unchanged: single default-runner
      run step, exit 0.
- [ ] `zig build test -Dtest-shards=4` exits 0 and the shard `ran` counts sum
      to the full suite count.
- [ ] Failure/leak/misconfig probes (Step 3.4–3.6) produce exit code 1.
- [ ] `zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu`
      exits 0 locally under qemu.
- [ ] CI `big-endian` job green with the new command; duration ≤ 6 minutes
      (expected ~3).
- [ ] `grep -n "test-shards=4" RELEASING.MD PLAN.MD CHANGELOG.MD .github/workflows/ci.yml` → 4 files hit.
- [ ] `git status` shows no modifications outside the in-scope list.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- Any test fails, crashes, or leaks under `-Doptimize=ReleaseSafe` on
  powerpc64 (Step 4) or in CI (Step 7) while the same suite passes in Debug —
  that is a real optimize-mode or endianness bug in the library, a valuable
  finding that must be reported, never patched inside this plan. (For
  calibration: at `29be0df` the full ReleaseSafe suite passed on powerpc64 —
  464/464, direct qemu run, exit 0.)
- The shard `ran` counts do not sum to the full suite count, or a shard
  reports `ran 0` — the modulo partition is broken; do not ship a gate with
  a coverage hole.
- The reference runner fails to compile against the pinned Zig and the fix
  is not a mechanical API-name adjustment — the `Init.Minimal` /
  `io_instance` / `fuzz` contracts may have drifted; report the compile
  error and the toolchain version.
- `expectExitCode(0)` on the shard run steps does not fail the build for the
  failing probe (re-test via a temporary always-fail test in a scratch
  checkout if unsure) — the gate would be green-while-broken.
- The CI job with the new command exceeds 8 minutes — the speedup did not
  materialize on CI hardware; report measured numbers instead of stacking
  more changes.

## Maintenance notes

- **Zig upgrades**: `tools/shard_test_runner.zig` mirrors two contracts of
  the default runner (`lib/compiler/test_runner.zig` in the toolchain):
  per-test setup/teardown in `mainTerminal`, and the `pub fn fuzz` non-fuzz
  path. On every toolchain bump (AGENTS.md says compiler upgrades land as
  dedicated changes), diff those two spots and re-run Step 3's probes.
- The shard count (4) matches GitHub's 4-vCPU ubuntu runners. If runner
  sizes change, adjust `-Dtest-shards` in ci.yml only — no code change.
- Reviewers should scrutinize: the `expectExitCode(0)` calls (silent-green
  risk), and that `ci_step` still depends on the *default* runner path.
- Known upstream issue worth filing (deferred, not this plan): zig 0.16's
  build runner reports a spurious `failed command:` with a stray `" w"`
  annotation (`lib/compiler/build_runner.zig:1170-1173` prints a literal
  `" w"` when a step fails with empty error messages and non-empty stderr)
  for `--listen` test runs under an explicit qemu interpreter, even when all
  tests pass. Evidence: reproduced at `29be0df` in Debug and ReleaseSafe,
  qemu 10.0.8, no binfmt; the same binaries pass with exit 0 when run
  directly under qemu.
- Deferred follow-ups (explicitly out of this plan): caching `~/.cache/zig`
  in CI (~1 min/job), applying ReleaseSafe/sharding to the wasm job (already
  ~2.5 min), and sharding native jobs (not worth the coverage-risk surface
  when they already run in ~2 min).
