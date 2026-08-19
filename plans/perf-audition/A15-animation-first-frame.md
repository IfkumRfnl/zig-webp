# A15 — Animation first-frame-only decode

**Verdict: `already-on-master`.** Independently recovered and verified from
worktree `01a01971-2556-7351-8e1e-b6c80a2b1eb5` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, libwebp/libwebpdemux 1.5.0, 3 warmups + 15
medians.

Across four setup-dominated 32×24 lossless animations, creating a decoder,
decoding frame 0, and destroying it totals **30,586 ns** in Zig versus
**72,192 ns** in C: **0.424×**. Individual ratios are 0.339×, 0.487×, 0.409×,
and 0.480×, so the protocol's ≤0.50 early stop applies.

No production change. Full-animation control is unchanged at 70,804 ns. The
claim is narrow: across all ten animation fixtures, first-frame Zig/C is
1.261×, because larger/lossy content dominates setup.

All ten decoded frame-0 RGBA canvases matched libwebp byte-for-byte.
`zig fmt --check .`, `zig build test`, and `zig build ci` passed.
