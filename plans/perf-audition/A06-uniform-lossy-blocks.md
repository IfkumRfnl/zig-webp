# A06 — Uniform-block lossy method-0 skip

**Verdict: `not-worthy`.** Independently recovered and verified from worktree
`01a01971-254a-7e21-8d16-c82d9d519602` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, quality 75/method 0.

Baseline solid+uniform-macrotile Zig/C is **1.795110×**. The isolated VP8
encoder shortcut reuses transform/quant/reconstruction for uniform blocks and
improves Zig **30.55%**, but final Zig/C is still **1.246785×**, far outside
the 0.67 bar. Controls improve/noise-neutral at 0.988602× summed.

All four Zig outputs are byte-identical before/after; `dwebp`, quality checks,
`zig build test`, and `zig build ci` pass. Do not promote the 123-line isolated
source change: C remains faster and the macroblock-tile output is 1.992× C's
size at slightly lower luma quality.
