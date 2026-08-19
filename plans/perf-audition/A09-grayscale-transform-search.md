# A09 — Grayscale skip color-transform search

**Verdict: `not-worthy`.** Verified at `a2b7f81`, Zig 0.16.0, ReleaseFast,
single-threaded, over six grayscale photo/ramp/UI fixtures, 3 warmups + 15
medians, libwebp 1.5.0 preset 0 with `exact=1`.

Target median-time sums are **287,544,208 ns** for Zig and **30,851,189 ns**
for C: **9.320×**. Output size favors Zig at 160,338 versus 177,816 bytes
(0.902×), but only the 17×17 toolbar is a time win. Large grayscale cases are
6.96–18.44× slower than C.

No production change. Skipping analysis might repair a Zig weakness, but the
baseline does not confirm a C weakness and exceeds the protocol's ≥0.90 stop
threshold. All Zig/C outputs round-tripped and matched via PAM; no source or
build file changed.
