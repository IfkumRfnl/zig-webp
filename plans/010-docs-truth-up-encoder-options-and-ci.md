# Plan 010: Fix public docs that contradict the shipped encoder, and give contributors a CI-mirroring command

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5d6ed3c..HEAD -- src/options.zig src/root.zig README.MD AGENTS.md build.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW (comments/docs plus one additive build step)
- **Depends on**: none
- **Category**: docs / dx
- **Planned at**: commit `5d6ed3c`, 2026-07-04

## Why this matters

The public option type tells callers that four shipped, tested encoder
features are no-ops, and the module-level doc says the library only decodes
lossless stills — both many roadmap steps out of date (the encoder work landed
in steps 8b/8c, June 2026; these comments predate it). Wrong docs are worse
than missing docs: a caller reading `EncoderOptions` will avoid `target_size`,
`method`, `target_psnr`, and `use_sharp_yuv` even though they work and are
covered by tests. Separately, the README has no consumer install flow for a
published 0.1.0 package, and both README and AGENTS.md omit one of CI's three
gates (`zig build check`), so a contributor following the docs can pass
locally and fail CI. This plan makes the docs match reality and adds a single
`zig build ci` command that mirrors the full CI gate set.

## Current state

### A. Stale "not yet honored" option docs — `src/options.zig:22-47`

The comments below are FALSE at head; the cited `src/encode.zig` lines are
where each knob is consumed:

```zig
// src/options.zig:27-31 — but src/encode.zig:280 passes `.method = encode_options.method`
/// ... The lossy default 4
/// matches the step-8b gate's `cwebp -q 75 -m 4`. Scaffolded for step 8c-1;
/// not yet honored — the encoder uses its fixed RD search regardless.
method: u8 = 4,
// src/options.zig:32-35 — but src/encode.zig:170-176 runs the size search
/// Target output size in bytes. When set, the encoder iterates quality to
/// land within tolerance of this size. Scaffolded for step 8c-3; not yet
/// honored — `quality` alone selects the quantizer.
target_size: ?u32 = null,
// src/options.zig:36-39 — but src/encode.zig:181-188 runs the PSNR search
/// Target reconstructed luma PSNR in dB. When set, the encoder iterates
/// quality to reach it. Mutually exclusive with `target_size`. Scaffolded
/// for step 8c-3; not yet honored.
target_psnr: ?f32 = null,
// src/options.zig:45-47 — but src/encode.zig:145 branches on it
/// Use sharp (iterative) RGB→YUV chroma downsampling instead of the box
/// average. Scaffolded for step 8c-4; not yet honored.
use_sharp_yuv: bool = false,
```

The `alpha_quality` comment (`src/options.zig:40-44`) is accurate — use its
tone as the model. Ground truth for behavior: `src/encode.zig:64-110` (the
`encodeStaticLossy` doc comment describes the honored semantics of every knob,
including the search bounds and the both-targets-set error) and the tests near
`src/encode.zig:1132`.

### B. Stale module and function docs — `src/root.zig`

```zig
// src/root.zig:1-14 (module doc; lines 4-5 are false, list is incomplete)
//! Most callers need only a handful of names:
//! - `decodeStatic` — decode a complete WebP file to pixels
//!   (still lossless only at present; see PLAN.MD step 5 for lossy).
...
```

Reality: `decodeStatic` decodes lossless, lossy, and lossy+alpha (its own doc
at `src/root.zig:372-378` is accurate); the headline exports `encodeLossless`
(:314), `encodeLossy` (:351), `decodeAnimation` (:394), and the animation
encoders (:252-297) are missing from the list.

```zig
// src/root.zig:232-234 (encodeStatic doc; the second sentence is false)
/// Muxes an already-encoded VP8/VP8L bitstream (`StaticImage`) into a
/// canonical WebP file. It does not encode pixels — bitstream encoders are
/// future work. Returns caller-owned bytes (free with the same allocator).
```

Reality: the pixel encoders exist; the right framing is "it does not encode
pixels — use `encodeLossless`/`encodeLossy` for that."

```zig
// src/root.zig:303-305 (encodeLossless doc; the parenthetical is false)
/// ... (single global
/// prefix-code group, no color cache yet; see PLAN.MD step 7), so the output is
/// valid and round-trips bit-exactly.
```

Reality: step 7 slice 3 delivered the optional color cache and the entropy
image / multiple prefix groups (meta-prefix), each chosen by measured encoded
size (see `PROGRESS.MD`, "Step 7 — VP8L Lossless Encoder (slice 3)").

### C. README gaps — `README.MD`

