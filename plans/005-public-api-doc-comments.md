# Plan 005: Document the public API surface in src/root.zig

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1aa7670..HEAD -- src/root.zig`
> If `src/root.zig` changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 003 (the option-field doc comments there are referenced here; execute 003 first to avoid edit collisions in spirit — different files, soft dependency only)
- **Category**: docs
- **Planned at**: commit `1aa7670`, 2026-06-13

## Why this matters

`src/root.zig` is the package's entire public surface: ~40 module re-exports,
~60 type aliases, and 8 entry-point functions — and the only doc comment in
the file is the one-line module header. Editor hover, `zig std`-style doc
generation, and first-time readers all get nothing. The library is close to
its first genuinely usable milestone (still-lossless decode is complete and
oracle-locked), so the cost of an undocumented surface is about to be paid by
real adopters. This plan adds `///` doc comments to the entry-point functions
and the high-traffic aliases, and a module-level orientation comment that
tells a newcomer which five names matter.

## Current state

- `src/root.zig:1` — module doc is a single line:
  `//! Public module surface for zig-webp.`
- `src/root.zig:107-153` — the 8 public functions, all undocumented:
  `errorCategory`, `isWebP`, `parseHeader`, `parseChunkHeader`,
  `parseFeatures`, `parseWebP`, `encodeStatic`, `decodeStatic`. Each is a
  one-line delegation, e.g.:

```zig
// src/root.zig:147-153
pub fn decodeStatic(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: DecoderOptions,
) Error!image.OwnedBuffer {
    return decode.decodeStatic(gpa, bytes, decode_options);
}
```

- Behavior facts to encode in the comments (verified at planning time —
  re-verify against the live code while writing):
  - `decodeStatic` (`src/decode.zig:17-30`): decodes a complete WebP file
    to an owned pixel buffer; currently still-lossless (VP8L) only — lossy
    inputs fail with `error.UnsupportedImageFormat`, animations with
    `error.UnsupportedAnimationDecode`. Allocation is budgeted against
    `DecoderOptions.limits.allocation_bytes_max`. Caller frees via
    `OwnedBuffer.deinit()`.
  - `parseWebP` (`src/demux.zig:75`): strict RIFF/WebP demux of a complete
    buffer; returns chunk locations/features; caller calls
    `Result.deinit()`. Does not decode pixels.
  - `parseFeatures` (`src/demux.zig:142`): like `parseWebP` but returns
    only the by-value `FeatureSummary` (dimensions, format, alpha,
    animation, metadata presence) — feature probing without pixel decode.
  - `encodeStatic` (`src/mux.zig:35`): muxes an already-encoded VP8/VP8L
    bitstream (`StaticImage`) into a canonical WebP file; it does NOT
    encode pixels (encoders are future work).
  - `isWebP`/`parseHeader`/`parseChunkHeader` (`src/container.zig`):
    cheap, allocation-free container checks.
  - `errorCategory` (`src/errors.zig`): maps any `Error` to its coarse
    `ErrorCategory` for callers that branch on failure class.
- Convention: doc comments in this repo are full sentences, wrapped near 80
  columns, factual about scope limits — see `src/alpha.zig:104-106` and
  `src/limits.zig:1` for the voice to match. `zig fmt` validates doc-comment
  placement.

## Commands you will need

| Purpose | Command | Expected on success |
|-----------|--------------------------|---------------------|
| Format | `zig fmt .` | exit 0 |
| Tests (includes `refAllDecls` compile check of root) | `zig build test` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/root.zig`

**Out of scope** (do NOT touch):
- Doc comments inside the implementation modules (many already have them;
  improving them is not this plan).
- Adding/removing/renaming any export — zero API change. If an alias looks
  wrong or dead while you work, note it in your report; do not remove it.
- README/PLAN/PROGRESS (plan 003 owns prose docs).

## Git workflow

- Branch: `claude/root-api-docs`
- Single imperative commit, e.g. `Document the public API surface in root.zig`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Expand the module-level doc comment

Replace the single `//!` line at `src/root.zig:1` with an orientation block
(keep `//!` style):

