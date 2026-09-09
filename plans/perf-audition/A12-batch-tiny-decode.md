# A12 — Batch tiny decode-into

**Verdict: `not-worthy`.** Independently recovered and verified from worktree
`01a01971-2556-7351-8e1e-b692cc42d9a7` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, caller-owned RGBA, 3 warmups + 15 medians.

Fresh baseline over 25 tiny stills is **256,283 ns** Zig versus **368,954 ns**
C (**0.694620×**). A 128 KiB stack-first allocator for ≤4096-pixel calls
reaches **250,469 ns** (**0.678862×**), only 2.27% faster and still above the
0.67 bar. A 256 KiB variant was no better. Large-control regression is 0.73%.

Tiny and large RGBA matched C byte-for-byte; `zig fmt`, `zig build test`, and
`zig build ci` passed 517/517 tests. Do not promote the isolated source change
or add a batch/scratch API: 128 KiB stack and changed allocator observability
are not justified by the narrow gain.
