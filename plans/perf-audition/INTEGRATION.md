# C-win integration candidate

Prepared 2026-08-19 against `origin/main` at `a2b7f81`, Zig 0.16.0, and
libwebp 1.5.0. The maintainer's acceptance threshold is final Zig time below
matched C time. Claims below are deliberately limited to their measured asset
classes.

## Included source changes

| ID | File | Change | Fresh combined Zig/C | Status |
|---|---|---|---:|---|
| A17 | `src/vp8l/inverse_transform.zig` | Use the existing grouped packed-index lookup for every non-empty 1–16-color image. | **0.371183×** | include |
| A02 | `src/vp8l/encoder.zig` | Emit constant VP8L streams directly without generic planning or token buffers. | **0.494619×** geomean | include |
| A07 | `src/alpha.zig` | For non-row-uniform binary masks up to 4,096 pixels, test only unfiltered raw vs VP8L. | **0.460731×** aggregate | include |

The changes touch separate codec paths and apply without conflict. They add no
dependency or public API. The final worktree source diff is 154 insertions and
one deletion across three files.

## Fresh combined-tree evidence

All target adapters were rebuilt from the combined source in ReleaseFast and
used one calling thread, three warmups, 15 timed samples, and median timing.
Tiny cases were batched under the original audition protocol.

- A17 packed-palette decode: 55,791 ns Zig versus 150,306 ns C over four
  files and 68,913 pixels. RGBA was byte-identical to libwebp, SHA-256
  `03d5215b81c546aa75580bb3164ab76e8772ab8db7f45099aa8737ed4e19d094`.
- A02 solid VP8L encode, median of three invocations per row: 50,203/81,114
  ns (100x100), 17,739/44,172 ns (32x32), 195,355/291,036 ns (256x256),
  and 2,721,578/7,586,326 ns (1024x1024), written Zig/C. Geomean ratio is
  0.494619×. Zig sizes are 32/36/36/36 bytes versus C 34/38/38/38 bytes.
- A07 binary-alpha encode, median of three invocations per row: 32,693/93,417
  ns (16x16), 51,308/157,871 ns (32x32), and 129,884/212,942 ns (64x64),
  written Zig/C. Aggregate is 213,885/464,230 ns = 0.460731×; aggregate size
  remains 490/504 bytes.

A 40-case deterministic A07 size sweep caught a 31-to-90-byte regression for
64x64 horizontal stripes in the isolated patch. The integrated version routes
row-uniform masks through the original full filter search. After that
hardening, the sweep's largest remaining increase was two bytes (22 to 24) on
a 64x64 vertical split; the benchmark class stayed on the fast path.

The final A02 and A07 artifacts were accepted by `dwebp` and validated against
the prepared source pixels/alpha. The isolated reports retain the control-class
and baseline measurements.

## Held changes

- A19 allocation-free static demux cursor: both baseline and candidate beat C
  on tiny still decode. In a fresh three-run back-to-back comparison against
  the A17-only decode tree, the candidate did not reproduce a stable
  incremental win (median approximately 1.1% slower). Do not include its
  roughly 180-line parser/decode refactor without stronger evidence.
- A12 stack-first tiny decode: final time was 0.678862× C, but unmodified Zig
  was already 0.694620× C. A 2.27% gain does not justify a 128 KiB per-call
  stack fallback and changed allocator observability.
- A16 full demux scan: current main measured 0.990× C; there is no production
  patch to integrate and the margin is too small for a broad claim.

## Verification

- `zig fmt .`: passed.
- Combined four-patch `zig build ci --summary all`: 19/19 steps and 518/518
  tests passed before A19 was removed.
- Final reduced three-patch `zig build ci --summary all`: 19/19 steps and
  518/518 tests passed.

No source or documentation change has been committed or pushed.
