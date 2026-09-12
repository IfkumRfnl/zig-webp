# A16 — Demux/chunk scan vs WebPDemux

**Verdict: `already-on-master` (narrow).** Verified at `a2b7f81`, Zig 0.16.0 ReleaseFast
versus libwebpdemux 1.5.0 `-O3`, single-threaded, 3 warmups + 15 medians.

Across 141 in-tree files (19,453,834 bytes), full demux and field consumption
took **18,135 ns** per pass in Zig versus **18,327 ns** in C: **0.990×**.
Both accepted 141/141 files. The four-file control favors Zig at 0.557×, but
the declared broad target exceeds the protocol's ≥0.90 early-stop threshold.

No production change. Under the maintainer's final threshold of Zig faster
than matched C, current main already passes by 1.0%; the small margin does not
support a broad demux-superiority claim. Only the recovered `.zig-cache`
harness was adjusted to the Zig 0.16 clock API.
