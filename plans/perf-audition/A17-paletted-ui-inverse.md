# A17 — Paletted UI color-index inverse

**Verdict: `worthy`.** Independently recovered and verified from worktree
`01a01980-e46d-73a2-a74d-6c57c9d3455f` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, caller-owned RGBA, 3 warmups + 15 medians.

The isolated change is one line: lower `grouped_color_indexing_pixel_min` from
100,000 to 1 while leaving green/alpha thresholds unchanged. Across four
pinned 1–16-color VP8L UI streams below 100k pixels, baseline Zig/C is
**1.121536×** and optimized Zig/C is **0.386885×**; Zig improves **65.50%**.

The >16-color palette control regresses only 0.42%. All 275,652 optimized RGBA
bytes match source, C, and `dwebp` exactly. `zig build ci` passes 19/19 steps
and 517/517 tests.

Candidate remains isolated for the post-campaign embed discussion; no source
was copied to `main`.
