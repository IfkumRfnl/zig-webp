# Plan 014: WASM (wasm32) build spike — prove the library compiles and passes tests on wasm32-wasi

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This is a **spike**: the primary deliverable is
> verified knowledge (recorded in PROGRESS.MD) plus the smallest CI gate that
> proved true — not a polished feature. When done, update the status row in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- build.zig .github/workflows/ci.yml src/limits.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S (spike; timebox ~half a day of agent work)
- **Risk**: LOW (additive build step + CI job; no library code changes allowed)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

zig-webp is pure Zig, zero-dependency, no-libc (`build.zig` sets
`.link_libc = false`), with caller-controlled allocation and explicit
resource limits — exactly the profile that makes a WebAssembly build
disproportionately cheap, and a differentiated deployment story versus
emscripten-built libwebp. The maintainer recorded this as a direction option
on 2026-07-04. The open questions are narrow: does everything compile and
behave on a 32-bit `usize` target, and can the test suite actually run under
a wasm runtime? This spike answers both and locks the answer in CI so it
cannot silently rot.

## Current state

- `build.zig` — one module (`webp`, root `src/root.zig`), a static library
  artifact, eleven CLI tools built from a `tools` array, a `check` step that
  compiles the library and all tools, `test`/`ci` steps. There is no
  target-override or wasm-specific step. Relevant excerpt:

  ```zig
  // build.zig:7
  const webp_module = b.addModule("webp", .{
      .root_source_file = b.path("src/root.zig"),
      .target = target,
      .optimize = optimize,
      .link_libc = false,
  });
  ```

  Note: the standard `-Dtarget=` option changes `target` for EVERYTHING,
  including the CLI tools (which use `std.process.Init` and file I/O). The
  library itself has no OS dependencies; the tools might not build for wasm.
  So the wasm gate should compile the **library module only**, via a
  dedicated step that resolves its own wasm target instead of reusing
  `-Dtarget` (see step 2).

- `src/limits.zig:50-58` — `pixelCount` caps `width*height` at
  `maxInt(u32)`, so pixel counts always fit a 32-bit `usize`; byte-size
  arithmetic throughout the library is done in `u64` with checked
  conversions (the step-11a hardening audit verified overflow-checked
  arithmetic on every public decode path). A 32-bit target should therefore
  work, but "should" is what this spike tests.

- `.github/workflows/ci.yml` — single `test` job on ubuntu-latest:
  `zig fmt --check .`, `zig build check`, `zig build test`. Zig is installed
  by the local composite action `./.github/actions/setup-zig` (version
  `0.16.0`).

- The unit test suite includes corpus tests that read files under
  `testdata/` via `std.Io` — running tests under a wasm runtime requires the
  runtime to preopen the repo directory (wasmtime: `--dir .`).

- Zig 0.16.0 can run wasi test binaries via the `-fwasmtime` build flag when
  `wasmtime` is on PATH.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Baseline | `zig build ci` | exit 0 |
| Wasm compile gate (after step 2) | `zig build wasm-check` | exit 0 |
| Wasm test run (experiment) | `zig build test -Dtarget=wasm32-wasi -fwasmtime` | exit 0 IF tools compile for wasi and wasmtime cooperates — treat failure as data, not defeat; see step 3 |
| Install wasmtime locally | `curl https://wasmtime.dev/install.sh -sSf \| bash` | `wasmtime --version` works |

## Scope

**In scope** (the only files you should modify):

- `build.zig` — add a `wasm-check` step (and, only if step 3 succeeds
  cleanly, a wasm test step).
- `.github/workflows/ci.yml` — add a wasm job.
- `PROGRESS.MD` — the spike's findings (dated).
- `PLAN.MD` — one sentence in the portability stance if wasm becomes a
  CI-covered target.
- `README.MD` — one sentence only if the test suite (not just compile)
  passes on wasm.
- `plans/README.md` — status row.

**Out of scope** (do NOT touch):

- ANY file under `src/` or `tools/`. If wasm compilation or tests fail
  because of library code, that is the spike's finding — record it precisely
  (file, line, error) and stop. Fixing it is a follow-up plan.
- A JS/browser demo, npm packaging, `wasm32-freestanding` exports, or a
  custom allocator story. Record them as follow-ups.

## Git workflow

- Branch: `wasm32-spike` (repo convention: `<slug>`).
- Commit style: single imperative summary line, e.g.
  `Add wasm32 compile gate and record wasm spike findings`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Compile experiment (no repo changes yet)

From the repo root, check whether the library module alone compiles for
wasm32. The cheapest probe without touching build.zig:

```sh
zig build-lib src/root.zig -target wasm32-wasi -O ReleaseSmall --name zig-webp-wasm -femit-bin=/dev/null
zig build-lib src/root.zig -target wasm32-freestanding -O ReleaseSmall --name zig-webp-wasm-fs -femit-bin=/dev/null
```

Record for each: exit code and, on failure, the first full error with
file:line. Expected: wasi compiles; freestanding may fail if anything pulls
in OS facilities (that failure is a finding, not a bug to fix — the testing
modules referenced from `src/root.zig` read files, so freestanding may need a
narrower root; record that).

