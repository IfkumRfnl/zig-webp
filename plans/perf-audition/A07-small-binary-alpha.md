# A07 — Small binary-alpha ALPH fast path

**Verdict: `worthy`, scoped to binary masks ≤4096 pixels.** Independently
recovered and verified from worktree `01a01971-2556-7351-8e1e-b64cfdd00b82`
at `a2b7f81`, Zig 0.16.0, ReleaseFast, single-threaded, libwebp 1.5.0 method 0,
3 warmups + 15 medians.

The isolated 66-line alpha-module change detects small 0/255 masks and tests
only the unfiltered raw-or-VP8L candidate instead of running all four filter
encodes. Target aggregate moves from **1.055830×** C to **0.451476×** C;
after/baseline Zig is **0.427603×** (2.34× faster). Aggregate size is
**490/504 bytes (0.972222× C)**, and every final target file is byte-identical
to baseline.

Non-binary control regression is 3.63%; binary-above-cutoff control improves
within noise. Exact alpha, `dwebp`, and `webpinfo` checks pass. `zig build ci`
passes 19/19 steps and 518/518 tests.

## Integration hardening

A broader 40-case deterministic size sweep found that the isolated shortcut
could grow a 64x64 horizontal-stripe ALPH payload from 31 to 90 bytes because
horizontal filtering collapses uniform rows. The integrated version keeps the
original full filter search when every row is uniform. The rerun's largest
remaining size increase was two bytes (22 to 24) on a 64x64 vertical split,
while the three target rows remained on the fast path and measured 0.460731× C
in aggregate.
