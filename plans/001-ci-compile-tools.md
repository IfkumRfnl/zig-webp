# Plan 001: Make CI compile the CLI tools so they cannot break silently

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1aa7670..HEAD -- build.zig .github/workflows/ci.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `1aa7670`, 2026-06-13

## Why this matters

The project's correctness story rests on differential oracle runs driven by
four CLI tools (`tools/zig-webp-decode.zig`, `tools/zig-webp-alpha.zig`,
`tools/zig-webp-yuv.zig`, `tools/zig-webp-corpus-hashes.zig`) via
`tools/webp-oracle.sh`. CI currently runs only `zig fmt --check .` and
`zig build test`, and `zig build test` compiles only the `webp` module — the
tool executables are built only when their own build steps (`decode`,
`alpha`, `yuv`, `corpus-hashes`) are invoked. A refactor of any `src/` API
the tools use can merge green and break the oracle tooling silently; the
breakage is then discovered at the worst time — during an oracle run that
gates a decoder milestone. After this plan, one build step compiles the
library and all four tools, and CI runs it on every PR.

## Current state

- `build.zig` — defines the build graph. The `check` step compiles only the
  library; the `test` step runs only the unit tests:

```zig
// build.zig:21-22
    const check_step = b.step("check", "Compile the library");
    check_step.dependOn(&webp_library.step);
```

```zig
// build.zig:102-109
    const unit_tests = b.addTest(.{
        .root_module = webp_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
```

- The four tool executables are created with `b.addExecutable(...)` and
  stored in `const decode_tool` (build.zig:24), `const alpha_tool`
  (build.zig:42), `const yuv_tool` (build.zig:61), and
  `const corpus_hashes_tool` (build.zig:80). Each is a
  `*std.Build.Step.Compile`; none is a dependency of `check` or `test`.

- `.github/workflows/ci.yml` — the only CI workflow:

```yaml
# .github/workflows/ci.yml:19-28
      - name: Check formatting
        run: zig fmt --check .

      # The unit test suite includes the hash-based corpus regression:
      # decoded RGBA and alpha planes of the committed corpus are compared
      # against SHA-256 hashes in testdata/corpus-hashes.tsv, so CI needs
      # no dwebp. Full dwebp/cwebp differential runs stay local via
      # tools/webp-oracle.sh.
      - name: Run tests
        run: zig build test
```

- Convention: this repo treats `zig build check` as "does everything
  compile". Extending `check` (rather than `test`) keeps `zig build test`
  semantics unchanged.

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|--------------------------|---------------------|
| Format | `zig fmt .` | exit 0 |
| Compile check | `zig build check --summary all` | exit 0; summary lists the four tool compile steps |
| Tests | `zig build test` | exit 0, no output |

(Verified during recon on Zig 0.16.0.)

## Scope

**In scope** (the only files you should modify):
- `build.zig`
- `.github/workflows/ci.yml`

**Out of scope** (do NOT touch, even though they look related):
- `tools/*.zig` — if a tool fails to compile, that is a STOP condition, not
  something to fix here.
- `src/**` — no library changes.
- `tools/webp-oracle.sh` — the shell driver is unaffected.

## Git workflow

- Branch: `claude/ci-compile-tools`
- Single imperative commit, e.g. `Make zig build check compile the CLI tools and run it in CI`
  (matches repo history style: `Add VP8 full-frame reconstruction with YUV oracle tooling`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extend the `check` step to compile all four tools

In `build.zig`, the `check_step` is declared at line 21, *before* the tool
executables are declared. Move the `check_step` declaration and its
`dependOn` lines to **after** the last tool declaration (after the
`corpus_hashes_step` block, around line 100), so all four compile steps are
in scope, and add the dependencies:

```zig
    const check_step = b.step("check", "Compile the library and tools");
    check_step.dependOn(&webp_library.step);
    check_step.dependOn(&decode_tool.step);
    check_step.dependOn(&alpha_tool.step);
    check_step.dependOn(&yuv_tool.step);
    check_step.dependOn(&corpus_hashes_tool.step);
```

Delete the original two-line `check_step` block at lines 21-22.

**Verify**: `zig build check --summary all` → exit 0, and the summary tree
lists compile steps for `zig-webp-decode`, `zig-webp-alpha`, `zig-webp-yuv`,
and `zig-webp-corpus-hashes`.

### Step 2: Run the check step in CI

In `.github/workflows/ci.yml`, add a step between "Check formatting" and
"Run tests":

```yaml
      # Compiles the library and the four CLI tools that back
      # tools/webp-oracle.sh, so tool breakage cannot merge silently.
      - name: Compile library and tools
        run: zig build check
```

**Verify**: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` → exit 0
(if python3/yaml is unavailable, verify indentation matches the sibling
steps exactly: 6 spaces before `-`).

### Step 3: Format and full test pass

**Verify**: `zig fmt --check .` → exit 0, and `zig build test` → exit 0.

## Test plan

No new tests — this plan changes the build graph and CI only. The
verification gates above are the test: the `check` summary must show all
four tool compile steps, and the existing suite must still pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build check --summary all` exits 0 and its summary names all four tool binaries
- [ ] `zig build test` exits 0
- [ ] `zig fmt --check .` exits 0
- [ ] `grep -c "check_step.dependOn" build.zig` returns `5`
- [ ] `grep -n "zig build check" .github/workflows/ci.yml` returns exactly one match
- [ ] `git status --porcelain` shows only `build.zig`, `.github/workflows/ci.yml`, and `plans/README.md` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any tool fails to compile under `zig build check` — that means a tool is
  *already* broken at HEAD; report which tool and the compile error. Do not
  fix the tool in this plan.
- `build.zig` no longer matches the "Current state" excerpts (drift).
- Moving the `check_step` declaration changes any other step's behavior
  (e.g. a step that referenced `check_step` earlier in the file — there is
  none at planning time).

## Maintenance notes

- Any future tool added under `tools/` must get a
  `check_step.dependOn(&<tool>.step);` line — reviewers should ask for it.
- If `zig build check` becomes slow as tools grow, CI can drop the separate
  step and instead make `test_step` depend on the tool compiles; keep one or
  the other, never neither.
- Deferred: compiling `tools/webp-oracle.sh`'s dependencies (dwebp/cwebp)
  in CI is deliberately out of scope (documented decision in PLAN.MD —
  CI must not require libwebp tools).
