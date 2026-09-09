# A04 — Feature probe vs libwebp

**Verdict: `not-worthy`.** Verified at `a2b7f81`, Zig 0.16.0, ReleaseFast,
single-threaded, over 141 hot in-memory files (19,453,834 bytes), 3 warmups +
15 medians.

Zig `parseFeatures` took **41,288 ns** for the set. libwebp took **6,171 ns**
for `WebPGetInfo` and **5,911 ns** for `WebPGetFeatures`: Zig/C is **6.690×**
and **6.985×**, respectively. Zig's summary is richer (metadata presence,
chunk count, locations), but this is the opposite of a measured C weakness.

No production change. An allocation-free Zig cursor could repair our own API,
but it does not qualify for this C-weakness campaign. The docs-only worktree
left all `.zig` and build files untouched; its unmodified test run passed.
