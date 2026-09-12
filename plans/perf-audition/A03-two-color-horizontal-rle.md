# A03 — Two-color horizontal RLE

**Verdict: `not-worthy`.** Independently recovered and verified from worktree
`01a01971-2537-73e1-a1aa-64381ed526ff` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, 3 warmups + 15 medians, libwebp 1.5.0 preset 0
with `exact=1`.

Baseline target Zig/C geomean was **1.065621**. The repaired candidate retained
previous-row matches and added distance-1 horizontal runs only when longer; it
improved Zig by **2.74%**, but final Zig/C was still **1.049984**, far outside
the 0.67 bar. Aggregate size passed at **0.912890×** C. The suspended pure-RLE
form was worse: 5,060 bytes, **1.489×** C, because it discarded row matches.

Control passes (1.000687 geomean, 1.030682 summed after/baseline). `zig build
ci` passed 518/518 tests; own-decoder and `dwebp` pixels matched all targets.
Do not promote the isolated 116-line source change.
