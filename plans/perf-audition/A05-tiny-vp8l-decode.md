# A05 — Tiny VP8L decode setup

**Verdict: `already-on-master`.** Verified at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, libwebp 1.5.0, caller-owned RGBA output, 3
warmups + 15 medians.

Across 18 tiny fixtures (six official 16×16 vectors plus generated
solid/checker/gradient/noise at 8×8, 16×16, and 32×32), summed medians are
**121,600 ns** Zig versus **277,365 ns** C: **0.438×**, triggering the ≤0.50
early stop. The 512×512 control is near parity at **0.980×**.

No production change. All 25 measured inputs decoded successfully through both
in-memory caller-output adapters; generated streams came from
`cwebp -lossless -exact`.
