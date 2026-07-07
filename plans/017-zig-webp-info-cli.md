# Plan 017: Add a `zig-webp-info` CLI — webpinfo-style probe built on `parseWebP`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 4c5572a..HEAD -- build.zig tools/ src/demux.zig src/features.zig src/metadata.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW (new tool file + one build.zig array entry; no library code)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `4c5572a`, 2026-07-07

## Why this matters

`AGENTS.md` names "feature probing speed" and "mux/demux ergonomics" among
the library's chosen competitive dimensions, and the demux layer already
exposes everything a `webpinfo`-equivalent needs (`parseWebP` returns chunk
locations, features, metadata locations, animation info, and frames). Yet
there is no way to *show* any of that from the command line — the ten
existing `zig-webp-*` tools decode pixels or produce reports, none prints
container structure. A small `zig-webp-info` tool dogfoods the probing API
(useful pressure on step-12 API ergonomics), gives contributors a debugging
instrument for malformed corpus files, and is the first user-facing artifact
of the "probing" competitive dimension. This was first recorded as a
direction option in the 2026-06-13 audit and remains unbuilt.

## Current state

- `src/demux.zig:28-49` — `parseWebP` returns `demux.Result`:

  ```zig
  pub const Result = struct {
      gpa: std.mem.Allocator,
      header: container.ContainerHeader,
      file_size_bytes: u64,
      features: features.Summary,
      chunks: []container.ChunkLocation,
      unknown_chunks: []container.ChunkLocation,
      metadata: metadata.RawLocations,
      animation_info: ?animation.Info,
      frames: []animation.Frame,
      pub fn deinit(self: *Result) void { ... }
      pub fn metadataPayloads(self: Result, bytes: []const u8) metadata.RawPayloads { ... }
  };
  ```

- `src/features.zig:24-37` — `Summary`: `file_kind` (simple/extended),
  `format` (?lossy/lossless), `canvas` (Dimensions), `has_alpha`,
  `is_animation`, `metadata` (Presence bools), `chunk_count`, plus optional
  `ChunkLocation`s.
- `src/metadata.zig:11-19` — `Presence`: `color_profile`, `exif`, `xmp`
  bools.
- `container.ChunkLocation` / `ChunkHeader` — inspect `src/container.zig`
  for the exact fields when printing per-chunk FourCC, offset, and payload
  size (a `ChunkLocation` knows its header and offsets; use what's there,
  do not add fields).
- `animation.Info` / `animation.Frame` — inspect `src/animation.zig` for
  loop count, background color, canvas, and per-frame rect/duration/
  dispose/blend fields.
- `tools/cli_common.zig` — shared CLI scaffolding: `Cli.init(process)`,
  `ctx.readInput(path)` (bounded by default `input_bytes_max`),
  `ctx.writeStdout(text)`, `ctx.usageError(usage)` (exits 2).
- `tools/zig-webp-decode.zig` — the structural exemplar (39 lines): `pub fn
  main(init: std.process.Init) !void`, `Cli.init`, argc check +
  `usageError`, `readInput`, work, output. Match this shape exactly.
- `build.zig:36-128` — the `Tool` struct and `tools` array; each entry
  wires an executable, a named run step, and membership in `zig build
  check`. New tools are one array entry.
- Repo conventions: tools import `webp` and `cli_common` modules only; no
  `test` blocks under `tools/` (by observed convention); output text goes
  through `ctx.writeStdout`; usage errors exit 2 (`cli.usage_exit_code`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Compile lib + all tools | `zig build check` | exit 0 |
| Full gate | `zig build ci` | exit 0 |
| Run the new tool | `zig build info -- testdata/libwebp-test-data/<some>.webp` | report on stdout, exit 0 |
| Reference comparison (optional, local) | `webpinfo <same file>` | fields agree |

## Scope

**In scope** (the only files you should modify):

- `tools/zig-webp-info.zig` (create)
- `build.zig` (one `tools` array entry)
- `README.MD` (one sentence listing the tool)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):

- Any `src/` file. If `parseWebP`'s result lacks something you want to
  print, print what exists — API gaps are findings for the step-12 work,
  not changes to smuggle in here. Note them in your report.
