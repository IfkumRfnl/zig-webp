# A18 — Solid-color VP8L decode fill

**Verdict: `already-on-master`.** Independently recovered and verified at
`a2b7f81`, Zig 0.16.0, ReleaseFast, caller-owned RGBA, libwebp 1.5.0.

The named optimization already exists as the `constantLiteral` + `@memset`
path. Across nine solid/trivial-Huffman streams (1,408,080 pixels), the
conservative aggregate is **342,396 ns** Zig versus **2,066,754 ns** C:
**0.165668×**. The slowest individual ratio is 0.229750×. The complex
lossless-color-transform control is near parity at 0.960634×.

All aggregate output bytes match C and `dwebp` exactly. `zig build ci` passes
19/19 steps and 517/517 tests. No production change.