**Verify**: both commands run; results captured verbatim for PROGRESS.MD.

### Step 2: Add a `wasm-check` build step

In `build.zig`, add a step that compiles the library for wasm32-wasi
regardless of the user's `-Dtarget`, by resolving an explicit query:

```zig
const wasm_target = b.resolveTargetQuery(.{
    .cpu_arch = .wasm32,
    .os_tag = .wasi,
});
const webp_wasm_module = b.createModule(.{
    .root_source_file = b.path("src/root.zig"),
    .target = wasm_target,
    .optimize = .ReleaseSmall,
    .link_libc = false,
});
const webp_wasm_library = b.addLibrary(.{
    .name = "zig-webp-wasm",
    .root_module = webp_wasm_module,
    .linkage = .static,
});
const wasm_check_step = b.step("wasm-check", "Compile the library for wasm32-wasi");
wasm_check_step.dependOn(&webp_wasm_library.step);
```

(Adapt to the exact 0.16.0 build API if a call differs — the existing
`build.zig` is the authority on idiom; do not guess new APIs beyond it.)
Only add wasi; add freestanding only if step 1 showed it compiles.
Do NOT make `check` or `ci` depend on it yet — wire CI explicitly (step 4)
so a wasm breakage is visibly a wasm job failure, not a mystery `ci` failure.

**Verify**: `zig build wasm-check` → exit 0; `zig build ci` → still exit 0.

### Step 3: Test-suite experiment under wasmtime (timeboxed)

With wasmtime installed:

```sh
zig build test -Dtarget=wasm32-wasi -fwasmtime
```

Three plausible outcomes — all acceptable spike results:

1. **Passes**: the full suite (including corpus file reads and the 32-bit
   `usize` arithmetic everywhere) is wasm-verified. Add a build step or CI
   line for it, update README per Scope.
2. **Fails building the tools**: `-Dtarget` rebuilds the CLI tools too. If
   tool code (not library code) is what fails, record it; the compile gate
   from step 2 remains the CI deliverable, and running the *unit tests only*
   on wasm needs a build.zig test step bound to the wasm module — add one
   ONLY if it is a small, obvious edit mirroring the existing `unit_tests`
   block; otherwise record as follow-up.
3. **Fails in the runtime** (preopen/dir access, wasmtime flags): try
   ~two variations (e.g. running the emitted test binary manually with
   `wasmtime --dir . <binary>`); if still failing, record exactly what broke
   and keep compile-only.

Timebox: if this step exceeds roughly a dozen command iterations, stop
experimenting and record the state.

**Verify**: the outcome (whichever) is written down with the exact commands
and errors, ready for PROGRESS.MD.

### Step 4: CI job + findings

- Add a `wasm` job to `.github/workflows/ci.yml` (checkout + setup-zig +
  `zig build wasm-check`; plus the test run only if step 3's outcome 1 or 2
  produced a green command).
- `PROGRESS.MD`: dated spike entry — what compiles (wasi/freestanding), what
  runs, 32-bit findings (ideally: "test suite passed under wasmtime — 32-bit
  usize verified" or the precise failure), and the follow-up list (browser
  demo, freestanding export surface, allocator story).
- `PLAN.MD` portability sentence + `plans/README.md` row.

**Verify**: `zig build ci` → exit 0; workflow YAML parses.

## Test plan

The spike runs the existing suite on a new target; it adds no new test
content. The permanent artifact is the `wasm-check` compile gate (plus the
wasm test run if it proved green).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build wasm-check` exits 0.
- [ ] `zig build ci` still exits 0.
- [ ] `.github/workflows/ci.yml` contains a wasm job running `wasm-check`.
- [ ] PROGRESS.MD contains the dated spike findings, including the
      freestanding result and the wasmtime test outcome (pass, or exact
      failure).
- [ ] No files under `src/` or `tools/` modified (`git status`).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- `src/root.zig` (the library, not the tools/test harness) fails to compile
  for wasm32-wasi — record the error verbatim; fixing library code is out of
  scope for the spike.
- Any test fails under wasmtime for an arithmetic/32-bit reason (integer
  overflow panic, `@intCast` failure): that is a real 32-bit portability bug
  — the single most valuable thing this spike can find. Report file:line and
  stop.
- The 0.16.0 build API doesn't match the step-2 sketch and the fix isn't
  obvious from the existing `build.zig` idioms after two attempts.

## Maintenance notes

- Follow-ups deliberately out of this spike: a `wasm32-freestanding` export
  surface with an explicit allocator handoff (pairs with plan 015's C-ABI
  design — a wasm JS embedding and a C caller want the same
  caller-owned-buffer API from plan 012); an npm-publishable demo; binary
  size reporting for the wasm artifact (ReleaseSmall size is a marketable
  number — record it in PROGRESS.MD if you have it).
- If the wasm job ever starts failing on a Zig upgrade, that's the toolchain
  policy (PLAN.MD) doing its job — treat it as part of the upgrade commit.