- The "Use" section (`README.MD:85-96`) lists only in-repo dev commands; the
  only consumer-facing line is `README.MD:96`: "The package exposes the `webp`
  module from `src/root.zig`." There is no `zig fetch` / `b.dependency` /
  `addImport` example. The module name is `webp` (`build.zig:7`:
  `b.addModule("webp", ...)`) and `build.zig.zon` has `.version = "0.1.0"`
  (check the `.name` field there for the dependency key to use in the example).
- `README.MD:111-112`: "CI runs `zig fmt --check .` and `zig build test` on
  every pull request." — omits the third gate, `zig build check`
  (`.github/workflows/ci.yml:28`).

### D. AGENTS.md gap — `AGENTS.md:54`

"Run `zig fmt .` and `zig build test` before handing work back." — omits
`zig build check`. CI's actual gates (`.github/workflows/ci.yml:22-36`):
`zig fmt --check .`, `zig build check`, `zig build test`.

### E. No aggregate build step — `build.zig`

`build.zig` defines `check` (line 130) and `test` (line 168) steps plus
per-tool run steps; nothing runs the full CI set in one command. Zig's build
system has `b.addFmt(.{ .paths = &.{"."}, .check = true })` for a
formatting-check step.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Tests | `zig build test` | exit 0 |
| Tool compile | `zig build check` | exit 0 |
| Format | `zig fmt .` / `zig fmt --check .` | exit 0 |
| New aggregate (after Step 5) | `zig build ci` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/options.zig` (doc comments only)
- `src/root.zig` (doc comments only)
- `README.MD` (Use section + CI sentence)
- `AGENTS.md` (line 54 command list)
- `build.zig` (one additive `ci` step)

**Out of scope** (do NOT touch, even though they look related):
- `PLAN.MD` / `PROGRESS.MD` — accurate and maintainer-owned; PROGRESS is the
  history log, do not "fix" it.
- `CHANGELOG.MD`, `RELEASING.MD` — verified accurate at planning time.
- Any behavior change anywhere. This plan changes zero semantics; if fixing a
  comment seems to require changing code, the comment is telling you something
  — STOP.
- `.github/workflows/ci.yml` — CI itself is correct; the docs are what drift.

## Git workflow

- Branch: `claude/docs-truth-up-8c` (repo convention: `claude/` prefix).
- Commit style: short imperative summary, e.g. `Truth up encoder option docs and CI commands`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the four option docs in `src/options.zig`

Rewrite each stale comment to describe the honored behavior, sourcing the
semantics from `src/encode.zig:64-110`'s doc comment. Keep the step
references (they're the repo's style — e.g. "(step 8c-1)") but drop every
"not yet honored"/"Scaffolded" clause. Accuracy requirements per knob:
- `method`: 0..6, `cwebp -m` compatible; scales the RD search; default 4
  matches the 8b gate; **methods 5–6 currently clamp to 4** (that caveat is
  real — keep it; see `PROGRESS.MD` step 8c summary).
- `target_size`: bounded quantizer search (up to 8 passes) toward the byte
  size; mutually exclusive with `target_psnr` (both set ⇒
  `error.InvalidEncodeOptions` — verify the exact error name at
  `src/encode.zig:113`).
- `target_psnr`: same search toward a minimum luma PSNR; same exclusivity.
- `use_sharp_yuv`: iterative sharp RGB→YUV chroma (step 8c-4) instead of box
  averaging.

**Verify**: `grep -n "not yet honored" src/options.zig` → no matches;
`zig build test` → exit 0.

### Step 2: Fix `src/root.zig` module doc (lines 1-14)

Remove the "(still lossless only at present; see PLAN.MD step 5 for lossy)"
parenthetical and extend the "most callers need" list to include
`decodeAnimation`, `encodeLossless`, `encodeLossy` (one line each, matching
the existing list's voice). Keep the list short — headline names only, not
all eight encode functions.

**Verify**: `grep -n "lossless only at present" src/root.zig` → no matches.

### Step 3: Fix the two stale function docs in `src/root.zig`

- `:232-234` (`encodeStatic`): replace "bitstream encoders are future work"
  with a pointer to `encodeLossless`/`encodeLossy`.
- `:303-305` (`encodeLossless`): replace "(single global prefix-code group, no
  color cache yet; see PLAN.MD step 7)" with the delivered feature set: LZ77 +
  decision-gated subtract-green/color/predictor/palette transforms, optional
  color cache, and optional meta-prefix (multiple prefix groups), each chosen
  by measured encoded size.

**Verify**: `grep -n "no color cache yet\|future work" src/root.zig` → no
matches; `zig build test` → exit 0.

### Step 4: Add an Install section to `README.MD` and fix the CI sentence

- Before the "Use" section's command list, add an "Install" subsection:
  `zig fetch --save git+https://github.com/IfkumRfnl/zig-webp` (derive the
  exact URL from `git remote get-url origin`), then the consumer `build.zig`
  snippet:

  ```zig
  const webp_dep = b.dependency("zig_webp", .{ .target = target, .optimize = optimize });
  exe.root_module.addImport("webp", webp_dep.module("webp"));
  ```

  Use the dependency name that matches `build.zig.zon`'s `.name` field (read
  it — the `b.dependency("...")` key must be that name, not a guess), and show
  a one-line usage: `const webp = @import("webp");`.