```zig
//! Public module surface for zig-webp, a zero-dependency WebP codec.
//!
//! Most callers need only a handful of names:
//! - `decodeStatic` — decode a complete WebP file to pixels
//!   (still lossless only at present; see PLAN.MD step 5 for lossy).
//! - `parseFeatures` — probe dimensions/format/alpha/animation/metadata
//!   without decoding pixels.
//! - `parseWebP` — strict RIFF demux to chunk locations.
//! - `encodeStatic` — mux an existing VP8/VP8L bitstream into a WebP file.
//! - `ResourceLimits` / `DecoderOptions` — bound untrusted-input handling.
//!
//! The `vp8_*` and `vp8l_*` exports expose codec internals for tooling,
//! tests, and advanced callers; their APIs are less stable than the
//! functions above.
```

**Verify**: `zig build test` → exit 0.

### Step 2: Document the 8 entry-point functions

Add `///` comments above each function at `src/root.zig:107-153`, using the
behavior facts from "Current state". Required content per function (wording
may be adjusted to match repo voice, facts may not):

- `errorCategory`: one line — coarse failure class for an `Error`.
- `isWebP`: one line — cheap signature check, no allocation, no validation
  beyond the RIFF/WEBP magic.
- `parseHeader` / `parseChunkHeader`: one line each — bounded header
  parses of a complete buffer slice.
- `parseFeatures`: 2-3 lines — feature probe without pixel decode; strict
  container validation; allocation bounded by `DemuxOptions.limits`.
- `parseWebP`: 2-3 lines — strict demux; caller owns `Result.deinit()`;
  rejects malformed ordering/duplicate chunks.
- `encodeStatic`: 2-3 lines — muxes an already-encoded bitstream; does not
  encode pixels; returns caller-owned bytes.
- `decodeStatic`: 3-5 lines — the current still-lossless-only scope, the
  two unsupported-format errors, allocation budgeting via options, and
  `OwnedBuffer.deinit()` ownership. State the scope as "currently", so the
  comment ages gracefully when lossy lands.

**Verify**: `zig fmt --check .` → exit 0 and `zig build test` → exit 0.

### Step 3: Document the high-traffic aliases

Add one-line `///` comments to these aliases only (the rest inherit docs
from their source declarations): `DecoderOptions`, `EncoderOptions`,
`ResourceLimits`, `ImageBuffer`, `Dimensions`, `FeatureSummary`,
`DemuxResult`, `StaticImage`, `MetadataPayloads`, `Error`, `ErrorCategory`.
Example:

```zig
/// Decode-time options: resource limits and output pixel format.
pub const DecoderOptions = options.DecoderOptions;
```

For `EncoderOptions`, mirror plan 003's framing: forward-looking, not yet
consumed by any encode path.

**Verify**: `zig fmt --check .` → exit 0 and `zig build test` → exit 0.

## Test plan

No new tests. The existing `test "root public declarations compile"`
(`src/root.zig:165-168`, `refAllDecls`) plus `zig fmt --check` are the
gates — doc comments in Zig are syntax-checked, so a malformed comment
fails the build.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "^///" src/root.zig` returns >= 19 (8 functions + 11 aliases)
- [ ] `grep -c "^//!" src/root.zig` returns >= 10 (module orientation block)
- [ ] `zig build test` exits 0
- [ ] `zig fmt --check .` exits 0
- [ ] `git diff --stat` touches only `src/root.zig` (+ `plans/README.md`)
- [ ] No `pub` declaration added, removed, or renamed:
      `git diff src/root.zig | grep "^[+-]pub" | wc -l` returns 0
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A behavior fact in "Current state" no longer matches the code (e.g.
  `decodeStatic` has gained lossy support since planning) — re-derive that
  comment from the live implementation; if you cannot verify a claim by
  reading the implementation, leave that function undocumented and report
  it rather than guessing.
- `zig fmt` rejects a doc-comment placement you cannot resolve in two
  attempts.

## Maintenance notes

- Doc comments that state current scope ("currently still-lossless only")
  must be updated by the slice that changes the scope — the step 5
  lossy-wiring PR should grep root.zig for "currently".
- Reviewers: check the facts, not the prose — every claimed error value
  and ownership rule must be visible in the delegated-to implementation.
- Deferred: doc comments deeper in `src/**` modules, and any generated-docs
  build step (`zig build docs`) — worth considering once the API stabilizes
  (PLAN.MD step 12).