- `tools/cli_common.zig` — only touch it if two+ existing tools already
  duplicate the helper you need (they don't, for plain field printing).
- `tools/webp-oracle.sh` — no oracle integration in this plan.

## Git workflow

- Branch: `claude/zig-webp-info-cli` (repo convention: `claude/<slug>`).
- Commit style: single imperative summary line, e.g.
  `Add zig-webp-info: webpinfo-style container probe CLI`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `tools/zig-webp-info.zig`

Usage: `zig-webp-info INPUT.webp` (exactly one argument; else
`ctx.usageError("usage: zig-webp-info INPUT.webp\n")`).

Behavior: read the file (`ctx.readInput`), call `webp.parseWebP(ctx.gpa,
bytes, .{})`, `defer result.deinit()`, and print a plain-text report to
stdout. Build the report with `std.fmt.allocPrint`/an ArrayList writer and
one `ctx.writeStdout` (or several — match cli_common idioms). Output format
(labels one per line, stable order — this exact shape):

```
file: <path>
file_size: <file_size_bytes>
kind: simple|extended
format: lossy|lossless|none
canvas: <width>x<height>
alpha: true|false
animation: true|false
metadata: iccp=<bool> exif=<bool> xmp=<bool>
chunks: <chunk_count>
  <FOURCC> offset=<offset> size=<payload size>   (one line per entry in result.chunks)
unknown_chunks: <len>                             (then same per-line format)
```

For animated files, append:

```
loop_count: <n>
background: #AARRGGBB (or the raw u32 — match what animation.Info stores)
frames: <len>
  frame <i>: rect=<x>,<y> <w>x<h> duration=<ms>ms dispose=<name> blend=<name>
```

Use `@tagName` for enum fields. Take exact field names from
`src/container.zig` / `src/animation.zig` (read them first); if a field in
the sketch doesn't exist under that name, use the real field — the report
shape is the contract, not my guessed field names.

Parse failures: let the error return from `main` (Zig prints the error and
exits nonzero) — consistent with the other tools, which `try` their decode
calls.

**Verify**: `zig fmt tools/zig-webp-info.zig` → exit 0 (file unchanged
after formatting).

### Step 2: Register the tool in `build.zig`

Add to the `tools` array (alphabetical-ish placement near the other
decode-side tools):

```zig
.{
    .name = "zig-webp-info",
    .source = "tools/zig-webp-info.zig",
    .step = "info",
    .description = "Print WebP container structure and features (webpinfo-style)",
    .install = true,
},
```

**Verify**: `zig build check` → exit 0 (the check step now compiles the new
tool).

### Step 3: Exercise it across the corpus shapes

Run against at least: a simple lossless file, a simple lossy file, a
lossy+alpha (VP8X) file, a metadata-bearing file, and an animation
(`testdata/animation/anim_minimized_lossless.webp`). Spot-check fields
against `webpinfo` if available locally (chunk fourCCs, sizes, frame count,
loop count); otherwise against `parseFeatures` expectations from the file
names.

```sh
zig build info -- testdata/animation/anim_minimized_lossless.webp
```

**Verify**: each run exits 0 with a plausible, complete report; the
animation run lists ≥2 frames with sub-canvas rects (that file is the
minimized sample — at least one frame rect is smaller than the canvas).

### Step 4: Docs and index

- `README.MD`: extend the tools sentence (the one mentioning
  `zig-webp-encode`, README.MD:68-69) with `zig-webp-info` and its one-line
  purpose.
- `plans/README.md`: status row.

**Verify**: `zig build ci` → exit 0; `git status` → only the four in-scope
files.

## Test plan

No `test` blocks (repo convention: tools are compile-gated by `zig build
check` and exercised via oracle scripts/manual runs; the 2026-07-04 audit
explicitly deprioritized CLI behavioral tests). Step 3's five corpus runs
are the acceptance exercise; paste one full animation report into the PR/
handoff description.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `tools/zig-webp-info.zig` exists; `zig build check` exits 0.
- [ ] `zig build info -- testdata/animation/anim_minimized_lossless.webp`
      exits 0 and prints `animation: true`, a `frames:` count ≥ 2, and
      per-frame lines.
- [ ] `zig build info` with no args exits 2 with a usage line on stderr.
- [ ] `zig build ci` exits 0.
- [ ] Only the four in-scope files are modified/created (`git status`).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- `demux.Result` / `features.Summary` / `animation.Info` lack a field the
  report needs and you are tempted to modify `src/` — print what exists,
  note the gap, and if the gap guts the tool's purpose (e.g. chunks carry no
  offsets at all), stop and report instead.
- The `std.process.Init`-style `main` signature in the exemplar tool no
  longer matches the Zig version in use (toolchain drift).

## Maintenance notes

- If step-12 API work (plan 012/013 era) reshapes `DemuxResult`, this tool
  is the first consumer to update — it doubles as an ergonomics probe;
  friction encountered here is direct input to the step-12 stabilization.
- A future `--json` flag would make the tool scriptable for oracle
  comparisons against `webpinfo`; deferred — the plain format above is the
  v1 contract, so append, don't reshuffle, if fields are added.
