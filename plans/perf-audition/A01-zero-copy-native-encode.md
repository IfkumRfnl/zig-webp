# A01 — Zero-copy encode from packed native pixels

**Verdict: `already-on-master`.** Verified from recovered worktree
`01a01971-2536-7e43-9be7-52d8b2ca7f01` at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, 3 warmups + 15 medians, libwebp 1.5.0 preset 0
with `exact=1`.

On the two tiny import-dominated BGRA cases, current Zig totals **51,702 ns**
versus C's **136,058 ns** (**0.380×**) and 258 versus 236 aggregate bytes
(**1.093×**). Individual ratios are 0.365× for the 17×17 toolbar and 0.393×
for the 32×32 alpha icon, triggering the protocol's ≤0.50 early stop.

No production change. A borrow path would apply only to aligned, tight-stride
BGRA on little-endian hosts; the public `[]u8` does not promise `u32`
alignment, and alpha still needs a scan. Larger cases are dominated by codec
behavior, not import-copy tax.

Verification: rebuilt benchmark hash matched the recovered binary; internal
exact round-trips, five `dwebp` PAM pixel comparisons, `zig fmt .`, and
`zig build test` passed.
