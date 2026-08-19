# A14 — All-skip lossy frames skip loop filter

**Verdict: `not-worthy`.** Independently recovered and verified at `a2b7f81`,
Zig 0.16.0, ReleaseFast, quality 75/method 0, three independent 15-sample
medians.

True all-skip 512² is **5.068601 ms** Zig versus **2.829562 ms** C
(**1.791302×**); 1024² is **19.121300 ms** versus **10.778550 ms**
(**1.774014×**). The ≥0.90 early stop applies. A blanket filter omission is
also unsound: skipped coefficients do not imply absent prediction/B_PRED edges.

No codec change. `dwebp` validation and exact target RGBA pass; `zig build ci`
passes 19/19 steps and 517/517 tests.
