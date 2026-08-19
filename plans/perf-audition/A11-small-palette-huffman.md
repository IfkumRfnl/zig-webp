# A11 — Small-palette direct Huffman

**Verdict: `not-worthy`.** Verified at `a2b7f81`, Zig 0.16.0, ReleaseFast,
single-threaded, over 13 generated/real 1/2/4/16-color files, 3 warmups + 15
medians, libwebp 1.5.0 preset 0 with `exact=1`.

Target median-time sums are **2,341,492 ns** for Zig and **2,068,618 ns** for
C (**1.132×**). Output size is **1.082×** C (3,756 versus 3,470 bytes). Zig
wins the tiny/real cases, but every generated 256×256 and 320×180 fixture is
1.18–1.47× slower.

No production change. The declared class misses the ≥0.90 early-stop gate;
larger inputs expose a Zig weakness rather than a generic-Huffman weakness in
C. All 26 Zig/C output rows record exact roundtrip and validity success.
