# A10 — Identical-row copy tokens

**Verdict: `already-on-master`.** Verified at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, 3 warmups + 15 medians, libwebp 1.5.0 preset 0
with `exact=1`.

The 320×200 repeated-bars fixture measures **397,424 ns** Zig versus
**804,014 ns** C (**0.494×**), 88 versus 13,668 bytes. The 64×64 repeated-row
icon measures **34,224 ns** versus **83,320 ns** (**0.411×**), 104 versus 222
bytes. Both trigger the ≤0.50 early stop.

No specialist tokenizer was added: current palette/LZ77 handling already
captures the class. Both outputs round-tripped through Zig and libwebp, their
PAM pixels matched byte-for-byte, and all 24 recovered UI-control rows report
roundtrip/validity success.
