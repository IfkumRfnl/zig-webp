# A02 — Specialist solid-color VP8L emit

**Verdict: `worthy`.** Independently recovered and verified from worktree
`01a01971-2537-73e1-a1aa-6426e8a2d4c9` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, libwebp 1.5.0 preset 0 with `exact=1`.

The isolated 56-line change detects a constant source before generic planning
and directly emits a one-entry color-index transform plus zero-bit
single-symbol index stream. Solid-color geomean Zig/C improves from
**0.584816×** to **0.467937×**; Zig improves **18.82%** versus baseline. The
four outputs are 32/36/36/36 bytes versus C's 34/38/38/38 (aggregate
**0.945946×**).

Seven non-solid controls improve 0.81% by geomean and remain byte-size
identical. Exact own-decoder and `dwebp` validation passed for targets and all
24 corpus artifacts. `zig build ci` passed 19/19 steps and 517/517 tests.

Candidate remains isolated for the post-campaign embed discussion; no source
was copied to `main`.