- Update `README.MD:111-112` to name all three CI gates — or, after Step 5,
  simply: "CI runs `zig build ci` (format check, library+tool compile, full
  test suite) on every pull request." Keep whichever reads better with the
  surrounding paragraph, but it must mention `zig build check` or `zig build ci`.

**Verify**: `grep -n "zig fetch" README.MD` → one match;
`grep -n "build check\|build ci" README.MD` → at least one match.

### Step 5: Add the `zig build ci` aggregate step and point AGENTS.md at it

In `build.zig`, after the existing `test_step` wiring (line ~168), add:

```zig
const fmt_check = b.addFmt(.{ .paths = &.{"."}, .check = true });
const ci_step = b.step("ci", "Run the full CI gate set: fmt check, compile, tests");
ci_step.dependOn(&fmt_check.step);
ci_step.dependOn(check_step);
ci_step.dependOn(&run_unit_tests.step);
```

(Adjust to the actual `std.Build.addFmt` API on Zig 0.16.0 if the signature
differs — `zig build --help` after adding it, and check `.check = true`
exists; if `addFmt` is unavailable on 0.16.0, fall back to a
`b.addSystemCommand(&.{ "zig", "fmt", "--check", "." })` step.) Note
`addFmt`'s paths will include `references/` if present locally — if the fmt
check fails on vendored reference clones, scope `.paths` to
`&.{ "src", "tools", "build.zig" }` instead.

Then update `AGENTS.md:54` to: "Run `zig build ci` (or `zig fmt .` plus
`zig build check` plus `zig build test`) before handing work back."

**Verify**: `zig build ci` → exit 0; deliberately misformat a scratch copy is
NOT needed — trust the step wiring; `zig build --list-steps 2>/dev/null || zig build -h`
shows the `ci` step.

### Step 6: Final gates

**Verify**: `zig build ci` → exit 0 (this now subsumes the other three);
`git diff --stat` touches only the five in-scope files.

## Test plan

No new tests — this plan is docs + one build step. The existing suite is the
regression net proving zero behavior change: `zig build test` must pass
identically before and after. The one "test" of the new step is that
`zig build ci` exits 0 and its three dependencies each ran (visible in the
build output).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -rn "not yet honored" src/` → no matches
- [ ] `grep -n "lossless only at present\|no color cache yet" src/root.zig` → no matches
- [ ] `grep -c "zig fetch" README.MD` ≥ 1 and the README names `zig build check` or `zig build ci`
- [ ] `grep -n "zig build ci\|zig build check" AGENTS.md` ≥ 1 match
- [ ] `zig build ci` exits 0
- [ ] `zig build test` exits 0 (no behavior change)
- [ ] `git status` shows only the five in-scope files modified (plus `plans/README.md`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt doesn't match the live file (drift — someone may
  have fixed a subset already; reconcile what remains before proceeding).
- A knob's actual behavior contradicts this plan's description of it (e.g.
  `method` is NOT consumed at `src/encode.zig:280`) — the plan's ground truth
  is then wrong; report rather than document a guess.
- `addFmt` does not exist on Zig 0.16.0 AND the `addSystemCommand` fallback
  also fails (report the error; the maintainer may prefer to skip the fmt leg).
- Fixing a doc appears to require a code change.

## Maintenance notes

- The root cause of this drift: options were scaffolded (inert) in one slice
  and wired in later slices, and the wiring slices didn't update the scaffold
  comments. Reviewers of future scaffold-then-wire slices should check the
  scaffold's doc comments in the wiring PR.
- `zig build ci` and `.github/workflows/ci.yml` must stay in sync — if CI
  gains a gate, add it to the `ci` step in the same PR.
- Deferred: doc comments for the newer public animation-encode API
  (`encodeAnimationFromBuffers`/`encodeAnimationMinimized` docs were verified
  accurate at planning time, no work needed).
